import Foundation

/// The scope's sole durable undo journal owns private construction containers,
/// sealed publication evidence and terminal disposal. The scope writer lock spans
/// preparation, commit and recovery; external writers are identified by inode and digest.
package final class FileTransaction {
  struct Content {
    var url: URL?
    var link: Bool
    var linkDestination: String?
    var data: Data?
    var expectedHash: String?
    var executableFlags: [String: Bool]?
    var expectedKind: mode_t?
    var expectedMode: mode_t?
    var prepare: ((URL) throws -> URL)?
  }
  private struct Request {
    var action: TransactionJournal.Action
    let path: String
    let evidence: TargetPrecondition
    var content: Content
  }
  private let store: StateStore
  private let checkpoint: (String) throws -> Void
  private let outcome: TransactionOutcome
  private var requests: [Request] = []
  package var validateBeforePublication: () throws -> Void = {}
  package var targetPaths: Set<String> { Set(requests.map { $0.evidence.url.path }) }

  package init(
    store: StateStore, outcome: TransactionOutcome = TransactionOutcome(),
    checkpoint: @escaping (String) throws -> Void = { _ in }
  ) {
    self.store = store
    self.outcome = outcome
    self.checkpoint = checkpoint
  }

  package func replace(
    _ destination: URL, content: URL?, link: Bool = false, data: Data? = nil,
    expectedHash: String? = nil, executableFlags: [String: Bool]? = nil,
    expecting: TargetPrecondition? = nil
  ) throws {
    if let expectedHash {
      try StateValidation.digest(expectedHash)
      guard content != nil || data != nil else {
        throw CoreError.invalidState("verification requires content")
      }
    }
    let path = try TransactionPaths(store: store).path(for: destination)
    guard !requests.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    let evidence = try expecting ?? TargetPrecondition(destination)
    guard evidence.url.path == destination.standardizedFileURL.path else {
      throw CoreError.invalidState("precondition belongs to another target")
    }
    var hash = expectedHash
    var flags = executableFlags
    var kind: mode_t?
    var mode: mode_t?
    if let content, data == nil, !link {
      let expected = try Self.copyExpectation(content, hash: hash, flags: flags)
      (hash, flags, kind, mode) = expected
    }
    requests.append(
      Request(
        action: content != nil || data != nil ? .install : .delete,
        path: path, evidence: evidence,
        content: Content(
          url: content, link: link,
          linkDestination: link
            ? content.map {
              Self.linkDestination(
                $0, parent: destination.deletingLastPathComponent(), store: store)
            } : nil,
          data: data, expectedHash: hash, executableFlags: flags, expectedKind: kind,
          expectedMode: mode)))
  }

  fileprivate static func copyExpectation(
    _ source: URL, hash: String?, flags: [String: Bool]?
  ) throws -> (String?, [String: Bool]?, mode_t?, mode_t?) {
    let physical = source.resolvingSymlinksInPath()
    let parent = try DirectoryHandle(at: physical.deletingLastPathComponent())
    if let hash, let flags {
      let info = try parent.info(physical.lastPathComponent)
      return (
        hash, flags, info.map(FileObjectIdentity.init)?.kind, info.map { $0.st_mode & 0o7777 }
      )
    }
    let capture = try FileSnapshot.capture(physical.lastPathComponent, from: parent)
    guard let snapshot = capture.snapshot else { throw CoreError.notFound(source.path) }
    return (
      hash ?? "sha256:" + capture.contentHash, flags ?? capture.executableFlags,
      snapshot.identity.kind, snapshot.mode
    )
  }

  /// A producer may construct arbitrary intermediate objects only inside its private container.
  func prepare(_ destination: URL, content: @escaping (URL) throws -> URL) throws {
    try replace(destination, content: nil)
    requests[requests.count - 1].action = .install
    requests[requests.count - 1].content.prepare = content
  }

  func remove(_ name: String, from parent: DirectoryHandle) throws {
    try replace(parent.url.appendingPathComponent(name), content: nil)
  }

  package func commit() throws {
    guard !requests.isEmpty else { return }
    guard let directory = try store.openDirectoryIfPresent(),
      try directory.info("transaction.json") == nil, try directory.info("transaction.new") == nil
    else {
      throw CoreError.invalidState("transaction recovery is required")
    }
    try validateBeforePublication()
    for request in requests { try request.evidence.validate() }
    try validateOverlap()
    let session = try makeSession(directory)
    outcome.journalID = session.journal.id
    do {
      try session.persist(.created)
      try session.emit(.phase(.preparing))
      try session.createContainers()
      try session.checkCapabilities()
      // Capability probing may only touch missing ancestry, journal and private containers.
      if session.journal.entries.contains(where: {
        ["state/agents.watch", "state/agents.resolved"].contains($0.path)
      }) {
        try SourceCache(store: store, checkpoint: checkpoint).beginWatchReferenceUpdate()
      }
      for index in session.journal.entries.indices {
        try session.stage(index, content: requests[index].content)
      }
      try session.emit(.preconditions)
      try validateBeforePublication()
      try session.validatePreimages()
      outcome.disposition = .recoveryRequired
      for index in session.journal.entries.indices { try session.publish(index) }
      try validateBeforePublication()
      try session.prepareCleanup()
      try session.emit(.commitValidated)
      session.journal.phase = .committed
      try session.persist(.terminal)
      outcome.disposition = .committed
      try session.emit(.phase(.committed))
      try session.cleanup()
    } catch {
      do { _ = try Self.recover(store: store, outcome: outcome) } catch {
        outcome.disposition = .recoveryRequired
      }
      throw error
    }
  }

  private func validateOverlap() throws {
    var targets: [URL] = []
    for request in requests {
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
        roots[key] = try paths.root(key, create: true, checkpoint: checkpoint)
      }
    }
    let parents = try requests.map {
      try paths.parent(for: $0.path, roots: roots, create: true, checkpoint: checkpoint)
    }
    for request in requests { try request.evidence.validateIdentity() }
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
        containers.append(.init(entry: index, name: ".agents-\(id.uuidString)-\(container)"))
      }
      entries.append(
        .init(
          path: request.path, action: request.action, preimage: request.evidence.snapshot,
          parentIdentity: identity, container: container))
    }
    let journal = TransactionJournal(
      id: id, scope: try directory.identity,
      roots: try roots.mapValues { try $0.identity }, entries: entries, containers: containers)
    let session = TransactionSession(
      journal: journal, directory: directory, parents: parents,
      checkpoint: checkpoint)
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

