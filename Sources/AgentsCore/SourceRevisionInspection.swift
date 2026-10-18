import Foundation

extension SourceCache {
  /// Resolves selection intent without fetching, creating a cache or refreshing an index.
  /// Full object IDs must resolve to commits through cached objects or advertised refs.
  package func inspectRevision(_ source: SourceDeclaration) throws -> SourceRevision {
    let id = try source.identity(environment: store.environment)
    try source.requirement?.validate()
    guard source.kind != .wellKnown else {
      throw CoreError.invalidSource("well-known sources have no Git revisions")
    }
    if source.kind == .local {
      let root = source.localURL(environment: store.environment)
      func git(_ arguments: [String]) throws -> String {
        try ProcessRunner.run(
          "/usr/bin/env", arguments: ["git", "--no-optional-locks", "-C", root.path] + arguments
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let tags = try git(["tag", "--list"]).split(separator: "\n").map(String.init)
      let ref = try SourceReference(requirement: source.requirement, tags: tags)
      return try SourceRevision(
        revision: git(["rev-parse", "--verify", ref.name + "^{commit}"]), version: ref.version)
    }
    func cachedCommit(_ object: String) throws -> String? {
      let mirror = mirrorURL(sourceID: id)
      try validatePath(mirror)
      guard FileManager.default.fileExists(atPath: mirror.path) else { return nil }
      return try? ProcessRunner.run(
        "/usr/bin/env",
        arguments: [
          "git", "--no-optional-locks", "-C", mirror.path, "rev-parse", "--verify",
          object + "^{commit}",
        ]
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if case .revision(let object) = source.requirement, Self.isObjectID(object),
      let commit = try cachedCommit(object)
    {
      return SourceRevision(revision: commit)
    }
    let output = try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "--no-optional-locks", "ls-remote", "--", source.gitURL]
    ).stdout
    var refs: [String: String] = [:]
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2, Self.isObjectID(String(parts[0])) else { continue }
      refs[String(parts[1])] = String(parts[0])
    }
    let tags = refs.keys.filter { $0.hasPrefix("refs/tags/") && !$0.hasSuffix("^{}") }
      .map { String($0.dropFirst("refs/tags/".count)) }
    let ref = try SourceReference(requirement: source.requirement, tags: tags)
    if Self.isObjectID(ref.name) {
      let tag = refs.keys.sorted().first {
        $0.hasPrefix("refs/tags/") && !$0.hasSuffix("^{}") && refs[$0] == ref.name
      }
      let peeled = tag.flatMap { refs[$0 + "^{}"] } ?? ref.name
      if peeled != ref.name, let commit = try cachedCommit(peeled) {
        return SourceRevision(revision: commit)
      }
      // A peeled tag may still name a tree or blob. Branch heads establish commit identity.
      if refs.contains(where: { $0.key.hasPrefix("refs/heads/") && $0.value == peeled }) {
        return SourceRevision(revision: peeled)
      }
      throw CoreError.notFound(
        "source object cannot be resolved to a commit without fetching: \(ref.name)")
    }
    // Follow Git's ref disambiguation order, peeling annotated tags to their target commit.
    for name in [ref.name, "refs/" + ref.name, "refs/tags/" + ref.name, "refs/heads/" + ref.name] {
      if let revision = refs[name + "^{}"] ?? refs[name] {
        return SourceRevision(revision: revision, version: ref.version)
      }
    }
    throw CoreError.notFound("source reference cannot be resolved without fetching: \(ref.name)")
  }

  private static func isObjectID(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
  }
}
