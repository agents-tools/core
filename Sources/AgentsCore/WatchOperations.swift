import Foundation

/// Scope-bound subscriptions. Discovery and artifact loading are supplied by the owning module,
/// and declaration reading and planning by the declaration format's module.
public struct WatchOperations: Sendable {
  private let discoverSkills: @Sendable (URL) throws -> [WatchSkill]
  private let fetchArtifacts: @Sendable (String) throws -> [WatchArtifact]
  private let declarations: DeclarationAccess
  private let checkpoint: @Sendable (String) throws -> Void

  package init(
    discoverSkills: @escaping @Sendable (URL) throws -> [WatchSkill],
    fetchArtifacts: @escaping @Sendable (String) throws -> [WatchArtifact],
    declarations: DeclarationAccess,
    checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }
  ) {
    self.discoverSkills = discoverSkills
    self.fetchArtifacts = fetchArtifacts
    self.declarations = declarations
    self.checkpoint = checkpoint
  }

  /// Declares a source when needed and acknowledges its current content without installing it.
  /// The declaration change is planned before Git or an index is contacted.
  @discardableResult
  public func add(
    _ source: String, alias: String? = nil, requirement: SourceRequirement? = nil,
    path: String? = nil, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchChange {
    try add(
      source, alias: alias, requirement: requirement, path: path, scope: scope,
      environment: environment, expected: nil, outcome: TransactionOutcome())
  }

  private func add(
    _ source: String, alias: String?, requirement: SourceRequirement?, path: String?,
    scope: InstallScope, environment: RuntimeEnvironment, expected: WatchMutationPreview?,
    outcome: TransactionOutcome
  ) throws -> WatchChange {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withLock(checkpoint: checkpoint, outcome: outcome) {
      let baseline = try StatePrecondition(store: store)
      let previous = try declarations.read(store, baseline)
      let lock = try store.readLedger(prepared: baseline)
      var watch = try store.readWatch(prepared: baseline)
      let planned = try planAdd(
        source, alias: alias, requirement: requirement, path: path,
        declaration: previous, store: store, baseline: baseline)
      let (name, id, declared, change) = (planned.alias, planned.id, planned.source, planned.change)
      if let expected {
        try requireFingerprint(
          expected, baseline: baseline, change: change, seen: expected.seen, store: store,
          alias: name, sourceID: id, removing: false)
      }
      let current = try acknowledge(declared, revision: nil, expected: expected?.seen, store: store)
      watch.sources[id] = WatchSourceState(seen: current)
      try commit(
        change, watch: watch, lock: lock, store: store, baseline: baseline, outcome: outcome)
      return WatchChange(alias: name, sourceID: id, seen: current)
    }
  }

  /// Fetches upstream content without writing declaration, lock, watch state, or retained trees.
  public func status(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [WatchStatus] {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let declaration = try declarations.read(store, nil)
      _ = try store.readLedger()
      let watch = try store.readWatch()
      return try (declaration.watch ?? []).sorted().map { alias in
        try inspect(alias: alias, declaration: declaration, watch: watch, store: store)
      }
    }
  }

  /// Returns typed before/after file contents. Kind can disambiguate equal skill and section names.
  public func diff(
    _ source: String, name: String? = nil, kind: WatchItemKind? = nil,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchStatus {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let declaration = try declarations.read(store, nil)
      _ = try store.readLedger()
      let watch = try store.readWatch()
      let alias = try subscription(source, declaration: declaration, environment: environment)
      var result = try inspect(alias: alias, declaration: declaration, watch: watch, store: store)
      result.changes = result.changes.filter {
        (name == nil || $0.name == name) && (kind == nil || $0.kind == kind)
      }
      return result
    }
  }

  @discardableResult
  public func seen(
    _ source: String, revision: String? = nil, ifCurrentIs expected: WatchSeen? = nil,
    ifSourceIs expectedSource: String? = nil,
    scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchChange {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withLock(checkpoint: checkpoint) {
      let baseline = try StatePrecondition(store: store)
      let declaration = try declarations.read(store, baseline)
      let lock = try store.readLedger(prepared: baseline)
      var watch = try store.readWatch(prepared: baseline)
      let alias = try subscription(source, declaration: declaration, environment: environment)
      let declared = declaration.sources[alias]!
      let id = try declared.identity(environment: environment)
      guard expectedSource == nil || expectedSource == id else {
        throw CoreError.invalidState("watch source changed; refresh before acknowledging")
      }
      let current = try acknowledge(declared, revision: revision, expected: expected, store: store)
      guard expected == nil || expected == current else {
        throw CoreError.invalidState("watch content changed; refresh before acknowledging")
      }
      watch.sources[id] = WatchSourceState(seen: current)
      try commit(nil, watch: watch, lock: lock, store: store, baseline: baseline)
      return WatchChange(alias: alias, sourceID: id, seen: current)
    }
  }

  /// Acknowledges exactly the displayed source/content pair, revalidated under the writer lock.
  @discardableResult
  public func seen(
    _ status: WatchStatus, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchChange {
    try seen(
      status.alias, ifCurrentIs: status.current, ifSourceIs: status.sourceID,
      scope: scope, environment: environment)
  }

  /// Removes only the subscription and baseline. Source declarations and installations remain.
  @discardableResult
  public func remove(
    _ source: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchChange {
    try remove(
      source, scope: scope, environment: environment, expected: nil, outcome: TransactionOutcome())
  }

  private func remove(
    _ source: String, scope: InstallScope, environment: RuntimeEnvironment,
    expected: WatchMutationPreview?, outcome: TransactionOutcome
  ) throws -> WatchChange {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withLock(checkpoint: checkpoint, outcome: outcome) {
      let baseline = try StatePrecondition(store: store)
      let previous = try declarations.read(store, baseline)
      var declaration = previous
      let lock = try store.readLedger(prepared: baseline)
      var watch = try store.readWatch(prepared: baseline)
      let alias = try subscription(source, declaration: declaration, environment: environment)
      let id = try declaration.sources[alias]!.identity(environment: environment)
      declaration.watch?.removeAll { $0 == alias }
      watch.sources.removeValue(forKey: id)
      let change = try declarations.plan(store, previous, declaration, baseline)
      if let expected {
        try requireFingerprint(
          expected, baseline: baseline, change: change, seen: nil, store: store, alias: alias,
          sourceID: id, removing: true)
      }
      try commit(
        change, watch: watch, lock: lock, store: store, baseline: baseline, outcome: outcome)
      return WatchChange(alias: alias, sourceID: id, seen: nil)
    }
  }

  /// Resolves acknowledgment in disposable storage without retaining refs or recovering the scope.
  public func previewAdd(
    _ source: String, alias: String? = nil, requirement: SourceRequirement? = nil,
    path: String? = nil, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchMutationPreview {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let previous = try declarations.read(store, baseline)
      _ = try store.readLedger(prepared: baseline)
      _ = try store.readWatch(prepared: baseline)
      let planned = try planAdd(
        source, alias: alias, requirement: requirement, path: path,
        declaration: previous, store: store, baseline: baseline)
      let seen = try observe(planned.source, store: store)
      let fingerprint = try mutationFingerprint(
        baseline: baseline, change: planned.change, seen: seen, store: store, alias: planned.alias,
        sourceID: planned.id, removing: false)
      try baseline.validate()
      return WatchMutationPreview(
        action: .add(source, alias, requirement, path), store: store,
        alias: planned.alias, sourceID: planned.id, seen: seen, displayedFingerprint: fingerprint,
        readLocations: mutationReadLocations(store, source: planned.source))
    }
  }

  public func previewRemove(
    _ source: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchMutationPreview {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let previous = try declarations.read(store, baseline)
      var declaration = previous
      _ = try store.readLedger(prepared: baseline)
      _ = try store.readWatch(prepared: baseline)
      let alias = try subscription(source, declaration: declaration, environment: environment)
      let selected = declaration.sources[alias]!
      let id = try selected.identity(environment: environment)
      declaration.watch?.removeAll { $0 == alias }
      let change = try declarations.plan(store, previous, declaration, baseline)
      let fingerprint = try mutationFingerprint(
        baseline: baseline, change: change, seen: nil, store: store, alias: alias, sourceID: id,
        removing: true)
      try baseline.validate()
      return WatchMutationPreview(
        action: .remove(source), store: store,
        alias: alias, sourceID: id, seen: nil, displayedFingerprint: fingerprint,
        readLocations: mutationReadLocations(store, source: selected))
    }
  }

  /// Revalidates exactly the displayed subscription mutation inside its sole scope writer.
  @discardableResult
  public func apply(_ preview: WatchMutationPreview) throws -> WatchChange {
    try apply(preview, outcome: TransactionOutcome())
  }

  package func apply(_ preview: WatchMutationPreview, outcome: TransactionOutcome) throws
    -> WatchChange
  {
    switch preview.action {
    case .add(let source, let alias, let requirement, let path):
      return try add(
        source, alias: alias, requirement: requirement, path: path,
        scope: preview.store.scope, environment: preview.store.environment, expected: preview,
        outcome: outcome)
    case .remove(let source):
      return try remove(
        source, scope: preview.store.scope, environment: preview.store.environment,
        expected: preview, outcome: outcome)
    }
  }

  private func mutationReadLocations(_ store: StateStore, source: SourceDeclaration) -> [URL] {
    [store.declarationURL, store.resolvedURL, store.watchURL]
      + (source.kind == .local ? [source.localURL(environment: store.environment)] : [])
  }

  private func mutationFingerprint(
    baseline: StatePrecondition, change: DeclarationChange?,
    seen: WatchSeen?, store: StateStore, alias: String, sourceID: String, removing: Bool
  ) throws -> String {
    struct Evidence: Encodable {
      let scope: InstallScope
      let alias: String
      let sourceID: String
      let removing: Bool
      let state: [String?]
      let declaration: String?
      let seen: WatchSeen?
    }
    return try ResolvedLedgerCodec.digest(
      Evidence(
        scope: store.scope, alias: alias, sourceID: sourceID, removing: removing,
        state: [store.declarationURL, store.resolvedURL, store.watchURL].map {
          try baseline.bytes(for: $0).map { FileHash.sha256Hex(data: $0) }
        }, declaration: change.map { FileHash.sha256Hex(data: $0.bytes) }, seen: seen))
  }

  private func requireFingerprint(
    _ preview: WatchMutationPreview, baseline: StatePrecondition,
    change: DeclarationChange?, seen: WatchSeen?, store: StateStore, alias: String,
    sourceID: String, removing: Bool
  ) throws {
    guard
      try mutationFingerprint(
        baseline: baseline, change: change, seen: seen, store: store, alias: alias,
        sourceID: sourceID, removing: removing) == preview.displayedFingerprint
    else {
      throw CoreError.invalidState("subscription changed; refresh before confirming")
    }
  }

  private func observe(_ source: SourceDeclaration, store: StateStore) throws -> WatchSeen {
    if source.kind == .wellKnown {
      return .artifacts(
        Dictionary(
          uniqueKeysWithValues: try artifacts(source).map { ($0.name, $0.artifact.digest) }))
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-watch-preview-" + UUID().uuidString)
    try FileSystem.createDirectory(at: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var source = source
    if source.kind == .local {
      source.location = source.localURL(environment: store.environment).path
    }
    let environment = RuntimeEnvironment(
      projectDirectory: temporary, homeDirectory: temporary,
      environment: store.environment.environment)
    return .revision(
      try SourceCache(store: StateStore(scope: .project, environment: environment)).watchRevision(
        source))
  }

  private struct AddPlan {
    let alias: String
    let id: String
    let source: SourceDeclaration
    let change: DeclarationChange?
  }

  private func planAdd(
    _ source: String, alias: String?, requirement: SourceRequirement?, path: String?,
    declaration previous: Declaration, store: StateStore, baseline: StatePrecondition
  ) throws -> AddPlan {
    let environment = store.environment
    var declaration = previous
    var argument = try SourceArgument(source)
    guard argument.name == nil else {
      throw CoreError.invalidSource("@skill: selects skills; watch subscribes to whole sources")
    }
    if declaration.sources[argument.location] == nil,
      let alias = try declaration.sources.keys.sorted().first(where: {
        try declaration.sources[$0]?.identity(environment: environment) == argument.location
      })
    {
      argument.location = alias
    }
    let selection = try argument.selection(
      in: declaration, requirement: requirement, path: path, environment: environment)
    let parsed = selection.source
    let id = try parsed.identity(environment: environment)
    let existing = try declaration.sources.keys.sorted().first {
      try declaration.sources[$0]?.identity(environment: environment) == id
    }
    let name = alias ?? existing ?? declaration.derivedAlias(for: parsed.location)
    if let current = declaration.sources[name],
      try current.identity(environment: environment) != id
    {
      throw CoreError.invalidSource("source alias already refers to another source: \(name)")
    }
    let declared = selection.applied(to: existing.flatMap { declaration.sources[$0] } ?? parsed)
    declaration.sources[name] = declared
    declaration.watch = Array(Set((declaration.watch ?? []) + [name])).sorted()
    try declaration.validate(environment: environment)
    let change = try declarations.plan(store, previous, declaration, baseline)
    return AddPlan(alias: name, id: id, source: declared, change: change)
  }

  private func sourceDeclaration(
    _ input: String, declaration: Declaration, environment: RuntimeEnvironment
  ) throws -> SourceDeclaration {
    if let source = declaration.sources[input] { return source }
    let parsed = try SourceParser.parse(
      input, currentDirectory: environment.projectDirectory,
      homeDirectory: environment.homeDirectory)
    return SourceDeclaration(
      kind: parsed.type, location: parsed.localPath ?? parsed.url,
      requirement: parsed.requirement, path: parsed.subpath)
  }

  private func subscription(
    _ input: String, declaration: Declaration, environment: RuntimeEnvironment
  ) throws -> String {
    if (declaration.watch ?? []).contains(input) { return input }
    for alias in declaration.watch ?? [] {
      if try declaration.sources[alias]!.identity(environment: environment) == input {
        return alias
      }
    }
    let id = try sourceDeclaration(input, declaration: declaration, environment: environment)
      .identity(environment: environment)
    for alias in declaration.watch ?? [] {
      if try declaration.sources[alias]!.identity(environment: environment) == id { return alias }
    }
    throw CoreError.notFound("source is not subscribed: \(input)")
  }

  /// The prepared generation, captured before any network acknowledgment, is the journal's
  /// preimage evidence and also guards the lock that pruning follows.
  private func commit(
    _ change: DeclarationChange?, watch: WatchState, lock: ResolvedLedger, store: StateStore,
    baseline: StatePrecondition, outcome: TransactionOutcome = TransactionOutcome()
  ) throws {
    try watch.validate()
    let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
    transaction.requireUnchanged(since: baseline)
    try store.stageDeclaration(change, in: transaction, prepared: baseline)
    try transaction.replace(
      store.watchURL, with: .data(StateStore.encode(watch)),
      expecting: baseline.evidence(for: store.watchURL))
    var references = try RetentionReferences(ledger: lock, roots: store.ledgerRoots)
    try references.include(watch: watch)
    try SourceCache(store: store).prune(references: references, transaction: transaction)
    try transaction.commit()
  }

  private func acknowledge(
    _ source: SourceDeclaration, revision: String?, expected: WatchSeen? = nil, store: StateStore
  ) throws -> WatchSeen {
    let cache = SourceCache(store: store, checkpoint: checkpoint)
    let id = try source.identity(environment: store.environment)
    if source.kind != .wellKnown {
      let head = try cache.watchRevision(source, revision: revision)
      guard expected == nil || expected == .revision(head) else {
        throw CoreError.invalidState("watch content changed; refresh before acknowledging")
      }
      try checkpoint("watch.mirror.fetched")
      try cache.retainWatchRevision(sourceID: id, source: source.location, revision: head)
      return .revision(head)
    }
    guard revision == nil else {
      throw CoreError.invalidSource("well-known subscriptions do not accept Git revisions")
    }
    let artifacts = try artifacts(source)
    let current = WatchSeen.artifacts(
      Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.artifact.digest) }))
    guard expected == nil || expected == current else {
      throw CoreError.invalidState("watch content changed; refresh before acknowledging")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-watch-" + UUID().uuidString)
    try FileSystem.createDirectory(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    // Each nested cache transaction names its checkpoints within its artifact and role, so
    // they stay distinct from one another and from the watch commit.
    func artifactCache(_ scope: String) -> SourceCache {
      SourceCache(store: store) { try checkpoint("watch.artifact." + scope + "." + $0) }
    }
    for (index, artifact) in artifacts.enumerated() {
      let directory = root.appendingPathComponent(artifact.name)
      try FileSystem.createDirectory(at: directory)
      for (path, data) in artifact.files {
        let destination = try PathSafety.resolvedChild(base: directory, subpath: path)
        try FileSystem.createDirectory(at: destination.deletingLastPathComponent())
        try FileSystem.write(data, to: destination)
      }
      for (payload, (digest, data)) in artifact.payloads.sorted(by: { $0.key < $1.key })
        .enumerated()
      {
        _ = try artifactCache("\(index).payload.\(payload)").storeArtifact(data, digest: digest)
      }
      _ = try artifactCache("\(index).content").materializeArtifact(
        directory, digest: artifact.artifact.digest,
        hash: "sha256:" + FileHash.folderHash(directory))
    }
    return .artifacts(
      Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.artifact.digest) }))
  }

  private func artifacts(_ source: SourceDeclaration) throws -> [WatchArtifact] {
    let artifacts = try fetchArtifacts(source.location)
    try Declaration.validateNames(artifacts.map(\.name))
    for artifact in artifacts {
      try artifact.artifact.validate()
      for path in artifact.files.keys { _ = try PathSafety.sanitizeSubpath(path) }
      for (digest, data) in artifact.payloads {
        guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
          throw CoreError.invalidState("watch artifact payload digest mismatch")
        }
      }
      if artifact.artifact.type == .files {
        let records = artifact.artifact.files ?? []
        guard try LockedArtifact.filesDigest(records) == artifact.artifact.digest,
          Set(records.map(\.path)) == Set(artifact.files.keys)
        else { throw CoreError.invalidState("watch files artifact digest mismatch") }
        for record in records {
          guard let data = artifact.files[record.path],
            "sha256:" + FileHash.sha256Hex(data: data) == record.digest
          else { throw CoreError.invalidState("watch artifact file digest mismatch") }
        }
      } else {
        guard artifact.payloads[artifact.artifact.digest] != nil else {
          throw CoreError.invalidState("watch artifact is missing its download bytes")
        }
        if artifact.artifact.type == .skillMD,
          artifact.files != ["SKILL.md": artifact.payloads[artifact.artifact.digest]!]
        {
          throw CoreError.invalidState("watch Markdown artifact differs from its download")
        }
      }
    }
    return artifacts
  }

  private func inspect(
    alias: String, declaration: Declaration, watch: WatchState, store: StateStore
  ) throws -> WatchStatus {
    let source = declaration.sources[alias]!
    let id = try source.identity(environment: store.environment)
    guard let seen = watch.sources[id]?.seen else {
      throw CoreError.invalidState("subscription has no seen state: \(alias)")
    }
    let cache = SourceCache(store: store)
    let current: WatchSeen
    let count: Int?
    let before: [WatchItemKey: WatchUnit]
    let after: [WatchItemKey: WatchUnit]
    switch seen {
    case .revision(let revision):
      guard source.kind != .wellKnown else { throw CoreError.invalidState("watch kind mismatch") }
      let head = try cache.watchRevision(source)
      current = .revision(head)
      count = try cache.watchCommitCount(
        sourceID: id, source: source.location, seen: revision, current: head)
      before = try units(source, revision: revision, cache: cache)
      after = revision == head ? before : try units(source, revision: head, cache: cache)
    case .artifacts(let digests):
      guard source.kind == .wellKnown else { throw CoreError.invalidState("watch kind mismatch") }
      let artifacts = try artifacts(source)
      current = .artifacts(
        Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.artifact.digest) }))
      count = nil
      var old: [WatchItemKey: WatchUnit] = [:]
      for (name, digest) in digests {
        let directory = store.cacheDirectory.appendingPathComponent(
          "artifact-content/\(digest.dropFirst(7))")
        try cache.validatePath(directory)
        old[WatchItemKey(kind: .artifact, name: name)] = WatchUnit(
          path: nil, digest: digest, files: try WatchUnit.read(directory))
      }
      before = old
      after = Dictionary(
        uniqueKeysWithValues: artifacts.map {
          (
            WatchItemKey(kind: .artifact, name: $0.name),
            WatchUnit(
              path: nil, digest: $0.artifact.digest,
              files: $0.files.mapValues { .file($0, executable: false) })
          )
        })
    }
    let keys = Set(before.keys).union(after.keys).sorted {
      $0.kind.rawValue == $1.kind.rawValue ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue
    }
    let changes = keys.compactMap { key -> WatchItemChange? in
      let old = before[key]
      let new = after[key]
      guard old != new else { return nil }
      let paths = Set(old?.files.keys.map { $0 } ?? []).union(new?.files.keys.map { $0 } ?? [])
      let files = paths.sorted().compactMap { path -> WatchFileChange? in
        let left = old?.files[path]
        let right = new?.files[path]
        return left == right ? nil : WatchFileChange(path: path, before: left, after: right)
      }
      return WatchItemChange(
        name: key.name, kind: key.kind,
        change: old == nil ? .new : new == nil ? .removed : .changed,
        oldPath: old?.path, newPath: new?.path, oldDigest: old?.digest, newDigest: new?.digest,
        files: files)
    }
    return WatchStatus(
      alias: alias, sourceID: id, seen: seen, current: current, commitCount: count, changes: changes
    )
  }

  private func units(
    _ source: SourceDeclaration, revision: String, cache: SourceCache
  ) throws -> [WatchItemKey: WatchUnit] {
    let id = try source.identity(environment: cache.store.environment)
    let locked = LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
    return try cache.withSnapshot(sourceID: id, source: locked, revision: revision) { snapshot in
      let root = try PathSafety.resolvedChild(base: snapshot, subpath: source.path ?? ".")
      guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
      var result: [WatchItemKey: WatchUnit] = [:]
      let skills = try discoverSkills(root)
      try Declaration.validateNames(skills.map(\.name))
      for skill in skills {
        let directory = try PathSafety.resolvedChild(base: root, subpath: skill.path)
        result[WatchItemKey(kind: .skill, name: skill.name)] = WatchUnit(
          path: skill.path, digest: nil, files: try WatchUnit.read(directory))
      }
      for path in ["instructions", ".agents/instructions"] {
        let directory = try PathSafety.resolvedChild(base: root, subpath: path)
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        // Instructions files are named by their path inside the container, subdirectories included.
        func collect(_ handle: DirectoryHandle, prefix: String) throws {
          for file in try handle.names() {
            let mode = try (handle.info(file)?.st_mode ?? 0) & 0o170000
            if mode == 0o040000 {
              try collect(handle.child(file), prefix: prefix + file + "/")
              continue
            }
            // Target names are never instructions files, as in discovery.
            guard file.hasSuffix(".md"), !["AGENTS.md", "GEMINI.md"].contains(file) else {
              continue
            }
            let key = WatchItemKey(kind: .instructions, name: prefix + String(file.dropLast(3)))
            guard result[key] == nil else {
              throw CoreError.invalidSource("duplicate instructions name: \(key.name)")
            }
            result[key] = WatchUnit(
              path: path + "/" + prefix + file, digest: nil,
              files: [file: try WatchUnit.entry(file, in: handle)])
          }
        }
        try collect(DirectoryHandle(at: directory), prefix: "")
      }
      return result
    }
  }
}

