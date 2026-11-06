import Foundation

/// Owns disposable exact snapshots for one scope-locked preparation.
package final class SourceResolutionSession {
  private struct Snapshot {
    let identity: String
    let source: LockedSource
    let pin: SourceRevision
    let root: URL
  }
  private let store: StateStore
  private let cache: SourceCache
  package enum ReadMode { case persistentCache, temporary }
  private let mode: ReadMode
  private let temporaryCache: SourceCache
  private var catalogs: [String: SourceCatalog] = [:]
  private var exact: [SourceSnapshotID: SourceSnapshot] = [:]
  private var localTrees: [String: SourceSnapshot] = [:]
  private var closed = false
  private var borrowed: [SourceSnapshotID: SourceSnapshot] = [:]
  private var evidence: [SourceSnapshotID: SourceSnapshotEvidence] = [:]
  private let workspace: URL
  private var snapshots: [Snapshot] = []

  package init(store: StateStore, mode: ReadMode = .persistentCache) throws {
    self.mode = mode
    self.store = store
    cache = SourceCache(store: store)
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-resolution-" + UUID().uuidString)
    try FileSystem.createDirectory(at: workspace)
    var environment = store.environment
    environment.projectDirectory = workspace.appendingPathComponent("sources")
    temporaryCache = SourceCache(store: StateStore(scope: .project, environment: environment))
  }

  deinit { try? FileManager.default.removeItem(at: workspace) }

  /// All borrowed views must be consumed inside this closure. Cleanup errors are observable.
  package static func withTemporaryRead<T>(
    store: StateStore, _ body: (SourceResolutionSession) throws -> T
  ) throws -> T {
    let session = try SourceResolutionSession(store: store, mode: .temporary)
    do {
      let result = try body(session)
      try Task.checkCancellation()
      try session.close()
      return result
    } catch {
      try session.close()
      throw error
    }
  }

  package func close() throws {
    guard !closed else { return }
    try FileManager.default.removeItem(at: workspace)
    closed = true
    snapshots.removeAll()
    exact.removeAll()
    localTrees.removeAll()
    borrowed.removeAll()
    evidence.removeAll()
  }

  private func requireOpen() throws {
    guard !closed else { throw CoreError.invalidState("source session is closed") }
    if mode == .temporary { try Task.checkCancellation() }
  }

  /// Candidate evidence is captured once per normalized source, including revision expressions
  /// first encountered later during backtracking. No persistent mirror or ref is written.
  package func candidates(
    for source: SourceDeclaration, requirements: [SourceRequirement?],
    spending: (Int) throws -> Void = { _ in }
  ) throws -> [SourceRevision] {
    try requireOpen()
    for requirement in requirements { try requirement?.validate() }
    let id = try source.identity(environment: store.environment)
    let exactObjects = requirements.compactMap { requirement -> String? in
      if case .revision(let object) = requirement, SourceCache.isObjectID(object) { return object }
      return nil
    }
    if exactObjects.count == requirements.compactMap({ $0 }).count, !exactObjects.isEmpty {
      return Set(exactObjects).count == 1 ? [SourceRevision(revision: exactObjects[0])] : []
    }
    if catalogs[id] == nil {
      catalogs[id] = try temporaryCache.referenceCatalog(source, spending: spending)
      try Task.checkCancellation()
    }
    var catalog = catalogs[id]!
    for requirement in requirements {
      if case .revision(let expression) = requirement, catalog.references[expression] == nil {
        catalog.references[expression] = try temporaryCache.catalogRevision(
          expression, source: source)
      }
    }
    catalogs[id] = catalog
    return try catalog.candidates(requirements: requirements, spending: spending)
  }

  package func snapshot(_ source: SourceDeclaration, at pin: SourceRevision) throws
    -> SourceSnapshot
  {
    try requireOpen()
    let id = try source.identity(environment: store.environment)
    let key = SourceSnapshotID(source: id, revision: pin.revision)
    let base: SourceSnapshot
    if let existing = exact[key] {
      base = existing
    } else {
      var selected = source
      selected.requirement = .revision(pin.revision)
      selected.path = nil
      func copy(_ tree: URL) throws -> SourceSnapshot {
        let root = workspace.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: tree, to: root)
        return try SourceSnapshot(
          snapshot: key, pin: pin, root: root,
          localEnvironment: localEnvironment(for: source),
          liveRoot: source.kind == .local && source.requirement == nil
            ? source.localURL(environment: store.environment) : nil)
      }
      if catalogs[id] != nil,
        try temporaryCache.catalogRevision(pin.revision, source: selected) == pin.revision
      {
        base = try temporaryCache.withSnapshot(
          sourceID: id,
          source: LockedSource(
            kind: selected.kind, url: selected.kind == .git ? selected.gitURL : nil,
            requirement: selected.requirement), revision: pin.revision, copy)
      } else {
        base = try cache.withResolvedSnapshot(selected, cacheSource: false) { _, tree in
          try copy(tree)
        }
      }
      exact[key] = base
      register(
        base,
        source: LockedSource(
          kind: source.kind,
          url: source.kind == .git ? source.gitURL : nil, requirement: .revision(pin.revision)))
      try Task.checkCancellation()
    }
    return try SourceSnapshot(
      snapshot: key, pin: pin, root: base.root,
      discoveryPath: source.path ?? ".",
      localEnvironment: localEnvironment(for: source),
      liveRoot: source.kind == .local && source.requirement == nil
        ? source.localURL(environment: store.environment) : nil)
  }

  /// Non-Git local producers are copied once, then identified by bytes and executable flags.
  package func localSnapshot(_ source: SourceDeclaration) throws -> SourceSnapshot {
    try requireOpen()
    let id = try source.identity(environment: store.environment)
    if let existing = localTrees[id] {
      return try SourceSnapshot(
        snapshot: existing.snapshot, pin: nil, root: existing.root,
        discoveryPath: source.path ?? ".", localEnvironment: localEnvironment(for: source),
        liveRoot: existing.liveRoot)
    }
    guard source.kind == .local, source.requirement == nil else {
      throw CoreError.invalidSource("a non-Git source cannot have a Git requirement")
    }
    let live = source.localURL(environment: store.environment)
    let root = workspace.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: live, to: root)
    try Self.validateLinks(root)
    let flags = try FileHash.executableFlags(root)
    let content = try FileHash.folderHash(root)
    let evidence = FileHash.hashRecords(
      [("content", Data(content.utf8))]
        + flags.keys.sorted().map {
          ("execute\0" + $0, Data([flags[$0]! ? 1 : 0]))
        })
    let result = try SourceSnapshot(
      snapshot: SourceSnapshotID(
        source: id, revision: "sha256:" + evidence),
      pin: nil, root: root, discoveryPath: source.path ?? ".",
      localEnvironment: localEnvironment(for: source), liveRoot: live)
    localTrees[id] = result
    register(result)
    try Task.checkCancellation()
    return result
  }

  /// Registers only a borrowed view; closing the session invalidates all resource access.
  package func register(_ view: SourceSnapshot, source: LockedSource? = nil) {
    borrowed[view.snapshot] = view
    if source == nil, evidence[view.snapshot] != nil { return }
    let container =
      view.packageIdentity == view.snapshot.source
      ? nil
      : SourceSnapshotID(
        source: view.packageIdentity, revision: view.snapshot.revision)
    let descriptor =
      source
      ?? (container == nil
        ? LockedSource(
          kind: view.snapshot.source.hasPrefix("local:") ? .local : .wellKnown) : nil)
    evidence[view.snapshot] = SourceSnapshotEvidence(
      snapshot: view.snapshot, pin: view.pin.map { SourceRevision(revision: $0.revision) },
      source: descriptor, container: container)
  }

  package func sourceEvidence(for snapshots: Set<SourceSnapshotID>) -> [SourceSnapshotEvidence] {
    var required = snapshots
    var pending = Array(snapshots)
    while let snapshot = pending.popLast() {
      if let container = evidence[snapshot]?.container, required.insert(container).inserted {
        pending.append(container)
      }
    }
    return required.compactMap { evidence[$0] }.sorted {
      $0.snapshot.source == $1.snapshot.source
        ? $0.snapshot.revision < $1.snapshot.revision : $0.snapshot.source < $1.snapshot.source
    }
  }

  package func resource(snapshot: SourceSnapshotID, path: String) throws -> URL {
    try requireOpen()
    guard let view = borrowed[snapshot] else { throw CoreError.notFound("source snapshot") }
    return try view.resource(path)
  }

  package func fileSnapshot(source: String, revision: String, files: [String: Data]) throws
    -> SourceSnapshot
  {
    try requireOpen()
    let id = SourceSnapshotID(source: source, revision: revision)
    if let existing = borrowed[id] { return existing }
    let root = workspace.appendingPathComponent(UUID().uuidString)
    try FileSystem.createDirectory(at: root)
    for path in files.keys.sorted() {
      try Task.checkCancellation()
      try FileSystem.write(files[path]!, to: PathSafety.resolvedChild(base: root, subpath: path))
    }
    let result = try SourceSnapshot(snapshot: id, pin: nil, root: root)
    register(result)
    return result
  }

  package func liveSnapshot(_ source: SourceDeclaration) throws -> SourceSnapshot {
    try requireOpen()
    guard source.kind == .local, source.requirement == nil else {
      throw CoreError.invalidSource("edit requires an actual local source with no requirement")
    }
    let root = source.localURL(environment: store.environment)
    let result = try SourceSnapshot(
      snapshot: SourceSnapshotID(
        source: source.identity(environment: store.environment), revision: "live"),
      pin: nil, root: root, discoveryPath: source.path ?? ".",
      localEnvironment: localEnvironment(for: source), liveRoot: root)
    register(result)
    return result
  }

  package func isGitSource(_ source: SourceDeclaration) throws -> Bool {
    guard source.kind == .local else { return source.kind == .git }
    let local = source.localURL(environment: store.environment)
    return
      (try? ProcessRunner.git(
        ["-C", local.path, "rev-parse", "--git-dir"],
        operation: .findRepositoryRoot, source: source.location)) != nil
  }

  private func localEnvironment(for source: SourceDeclaration) -> SourceEnvironment? {
    guard source.kind == .local else { return nil }
    return SourceEnvironment(
      projectDirectory: source.localURL(environment: store.environment),
      homeDirectory: source.environment?.homeDirectory ?? store.environment.homeDirectory)
  }

  private static func validateLinks(_ root: URL) throws {
    guard let real = PathSafety.realPath(root.path),
      let entries = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let entry as URL in entries {
      try Task.checkCancellation()
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
        try !PathSafety.linkStaysInside(entry, root: real)
      {
        throw CoreError.unsafePath("local source symlink escapes snapshot")
      }
    }
  }

  package func withSnapshot<T>(
    _ source: SourceDeclaration, _ body: (SourceRevision, URL) throws -> T
  ) throws -> T {
    try requireOpen()
    let identity = try source.identity(environment: store.environment)
    let effective = LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
    if let snapshot = snapshots.first(where: { $0.identity == identity && $0.source == effective })
    {
      return try body(snapshot.pin, snapshot.root)
    }
    let snapshot = try cache.withResolvedSnapshot(source, cacheSource: mode == .persistentCache) {
      pin, tree in
      let root = workspace.appendingPathComponent(UUID().uuidString)
      try FileSystem.withAccessErrors(at: root) {
        try FileManager.default.copyItem(at: tree, to: root)
      }
      return Snapshot(identity: identity, source: effective, pin: pin, root: root)
    }
    snapshots.append(snapshot)
    return try body(snapshot.pin, snapshot.root)
  }
}
