import Foundation

/// Owns disposable exact snapshots for one scope-locked preparation.
package final class SourceResolutionSession {
  private struct Snapshot {
    let identity: String
    let source: LockedSource
    let pin: SourceRevision
    let root: URL
  }
  package let sourcePolicy: EffectiveSourcePolicy
  package var sourceAccess: SourceAccessConfiguration { store.environment.sourceAccess }
  package let acquisitions: GitAcquisitionCaptures
  private let store: StateStore
  private let stagedLocalSources: [String: URL]
  private let cache: SourceCache
  package enum ReadMode { case persistentCache, temporary }
  private let mode: ReadMode
  private let temporaryCache: SourceCache
  /// Exact-object acquisition cannot update the mirror behind frozen reference evidence.
  private let objectCache: SourceCache
  private var archiveTrees: [PrivateSourceRecovery.Reference: URL] = [:]
  private var commits: [SourceSnapshotID: String] = [:]
  private var catalogs: [String: SourceCatalog] = [:]
  private var advertisements: [String: GitAcquisition.Advertisement] = [:]
  private var observedSelections: [SourceSnapshotID: Set<String>] = [:]
  private var exact: [SourceSnapshotID: SourceSnapshot] = [:]
  private var localTrees: [String: SourceSnapshot] = [:]
  private var closed = false
  private var borrowed: [SourceSnapshotID: SourceSnapshot] = [:]
  private var evidence: [SourceSnapshotID: SourceSnapshotEvidence] = [:]
  package private(set) var bundlePackageNames: [SourceSnapshotID: String] = [:]
  package private(set) var bundleSources: [SourceSnapshotID: [PortableSourceEvidence]] = [:]
  private let workspace: URL
  private var snapshots: [Snapshot] = []

  package init(
    store: StateStore, mode: ReadMode = .persistentCache,
    sourcePolicy: EffectiveSourcePolicy = .init(), requireRecordedTransport: Bool = false,
    stagedLocalSources: [String: URL] = [:], acquisitions: GitAcquisitionCaptures? = nil
  ) throws {
    self.sourcePolicy = sourcePolicy
    let acquisitions = acquisitions ?? GitAcquisitionCaptures()
    self.acquisitions = acquisitions
    self.stagedLocalSources = stagedLocalSources
    self.mode = mode
    self.store = store
    cache = SourceCache(
      store: store, sourcePolicy: sourcePolicy, requireRecordedTransport: requireRecordedTransport,
      acquisitions: acquisitions)
    workspace = try PrivateSourceRecovery.makeWorkspace(prefix: "agents-resolution-").url
    var environment = store.environment
    environment.projectDirectory = workspace.appendingPathComponent("sources")
    temporaryCache = SourceCache(
      store: StateStore(scope: .project, environment: environment), sourcePolicy: sourcePolicy,
      requireRecordedTransport: requireRecordedTransport, acquisitions: acquisitions)
    environment.projectDirectory = workspace.appendingPathComponent("objects")
    objectCache = SourceCache(
      store: StateStore(scope: .project, environment: environment), sourcePolicy: sourcePolicy,
      requireRecordedTransport: requireRecordedTransport, acquisitions: acquisitions)
  }

  deinit { try? FileManager.default.removeItem(at: workspace) }

  /// All borrowed views must be consumed inside this closure. Cleanup errors are observable.
  package static func withTemporaryRead<T>(
    store: StateStore, sourcePolicy: EffectiveSourcePolicy = .init(),
    requireRecordedTransport: Bool = false, stagedLocalSources: [String: URL] = [:],
    acquisitions: GitAcquisitionCaptures? = nil,
    _ body: (SourceResolutionSession) throws -> T
  ) throws -> T {
    let session = try SourceResolutionSession(
      store: store, mode: .temporary, sourcePolicy: sourcePolicy,
      requireRecordedTransport: requireRecordedTransport, stagedLocalSources: stagedLocalSources,
      acquisitions: acquisitions)
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
    archiveTrees.removeAll()
    bundleSources.removeAll()
    bundlePackageNames.removeAll()
    commits.removeAll()
    advertisements.removeAll()
    observedSelections.removeAll()
  }

  private func requireOpen() throws {
    guard !closed else { throw CoreError.invalidState("source session is closed") }
    if mode == .temporary { try Task.checkCancellation() }
  }

  /// Bundle storage has its own admission path, where the seal is checked before copying.
  package func requireSource(_ source: SourceDeclaration) throws {
    if source.kind == .local,
      BundleSourceLocation.container(of: source.localURL(environment: store.environment), in: store)
        != nil
    {
      guard source.requirement == nil else {
        throw CoreError.invalidSource("bundle sources cannot select Git revisions")
      }
      return
    }
    _ = try cache.route(source)
  }

  /// Candidate evidence is captured once per normalized source, including revision expressions
  /// first encountered later during backtracking. No persistent mirror or ref is written.
  package func candidates(
    for source: SourceDeclaration, requirements: [SourceRequirement?],
    spending: (Int) throws -> Void = { _ in }
  ) throws -> [SourceRevision] {
    try requireOpen()
    let route = try cache.route(source)
    for requirement in requirements { try requirement?.validate() }
    if case .archive(let repository, let profile) = route {
      let selectors = try requirements.compactMap { requirement in
        try requirement.map { try VCSArchiveRef(requirement: $0) }
      }
      guard let ref = selectors.first else { throw SourceAccessError.discoveryUnavailable }
      guard selectors.allSatisfy({ $0 == ref }) else { return [] }
      try spending(1)
      let request = try VCSArchiveRequest(repository: repository, ref: ref, mirror: profile)
      return [try observeArchive(source, route: route, request: request, profile: profile)]
    }
    let source = declaringSource(source)
    let id = try source.identity(environment: store.environment)
    let exactObjects = requirements.compactMap { requirement -> String? in
      if case .revision(let object) = requirement, SourceCache.isObjectID(object) { return object }
      return nil
    }
    if exactObjects.count == requirements.compactMap({ $0 }).count, !exactObjects.isEmpty {
      let selected = try exactObjects.map { object in
        try spending(1)
        return try commit(object, source: source)
      }
      return Set(selected).count == 1 ? [SourceRevision(revision: selected[0])] : []
    }
    if catalogs[id] == nil {
      if let acquisition = cache.anonymousAcquisition(source),
        let advertisement = try cache.attemptAnonymous({ try acquisition.discover() }),
        remoteResolves(requirements, in: advertisement.catalog)
      {
        for _ in advertisement.catalog.references { try spending(1) }
        advertisements[id] = advertisement
        catalogs[id] = advertisement.catalog
      } else {
        catalogs[id] = try temporaryCache.referenceCatalog(source, spending: spending)
      }
      try Task.checkCancellation()
    } else if let advertisement = advertisements[id],
      !remoteResolves(requirements, in: advertisement.catalog)
    {
      let complete = try temporaryCache.referenceCatalog(source, spending: spending)
      guard
        advertisement.catalog.references.filter({
          $0.key == "HEAD" || $0.key.hasPrefix("refs/heads/") || $0.key.hasPrefix("refs/tags/")
        })
          == complete.references.filter({
            $0.key == "HEAD" || $0.key.hasPrefix("refs/heads/") || $0.key.hasPrefix("refs/tags/")
          })
      else { throw CoreError.invalidState("Git references changed during source resolution") }
      catalogs[id] = complete
      advertisements[id] = nil
    }
    var catalog = catalogs[id]!
    for requirement in requirements {
      if case .revision(let expression) = requirement, catalog.references[expression] == nil {
        if SourceCache.isObjectID(expression) {
          try spending(1)
          catalog.references[expression] = try commit(expression, source: source)
        } else if let advertisement = advertisements[id] {
          catalog.references[expression] =
            GitAcquisition.reference(
              expression, in: advertisement.catalog)?.1
        } else {
          catalog.references[expression] = try temporaryCache.catalogRevision(
            expression, source: source)
        }
      }
    }
    catalogs[id] = catalog
    let selected = try catalog.candidates(requirements: requirements, spending: spending)
    if let advertisement = advertisements[id] {
      for pin in selected {
        let availableTags = advertisement.catalog.tags.filter { $0.value == pin.revision }
        let key = SourceSnapshotID(source: id, revision: pin.revision)
        for requirement in requirements.isEmpty ? [nil] : requirements {
          if case .revision(let object) = requirement, SourceCache.isObjectID(object) { continue }
          if let reference = try? SourceReference(
            requirement: requirement, tags: Array(availableTags.keys)),
            let (name, object) = GitAcquisition.reference(
              reference.name, in: advertisement.catalog), object == pin.revision
          {
            observedSelections[key, default: []].insert(name)
          }
        }
      }
    }
    return selected
  }

  private func observeArchive(
    _ source: SourceDeclaration, route: SourceRoute, request: VCSArchiveRequest,
    profile: SourceArchiveMirror
  ) throws -> SourceRevision {
    let key = source.gitURL + "\0" + request.url.absoluteString
    if let prior = acquisitions.archiveSelections[key] { return prior }
    let bytes = try PrivateSourceRecovery.download(
      request, route: route, environment: store.environment)
    let verified = try VerifiedVCSArchive(bytes)
    let archive = SourceArchiveEvidence(
      effectiveURL: request.url, flavor: profile.flavor, ref: request.ref,
      treeDigest: verified.treeDigest, observedArchiveDigest: verified.byteDigest,
      requiredArchiveDigest: profile.requiresExactArchiveBytes ? verified.byteDigest : nil)
    var version: String?
    if case .tag(let name) = request.ref { version = SemanticVersion(name)?.description }
    let pin = SourceRevision(revision: archive.treeDigest, version: version, archive: archive)
    let reference = PrivateSourceRecovery.Reference(transport: source.gitURL, archive: archive)
    try acquisitions.captureArchive(bytes, verified: verified, reference: reference)
    acquisitions.archiveSelections[key] = pin
    return pin
  }

  private func archiveSnapshot(
    _ source: SourceDeclaration, pin: SourceRevision, reference: PrivateSourceRecovery.Reference,
    route: SourceRoute, request: VCSArchiveRequest, offline: Bool
  ) throws -> SourceSnapshot {
    guard pin.revision == reference.archive.treeDigest else {
      throw SourceAccessError.archiveChanged
    }
    let environment = store.environment
    let root: URL
    if let existing = archiveTrees[reference] {
      root = existing
    } else {
      let verified: VerifiedVCSArchive
      if let data = try acquisitions.readArchive(reference) {
        verified = try VerifiedVCSArchive(data)
      } else if let (_, retained) = try PrivateSourceRecovery(environment: environment).read(
        reference)
      {
        verified = retained
      } else {
        guard !offline else { throw SourceAccessError.recoveryUnavailable }
        let bytes = try PrivateSourceRecovery.download(
          request, route: route, environment: environment)
        verified = try VerifiedVCSArchive(bytes)
        try reference.archive.verify(verified)
        try acquisitions.captureArchive(bytes, verified: verified, reference: reference)
      }
      try reference.archive.verify(verified)
      root = try verified.extract(
        named: UUID().uuidString, in: DirectoryHandle(at: workspace), environment: environment)
      archiveTrees[reference] = root
    }
    let key = try SourceSnapshotID(
      source: source.identity(environment: environment), revision: pin.revision)
    let base = try SourceSnapshot(snapshot: key, pin: pin, root: root)
    if let previous = evidence[key]?.archive, previous != reference.archive {
      throw SourceAccessError.ambiguousRoute
    }
    register(base, source: LockedSource(kind: .git, url: source.gitURL))
    return try SourceSnapshot(
      snapshot: key, pin: pin, root: root, discoveryPath: source.path ?? ".")
  }

  private func remoteResolves(
    _ requirements: [SourceRequirement?], in catalog: SourceCatalog
  ) -> Bool {
    requirements.allSatisfy { requirement in
      guard case .revision(let expression) = requirement, !SourceCache.isObjectID(expression)
      else { return true }
      return GitAcquisition.reference(expression, in: catalog) != nil
    }
  }

  package func snapshot(
    _ source: SourceDeclaration, at pin: SourceRevision, offline: Bool = false
  ) throws -> SourceSnapshot {
    try requireOpen()
    let route = try cache.route(source)
    if let request = try route.requireRecordedArchive(pin.archive), let archive = pin.archive {
      return try archiveSnapshot(
        source, pin: pin, reference: .init(transport: source.gitURL, archive: archive),
        route: route, request: request, offline: offline)
    }
    let source = declaringSource(source)
    var pin = pin
    pin.revision = try commit(pin.revision, source: source)
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
      let available: SourceCache?
      if try temporaryCache.catalogRevision(pin.revision, source: selected) == pin.revision {
        available = temporaryCache
      } else if try objectCache.catalogRevision(pin.revision, source: selected) == pin.revision {
        available = objectCache
      } else {
        available = nil
      }
      if let available {
        base = try available.withSnapshot(
          sourceID: id,
          source: LockedSource(
            kind: selected.kind, url: selected.kind == .git ? selected.gitURL : nil,
            requirement: selected.requirement), revision: pin.revision, copy)
      } else {
        base = try cache.withResolvedSnapshot(selected, cacheSource: false) { resolved, tree in
          guard resolved.revision == pin.revision else {
            throw CoreError.invalidState("resolved snapshot differs from its commit pin")
          }
          return try copy(tree)
        }
      }
      if let refs = observedSelections[key], let advertisement = advertisements[id],
        let acquisition = cache.anonymousAcquisition(source),
        let pack = try acquisition.exact(pin.revision, offline: true)
      {
        for ref in refs.sorted() {
          acquisition.note(ref, pack: pack, observedAt: advertisement.time)
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

  private func commit(_ object: String, source: SourceDeclaration) throws -> String {
    guard SourceCache.isObjectID(object) else {
      throw CoreError.invalidState("snapshot requires an exact Git object")
    }
    let key = try SourceSnapshotID(
      source: source.identity(environment: store.environment), revision: object)
    if let existing = commits[key] { return existing }
    let resolved: String
    if advertisements[key.source] != nil,
      let acquisition = cache.anonymousAcquisition(source),
      let pack = try cache.attemptAnonymous({ try acquisition.exact(object) })
    {
      acquisition.remember(pack)
      resolved = pack.revision
    } else if let cached = try cache.catalogRevision(object, source: source) {
      resolved = cached
    } else if let frozen = try temporaryCache.catalogRevision(object, source: source) {
      resolved = frozen
    } else {
      resolved = try objectCache.acquireCommit(object, source: source)
    }
    commits[key] = resolved
    commits[SourceSnapshotID(source: key.source, revision: resolved)] = resolved
    try Task.checkCancellation()
    return resolved
  }

  private func declaringSource(_ source: SourceDeclaration) -> SourceDeclaration {
    var source = source
    if source.environment == nil {
      source.environment = SourceEnvironment(
        projectDirectory: store.environment.projectDirectory,
        homeDirectory: store.environment.homeDirectory)
    }
    return source
  }

  /// Non-Git local producers are copied once, then identified by bytes and executable flags.
  package func localSnapshot(_ source: SourceDeclaration) throws -> SourceSnapshot {
    try requireOpen()
    let id = try source.identity(environment: store.environment)
    let live = source.localURL(environment: store.environment)
    let bundleContainer = BundleSourceLocation.container(of: live, in: store)
    try requireSource(source)
    let bundled = bundleContainer != nil
    let local = bundled ? nil : localEnvironment(for: source)
    if let existing = localTrees[id] {
      return try SourceSnapshot(
        snapshot: existing.snapshot, pin: nil, root: existing.root,
        discoveryPath: source.path ?? ".", localEnvironment: local,
        liveRoot: existing.liveRoot)
    }
    guard source.kind == .local, source.requirement == nil else {
      throw CoreError.invalidSource("a non-Git source cannot have a Git requirement")
    }
    let root = workspace.appendingPathComponent(UUID().uuidString)
    let input: URL
    if let staged = stagedLocalSources[id] {
      guard bundleContainer != nil else {
        throw CoreError.invalidState("invalid staged bundle source")
      }
      input = staged.resolvingSymlinksInPath()
    } else if let bundleContainer {
      // Only the caller's configured base may resolve an alias. The bundle store and its
      // contents are opened through no-follow directory handles.
      let base = store.directory.deletingLastPathComponent().resolvingSymlinksInPath()
      input = base.appendingPathComponent(store.directory.lastPathComponent)
        .appendingPathComponent(BundleSourceLocation.directory)
        .appendingPathComponent(bundleContainer.lastPathComponent)
        .appendingPathComponent(BundleSourceLocation.tree)
    } else {
      input = live.resolvingSymlinksInPath()
    }
    let marker =
      try bundled ? BundleStoredSource.readMarker(input.deletingLastPathComponent()) : nil
    if let marker {
      try sourcePolicy.requireBundleSources(
        marker.sources, reference: bundleContainer!.lastPathComponent)
    }
    let origin = try DirectoryHandle(at: input)
    let destination = try DirectoryHandle(at: workspace)
    try destination.copy(root.lastPathComponent, from: origin, named: ".") { _ in
      try Task.checkCancellation()
    }
    try Self.validateLinks(root)
    try marker?.validateTree(root)
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
      localEnvironment: local, liveRoot: bundled ? nil : live)
    localTrees[id] = result
    bundleSources[result.snapshot] = marker?.sources
    if marker?.marketplaceNode == nil { bundlePackageNames[result.snapshot] = marker?.package.name }
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
      snapshot: view.snapshot,
      pin: view.pin.map { pin in
        pin.archive == nil ? SourceRevision(revision: pin.revision) : pin
      }, source: descriptor, container: container,
      archive: container == nil ? view.pin?.archive : nil)
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

  package func fileSnapshot(
    source: String, revision: String, files: [String: Data], executableFlags: [String: Bool] = [:]
  ) throws
    -> SourceSnapshot
  {
    try requireOpen()
    let id = SourceSnapshotID(source: source, revision: revision)
    if let existing = borrowed[id] { return existing }
    let root = workspace.appendingPathComponent(UUID().uuidString)
    try FileSystem.createDirectory(at: root)
    for path in files.keys.sorted() {
      try Task.checkCancellation()
      let file = try PathSafety.resolvedChild(base: root, subpath: path)
      try FileSystem.createDirectory(at: file.deletingLastPathComponent())
      try FileSystem.write(files[path]!, to: file)
      try FileManager.default.setAttributes(
        [.posixPermissions: executableFlags[path] == true ? 0o755 : 0o644], ofItemAtPath: file.path)
    }
    let result = try SourceSnapshot(snapshot: id, pin: nil, root: root)
    register(result)
    return result
  }

  /// Reborrows an admitted artifact closure without consulting its index or download coordinates.
  package func artifactSnapshot(
    source: String, resource: LedgerResource, objects: [String: Data]
  ) throws -> SourceSnapshot {
    try requireOpen()
    guard resource.kind == .artifact, let artifact = resource.artifact else {
      throw CoreError.invalidState("missing pinned artifact resource")
    }
    try artifact.validate()
    let id = SourceSnapshotID(source: source, revision: artifact.digest)
    if let existing = borrowed[id] { return existing }
    let root = workspace.appendingPathComponent(UUID().uuidString)
    let destination =
      resource.support.isEmpty
      ? try PathSafety.resolvedChild(base: root, subpath: resource.path) : root
    var embedded = resource
    embedded.kind = .embedded
    try LedgerResources.materialize(embedded, objects: objects, at: destination)
    let result = try SourceSnapshot(snapshot: id, pin: nil, root: root)
    let captured = try LedgerResources.capture(
      result.resource(resource.path), embed: false, limits: .standard, sourceRoot: root)
    guard captured.hash == resource.hash else {
      throw CoreError.invalidState("pinned artifact resource hash mismatch")
    }
    register(result)
    return result
  }

  package func liveSnapshot(_ source: SourceDeclaration) throws -> SourceSnapshot {
    try requireOpen()
    try sourcePolicy.require(source, environment: store.environment)
    guard source.kind == .local, source.requirement == nil else {
      throw CoreError.invalidSource("edit requires an actual local source with no requirement")
    }
    let root = source.localURL(environment: store.environment)
    guard BundleSourceLocation.container(of: root, in: store) == nil else {
      throw CoreError.invalidSource("bundle sources are immutable")
    }
    let result = try SourceSnapshot(
      snapshot: SourceSnapshotID(
        source: source.identity(environment: store.environment), revision: "live"),
      pin: nil, root: root, discoveryPath: source.path ?? ".",
      localEnvironment: localEnvironment(for: source), liveRoot: root)
    register(result)
    return result
  }

  package func isGitSource(_ source: SourceDeclaration) throws -> Bool {
    try requireSource(source)
    guard source.kind == .local else { return source.kind == .git }
    let local = source.localURL(environment: store.environment)
    if BundleSourceLocation.container(of: local, in: store) != nil { return false }
    // Validate this directory's metadata, including worktree gitfiles, without ancestor discovery.
    for path in [".git", "."] {
      if (try? ProcessRunner.git(
        ["--no-optional-locks", "-C", local.path, "rev-parse", "--resolve-git-dir", path],
        operation: .findRepositoryRoot, source: source.location)) != nil
      {
        return true
      }
    }
    return false
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
    try sourcePolicy.require(source, environment: store.environment)
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