final class TransactionSession {
  var journal: TransactionJournal
  let directory: DirectoryHandle
  let parents: [DirectoryHandle]
  let checkpoint: (String) throws -> Void

  init(
    journal: TransactionJournal, directory: DirectoryHandle, parents: [DirectoryHandle],
    checkpoint: @escaping (String) throws -> Void
  ) {
    self.journal = journal
    self.directory = directory
    self.parents = parents
    self.checkpoint = checkpoint
  }

  func emit(_ point: TransactionCheckpoint) throws { try checkpoint(point.name) }
  func persist(_ change: TransactionCheckpoint.Change) throws {
    try requireScope()
    try directory.writeJournal(
      StateStore.encode(journal),
      afterWrite: {
        try emit(.persisted(journal.phase, change, .written))
      },
      afterRename: {
        try emit(.persisted(journal.phase, change, .renamed))
      })
  }

  func createContainers() throws {
    for index in journal.containers.indices {
      let parent = parents[journal.containers[index].entry]
      let created = try parent.makeDirectory(journal.containerName(index))
      let identity = try created.objectIdentity
      try emit(.containerCreated(index))
      guard try parent.info(journal.containerName(index)).map(FileObjectIdentity.init) == identity
      else {
        throw conflict(
          journal.containers[index].entry,
          "private container changed before its identity was durable")
      }
      journal.containers[index].identity = identity
    }
    // No object enters any container until all newly created identities are durable.
    try persist(.containers)
    try emit(.containersIdentified)
  }

