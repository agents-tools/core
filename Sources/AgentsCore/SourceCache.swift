import Foundation

/// A resolved commit, independent of other items from the same source.
package struct SourceRevision: Equatable, Sendable {
  package var revision: String
  package var version: String?

  package init(revision: String, version: String? = nil) {
    self.revision = revision
    self.version = version
  }
}

/// Scope-owned bare mirrors and immutable content shared by skills and instructions.
/// Content publication and pruning require the scope writer lock.
package struct SourceCache {
  package let store: StateStore

  private let checkpoint: (String) throws -> Void

  package init(store: StateStore, checkpoint: @escaping (String) throws -> Void = { _ in }) {
    self.store = store
    self.checkpoint = checkpoint
  }

  package func mirrorURL(sourceID: String) -> URL {
    store.cacheDirectory.appendingPathComponent("mirrors/\(key(sourceID)).git")
  }

  package func materializedURL(sourceID: String, revision: String) -> URL {
    store.cacheDirectory.appendingPathComponent(
      "materialized/\(key(sourceID))/\(revision)", isDirectory: true)
  }

  package func artifactURL(digest: String) throws -> URL {
    try StateValidation.digest(digest)
    let url = store.cacheDirectory.appendingPathComponent("artifacts/\(digest.dropFirst(7))")
    try validatePath(url, directory: false)
    return url
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
    } else if let selected = tags.last {
      ref = "refs/tags/" + selected.0
      version = selected.1.description
    } else {
      ref = "HEAD"
    }
    let revision = try git(mirror, ["rev-parse", "--verify", ref + "^{commit}"])
    return SourceRevision(revision: revision, version: version)
  }

  package func materialize(sourceID: String, source: LockedSource, revision: String) throws -> URL {
    guard revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
    else {
      throw CoreError.invalidState("materialization requires an exact commit")
    }
    try validatePath(materializedURL(sourceID: sourceID, revision: revision))
    try validatePath(store.cacheDirectory.appendingPathComponent("locks"))
    return try FileLock.withLock(
      at: store.cacheDirectory.appendingPathComponent("locks/\(key(sourceID))-\(revision).lock")
    ) {
      let destination = materializedURL(sourceID: sourceID, revision: revision)
      if FileManager.default.fileExists(atPath: destination.path) { return destination }
      let mirror = try pinnedMirror(sourceID: sourceID, source: source, revision: revision)
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.prepare(destination) { work in
        try extract(revision: revision, mirror: mirror, root: work)
      }
      try transaction.commit()
      return destination
    }
  }

  /// Inspection extracts to disposable storage; only applied operations retain materializations.
  package func withSnapshot<T>(
    sourceID: String, source: LockedSource, revision: String, _ body: (URL) throws -> T
  ) throws -> T {
    let mirror = try pinnedMirror(sourceID: sourceID, source: source, revision: revision)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-snapshot-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(extract(revision: revision, mirror: mirror, root: root))
  }

  private func pinnedMirror(sourceID: String, source: LockedSource, revision: String) throws -> URL
  {
    guard revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
    else {
      throw CoreError.invalidState("materialization requires an exact commit")
    }
    try validatePath(mirrorURL(sourceID: sourceID))
    var mirror = mirrorURL(sourceID: sourceID)
    if (try? git(mirror, ["cat-file", "-e", revision + "^{commit}"])) == nil {
      mirror = try fetch(declaration(sourceID: sourceID, source: source), id: sourceID)
    }
    guard try git(mirror, ["rev-parse", "--verify", revision + "^{commit}"]) == revision else {
      throw CoreError.invalidState("locked commit is unavailable")
    }
    return mirror
  }

  private func extract(revision: String, mirror: URL, root: URL) throws -> URL {
    let archive = root.appendingPathComponent("tree.tar")
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    _ = try git(mirror, ["archive", "--format=tar", "--output=" + archive.path, revision])
    try ProcessRunner.run("/usr/bin/env", arguments: ["tar", "-xf", archive.path, "-C", tree.path])
    try validateTree(tree)
    return tree
  }

  package func storeArtifact(_ data: Data, digest: String) throws -> URL {
    guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
      throw CoreError.invalidState("artifact digest mismatch")
    }
    let url = try artifactURL(digest: digest)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == data else {
        throw CoreError.invalidState("cached artifact digest mismatch")
      }
    } else {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(url, content: nil, data: data, expectedHash: digest)
      try transaction.commit()
    }
    return url
  }

  /// Publishes a verified expansion under the scope lock; interrupted staging is journaled.
  package func materializeArtifact(_ directory: URL, digest: String, hash: String) throws -> URL {
    try StateValidation.digest(digest)
    try StateValidation.digest(hash)
    let destination = store.cacheDirectory.appendingPathComponent(
      "artifact-content/\(digest.dropFirst(7))")
    try validatePath(destination)
    if FileManager.default.fileExists(atPath: destination.path) {
      guard try "sha256:" + FileHash.folderHash(destination) == hash else {
        throw CoreError.invalidState("cached artifact content mismatch")
      }
    } else {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(destination, content: directory, expectedHash: hash)
      try transaction.commit()
    }
    return destination
  }

  /// Retains pins and any cache tree containing a live edit source.
  /// The caller holds the scope lock, including during failure cleanup.
  package func prune(referencedBy lock: ResolvedState, transaction: FileTransaction? = nil) throws {
    guard let scope = try store.openDirectoryIfPresent(), try scope.info("cache") != nil else {
      return
    }
    let cache = try scope.child("cache")
    let transactionToUse = transaction ?? FileTransaction(store: store)
    var paths = Set<String>()
    var digests = Set<String>()
    var edits: [URL] = []
    func retain(source: String, revision: String?, artifact: LockedArtifact?) {
      if let revision {
        paths.insert(materializedURL(sourceID: source, revision: revision).standardizedFileURL.path)
      }
      if let artifact {
        digests.insert(String(artifact.digest.dropFirst(7)))
        for file in artifact.files ?? [] { digests.insert(String(file.digest.dropFirst(7))) }
      }
    }
    for skill in lock.skills.values {
      retain(source: skill.source, revision: skill.revision, artifact: skill.artifact)
      if skill.installs.values.contains(.edit), let source = lock.sources[skill.source] {
        let local = try declaration(sourceID: skill.source, source: source).localURL(
          environment: store.environment)
        edits.append(
          try PathSafety.resolvedChild(base: local, subpath: skill.path ?? ".")
            .resolvingSymlinksInPath())
      }
    }
    for section in lock.instructions.sections + lock.instructions.chatgpt.values.flatMap(\.sections)
    {
      retain(source: section.source, revision: section.revision, artifact: section.artifact)
    }
    func edited(_ url: URL) -> Bool {
      edits.contains { PathSafety.isContained($0, in: url) }
    }
    if try cache.info("materialized") != nil {
      let materialized = try cache.child("materialized")
      for name in try materialized.names() {
        let source = try materialized.child(name)
        let pins = try source.names()
        var unused: [String] = []
        for pin in pins {
          let tree = try source.child(pin)
          if !paths.contains(tree.url.path) && !edited(tree.url) { unused.append(pin) }
        }
        if unused.count == pins.count {
          try transactionToUse.remove(name, from: materialized)
        } else {
          for pin in unused { try transactionToUse.remove(pin, from: source) }
        }
      }
    }
    for container in ["artifacts", "artifact-content"] where try cache.info(container) != nil {
      let directory = try cache.child(container)
      for name in try directory.names() {
        let url = directory.url.appendingPathComponent(name)
        if container == "artifact-content" {
          _ = try directory.child(name)
        } else if (try directory.info(name)?.st_mode ?? 0) & 0o170000 != 0o100000 {
          throw CoreError.unsafePath("unexpected artifact cache entry")
        }
        if !digests.contains(name) && !edited(url) {
          try transactionToUse.remove(name, from: directory)
        }
      }
    }
    if transaction == nil { try transactionToUse.commit() }
  }

  package func validatePath(_ url: URL, directory: Bool = true) throws {
    guard var parent = try store.openDirectoryIfPresent() else { return }
    let relative = PathSafety.relativePath(url.path, to: store.directory.path)
    let parts = try PathSafety.sanitizeSubpath(relative).split(separator: "/").map(String.init)
    for (index, name) in parts.enumerated() {
      guard let info = try parent.info(name) else { return }
      if index == parts.count - 1 && !directory {
        guard info.st_mode & 0o170000 == 0o100000 else {
          throw CoreError.unsafePath("unexpected cache file")
        }
      } else {
        parent = try parent.child(name)
      }
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
    try validatePath(mirrorURL(sourceID: id))
    try validatePath(store.cacheDirectory.appendingPathComponent("locks"))
    return try FileLock.withLock(
      at: store.cacheDirectory.appendingPathComponent("locks/\(key(id)).lock")
    ) {
      try fetchMirror(source, id: id)
    }
  }

  private func fetchMirror(_ source: SourceDeclaration, id: String) throws -> URL {
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
