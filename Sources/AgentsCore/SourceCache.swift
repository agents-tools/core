import Foundation

/// A resolved commit, independent of other items from the same source.
public struct SourceRevision: Equatable, Sendable {
  public var revision: String
  public var version: String?

  public init(revision: String, version: String? = nil) {
    self.revision = revision
    self.version = version
  }
}

/// Scope-owned bare mirrors and immutable content shared by skills and instructions.
package struct SourceCache {
  package let store: StateStore

  package init(store: StateStore) { self.store = store }

  package func mirrorURL(sourceID: String) -> URL {
    store.cacheDirectory.appendingPathComponent("mirrors/\(key(sourceID)).git")
  }

  package func materializedURL(sourceID: String, revision: String) -> URL {
    store.cacheDirectory.appendingPathComponent(
      "materialized/\(key(sourceID))/\(revision)", isDirectory: true)
  }

  package func artifactURL(digest: String) throws -> URL {
    try StateValidation.digest(digest)
    return store.cacheDirectory.appendingPathComponent("artifacts/\(digest.dropFirst(7))")
  }

  /// Fetching only changes the bare mirror. No installed or materialized tree moves.
  package func resolve(_ source: SourceDeclaration) throws -> SourceRevision {
    let id = try source.identity(environment: store.environment)
    let mirror = try fetch(source, id: id)
    try source.requirement?.validate()
    let tags = try git(mirror, ["tag", "--list"]).split(separator: "\n").compactMap {
      raw -> (String, SemanticVersion)? in
      let name = String(raw)
      return SemanticVersion(name).map { (name, $0) }
    }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    var ref: String
    var version: String?
    if let requirement = source.requirement {
      switch requirement.kind {
      case "branch": ref = "refs/heads/" + requirement.value
      case "revision": ref = requirement.value
      default:
        guard let lower = SemanticVersion(requirement.value) else {
          throw CoreError.invalidSource("invalid semantic version")
        }
        let candidates: [(String, SemanticVersion)]
        if requirement.kind == "exact" {
          candidates = tags.filter { $0.1.description == lower.description }
        } else {
          let upper: SemanticVersion
          switch requirement.kind {
          case "from": upper = SemanticVersion(major: lower.major + 1, minor: 0, patch: 0)
          case "minor":
            upper = SemanticVersion(major: lower.major, minor: lower.minor + 1, patch: 0)
          default:
            guard let bound = requirement.upperBound, let parsed = SemanticVersion(bound) else {
              throw CoreError.invalidSource("missing version upper bound")
            }
            upper = parsed
          }
          candidates = tags.filter { $0.1.isInRange(from: lower, to: upper) }
        }
        guard let selected = candidates.last else {
          throw CoreError.notFound("no tag matches source requirement")
        }
        ref = "refs/tags/" + selected.0
        version = selected.1.description
      }
    } else if let selected = tags.last(where: { $0.1.prerelease.isEmpty }) {
      ref = "refs/tags/" + selected.0
      version = selected.1.description
    } else if !tags.isEmpty {
      guard let selected = tags.last else { throw CoreError.notFound("version tag") }
      ref = "refs/tags/" + selected.0
      version = selected.1.description
    } else {
      ref = "HEAD"
    }
    let revision = try git(mirror, ["rev-parse", "--verify", ref + "^{commit}"])
    return SourceRevision(revision: revision, version: version)
  }

  package func materialize(sourceID: String, source: LockedSource, revision: String) throws -> URL {
    let destination = materializedURL(sourceID: sourceID, revision: revision)
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    return try withSnapshot(sourceID: sourceID, source: source, revision: revision) { snapshot in
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: snapshot, to: destination)
      return destination
    }
  }

  /// Inspection extracts to disposable storage; only applied operations retain materializations.
  package func withSnapshot<T>(
    sourceID: String, source: LockedSource, revision: String, _ body: (URL) throws -> T
  ) throws -> T {
    guard revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
    else {
      throw CoreError.invalidState("materialization requires an exact commit")
    }
    var mirror = mirrorURL(sourceID: sourceID)
    if (try? git(mirror, ["cat-file", "-e", revision + "^{commit}"])) == nil {
      mirror = try fetch(declaration(sourceID: sourceID, source: source), id: sourceID)
    }
    guard try git(mirror, ["rev-parse", "--verify", revision + "^{commit}"]) == revision else {
      throw CoreError.invalidState("locked commit is unavailable")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-snapshot-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("tree.tar")
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    _ = try git(mirror, ["archive", "--format=tar", "--output=" + archive.path, revision])
    try ProcessRunner.run("/usr/bin/env", arguments: ["tar", "-xf", archive.path, "-C", tree.path])
    try validateTree(tree)
    return try body(tree)
  }

  package func storeArtifact(_ data: Data, digest: String) throws -> URL {
    guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
      throw CoreError.invalidState("artifact digest mismatch")
    }
    let url = try artifactURL(digest: digest)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == data else {
        throw CoreError.invalidState("cached artifact digest mismatch")
      }
    } else {
      try data.write(to: url, options: .atomic)
    }
    return url
  }

  /// Keep every pin referenced by either kind, including named prompts.
  package func prune(referencedBy lock: ResolvedState) throws {
    var paths = Set<String>()
    var digests = Set<String>()
    func retain(source: String, revision: String?, artifact: LockedArtifact?) {
      if let revision {
        paths.insert(
          materializedURL(sourceID: source, revision: revision).resolvingSymlinksInPath().path)
      }
      if let artifact {
        digests.insert(String(artifact.digest.dropFirst(7)))
        for file in artifact.files ?? [] { digests.insert(String(file.digest.dropFirst(7))) }
      }
    }
    for skill in lock.skills.values {
      retain(source: skill.source, revision: skill.revision, artifact: skill.artifact)
    }
    for section in lock.instructions.sections + lock.instructions.chatgpt.values.flatMap(\.sections)
    {
      retain(source: section.source, revision: section.revision, artifact: section.artifact)
    }
    let materialized = store.cacheDirectory.appendingPathComponent("materialized")
    for source in children(materialized) {
      for pin in children(source) where !paths.contains(pin.resolvingSymlinksInPath().path) {
        try FileManager.default.removeItem(at: pin)
      }
      if children(source).isEmpty { try FileManager.default.removeItem(at: source) }
    }
    for artifact in children(store.cacheDirectory.appendingPathComponent("artifacts"))
    where !digests.contains(artifact.lastPathComponent) {
      try FileManager.default.removeItem(at: artifact)
    }
    let content = store.cacheDirectory.appendingPathComponent("artifact-content")
    for artifact in children(content) where !digests.contains(artifact.lastPathComponent) {
      try FileManager.default.removeItem(at: artifact)
    }
  }

  package func declaration(sourceID: String, source: LockedSource) throws -> SourceDeclaration {
    let location: String
    switch source.kind {
    case .git:
      guard let url = source.url else { throw CoreError.invalidState("missing Git URL") }
      location = url
    case .local: location = String(sourceID.dropFirst("local:".count))
    case .wellKnown: location = sourceID
    }
    return SourceDeclaration(
      kind: source.kind, location: location, requirement: source.requirement, path: source.path)
  }

  private func fetch(_ source: SourceDeclaration, id: String) throws -> URL {
    guard source.kind != .wellKnown else {
      throw CoreError.invalidSource("well-known sources have no Git mirror")
    }
    let url =
      source.kind == .local ? source.localURL(environment: store.environment).path : source.gitURL
    let mirror = mirrorURL(sourceID: id)
    try FileManager.default.createDirectory(
      at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: mirror.path) {
      _ = try git(
        mirror,
        ["fetch", "--prune", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])
    } else {
      let staging = mirror.appendingPathExtension("staging-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: staging) }
      try ProcessRunner.run(
        "/usr/bin/env",
        arguments: ["git", "clone", "--mirror", "--no-hardlinks", "--", url, staging.path])
      try FileManager.default.moveItem(at: staging, to: mirror)
    }
    // A remote can change its default branch after the initial clone.
    let head = try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "ls-remote", "--symref", url, "HEAD"]
    ).stdout
    if let line = head.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }),
      let reference = line.split(separator: "\t").first
    {
      _ = try git(mirror, ["symbolic-ref", "HEAD", String(reference.dropFirst(5))])
    }
    return mirror
  }

  private func git(_ repository: URL, _ arguments: [String]) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repository.path] + arguments)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func key(_ sourceID: String) -> String {
    String(PathSafety.sanitizeName(sourceID).prefix(60)) + "-"
      + FileHash.sha256Hex(data: Data(sourceID.utf8))
  }

  private func children(_ directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
  }

  private func validateTree(_ tree: URL) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: tree, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        guard
          PathSafety.isContained(url.resolvingSymlinksInPath(), in: tree.resolvingSymlinksInPath())
        else {
          throw CoreError.unsafePath("source symlink escapes committed tree")
        }
      }
    }
  }
}