  func container(_ index: Int) throws -> DirectoryHandle {
    let record = journal.containers[index]
    let parent = parents[record.entry]
    guard let expected = record.identity,
      try parent.info(record.name).map(FileObjectIdentity.init) == expected
    else {
      throw conflict(record.entry, "private container identity changed or is missing")
    }
    let handle = try parent.child(record.name)
    guard try handle.objectIdentity == expected else {
      throw conflict(record.entry, "private container changed while opening")
    }
    return handle
  }

  func checkCapabilities() throws {
    for index in journal.containers.indices {
      try container(index).requireAtomicRenames { try emit(.probe(index, $0)) }
    }
  }

  func stage(_ index: Int, content input: FileTransaction.Content) throws {
    let entry = journal.entries[index]
    let parent = parents[index]
    let scratch = try container(entry.container)
    try entry.preimage?.synchronize(entry.name, from: parent)
    try emit(.stage(index, .preimageSynced))
    var content = try prepareContent(input, index: index, scratch: scratch)
    if content.data != nil {
      content.expectedMode = entry.preimage?.isRegular == true ? entry.preimage!.mode : 0o600
    }
    let name = TransactionScratch.staged.name(index)
    try construct(content, index: index, scratch: scratch, parent: parent)
    try emit(.stage(index, .constructed))
    let capture = try FileSnapshot.capture(name, from: scratch)
    try verify(content, capture: capture)
    if entry.action == .install, capture.snapshot == nil {
      throw conflict(index, "missing constructed object")
    }
    for slot in TransactionScratch.objectSlots
    where entry.action == .delete || slot != .staged {
      guard try scratch.info(slot.name(index)) == nil else {
        throw CoreError.invalidState("unexpected private recovery slot before sealing")
      }
    }
    try scratch.sync()
    journal.entries[index].staged = capture.snapshot
    try advance(index, to: .ready)
  }

  private func prepareContent(
    _ input: FileTransaction.Content, index: Int,
    scratch: DirectoryHandle
  ) throws -> FileTransaction.Content {
    guard let prepare = input.prepare else { return input }
    var content = input
    let name = TransactionScratch.work.name(index)
    try scratch.makeDirectory(name, syncParent: false)
    try emit(.stage(index, .workCreated))
    let root = scratch.url.appendingPathComponent(name)
    let source = try prepare(root)
    guard PathSafety.isContained(source.resolvingSymlinksInPath(), in: root) else {
      throw CoreError.unsafePath("prepared content escapes transaction staging")
    }
    content.url = source
    (content.expectedHash, content.executableFlags, content.expectedKind, content.expectedMode) =
      try FileTransaction.copyExpectation(
        source, hash: nil, flags: nil)
    try emit(.stage(index, .workPrepared))
    return content
  }

  private func construct(
    _ content: FileTransaction.Content, index: Int,
    scratch: DirectoryHandle, parent: DirectoryHandle
  ) throws {
    let entry = journal.entries[index]
    let name = TransactionScratch.staged.name(index)
    if let data = content.data {
      try scratch.write(
        name, data: data,
        preservingMetadataOf: entry.preimage?.isRegular == true ? entry.name : nil,
        originalParent: parent, syncParent: false,
        afterCreate: { try emit(.stage(index, .writeCreated)) })
    } else if let source = content.url {
      if content.link {
        // The link is interpreted after publication, relative to the target parent.
        let destination = content.linkDestination ?? source.path
        try scratch.link(name, destination: destination, syncParent: false)
      } else {
        try Self.validateCopy(source)
        let origin = source.resolvingSymlinksInPath()
        try scratch.copy(
          name, from: DirectoryHandle(at: origin.deletingLastPathComponent()),
          named: origin.lastPathComponent, syncParent: false
        ) { try emit(.copy(index, $0)) }
      }
    }
  }

