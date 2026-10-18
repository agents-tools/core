import Foundation

extension SourceCache {
  /// Resolves selection intent without fetching, creating a cache or refreshing an index.
  /// Remote revision expressions must be advertised refs or full immutable object IDs.
  package func inspectRevision(_ source: SourceDeclaration) throws -> SourceRevision {
    _ = try source.identity(environment: store.environment)
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
    if case .revision(let revision) = source.requirement, Self.isObjectID(revision) {
      // An immutable pin cannot advance; checking availability would require fetching objects.
      return SourceRevision(revision: revision)
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
