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

/// Exclusively owned bare mirrors and immutable content shared by skills and instructions.
/// Mirror access holds a per-source lock inherited by Git children.
/// Content publication, watch retention and pruning also require the scope writer lock.
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
    let tags = try git(
      mirror, ["tag", "--list"], operation: .listTags, source: source.location
    ).split(separator: "\n").map(String.init)
    let ref = try SourceReference(requirement: source.requirement, tags: tags)
    let revision = try git(
      mirror, ["rev-parse", "--verify", ref.name + "^{commit}"],
      operation: .resolveRevision(revision: ref.name), source: source.location)
    return SourceRevision(revision: revision, version: ref.version)
  }

  /// Subscriptions follow branches even when installations select a tag or version range.
  func watchRevision(_ source: SourceDeclaration, revision: String? = nil) throws -> String {
    let id = try source.identity(environment: store.environment)
    let mirror = try fetch(source, id: id)
    let ref: String
    if let revision {
      guard !revision.isEmpty, !revision.hasPrefix("-"), !revision.contains("\0") else {
        throw CoreError.invalidSource("invalid watch revision")
      }
      ref = revision
    } else if case .branch(let branch) = source.requirement {
      ref = "refs/heads/" + branch
    } else {
      ref = "HEAD"
    }
    return try git(
      mirror, ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
      operation: .resolveRevision(revision: ref), source: source.location)
  }

  func watchCommitCount(sourceID: String, source: String, seen: String, current: String) throws
    -> Int
  {
    let count = try git(
      mirrorURL(sourceID: sourceID), ["rev-list", "--count", seen + ".." + current],
      operation: .countCommits, source: source)
    guard let result = Int(count) else { throw CoreError.invalidState("invalid Git commit count") }
    return result
  }

  /// Publish objects and their retention ref durably before the scope journal can name them.
  func retainWatchRevision(sourceID: String, source: String, revision: String) throws {
    let url = mirrorURL(sourceID: sourceID)
    try withMirrorLock(at: url) { descriptor in
      try beginWatchReferenceUpdate()
      let mirror = try DirectoryHandle(at: url)
      let objects = try mirror.child("objects")
      if try objects.info("info") != nil {
        let info = try objects.child("info")
        if try info.info("alternates") != nil, try !info.read("alternates").isEmpty {
          throw CoreError.invalidState("watch requires self-contained mirror objects")
        }
      }
      // Explicit barriers cover pre-existing objects as well as newly fetched objects.
      func syncObjects(_ directory: DirectoryHandle) throws {
        for name in try directory.names() {
          if try (directory.info(name)?.st_mode ?? 0) & 0o170000 == 0o040000 {
            try syncObjects(directory.child(name))
          } else {
            try directory.syncFile(name)
          }
        }
        try directory.sync()
      }
      try syncObjects(objects)
      try checkpoint("watch.objects.synced")
      let refs = try mirror.child("refs")
      if try refs.info("agents-watch") == nil { try refs.makeDirectory("agents-watch") }
      let retained = try refs.child("agents-watch")
      _ = try git(
        url, ["update-ref", "--no-deref", "refs/agents-watch/" + revision, revision],
        operation: .updateReference, source: source, lock: descriptor)
      try checkpoint("watch.ref.updated")
      // Updating an already packed ref to the same commit can leave it packed.
      if try retained.info(revision) != nil { try retained.syncFile(revision) }
      if try mirror.info("packed-refs") != nil { try mirror.syncFile("packed-refs") }
      try retained.sync()
      try checkpoint("watch.ref.synced")
      try refs.sync()
      try mirror.syncFile("config")
      try mirror.syncFile("HEAD")
      let mirrors = try DirectoryHandle(at: url.deletingLastPathComponent())
      try mirrors.sync()
      try DirectoryHandle(at: store.cacheDirectory).sync()
      try store.openDirectoryIfPresent()?.sync()
      try checkpoint("watch.mirror.synced")
    }
  }

  /// The marker precedes ref preparation or a state change that can release an existing pin.
  func beginWatchReferenceUpdate() throws {
    guard let directory = try store.openDirectoryIfPresent(),
      try directory.info("cache") != nil,
      try directory.child("cache").info("mirrors") != nil
    else { return }
    if try directory.info("watch-refs.pending") == nil {
      try directory.write("watch-refs.pending", data: Data())
    } else {
      guard try directory.read("watch-refs.pending").isEmpty else {
        throw CoreError.invalidState("invalid watch ref cleanup marker")
      }
      try directory.syncFile("watch-refs.pending")
    }
    try checkpoint("watch.references.pending")
  }

  /// Run only after journal recovery or successful commit, while holding the scope lock.
  /// The marker survives interruptions until every deletion and its parent are durable.
  func recoverWatchReferences() throws -> Bool {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    guard try directory.info("transaction.json") == nil,
      try directory.info("transaction.new") == nil
    else { throw CoreError.invalidState("transaction recovery must precede watch ref cleanup") }
    if try directory.info("watch-refs.pending") != nil,
      try !directory.read("watch-refs.pending").isEmpty
    {
      throw CoreError.invalidState("invalid watch ref cleanup marker")
    }
    try recoverMirrorLocks(in: directory)
    guard try directory.info("watch-refs.pending") != nil else { return false }
    let watch = try store.readWatch()
    let resolved = try store.readResolved()
    var sourceLocations: [String: String] = [:]
    for id in watch.sources.keys {
      sourceLocations[key(id) + ".git"] =
        id.hasPrefix("local:") ? String(id.dropFirst("local:".count)) : id
    }
    for (id, source) in resolved.sources where source.kind != .wellKnown {
      sourceLocations[key(id) + ".git"] = try declaration(sourceID: id, source: source).location
    }
    for source in try store.readDeclaration().sources.values where source.kind != .wellKnown {
      let id = try source.identity(environment: store.environment)
      sourceLocations[key(id) + ".git"] = source.location
    }
    var retained: [String: Set<String>] = [:]
    func retain(_ source: String, _ revision: String?) {
      if let revision { retained[key(source) + ".git", default: []].insert(revision) }
    }
    for (source, state) in watch.sources {
      if case .revision(let revision) = state.seen { retain(source, revision) }
    }
    for skill in resolved.skills.values { retain(skill.source, skill.revision) }
    for section in resolved.instructions.sections
      + resolved.instructions.chatgpt.values.flatMap(\.sections)
    {
      retain(section.source, section.revision)
    }
    // Even a manually supplied generation must reach storage before its obsolete pins go away.
    for file in ["agents.watch", "agents.resolved"] where try directory.info(file) != nil {
      try directory.syncFile(file)
    }
    try directory.sync()
    if try directory.info("cache") != nil {
      let cache = try directory.child("cache")
      if try cache.info("mirrors") != nil {
        let mirrors = try cache.child("mirrors")
        for name in try mirrors.names() where name.hasSuffix(".git") {
          try withMirrorLock(at: mirrors.url.appendingPathComponent(name)) { descriptor in
            let mirror = try mirrors.child(name)
            let source = try sourceLocations[name] ?? mirrorSource(mirror.url, lock: descriptor)
            let refs = try mirror.child("refs")
            let owned = try refs.info("agents-watch") == nil ? nil : refs.child("agents-watch")
            if try mirror.info("packed-refs") != nil { try mirror.syncFile("packed-refs") }
            let references = try git(
              mirror.url,
              ["for-each-ref", "--format=%(refname) %(objectname)", "refs/agents-watch/"],
              operation: .listReferences, source: source, lock: descriptor)
            for line in references.split(separator: "\n") {
              let parts = line.split(separator: " ").map(String.init)
              guard parts.count == 2, parts[0] == "refs/agents-watch/" + parts[1],
                parts[1].range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression)
                  != nil
              else { throw CoreError.invalidState("invalid watch retention ref") }
              if retained[name, default: []].contains(parts[1]) { continue }
              if let owned, try owned.info(parts[1]) != nil { _ = try owned.read(parts[1]) }
              _ = try git(
                mirror.url, ["update-ref", "--no-deref", "-d", parts[0], parts[1]],
                operation: .deleteReference, source: source, lock: descriptor
              )
              try checkpoint("watch.references.deleted")
            }
            // A previous attempt may have unlinked the final loose ref or rewritten packed-refs.
            // Flush their parents even when enumeration now finds no obsolete refs.
            if try mirror.info("packed-refs") != nil { try mirror.syncFile("packed-refs") }
            if try refs.info("agents-watch") != nil { try refs.child("agents-watch").sync() }
            try refs.sync()
            try mirror.sync()
            try checkpoint("watch.references.synced")
          }
        }
      }
    }
    try directory.remove("watch-refs.pending")
    try checkpoint("watch.references.cleared")
    return true
  }

  /// Validate each mirror's candidates under its lock before unlinking;
  /// descriptor-relative traversal never follows a symlink outside the owned mirror.
  private func recoverMirrorLocks(in directory: DirectoryHandle) throws {
    guard try directory.info("cache") != nil else { return }
    let cache = try directory.child("cache")
    guard try cache.info("mirrors") != nil else { return }
    let mirrors = try cache.child("mirrors")
    for name in try mirrors.names() where name.hasSuffix(".git") {
      try withMirrorLock(at: mirrors.url.appendingPathComponent(name)) { _ in
        try recoverGitLocks(in: mirrors.child(name), scope: directory)
      }
    }
  }

  private func recoverGitLocks(in mirror: DirectoryHandle, scope directory: DirectoryHandle) throws
  {
    var locks: [(DirectoryHandle, String)] = []
    func inspect(_ parent: DirectoryHandle, isMirrorRoot: Bool = false) throws {
      for name in try parent.names() {
        guard let info = try parent.info(name) else { continue }
        // Packed ref transactions stage new contents separately from their lock file.
        if name.hasSuffix(".lock") || (isMirrorRoot && name == "packed-refs.new") {
          guard info.st_mode & 0o170000 == 0o100000 else {
            throw CoreError.unsafePath("abandoned Git lock or ref staging must be a regular file")
          }
          locks.append((parent, name))
        } else if info.st_mode & 0o170000 == 0o040000 {
          try inspect(parent.child(name))
        }
      }
    }
    try inspect(mirror, isMirrorRoot: true)
    if !locks.isEmpty { try beginWatchReferenceUpdate() }
    guard try directory.info("watch-refs.pending") != nil else { return }
    for (parent, name) in locks {
      try parent.remove(name) { try checkpoint("watch.git-lock.\($0)") }
    }
    // A killed cleanup may have unlinked the last lock before syncing its parent.
    // The pending marker requires these barriers even if no lock remains visible.
    func syncDirectories(_ parent: DirectoryHandle) throws {
      for name in try parent.names() {
        if try (parent.info(name)?.st_mode ?? 0) & 0o170000 == 0o040000 {
          try syncDirectories(parent.child(name))
        }
      }
      try parent.sync()
    }
    try syncDirectories(mirror)
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
        try extract(
          revision: revision, mirror: mirror,
          source: declaration(sourceID: sourceID, source: source).location, root: work)
      }
      try transaction.commit()
      return destination
    }
  }

  /// Inspection extracts to disposable storage; only applied operations retain materializations.
  /// With `cacheSource: false`, existing exact pins are read without mutation;
  /// new mirrors and their locks live in disposable storage.
  package func withResolvedSnapshot<T>(
    _ source: SourceDeclaration, cacheSource: Bool = true,
    _ body: (SourceRevision, URL) throws -> T
  ) throws -> T {
    if !cacheSource {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agents-discovery-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      if case .revision(let object) = source.requirement, Self.isObjectID(object),
        let cached = try withExistingMirror(
          sourceID: source.identity(environment: store.environment),
          { mirror, descriptor -> (SourceRevision, URL)? in
            guard
              let revision = try? git(
                mirror, ["--no-optional-locks", "rev-parse", "--verify", object + "^{commit}"],
                operation: .resolveRevision(revision: object), source: source.location,
                lock: descriptor)
            else { return nil }
            return try (
              SourceRevision(revision: revision),
              extract(
                revision: revision, mirror: mirror, source: source.location, root: root,
                lock: descriptor)
            )
          }) ?? nil
      {
        return try body(cached.0, cached.1)
      }
      var source = source
      if source.kind == .local {
        source.location = source.localURL(environment: store.environment).path
      }
      var environment = store.environment
      environment.projectDirectory = root
      let cache = SourceCache(store: StateStore(scope: .project, environment: environment))
      return try cache.withResolvedSnapshot(source, body)
    }
    let pin = try resolve(source)
    let locked = LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
    return try withSnapshot(
      sourceID: source.identity(environment: store.environment), source: locked,
      revision: pin.revision
    ) { try body(pin, $0) }
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
    return try body(
      extract(
        revision: revision, mirror: mirror,
        source: declaration(sourceID: sourceID, source: source).location, root: root))
  }

  private func pinnedMirror(sourceID: String, source: LockedSource, revision: String) throws -> URL
  {
    guard revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
    else {
      throw CoreError.invalidState("materialization requires an exact commit")
    }
    try validatePath(mirrorURL(sourceID: sourceID))
    var mirror = mirrorURL(sourceID: sourceID)
    let declaration = try declaration(sourceID: sourceID, source: source)
    if (try? git(
      mirror, ["cat-file", "-e", revision + "^{commit}"],
      operation: .resolveRevision(revision: revision), source: declaration.location)) == nil
    {
      mirror = try fetch(declaration, id: sourceID)
    }
    guard
      try git(
        mirror, ["rev-parse", "--verify", revision + "^{commit}"],
        operation: .resolveRevision(revision: revision), source: declaration.location) == revision
    else {
      throw CoreError.invalidState("locked commit is unavailable")
    }
    return mirror
  }

  private func extract(
    revision: String, mirror: URL, source: String, root: URL, lock: Int32? = nil
  ) throws -> URL {
    let archive = root.appendingPathComponent("tree.tar")
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let arguments = [
      "--no-optional-locks", "archive", "--format=tar", "--output=" + archive.path, revision,
    ]
    if let lock {
      _ = try git(
        mirror, arguments, operation: .extractRevision, source: source,
        replacingPaths: [root], lock: lock)
    } else {
      _ = try git(
        mirror, arguments, operation: .extractRevision, source: source,
        replacingPaths: [root])
    }
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
  package func prune(
    referencedBy lock: ResolvedState, watch: WatchState? = nil,
    transaction: FileTransaction? = nil
  ) throws {
    let watch = try watch ?? store.readWatch()
    guard let scope = try store.openDirectoryIfPresent(), try scope.info("cache") != nil else {
      return
    }
    let cache = try scope.child("cache")
    let transactionToUse = transaction ?? FileTransaction(store: store)
    var paths = Set<String>()
    var digests = Set<String>()
    for state in watch.sources.values {
      if case .artifacts(let artifacts) = state.seen {
        digests.formUnion(artifacts.values.map { String($0.dropFirst(7)) })
      }
    }
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
    try withMirrorLock(at: mirrorURL(sourceID: id)) { descriptor in
      try fetchMirror(source, id: id, lock: descriptor)
    }
  }

  private func fetchMirror(_ source: SourceDeclaration, id: String, lock: Int32) throws -> URL {
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
        ["fetch", "--prune", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
        operation: .fetch, source: source.location, lock: lock)
    } else {
      let staging = mirror.appendingPathExtension("staging-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: staging) }
      try ProcessRunner.git(
        Self.gitOptions + ["clone", "--mirror", "--no-local", "--", url, staging.path],
        operation: .clone, source: source.location,
        replacingPaths: [staging, store.cacheDirectory], inheritingLock: lock)
      try FileManager.default.moveItem(at: staging, to: mirror)
    }
    // A remote can change its default branch after the initial clone.
    let head = try ProcessRunner.git(
      ["ls-remote", "--symref", url, "HEAD"], operation: .listRemoteReferences,
      source: source.location, inheritingLock: lock
    ).stdout
    if let line = head.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }),
      let reference = line.split(separator: "\t").first
    {
      _ = try git(
        mirror, ["symbolic-ref", "HEAD", String(reference.dropFirst(5))],
        operation: .updateDefaultBranch, source: source.location, lock: lock)
    }
    return mirror
  }

  private func withMirrorLock<T>(at mirror: URL, _ body: (Int32) throws -> T) throws -> T {
    let locks = store.cacheDirectory.appendingPathComponent("locks")
    try validatePath(locks)
    let lock = locks.appendingPathComponent(
      mirror.deletingPathExtension().lastPathComponent + ".lock")
    return try FileLock.withDescriptor(
      at: lock, checkpoint: { try checkpoint("mirror." + $0) },
      { descriptor in
        try validatePath(mirror)
        return try body(descriptor)
      })
  }

  private func git(
    _ repository: URL, _ arguments: [String], operation: GitError.Operation, source: String,
    replacingPaths paths: [URL] = []
  ) throws -> String {
    try withMirrorLock(at: repository) { descriptor in
      try git(
        repository, arguments, operation: operation, source: source, replacingPaths: paths,
        lock: descriptor)
    }
  }

  func inspectCommit(_ object: String, sourceID: String, source: String) throws -> String? {
    try withExistingMirror(sourceID: sourceID) { mirror, descriptor in
      try git(
        mirror, ["--no-optional-locks", "rev-parse", "--verify", object + "^{commit}"],
        operation: .resolveRevision(revision: object), source: source, lock: descriptor)
    }
  }

  private func withExistingMirror<T>(
    sourceID: String, _ body: (URL, Int32) throws -> T
  ) throws -> T? {
    let mirror = mirrorURL(sourceID: sourceID)
    try validatePath(mirror)
    guard FileManager.default.fileExists(atPath: mirror.path) else { return nil }
    let locks = store.cacheDirectory.appendingPathComponent("locks")
    try validatePath(locks)
    let lock = locks.appendingPathComponent(
      mirror.deletingPathExtension().lastPathComponent + ".lock")
    return try FileLock.withExistingDescriptor(at: lock) { descriptor in
      try validatePath(mirror)
      return try body(mirror, descriptor)
    }
  }

  private func git(
    _ repository: URL, _ arguments: [String], operation: GitError.Operation, source: String,
    replacingPaths paths: [URL] = [], lock: Int32
  ) throws -> String {
    let mirror = try DirectoryHandle(at: repository)
    guard let config = try mirror.info("config"), config.st_mode & 0o170000 == 0o100000 else {
      throw CoreError.unsafePath("mirror configuration must be a regular file")
    }
    return try ProcessRunner.git(
      Self.gitOptions + ["-C", repository.path] + arguments, operation: operation, source: source,
      replacingPaths: paths + [repository, store.cacheDirectory], inheritingLock: lock
    )
    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func mirrorSource(_ mirror: URL, lock: Int32) throws -> String {
    // Orphaned mirrors outlive their declarations; the clone's origin retains the source location.
    let source: String
    do {
      source = try git(
        mirror, ["config", "--get", "remote.origin.url"],
        operation: .readOrigin, source: "the cached source", lock: lock)
    } catch let error as GitError where error.exitCode == 1 && error.stderr.isEmpty {
      throw CoreError.invalidState("cached Git source has no origin URL")
    }
    guard !source.isEmpty else {
      throw CoreError.invalidState("cached Git source has no origin URL")
    }
    return source
  }

  private static let gitOptions = [
    "-c", "core.fsync=objects,reference,pack-metadata", "-c", "core.fsyncMethod=fsync",
    "-c", "gc.auto=0", "-c", "maintenance.auto=false",
  ]

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