  private func verify(_ content: FileTransaction.Content, capture: FileSnapshot.Capture) throws {
    if let kind = content.expectedKind, capture.snapshot?.identity.kind != kind {
      throw CoreError.invalidState("staged content type mismatch")
    }
    if content.data != nil, capture.snapshot?.isRegular != true {
      throw CoreError.invalidState("staged content type mismatch")
    }
    if let mode = content.expectedMode, capture.snapshot?.mode != mode {
      throw CoreError.invalidState("staged content permissions mismatch")
    }
    if content.link {
      let destination = content.linkDestination ?? content.url!.path
      guard capture.snapshot?.isSymbolicLink == true,
        capture.snapshot?.digest == FileHash.sha256Hex(data: Data(destination.utf8))
      else { throw CoreError.invalidState("staged symbolic link destination mismatch") }
    }
    if let data = content.data, capture.snapshot?.digest != FileHash.sha256Hex(data: data) {
      throw CoreError.invalidState("staged content bytes mismatch")
    }
    if let expected = content.expectedHash {
      let actual = try content.link ? FileHash.folderHash(content.url!) : capture.contentHash
      guard "sha256:" + actual == expected else {
        throw CoreError.invalidState("staged content digest mismatch")
      }
    }
    if let flags = content.executableFlags {
      let actual =
        try content.link ? FileHash.executableFlags(content.url!) : capture.executableFlags
      guard actual == flags else {
        throw CoreError.invalidState("staged content executable mode mismatch")
      }
    }
  }

  func validatePreimages() throws {
    for index in journal.entries.indices { try requirePreimage(index) }
  }

  func publish(_ index: Int) throws {
    let entry = journal.entries[index]
    let parent = parents[index]
    let scratch = try container(entry.container)
    let layout = try distribution(index)
    guard layout.kind == .prepared else {
      throw conflict(index, "operation is not prepared")
    }
    try advance(index, to: .publishing)
    try requirePreimage(index)
    try emit(.publication(index, .validated))
    try grantDirectoryPermissions(index, layout: layout, purpose: .publicationGrant)
    if entry.action == .install {
      let exchange = entry.preimage != nil
      try scratch.move(
        TransactionScratch.staged.name(index), to: parent, named: entry.name,
        mode: exchange ? .exchange : .exclusive
      ) {
        try emit(.publication(index, exchange ? .exchanged : .created))
      }
    } else if entry.preimage != nil {
      try parent.move(
        entry.name, to: scratch, named: TransactionScratch.preimage.name(index), mode: .exclusive
      ) {
        try emit(.publication(index, .quarantined))
      }
    }
    try emit(.publication(index, .synced))
    try restoreDirectoryPermissions(index, purpose: .publicationRestore)
    guard try distribution(index, permittingDirectoryWrite: false).kind == .installed else {
      throw conflict(index, "publication did not retain its preimage")
    }
    try advance(index, to: .applied)
  }

  func requirePreimage(_ index: Int) throws {
    try requireParent(index)
    guard
      try FileSnapshot.read(journal.entries[index].name, from: parents[index])
        == journal.entries[index].preimage
    else {
      throw conflict(index, "preparation is stale; prepare again")
    }
  }

  /// A copied subtree keeps relative links that stay inside it, dangling ones included.
  private static func validateCopy(_ source: URL) throws {
    guard let root = PathSafety.realPath(source.path),
      let entries = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let entry as URL in entries {
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        entries.skipDescendants()
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        guard !destination.hasPrefix("/"), try PathSafety.linkStaysInside(entry, root: root) else {
          throw CoreError.unsafePath("copy symlink escapes installed subtree: \(entry.path)")
        }
      }
    }
  }
}
