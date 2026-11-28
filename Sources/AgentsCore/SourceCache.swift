import Foundation

/// A resolved commit, independent of other items from the same source.
package struct SourceRevision: Equatable, Sendable {
  package var revision: String
  package var version: String?
  package var archive: SourceArchiveEvidence?

  package init(
    revision: String, version: String? = nil, archive: SourceArchiveEvidence? = nil
  ) {
    self.revision = revision
    self.version = version
    self.archive = archive
  }
}

/// Exclusively owned bare mirrors and immutable content shared by skills and instructions.
/// Mirror access holds a per-source lock inherited by Git children.
/// Content publication, watch retention and pruning also require the scope writer lock.
package struct SourceCache {
  package let store: StateStore

  private let sourcePolicy: EffectiveSourcePolicy
  private let requireRecordedTransport: Bool
  private let checkpoint: (String) throws -> Void
  private let acquisitions: GitAcquisitionCaptures?

  package init(
    store: StateStore, sourcePolicy: EffectiveSourcePolicy = .init(),
    requireRecordedTransport: Bool = false, acquisitions: GitAcquisitionCaptures? = nil,
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) {
    self.store = store
    self.sourcePolicy = sourcePolicy
    self.requireRecordedTransport = requireRecordedTransport || sourcePolicy.isConfigured
    self.checkpoint = checkpoint
    self.acquisitions = acquisitions
  }

  func route(_ source: SourceDeclaration) throws -> SourceRoute {
    try SourceRoute(source, environment: store.environment, policy: sourcePolicy)
  }

  package func requireGit(_ source: SourceDeclaration) throws {
    try route(source).requireGitObjects()
  }

  package func mirrorURL(sourceID: String) -> URL {
    store.cacheDirectory.appendingPathComponent("mirrors/\(key(sourceID)).git")
  }

  package func materializedURL(sourceID: String, revision: String) -> URL {
    store.cacheDirectory.appendingPathComponent(
      "materialized/\(key(sourceID))/\(revision)", isDirectory: true)
  }

  package func existingPinnedTree(sourceID: String, revision: String) throws -> URL? {
    guard Self.isObjectID(revision) else {
      throw CoreError.invalidState("snapshot requires an exact Git object")
    }
    let tree = materializedURL(sourceID: sourceID, revision: revision)
    try validatePath(tree)
    return FileManager.default.fileExists(atPath: tree.path) ? tree : nil
  }

  /// Proves that replayed bytes match the exact regular Git blob, even if archive attributes
  /// or a materialized tree changed the spelling or contents presented to the renderer.
  package func withPinnedGitBlobCheck<T>(
    sourceID: String, revision: String,
    _ body: (_ matches: (String, Data, Bool) throws -> Bool) throws -> T
  ) throws -> T {
    guard Self.isObjectID(revision) else {
      throw CoreError.invalidState("producer patch needs an exact Git commit")
    }
    func unavailable() -> CoreError { .notFound("locked producer Git commit " + revision) }
    guard
      let result = try withExistingMirror(
        sourceID: sourceID,
        { mirror, lock in
          let directory = try DirectoryHandle(at: mirror)
          guard let config = try directory.info("config"), config.st_mode & S_IFMT == S_IFREG else {
            throw CoreError.unsafePath("mirror configuration must be a regular file")
          }
          let commit = try ProcessRunner.isolatedGit(
            ["rev-parse", "--verify", revision + "^{commit}"], in: mirror, inheritingLock: lock)
          guard commit.exitCode == 0, commit.stdout == revision + "\n" else { throw unavailable() }
          let result = try body { path, bytes, executable in
            let entry = try ProcessRunner.isolatedGit(
              ["--literal-pathspecs", "ls-tree", "-z", "--full-tree", revision, "--", path],
              in: mirror, inheritingLock: lock)
            guard entry.exitCode == 0 else { throw unavailable() }
            let fields = entry.stdout.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].utf8.elementsEqual((path + "\u{0}").utf8)
            else { return false }
            let metadata = fields[0].split(separator: " ")
            return metadata.count == 3 && metadata[0] == (executable ? "100755" : "100644")
              && metadata[1] == "blob"
              && FileHash.matchesGitBlob(bytes, object: String(metadata[2]))
          }
          guard try DirectoryHandle(at: mirror).objectIdentity == directory.objectIdentity else {
            throw unavailable()
          }
          return result
        })
    else {
      throw unavailable()
    }
    return result
  }

  /// Reads an existing materialization or exports the exact commit from local objects.
  /// The callback receives whether its tree is a durable cache entry or a disposable export.
  package func withOfflineSnapshot<T>(
    sourceID: String, source: LockedSource, revision: String, useMaterializedTree: Bool = true,
    lockedPaths: [String]? = nil,
    _ body: (URL, Bool) throws -> T
  ) throws -> T {
    let declared = try declaration(sourceID: sourceID, source: source)
    try requireGit(declared)
    if useMaterializedTree,
      let tree = try existingPinnedTree(sourceID: sourceID, revision: revision)
    {
      return try body(tree, true)
    }
    let location = declared.location
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-snapshot-" + UUID().uuidString)
    try FileSystem.createDirectory(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    func export(_ repository: URL, lock: Int32?) throws -> URL? {
      let arguments = [
        "--no-optional-locks", "rev-parse", "--quiet", "--verify", revision + "^{commit}",
      ]
      do {
        let result =
          try lockedPaths == nil
          ? ProcessRunner.git(
            Self.gitOptions + ["-C", repository.path] + arguments,
            operation: .resolveRevision(revision: revision), source: location,
            inheritingLock: lock, offline: true)
          : ProcessRunner.isolatedGit(arguments, in: repository, inheritingLock: lock)
        guard result.exitCode == 0,
          result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == revision
        else {
          return nil
        }
      } catch let error as GitError where error.exitCode == 1 && error.stderr.isEmpty {
        return nil
      }
      return try extract(
        revision: revision, mirror: repository, source: location, root: root, lock: lock,
        offline: true, lockedPaths: lockedPaths)
    }
    if let tree = try withExistingMirror(
      sourceID: sourceID,
      { mirror, lock in
        try export(mirror, lock: lock)
      }) ?? nil
    {
      return try body(tree, false)
    }
    if source.kind == .local {
      let repository = URL(fileURLWithPath: location)
      if FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path),
        let tree = try export(repository, lock: nil)
      {
        return try body(tree, false)
      }
    }
    if let acquisition = anonymousAcquisition(declared),
      let pack = try acquisition.exact(revision, offline: true)
    {
      return try withAnonymousTree(acquisition, pack: pack) { try body($0, false) }
    }
    throw CoreError.notFound("cached Git commit \(revision) for \(sourceID)")
  }

  package func artifactURL(digest: String) throws -> URL {
    try StateValidation.digest(digest)
    let url = store.cacheDirectory.appendingPathComponent("artifacts/\(digest.dropFirst(7))")
    try validatePath(url, directory: false)
    return url
  }

  package static func artifactContentLocation(digest: String) throws -> LedgerLocation {
    try StateValidation.digest(digest)
    return .init(
      kind: .registered, root: "state", path: "cache/artifact-content/\(digest.dropFirst(7))")
  }

  package func artifactContentURL(digest: String) throws -> URL {
    let location = try Self.artifactContentLocation(digest: digest)
    let url = try location.resolve(roots: ["state": store.directory])
    try validatePath(url)
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

  /// Captures all advertised refs in an owned mirror. The caller uses a disposable cache.
  func referenceCatalog(
    _ source: SourceDeclaration, spending: (Int) throws -> Void = { _ in }
  ) throws -> SourceCatalog {
    let mirror = try fetch(source, id: source.identity(environment: store.environment))
    let output = try git(
      mirror, ["show-ref", "--head", "--dereference"], operation: .listTags,
      source: source.location)
    var references: [String: String] = [:]
    var tags: [String: String] = [:]
    for line in output.split(separator: "\n") {
      try spending(1)
      let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
      guard fields.count == 2 else { continue }
      references[fields[1]] = fields[0]
    }
    for name in references.keys.sorted()
    where name.hasPrefix("refs/tags/") && !name.hasSuffix("^{}") {
      let commit = references[name + "^{}"] ?? references[name]
      references[name] = commit
      tags[String(name.dropFirst(10))] = commit
    }
    return SourceCatalog(tags: tags, references: references)
  }

  /// Resolves an expression against the already frozen mirror, without fetching new evidence.
  func catalogRevision(_ expression: String, source: SourceDeclaration) throws -> String? {
    try requireGit(source)
    try source.requirement?.validate()
    return try withExistingMirror(sourceID: source.identity(environment: store.environment)) {
      mirror, descriptor in
      do {
        return try git(
          mirror,
          [
            "--no-optional-locks", "rev-parse", "--quiet", "--verify", "--end-of-options",
            expression + "^{commit}",
          ],
          operation: .resolveRevision(revision: expression), source: source.location,
          lock: descriptor)
      } catch let error as GitError where error.exitCode == 1 && error.stderr.isEmpty {
        return nil
      }
    } ?? nil
  }

  /// Acquires a known object in an owned cache, without enumerating or selecting mutable refs.
  func acquireCommit(_ object: String, source: SourceDeclaration) throws -> String {
    guard Self.isObjectID(object) else {
      throw CoreError.invalidSource("expected an exact Git object")
    }
    try requireGit(source)
    if let commit = try catalogRevision(object, source: source) { return commit }
    if let acquisition = anonymousAcquisition(source),
      let pack = try attemptAnonymous({ try acquisition.exact(object) })
    {
      acquisition.remember(pack)
      if acquisitions == nil {
        _ = try importAnonymous(
          pack, from: acquisition,
          sourceID: source.identity(
            environment: store.environment))
      }
      return pack.revision
    }
    let mirror = try fetch(source, id: source.identity(environment: store.environment))
    return try git(
      mirror, ["rev-parse", "--verify", object + "^{commit}"],
      operation: .resolveRevision(revision: object), source: source.location)
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
  /// An existing marker is synced again; only its creation is a checkpoint.
  func beginWatchReferenceUpdate() throws {
    guard let directory = try store.openDirectoryIfPresent(),
      try directory.info("cache") != nil,
      try directory.child("cache").info("mirrors") != nil
    else { return }
    if try directory.info("watch-refs.pending") == nil {
      try directory.write("watch-refs.pending", data: Data())
      try checkpoint("watch.references.pending")
    } else {
      guard try directory.read("watch-refs.pending").isEmpty else {
        throw CoreError.invalidState("invalid watch ref cleanup marker")
      }
      try directory.syncFile("watch-refs.pending")
    }
  }

  /// Run only after journal recovery or successful commit, while holding the scope lock.
  /// The marker survives interruptions until every deletion and its parent are durable.
  func recoverWatchReferences() throws -> Bool {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    guard try !TransactionJournal.isPresent(in: directory) else {
      throw CoreError.invalidState("transaction recovery must precede watch ref cleanup")
    }
    if try directory.info("watch-refs.pending") != nil,
      try !directory.read("watch-refs.pending").isEmpty
    {
      throw CoreError.invalidState("invalid watch ref cleanup marker")
    }
    try recoverMirrorLocks(in: directory)
    guard try directory.info("watch-refs.pending") != nil else { return false }
    let watch = try store.readWatch()
    var references = try store.retentionReferences()
    try references.include(watch: watch)
    let sourceLocations = Dictionary(
      uniqueKeysWithValues: references.sourceLocations.map {
        (key($0.key) + ".git", $0.value)
      })
    var retained: [String: Set<String>] = [:]
    for pin in references.git {
      retained[key(pin.source) + ".git", default: []].insert(pin.revision)
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
        // Checkpoints are numbered by mirror and by deletion within this reconciliation.
        for (ordinal, name) in try mirrors.names().filter({ $0.hasSuffix(".git") }).enumerated() {
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
            var deleted = 0
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
              try checkpoint("watch.references.\(ordinal).\(deleted).deleted")
              deleted += 1
            }
            // A previous attempt may have unlinked the final loose ref or rewritten packed-refs.
            // Flush their parents even when enumeration now finds no obsolete refs.
            if try mirror.info("packed-refs") != nil { try mirror.syncFile("packed-refs") }
            if try refs.info("agents-watch") != nil { try refs.child("agents-watch").sync() }
            try refs.sync()
            try mirror.sync()
            try checkpoint("watch.references.\(ordinal).synced")
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
    for (ordinal, name) in try mirrors.names().filter({ $0.hasSuffix(".git") }).enumerated() {
      try withMirrorLock(at: mirrors.url.appendingPathComponent(name)) { _ in
        try recoverGitLocks(in: mirrors.child(name), ordinal: ordinal, scope: directory)
      }
    }
  }

  /// Checkpoints are numbered by the mirror's ordinal and the lock's position in traversal.
  private func recoverGitLocks(
    in mirror: DirectoryHandle, ordinal: Int, scope directory: DirectoryHandle
  ) throws {
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
    for (index, (parent, name)) in locks.enumerated() {
      try parent.remove(name) {
        try checkpoint("watch.git-lock.\(ordinal).\(index).\($0.step.rawValue)")
      }
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
    try requireGit(declaration(sourceID: sourceID, source: source))
    try validatePath(materializedURL(sourceID: sourceID, revision: revision))
    try validatePath(store.cacheDirectory.appendingPathComponent("locks"))
    return try FileLock.withLock(
      at: store.cacheDirectory.appendingPathComponent("locks/\(key(sourceID))-\(revision).lock")
    ) {
      let destination = materializedURL(sourceID: sourceID, revision: revision)
      if FileManager.default.fileExists(atPath: destination.path) { return destination }
      let mirror = try pinnedMirror(sourceID: sourceID, source: source, revision: revision)
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(
        destination,
        with: .prepared { work in
          try extract(
            revision: revision, mirror: mirror,
            source: declaration(sourceID: sourceID, source: source).location, root: work)
        })
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
    if case .archive = try route(source) {
      return try SourceResolutionSession.withTemporaryRead(
        store: store, sourcePolicy: sourcePolicy, acquisitions: acquisitions
      ) { session in
        guard
          let pin = try session.candidates(for: source, requirements: [source.requirement]).first
        else { throw SourceAccessError.discoveryUnavailable }
        let snapshot = try session.snapshot(source, at: pin)
        return try body(pin, snapshot.root)
      }
    }
    try requireGit(source)
    if let acquisition = anonymousAcquisition(source) {
      let exact: String?
      if case .revision(let object) = source.requirement, Self.isObjectID(object) {
        exact = object
      } else {
        exact = nil
      }
      let borrowed =
        exact.map { object in
          acquisitions?.containsAnonymousCommit(
            source, revision: object, environment: store.environment) == true
        } ?? false
      let scoped = try exact.flatMap { try catalogRevision($0, source: source) }
      if borrowed || scoped == nil,
        let selected = try attemptAnonymous({
          try self.selectAnonymous(source, acquisition: acquisition, exact: exact)
        })
      {
        return try withAnonymousTree(acquisition, pack: selected.pack) { tree in
          acquisition.remember(selected.pack)
          if let (reference, time) = selected.observed {
            acquisition.note(reference, pack: selected.pack, observedAt: time)
          }
          return try body(
            SourceRevision(revision: selected.pack.revision, version: selected.version), tree)
        }
      }
    }
    return try withScopedResolvedSnapshot(source, cacheSource: cacheSource, body)
  }

  func anonymousAcquisition(_ source: SourceDeclaration) -> GitAcquisition? {
    guard (try? requireGit(source)) != nil else { return nil }
    return GitAcquisition(source, environment: store.environment, captures: acquisitions)
  }

  /// Failed anonymous attempts fall back to the established scoped transport. Cancellation
  /// and policy failures are handled outside this optional acquisition.
  func attemptAnonymous<T>(_ acquire: () throws -> T?) throws -> T? {
    do { return try acquire() } catch {
      try Task.checkCancellation()
      return nil
    }
  }

  private func selectAnonymous(
    _ source: SourceDeclaration, acquisition: GitAcquisition, exact: String?
  ) throws -> (pack: GitAcquisition.Pack, version: String?, observed: (String, Date)?)? {
    if let exact {
      guard let pack = try acquisition.exact(exact) else { return nil }
      return (pack, nil, nil)
    }
    let discovered = try acquisition.discover()
    let requirement = try SourceReference(
      requirement: source.requirement, tags: Array(discovered.catalog.tags.keys))
    guard
      let (reference, object) = GitAcquisition.reference(
        requirement.name, in: discovered.catalog),
      let pack = try acquisition.exact(object), pack.revision == object
    else { return nil }
    return (pack, requirement.version, (reference, discovered.time))
  }

  private func withAnonymousTree<T>(
    _ acquisition: GitAcquisition, pack: GitAcquisition.Pack, _ body: (URL) throws -> T
  ) throws -> T {
    try acquisition.withVerifiedRepository(pack) { repository, _ in
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agents-snapshot-" + UUID().uuidString)
      try FileSystem.createDirectory(at: root)
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("tree.tar")
      try acquisition.archive(pack.revision, repository: repository, to: archive)
      return try body(unpack(archive, at: root))
    }
  }

  private func withScopedResolvedSnapshot<T>(
    _ source: SourceDeclaration, cacheSource: Bool, _ body: (SourceRevision, URL) throws -> T
  ) throws -> T {
    if !cacheSource {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agents-discovery-" + UUID().uuidString)
      try FileSystem.createDirectory(at: root)
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
      let cache = SourceCache(
        store: StateStore(scope: .project, environment: environment), sourcePolicy: sourcePolicy,
        requireRecordedTransport: requireRecordedTransport)
      return try cache.withScopedResolvedSnapshot(source, cacheSource: true, body)
    }
    if case .revision(let object) = source.requirement, Self.isObjectID(object) {
      let id = try source.identity(environment: store.environment)
      var mirror = mirrorURL(sourceID: id)
      // An immutable object may be an annotated tag. Peel it without selecting mutable refs.
      if (try? git(
        mirror, ["cat-file", "-e", object + "^{commit}"],
        operation: .resolveRevision(revision: object), source: source.location)) == nil
      {
        mirror = try fetch(source, id: id)
      }
      let revision = try git(
        mirror, ["rev-parse", "--verify", object + "^{commit}"],
        operation: .resolveRevision(revision: object), source: source.location)
      let locked = LockedSource(
        kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
        requirement: .revision(object), path: source.path)
      return try withSnapshot(sourceID: id, source: locked, revision: revision) {
        try body(SourceRevision(revision: revision), $0)
      }
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
    try requireGit(declaration(sourceID: sourceID, source: source))
    let mirror = try pinnedMirror(sourceID: sourceID, source: source, revision: revision)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-snapshot-" + UUID().uuidString)
    try FileSystem.createDirectory(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(
      extract(
        revision: revision, mirror: mirror,
        source: declaration(sourceID: sourceID, source: source).location, root: root))
  }

  private func pinnedMirror(
    sourceID: String, source: LockedSource, revision: String, offline: Bool = false
  ) throws -> URL {
    guard revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
    else {
      throw CoreError.invalidState("materialization requires an exact commit")
    }
    try validatePath(mirrorURL(sourceID: sourceID))
    var mirror = mirrorURL(sourceID: sourceID)
    let declaration = try declaration(sourceID: sourceID, source: source)
    try requireGit(declaration)
    if (try? git(
      mirror, ["cat-file", "-e", revision + "^{commit}"],
      operation: .resolveRevision(revision: revision), source: declaration.location,
      offline: offline)) == nil
    {
      if let acquisition = anonymousAcquisition(declaration),
        let pack = try attemptAnonymous({ try acquisition.exact(revision, offline: offline) }),
        pack.revision == revision
      {
        mirror = try importAnonymous(pack, from: acquisition, sourceID: sourceID)
        acquisition.remember(pack)
      } else if offline && declaration.kind != .local {
        throw CoreError.notFound("cached Git commit \(revision) for \(sourceID)")
      } else {
        mirror = try fetch(declaration, id: sourceID)
      }
    }
    guard
      try git(
        mirror, ["rev-parse", "--verify", revision + "^{commit}"],
        operation: .resolveRevision(revision: revision), source: declaration.location,
        offline: offline) == revision
    else {
      throw CoreError.invalidState("locked commit is unavailable")
    }
    return mirror
  }

  /// Copies a verified pack into the scope's own object database while holding its mirror lock.
  /// The scope never opens a Git config from the shared cache and owns every copied byte.
  private func importAnonymous(
    _ pack: GitAcquisition.Pack, from acquisition: GitAcquisition, sourceID: String
  ) throws -> URL {
    let mirror = mirrorURL(sourceID: sourceID)
    return try withMirrorLock(at: mirror) { _ in
      try acquisition.withVerifiedRepository(pack) { repository, stem in
        let parent = try DirectoryHandle(at: mirror.deletingLastPathComponent(), create: true)
        let name = mirror.lastPathComponent
        let existing = try parent.directory(name)
        let directory: DirectoryHandle
        if let existing {
          directory = existing
        } else {
          let staging = name + ".staging-" + UUID().uuidString
          let provisioned = try parent.makeDirectory(staging)
          let identity = try provisioned.objectIdentity
          defer { try? parent.remove(staging, identity: identity) }
          try acquisition.initializeMirror(at: provisioned.url, object: pack.revision)
          try installPack(repository, stem: stem, into: provisioned)
          try parent.move(staging, to: parent, named: name, mode: .exclusive)
          return mirror
        }
        try installPack(repository, stem: stem, into: directory)
        return mirror
      }
    }
  }

  private func installPack(_ repository: URL, stem: String, into mirror: DirectoryHandle) throws {
    let source = try DirectoryHandle(at: repository).child("objects").child("pack")
    let objects = try mirror.child("objects")
    if let info = try objects.directory("info"),
      try info.info("alternates") != nil || info.info("http-alternates") != nil
    {
      throw CoreError.invalidState("scope Git objects must be self-contained")
    }
    let destination = try objects.child("pack")
    for suffix in [".pack", ".idx"] {
      let name = stem + suffix
      let bytes = try source.read(name, maximumBytes: GitAcquisition.packLimit)
      if let previous = try destination.info(name) {
        guard previous.st_nlink == 1,
          try destination.read(
            name, matching: previous, maximumBytes: GitAcquisition.packLimit) == bytes
        else {
          throw CoreError.invalidState("scope Git pack differs from the verified acquisition")
        }
      } else {
        let staging = ".agents-pack-" + UUID().uuidString
        try destination.write(staging, data: bytes)
        defer { try? destination.remove(staging) }
        try destination.move(staging, to: destination, named: name, mode: .exclusive)
      }
    }
    try destination.sync()
    try objects.sync()
    try mirror.sync()
  }

  private func extract(
    revision: String, mirror: URL, source: String, root: URL, lock: Int32? = nil,
    offline: Bool = false, lockedPaths: [String]? = nil
  ) throws -> URL {
    let archive = root.appendingPathComponent("tree.tar")
    let arguments = [
      "--no-optional-locks", "archive", "--format=tar", "--output=" + archive.path, revision,
    ]
    if let lockedPaths {
      let selection = lockedPaths.contains(".") ? [] : ["--"] + lockedPaths
      let result = try ProcessRunner.isolatedGit(
        ["--literal-pathspecs"] + arguments + selection, in: mirror, inheritingLock: lock)
      guard result.exitCode == 0 else { throw CoreError.notFound("locked producer Git paths") }
    } else if offline {
      _ = try ProcessRunner.git(
        Self.gitOptions + ["-C", mirror.path] + arguments,
        operation: .extractRevision, source: source, replacingPaths: [root, mirror],
        inheritingLock: lock, offline: true)
    } else if let lock {
      _ = try git(
        mirror, arguments, operation: .extractRevision, source: source,
        replacingPaths: [root], lock: lock)
    } else {
      _ = try git(
        mirror, arguments, operation: .extractRevision, source: source,
        replacingPaths: [root])
    }
    return try unpack(archive, at: root)
  }

  private func unpack(_ archive: URL, at root: URL) throws -> URL {
    let tree = root.appendingPathComponent("tree")
    try FileSystem.createDirectory(at: tree)
    try ProcessRunner.unpackGitArchive(archive, into: tree)
    try validateTree(tree)
    return tree
  }

  package func storeArtifact(_ data: Data, digest: String) throws -> URL {
    guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
      throw CoreError.invalidState("artifact digest mismatch")
    }
    let url = try artifactURL(digest: digest)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try FileSystem.read(at: url) == data else {
        throw CoreError.invalidState("cached artifact digest mismatch")
      }
    } else {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(url, with: .data(data), expectedHash: digest)
      try transaction.commit()
    }
    return url
  }

  /// Publishes a verified expansion under the scope lock; interrupted staging is journaled.
  package func materializeArtifact(_ directory: URL, digest: String, hash: String) throws -> URL {
    try StateValidation.digest(hash)
    let destination = try artifactContentURL(digest: digest)
    if FileManager.default.fileExists(atPath: destination.path) {
      guard try "sha256:" + FileHash.folderHash(destination) == hash else {
        throw CoreError.invalidState("cached artifact content mismatch")
      }
    } else {
      let transaction = FileTransaction(store: store, checkpoint: checkpoint)
      try transaction.replace(destination, with: .copy(directory), expectedHash: hash)
      try transaction.commit()
    }
    return destination
  }

  /// Makes exact Git objects durable before the caller's journal can reference the new ledger.
  /// A failed preparation leaves a cleanup marker; reconciliation keeps the committed closure.
  package func retain(references: RetentionReferences, offline: Bool = false) throws {
    for (ordinal, pin) in references.git.sorted(by: {
      ($0.source, $0.revision) < ($1.source, $1.revision)
    }).enumerated() {
      guard let location = references.sourceLocations[pin.source], Self.isObjectID(pin.revision)
      else {
        throw CoreError.invalidState("missing exact retention coordinates")
      }
      let kind: SourceKind = pin.source.hasPrefix("local:") ? .local : .git
      let source = LockedSource(
        kind: kind, url: kind == .git ? location : nil,
        requirement: .revision(pin.revision))
      _ = try pinnedMirror(
        sourceID: pin.source, source: source, revision: pin.revision, offline: offline)
      let retained = SourceCache(
        store: store,
        checkpoint: { point in
          try checkpoint("retention.\(ordinal)." + point)
        })
      try retained.retainWatchRevision(
        sourceID: pin.source, source: location, revision: pin.revision)
    }
  }

  package func withArchivePublication<T>(
    previous: RetentionReferences, next: RetentionReferences, offline: Bool,
    _ body: () throws -> T
  ) throws -> T {
    try PrivateSourceRecovery(environment: store.environment).withPublication(
      store: store, previous: previous.archives, next: next.archives, captures: acquisitions,
      policy: sourcePolicy, offline: offline, checkpoint: checkpoint, body)
  }

  package static func privateWorkspace(prefix: String) throws -> URL {
    try PrivateSourceRecovery.makeWorkspace(prefix: prefix).url
  }

  package func requireArchivePublicationAccess() throws {
    try PrivateSourceRecovery(environment: store.environment).requirePublicationAccess()
  }

  package func archiveTree(transport: String, evidence: SourceArchiveEvidence) -> URL {
    PrivateSourceRecovery(environment: store.environment).treeURL(
      .init(transport: transport, archive: evidence))
  }

  /// The caller stages pruning with its state generation and commits only after validation.
  package func prune(references: RetentionReferences, transaction: FileTransaction) throws {
    guard let scope = try store.openDirectoryIfPresent(), try scope.info("cache") != nil else {
      return
    }
    guard try !TransactionJournal.isPresent(in: scope) else {
      throw CoreError.invalidState("transaction recovery must precede pruning")
    }
    let cache = try scope.child("cache")
    let transactionToUse = transaction
    let paths = Set(
      references.git.map {
        materializedURL(sourceID: $0.source, revision: $0.revision).standardizedFileURL.path
      })
    let digests = Set(references.artifacts.map { String($0.dropFirst(7)) })
    let edits = references.live
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
        let retainsDescendant = paths.contains {
          PathSafety.isContained(URL(fileURLWithPath: $0), in: source.url)
        }
        if unused.count == pins.count && !retainsDescendant {
          try transactionToUse.delete(materialized.url.appendingPathComponent(name))
        } else {
          for pin in unused { try transactionToUse.delete(source.url.appendingPathComponent(pin)) }
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
          try transactionToUse.delete(url)
        }
      }
    }
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
    try requireGit(source)
    return try withMirrorLock(at: mirrorURL(sourceID: id)) { descriptor in
      try fetchMirror(source, id: id, lock: descriptor)
    }
  }

  private func fetchMirror(_ source: SourceDeclaration, id: String, lock: Int32) throws -> URL {
    let selected = try route(source)
    try selected.requireGitObjects()
    if let managed = try ManagedSourceGit.select(selected, environment: store.environment) {
      return try fetchManaged(managed, id: id, lock: lock)
    }
    guard source.kind != .wellKnown else {
      throw CoreError.invalidSource("well-known sources have no Git mirror")
    }
    let url =
      source.kind == .local ? source.localURL(environment: store.environment).path : source.gitURL
    let mirror = mirrorURL(sourceID: id)
    let exists = FileManager.default.fileExists(atPath: mirror.path)
    let transportOptions = try recordedGitOptions(
      url, context: exists ? ["-C", mirror.path] : [], lock: lock)
    try FileSystem.createDirectory(at: mirror.deletingLastPathComponent())
    if exists {
      _ = try git(
        mirror,
        transportOptions + [
          "fetch", "--prune", "--", requireRecordedTransport ? url : "origin",
          "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*",
        ],
        operation: .fetch, source: source.location, lock: lock)
    } else {
      let staging = mirror.appendingPathExtension("staging-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: staging) }
      try ProcessRunner.git(
        Self.gitOptions + transportOptions + [
          "clone", "--mirror", "--no-local", "--", url, staging.path,
        ],
        operation: .clone, source: source.location,
        replacingPaths: [staging, store.cacheDirectory], inheritingLock: lock)
      try FileSystem.withAccessErrors(at: mirror) {
        try FileManager.default.moveItem(at: staging, to: mirror)
      }
    }
    // A remote can change its default branch after the initial clone.
    let head = try ProcessRunner.git(
      transportOptions + (requireRecordedTransport && exists ? ["-C", mirror.path] : [])
        + ["ls-remote", "--symref", "--", url, "HEAD"], operation: .listRemoteReferences,
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

  func recordedGitOptions(_ url: String, context: [String] = [], lock: Int32? = nil)
    throws -> [String]
  {
    guard requireRecordedTransport else { return [] }
    // An admitted direct transport cannot be changed by a Git URL rewrite.
    let rewritten = try ProcessRunner.git(
      context + ["ls-remote", "--get-url", "--", url], operation: .readOrigin,
      source: "admitted source", inheritingLock: lock
    ).stdout.trimmingCharacters(in: .newlines)
    guard rewritten.utf8.elementsEqual(url.utf8) else {
      throw CoreError.invalidSource("Git rewrites the admitted source URL")
    }
    let scheme = URLComponents(string: url)?.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else { return [] }
    var options = ["-c", "http.followRedirects=false"]
    if !url.contains("=") { options += ["-c", "http.\(url).followRedirects=false"] }
    let redirects = try ProcessRunner.git(
      options + context + ["config", "--get-urlmatch", "http.followRedirects", url],
      operation: .readOrigin, source: "admitted source", inheritingLock: lock
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard redirects == "false" else {
      throw CoreError.invalidSource("Git enables HTTP redirects for the admitted source")
    }
    return options
  }

  private func fetchManaged(_ managed: ManagedSourceGit, id: String, lock: Int32) throws -> URL {
    let mirror = mirrorURL(sourceID: id)
    let parentURL = mirror.deletingLastPathComponent()
    _ = try DirectoryAccessEvidence.capture(at: parentURL)
    try FileSystem.createDirectory(at: parentURL)
    _ = try DirectoryAccessEvidence.capture(at: parentURL)
    let parent = try DirectoryHandle(at: parentURL)
    if try parent.info(mirror.lastPathComponent) != nil {
      _ = try parent.requirePrivateAccess(mirror.lastPathComponent)
      _ = try ProcessRunner.git(
        [
          "fetch", "--no-recurse-submodules", "--prune", "--", managed.repository.url,
          "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*",
        ],
        operation: .fetch, source: "admitted source", inheritingLock: lock,
        managed: managed, managedMirror: mirror)
    } else {
      let name = "managed-" + UUID().uuidString
      let staging = try parent.createPrivateDirectory(name)
      defer { try? FileManager.default.removeItem(at: staging.url) }
      let bare = staging.url.appendingPathComponent("mirror.git")
      _ = try ProcessRunner.git(
        [
          "clone", "--mirror", "--no-local", "--template=", "--no-recurse-submodules", "--",
          managed.repository.url, bare.path,
        ],
        operation: .clone, source: "admitted source", inheritingLock: lock, managed: managed)
      guard chmod(bare.path, 0o700) == 0 else { throw SourceAccessError.requestFailed }
      try managed.sealClonedConfiguration(bare)
      _ = try staging.requirePrivateAccess("mirror.git")
      try FileManager.default.moveItem(at: bare, to: mirror)
      try parent.sync()
    }
    let head = try ProcessRunner.git(
      ["ls-remote", "--symref", "--", managed.repository.url, "HEAD"],
      operation: .listRemoteReferences, source: "admitted source", inheritingLock: lock,
      managed: managed
    ).stdout
    if let line = head.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }),
      let reference = line.split(separator: "\t").first
    {
      _ = try git(
        mirror, ["symbolic-ref", "HEAD", String(reference.dropFirst(5))],
        operation: .updateDefaultBranch, source: managed.repository.url, lock: lock, offline: true)
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
    replacingPaths paths: [URL] = [], offline: Bool = false
  ) throws -> String {
    try withMirrorLock(at: repository) { descriptor in
      try git(
        repository, arguments, operation: operation, source: source, replacingPaths: paths,
        lock: descriptor, offline: offline)
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
    replacingPaths paths: [URL] = [], lock: Int32, offline: Bool = false
  ) throws -> String {
    let mirror = try DirectoryHandle(at: repository)
    guard let config = try mirror.info("config"), config.st_mode & 0o170000 == 0o100000 else {
      throw CoreError.unsafePath("mirror configuration must be a regular file")
    }
    return try ProcessRunner.git(
      Self.gitOptions + ["-C", repository.path] + arguments, operation: operation, source: source,
      replacingPaths: paths + [repository, store.cacheDirectory], inheritingLock: lock,
      offline: offline || operation != .fetch
    )
    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func mirrorSource(_ mirror: URL, lock: Int32) throws -> String {
    // Recovery never reads the declaration. A mirror that neither watch state nor the lock
    // names, including an orphan, is identified by its clone's origin.
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

  /// Rejects a symbolic link that can lead outside the extracted tree. A dangling link that stays
  /// inside, such as one to an uncommitted file, cannot be followed and is kept.
  private func validateTree(_ tree: URL) throws {
    guard let root = PathSafety.realPath(tree.path),
      let enumerator = FileManager.default.enumerator(
        at: tree, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let url as URL in enumerator
    where try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      guard try PathSafety.linkStaysInside(url, root: root) else {
        throw CoreError.unsafePath("source symlink escapes committed tree")
      }
    }
  }
}
