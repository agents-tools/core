import CPlatform
import Foundation

/// The scope's sole durable undo journal owns private construction containers,
/// sealed publication evidence and terminal disposal. The scope writer lock spans
/// preparation, commit and recovery; external writers are identified by inode and digest.
package final class FileTransaction {
  package enum Source {
    case data(Data)
    case copy(URL)
    /// A symbolic link to the URL, relative to the target parent when the URL is in the scope.
    case link(URL)
    /// A producer may construct arbitrary intermediate objects only inside its private container.
    case prepared((URL) throws -> URL)
  }
  /// Checks for the sealed staging; nil fields are not compared.
  struct Expectation {
    var hash: String?
    /// Complete byte-identified subtree content and execute intent, independent of inode copies.
    var objectDigest: String?
    var executableFlags: [String: Bool]?
    var kind: mode_t?
    var mode: mode_t?
    /// The destination a staged symbolic link must contain.
    var linkDestination: String?
  }
  private struct Request {
    let path: String
    let evidence: TargetPrecondition
    /// Ordinary input. Private installs produce bytes only after verified creation.
    let source: Source?
    let expectation: Expectation
    let security: TransactionSecurity
    let privateData: (() throws -> Data)?
    var privateTree: PrivateTree? = nil
    var installs: Bool { source != nil || security.replacement == .privateMaterialization }
  }
  private let store: StateStore
  private let checkpoint: (String) throws -> Void
  private let outcome: TransactionOutcome
  private var requests: [Request] = []
  private var skillInitialization: SkillInitializationTarget?
  private var receiptStates: [String: MaterializationReceiptState] = [:]
  private var receiptIndices: [Int: MaterializationReceiptState] = [:]
  private var unchanged: [any PreparedEvidence] = []
  private var targetPaths: Set<String> { Set(requests.map { $0.evidence.url.path }) }

  package init(
    store: StateStore, outcome: TransactionOutcome = TransactionOutcome(),
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) {
    self.store = store
    self.outcome = outcome
    self.checkpoint = checkpoint
  }

  /// `expectedHash` and `executableFlags` describe the content's tree hash and execute bits.
  package func replace(
    _ destination: URL, with source: Source, expectedHash: String? = nil,
    executableFlags: [String: Bool]? = nil, expecting: TargetPrecondition? = nil
  ) throws {
    if let expectedHash { try StateValidation.digest(expectedHash) }
    let (path, evidence, previous) = try request(destination, expecting: expecting)
    var security = previous
    var expectation = Expectation(hash: expectedHash, executableFlags: executableFlags)
    switch source {
    case .copy(let url):
      expectation = try Self.copyExpectation(url, hash: expectedHash, flags: executableFlags)
    case .link(let url):
      expectation.linkDestination = Self.linkDestination(
        url, parent: destination.deletingLastPathComponent(), store: store)
    case .data, .prepared: break
    }
    if let route = NativeTargetRoute.targetRoute(path) {
      let requiredKind: mode_t = route.isContainer ? S_IFDIR : S_IFREG
      if route.isContainer, case .data = source {
        throw CoreError.unsafePath("registered native container requires a directory")
      }
      guard expectation.kind == nil || expectation.kind == requiredKind else {
        throw CoreError.unsafePath("registered native target has the wrong object kind")
      }
      if case .link = source {
        throw CoreError.unsafePath("registered native targets cannot be symbolic links")
      }
      expectation.kind = requiredKind
    }
    if security.preimage == .privateMaterialization {
      guard case .data(let data) = source else {
        throw CoreError.invalidState("sensitive replacement requires private byte construction")
      }
      security.replacement = .privateMaterialization
      requests.append(
        Request(
          path: path, evidence: evidence, source: nil, expectation: expectation,
          security: security, privateData: { data }))
    } else {
      requests.append(
        Request(
          path: path, evidence: evidence, source: source, expectation: expectation,
          security: security, privateData: nil))
    }
  }

  /// Admits only this explicit, absent local authoring file to the ordinary journal.
  package func initializeSkill(_ target: SkillInitializationTarget, bytes: Data) throws {
    guard target.scope.path.utf8.elementsEqual(store.directory.path.utf8),
      let context = TransactionLockContext.current(store), context.projectRootDirectory != nil
    else {
      throw CoreError.invalidState("skill initialization requires its observed existing parent")
    }
    try context.requireWriterScope()
    try target.evidence.validate()
    skillInitialization = target
    defer { skillInitialization = nil }
    try replace(target.file, with: .data(bytes), expecting: target.evidence)
  }

  package func delete(_ destination: URL, expecting: TargetPrecondition? = nil) throws {
    let (path, evidence, security) = try request(destination, expecting: expecting)
    requests.append(
      Request(
        path: path, evidence: evidence, source: nil, expectation: .init(), security: security,
        privateData: nil))
  }

  /// Values are resolved only inside commit, after private staging has been verified.
  package func replacePrivate(
    _ prepared: PreparedPrivateMaterialization, bindings: Set<String> = [],
    provider: any RuntimeBindingProvider,
    render: @escaping (RuntimeBindingValues) throws -> Data
  ) throws {
    guard NativeTargetRoute.targetRoute(prepared.target.path)?.isContainer != true,
      prepared.target.scope.path == store.directory.path, prepared.owner == geteuid(),
      bindings.allSatisfy({ !$0.isEmpty && !$0.contains("\0") })
    else { throw CoreError.invalidState("invalid private materialization inputs") }
    guard let receiptEvidence = prepared.receiptEvidence else {
      throw CoreError.invalidState(
        "private publication requires an existing admitted native parent")
    }
    try receiptEvidence.validate()
    let (path, evidence, previous) = try request(prepared.target.url, expecting: prepared.evidence)
    guard path == prepared.target.path else {
      throw CoreError.invalidState("materialization registration changed")
    }
    try prepared.ancestry.validate(at: evidence.physicalURL.deletingLastPathComponent())
    var security = previous
    security.replacement = .privateMaterialization
    security.permissionChange = prepared.accessChange != nil
    security.preimageAccess = prepared.beforeAccess
    security.ancestry = prepared.ancestry
    let environment = store.environment
    requests.append(
      Request(
        path: path, evidence: evidence, source: nil, expectation: .init(),
        security: security,
        privateData: {
          do {
            var values: [String: Data] = [:]
            for name in bindings.sorted() {
              values[name] = try provider.value(for: name, environment: environment)
            }
            return try render(RuntimeBindingValues(values))
          } catch {
            throw CoreError.invalidState(
              "private materialization could not resolve or render its bindings")
          }
        }))
  }

  /// Replaces one registered named container atomically. Inputs own their bytes.
  package func replacePrivateTree(
    _ prepared: PreparedPrivateMaterialization, entries: [PrivateTreeEntry],
    provider: any RuntimeBindingProvider
  ) throws {
    guard NativeTargetRoute.targetRoute(prepared.target.path)?.isContainer == true,
      prepared.target.scope.path.utf8.elementsEqual(store.directory.path.utf8),
      prepared.owner == geteuid(), let receipt = prepared.receiptEvidence
    else { throw CoreError.invalidState("private tree requires its prepared registered container") }
    let tree = try PrivateTree(entries: entries, provider: provider, environment: store.environment)
    try receipt.validate()
    let (path, evidence, previous) = try request(prepared.target.url, expecting: prepared.evidence)
    guard path.utf8.elementsEqual(prepared.target.path.utf8) else {
      throw CoreError.invalidState("materialization registration changed")
    }
    var security = previous
    security.replacement = .privateMaterialization
    security.permissionChange = prepared.accessChange != nil
    security.preimageAccess = prepared.beforeAccess
    security.preimageTreeAccess = prepared.preimageTreeAccess
    security.ancestry = prepared.ancestry
    requests.append(
      Request(
        path: path, evidence: evidence, source: nil,
        expectation: .init(kind: S_IFDIR), security: security, privateData: nil, privateTree: tree))
  }

  private func queueReceipt() throws {
    let originals = requests
    for state in receiptStates.values.sorted(by: { $0.path < $1.path }) {
      let receiptRoute = NativeTargetRoute.metadataRoute(state.path)
      let shared = receiptRoute != nil
      let affected = originals.filter {
        NativeTargetRoute.sharedRoute($0.path)?.root == receiptRoute?.root
          && ($0.security.isPrivate || state.records.targets[$0.path] != nil)
      }
      guard !affected.isEmpty else { continue }
      var sensitiveTargets = Set(state.records.targets.keys)
      for request in affected {
        if request.security.replacement == .privateMaterialization {
          sensitiveTargets.insert(request.path)
        } else {
          sensitiveTargets.remove(request.path)
        }
      }
      var security = TransactionSecurity()
      security.preimage = state.access == nil ? .ordinary : .privateMaterialization
      let deletesShared = shared && sensitiveTargets.isEmpty
      security.replacement = deletesShared ? .ordinary : .privateMaterialization
      security.preimageAccess = state.access
      security.ancestry = try DirectoryAccessEvidence.capture(
        at: state.url.deletingLastPathComponent())
      if !deletesShared { receiptIndices[requests.count] = state }
      requests.append(
        Request(
          path: state.path, evidence: state.evidence, source: nil,
          expectation: .init(), security: security, privateData: nil))
    }
  }

  /// Prepared inputs that this journal does not replace must still match at commit entry,
  /// after staging and after publication; the journal verifies its own targets itself.
  package func requireUnchanged(since evidence: any PreparedEvidence...) {
    unchanged += evidence
  }

  private func validateUnchanged() throws {
    for evidence in unchanged { try evidence.validate(excludingTargets: targetPaths) }
  }

  private func request(_ destination: URL, expecting: TargetPrecondition?) throws -> (
    path: String, evidence: TargetPrecondition, security: TransactionSecurity
  ) {
    let path = try TransactionPaths(store: store).path(
      for: destination, skillInitialization: skillInitialization)
    guard path != "state/" + MaterializationReceipts.fileName else {
      throw CoreError.unsafePath("materialization receipts are transaction-owned")
    }
    if NativeTargetRoute.sharedRoute(path) != nil {
      guard TransactionLockContext.current(store)?.writable == true else {
        throw CoreError.invalidState("shared writes require the held writer footprint")
      }
    }
    let receipt = try store.materializationReceipts(for: path)
    if receiptStates[receipt.path] == nil { receiptStates[receipt.path] = receipt }
    let receiptState = receiptStates[receipt.path]!
    guard !requests.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    let evidence = try expecting ?? TargetPrecondition(destination)
    if let route = NativeTargetRoute.targetRoute(path), let snapshot = evidence.snapshot {
      let requiredKind: mode_t = route.isContainer ? S_IFDIR : S_IFREG
      guard snapshot.identity.kind == requiredKind else {
        throw CoreError.unsafePath("registered native preimage has the wrong object kind")
      }
    }
    guard evidence.url.path == destination.standardizedFileURL.path else {
      throw CoreError.invalidState("precondition belongs to another target")
    }
    if let snapshot = evidence.snapshot, snapshot.identity.isDirectory {
      func holdsCoordination(_ value: FileSnapshot) -> Bool {
        (value.children ?? []).contains { member in
          let metadata =
            member.name.utf8.elementsEqual(SharedResource.metadataName.utf8)
            && member.snapshot.identity.isDirectory
            && (member.snapshot.children ?? []).contains { domain in
              domain.name.utf8.count == 64
                && domain.name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && domain.snapshot.identity.isDirectory
                && domain.snapshot.child(named: "lock")?.isRegular == true
            }
          return metadata || holdsCoordination(member.snapshot)
        }
      }
      guard !holdsCoordination(snapshot) else {
        throw CoreError.unsafePath("container contains independently coordinated native targets")
      }
    }
    var security = TransactionSecurity()
    if let record = receiptState.records.targets[path] {
      let paths = TransactionPaths(store: store)
      let key = try paths.components(path).root
      guard try store.materializationRootIdentity(key) == record.rootIdentity else {
        throw CoreError.invalidState("materialization receipt root changed")
      }
      // A known absence has no sensitive preimage; its receipt is reconciled in this journal.
      guard evidence.snapshot != nil else { return (path, evidence, security) }
      guard evidence.snapshot?.digest == record.digest,
        evidence.snapshot?.identity == record.access.identity
      else { throw CoreError.invalidState("materialized preimage differs from its receipt") }
      let parent = try DirectoryHandle(at: evidence.physicalURL.deletingLastPathComponent())
      _ = try parent.requirePrivateAccess(destination.lastPathComponent, matching: record.access)
      security.preimage = .privateMaterialization
      security.preimageAccess = record.access
      security.preimageTreeAccess = record.treeAccess
      try TreeMemberAccess.verify(
        record.treeAccess, snapshot: evidence.snapshot!, named: destination.lastPathComponent,
        in: parent, requirePrivate: true)
      security.ancestry = try DirectoryAccessEvidence.capture(at: parent.url)
    }
    return (path, evidence, security)
  }

  static func copyExpectation(
    _ source: URL, hash: String?, flags: [String: Bool]?
  ) throws -> Expectation {
    let physical = source.resolvingSymlinksInPath()
    let parent = try DirectoryHandle(at: physical.deletingLastPathComponent())
    let capture = try FileSnapshot.capture(physical.lastPathComponent, from: parent)
    guard let snapshot = capture.snapshot else { throw CoreError.notFound(source.path) }
    return Expectation(
      hash: hash ?? "sha256:" + capture.contentHash, objectDigest: snapshot.digest,
      executableFlags: flags ?? capture.executableFlags,
      kind: snapshot.identity.kind, mode: snapshot.mode)
  }

  package func commit() throws {
    guard !requests.isEmpty else { return }
    let shared = requests.filter { NativeTargetRoute.sharedRoute($0.path) != nil }
    if !shared.isEmpty {
      guard let context = TransactionLockContext.current(store), context.writable else {
        throw CoreError.invalidState("shared commit requires its held writer footprint")
      }
      try context.requireWriterScope()
      for request in shared {
        let resource = try context.resource(for: NativeTargetRoute.sharedRoute(request.path)!)
        let parent = try DirectoryHandle(
          at: request.evidence.physicalURL.deletingLastPathComponent())
        guard try parent.objectIdentity == resource.identity.parent else {
          throw CoreError.invalidState("shared commit physical registration changed")
        }
      }
    }
    guard let directory = try store.openDirectoryIfPresent(),
      try !TransactionJournal.isPresent(in: directory)
    else {
      throw CoreError.invalidState("transaction recovery is required")
    }
    try queueReceipt()
    for state in receiptStates.values { try state.evidence.validate() }
    try validateUnchanged()
    for request in requests { try request.evidence.validate() }
    try validateOverlap()
    let session = try makeSession(directory)
    outcome.journalID = session.journal.id
    do {
      try session.persist(.created)
      try session.emit(.phase(.preparing))
      try session.createReservations(owner: store.directory.path)
      try session.createContainers()
      try session.checkCapabilities()
      // Capability probing may only touch missing ancestry, journal and private containers.
      if session.journal.entries.contains(where: {
        ["state/agents.watch", "state/agents.resolved"].contains($0.path)
      }) {
        try SourceCache(store: store, checkpoint: checkpoint).beginWatchReferenceUpdate()
      }
      for (index, request) in requests.enumerated() {
        if let state = receiptIndices[index] {
          try session.stage(index, source: request.source, expectation: request.expectation) {
            let bytes = try StateStore.encode(
              session.materializationReceipts(
                previous: state.records,
                targetRoot: NativeTargetRoute.metadataRoute(state.path)?.root))
            try LedgerAdmission.check(bytes, limits: .standard)
            return bytes
          }
        } else {
          try session.stage(
            index, source: request.source, expectation: request.expectation,
            privateData: request.privateData, privateTree: request.privateTree)
        }
      }
      try session.emit(.preconditions)
      try validateUnchanged()
      try session.validatePreimages()
      outcome.requireRecovery()
      for index in session.journal.entries.indices { try session.publish(index) }
      try validateUnchanged()
      try session.sealDisposal()
      try session.emit(.commitValidated)
      try session.finish(.committed)
      outcome.recordTerminal(.committed)
      try session.emit(.phase(.committed))
      try session.dispose()
      outcome.recoveryPending = false
    } catch {
      // Recovery names its checkpoints under `recovery.`, apart from the failed commit's.
      do {
        _ = try Self.recover(store: store, outcome: outcome) {
          try self.checkpoint("recovery." + $0)
        }
      } catch {
        outcome.requireRecovery()
      }
      throw error
    }
  }

  private func validateOverlap() throws {
    var targets: [URL] = []
    var treeMembers = 0
    var treeBytes = 0
    for request in requests {
      if let tree = request.privateTree {
        guard tree.entries.count <= LedgerLimits.standard.entries - treeMembers,
          tree.inputBytes <= LedgerLimits.standard.resourceBytes - treeBytes
        else { throw CoreError.invalidState("private trees exceed candidate limits") }
        treeMembers += tree.entries.count
        treeBytes += tree.inputBytes
      }
      let target = request.evidence.physicalURL
      guard
        !targets.contains(where: {
          PathSafety.isContained(target, in: $0) || PathSafety.isContained($0, in: target)
        })
      else {
        throw CoreError.invalidState("overlapping transaction destinations")
      }
      targets.append(target)
    }
  }

  private func makeSession(_ directory: DirectoryHandle) throws -> TransactionSession {
    let paths = TransactionPaths(store: store)
    var roots: [String: DirectoryHandle] = [:]
    for request in requests {
      let key = try paths.components(request.path).root
      if roots[key] == nil {
        roots[key] = try paths.root(key, create: true) { step in
          try checkpoint(TransactionCheckpoint.rootAncestry(key, step).name)
        }
      }
    }
    let parents = try requests.enumerated().map { index, request in
      try paths.parent(for: request.path, roots: roots, create: true) { step in
        try checkpoint(TransactionCheckpoint.parentAncestry(entry: index, step).name)
      }
    }
    for (index, request) in requests.enumerated() {
      try request.evidence.validateIdentity()
      if NativeTargetRoute.targetRoute(request.path) != nil,
        parents[index].url.standardizedFileURL.path
          != request.evidence.physicalURL.deletingLastPathComponent().standardizedFileURL.path
      {
        throw CoreError.invalidState("registered native parent changed after preparation")
      }
    }
    let id = UUID()
    var containers: [TransactionJournal.Container] = []
    var identities: [String: Int] = [:]
    var entries: [TransactionJournal.Entry] = []
    for (index, request) in requests.enumerated() {
      let identity = try parents[index].identity
      let container: Int
      if let existing = identities[identity] {
        container = existing
      } else {
        container = containers.count
        identities[identity] = container
        containers.append(
          .init(entry: index, name: TransactionJournal.containerName(id: id, index: container)))
      }
      var security = request.security
      if let ancestry = security.ancestry {
        try ancestry.validate(at: parents[index].url, allowingCreation: true)
        security.ancestry = try DirectoryAccessEvidence.capture(at: parents[index].url)
      }
      entries.append(
        .init(
          path: request.path, action: request.installs ? .install : .delete,
          preimage: request.evidence.snapshot, parentIdentity: identity, container: container,
          security: security))
    }
    let sharedRoutes = Set(
      roots.keys.compactMap { key in
        NativeTargetRoute.sharedRoute(key) ?? NativeTargetRoute.metadataRoute(key)
      })
    let admittedResources = try sharedRoutes.map { route in
      guard let context = TransactionLockContext.current(store) else {
        throw CoreError.invalidState("shared transaction requires its held footprint")
      }
      return try context.resource(for: route)
    }.sorted { $0.identity < $1.identity }
    var resources: [SharedResource] = []
    for resource in admittedResources
    where !resources.contains(where: { $0.identity == resource.identity }) {
      resources.append(resource)
    }
    for index in entries.indices {
      if let route = NativeTargetRoute.sharedRoute(entries[index].path)
        ?? NativeTargetRoute.metadataRoute(entries[index].path)
      {
        let resource = try TransactionLockContext.current(store)!.resource(for: route)
        entries[index].coordination = resources.firstIndex { $0.identity == resource.identity }
      }
    }
    let journal = TransactionJournal(
      id: id, scope: try directory.identity,
      roots: try roots.mapValues { try $0.identity }, entries: entries, containers: containers,
      footprint: resources.map(\.identity))
    let session = TransactionSession(
      journal: journal, directory: directory, parents: parents,
      checkpoint: checkpoint, resources: resources,
      nativeRoots: try paths.nativeRootAuthorities(Set(journal.roots.keys)), outcome: outcome)
    try session.validateRecords(store: store)
    return session
  }

  package static func linkDestination(_ source: URL, parent: URL, store: StateStore) -> String {
    let root = (store.scope == .project ? store.environment.projectDirectory : store.directory)
      .resolvingSymlinksInPath()
    let source = source.resolvingSymlinksInPath()
    if PathSafety.isContained(source, in: root) {
      let from = parent.pathComponents
      let to = source.pathComponents
      let common = zip(from, to).prefix(while: { $0 == $1 }).count
      return (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(
        separator: "/")
    }
    return source.path
  }
}