private struct WatchItemKey: Hashable {
  let kind: WatchItemKind
  let name: String
}

private struct WatchUnit: Equatable {
  let path: String?
  let digest: String?
  let files: [String: WatchFileEntry]

  static func read(_ url: URL) throws -> [String: WatchFileEntry] {
    var files: [String: WatchFileEntry] = [:]
    func collect(_ directory: DirectoryHandle, prefix: String) throws {
      for name in try directory.names() {
        let value = try entry(name, in: directory)
        if value == .directory {
          let child = try directory.child(name)
          if try child.names().isEmpty { files[prefix + name] = value }
          try collect(child, prefix: prefix + name + "/")
        } else {
          files[prefix + name] = value
        }
      }
    }
    try collect(DirectoryHandle(at: url), prefix: "")
    return files
  }

  static func entry(_ name: String, in directory: DirectoryHandle) throws -> WatchFileEntry {
    guard let info = try directory.info(name) else { throw CoreError.notFound(name) }
    switch info.st_mode & 0o170000 {
    case 0o100000: return .file(try directory.read(name), executable: info.st_mode & 0o111 != 0)
    case 0o120000: return .symbolicLink(try directory.readLink(name))
    case 0o040000: return .directory
    default: throw CoreError.invalidSource("unsupported watch entry: \(name)")
    }
  }
}

/// Immutable subscription confirmation; no locks or borrowed resources escape preview.
public struct WatchMutationPreview: Sendable {
  fileprivate enum Action: Sendable {
    case add(String, String?, SourceRequirement?, String?)
    case remove(String)
  }
  fileprivate let action: Action
  package let store: StateStore
  public let alias: String
  public let sourceID: String
  public let seen: WatchSeen?
  public let displayedFingerprint: String
  public let readLocations: [URL]
}
