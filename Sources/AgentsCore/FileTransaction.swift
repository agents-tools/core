import Foundation

/// The scope's sole durable undo journal owns private construction containers,
/// sealed publication evidence and terminal disposal. The scope writer lock spans
/// preparation, commit and recovery; external writers are identified by inode and digest.
package final class FileTransaction {
  enum Source {
    case data(Data)
    case copy(URL)
    /// The destination is interpreted after publication, relative to the target parent.
    case link(URL, destination: String)
    /// A producer may construct arbitrary intermediate objects only inside its private container.
    case prepared((URL) throws -> URL)
  }
  /// Checks for the sealed staging; nil fields are not compared.
  struct Expectation {
    var hash: String?
    var executableFlags: [String: Bool]?
    var kind: mode_t?
    var mode: mode_t?
  }
  private struct Request {
    let path: String
    let evidence: TargetPrecondition
    /// Absent for a deletion.
    let source: Source?
    let expectation: Expectation
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
    let source: Source?
    if let data {
      source = .data(data)
    } else if let content {
      source =
        link
        ? .link(
          content,
          destination: Self.linkDestination(
            content, parent: destination.deletingLastPathComponent(), store: store))
        : .copy(content)
    } else {
      source = nil
    }
    try append(destination, source: source, expecting: expecting) {
      guard case .copy(let url) = source else {
        return Expectation(hash: expectedHash, executableFlags: executableFlags)
      }
      return try Self.copyExpectation(url, hash: expectedHash, flags: executableFlags)
    }
  }

  func prepare(_ destination: URL, content: @escaping (URL) throws -> URL) throws {
    try append(destination, source: .prepared(content), expecting: nil) { Expectation() }
  }

  func remove(_ name: String, from parent: DirectoryHandle) throws {
    try replace(parent.url.appendingPathComponent(name), content: nil)
  }

  private func append(
    _ destination: URL, source: Source?, expecting: TargetPrecondition?,
    expectation: () throws -> Expectation
  ) throws {
    let path = try TransactionPaths(store: store).path(for: destination)
    guard !requests.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    let evidence = try expecting ?? TargetPrecondition(destination)
    guard evidence.url.path == destination.standardizedFileURL.path else {
      throw CoreError.invalidState("precondition belongs to another target")
    }
    requests.append(
      Request(path: path, evidence: evidence, source: source, expectation: try expectation()))
  }

  fileprivate static func copyExpectation(
    _ source: URL, hash: String?, flags: [String: Bool]?
  ) throws -> Expectation {
    let physical = source.resolvingSymlinksInPath()
    let parent = try DirectoryHandle(at: physical.deletingLastPathComponent())
    if let hash, let flags {
      let info = try parent.info(physical.lastPathComponent)
      return Expectation(
        hash: hash, executableFlags: flags, kind: info.map(FileObjectIdentity.init)?.kind,
        mode: info.map { $0.st_mode & 0o7777 })
    }
    let capture = try FileSnapshot.capture(physical.lastPathComponent, from: parent)
    guard let snapshot = capture.snapshot else { throw CoreError.notFound(source.path) }
    return Expectation(
      hash: hash ?? "sha256:" + capture.contentHash,
      executableFlags: flags ?? capture.executableFlags,
      kind: snapshot.identity.kind, mode: snapshot.mode)
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
      for (index, request) in requests.enumerated() {
        try session.stage(index, source: request.source, expectation: request.expectation)
      }
      try session.emit(.preconditions)
      try validateBeforePublication()
      try session.validatePreimages()
      outcome.disposition = .recoveryRequired
      for index in session.journal.entries.indices { try session.publish(index) }
      try validateBeforePublication()
      try session.prepareCleanup()
      try session.emit(.commitValidated)
      try session.finish(.committed)
      outcome.disposition = .committed
      try session.emit(.phase(.committed))
      try session.dispose()
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
        roots[key] = try paths.root(key, create: true) { step in
          try checkpoint(TransactionCheckpoint.rootAncestry(key, step).name)
        }
      }
    }
    let parents = try requests.enumerated().map { index, request in
      try paths.parent(for: request.path, roots: roots, create: true) { level in
        try checkpoint(TransactionCheckpoint.parentCreated(entry: index, level: level).name)
      }
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
        containers.append(
          .init(entry: index, name: TransactionJournal.containerName(id: id, index: container)))
      }
      entries.append(
        .init(
          path: request.path, action: request.source == nil ? .delete : .install,
          preimage: request.evidence.snapshot, parentIdentity: identity, container: container))
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

extension TransactionSession {
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

  func checkCapabilities() throws {
    for index in journal.containers.indices {
      let container = try container(index)
      let device = try container.device
      guard !capableDevices.contains(device) else { continue }
      let names = TransactionScratch.probes
      try container.requireAtomicRenames(
        first: names.first, second: names.second, moved: names.moved
      ) { try emit(.probe(index, $0)) }
      capableDevices.insert(device)
    }
  }

  func stage(
    _ index: Int, source: FileTransaction.Source?, expectation: FileTransaction.Expectation
  ) throws {
    let entry = journal.entries[index]
    let parent = parents[index]
    let scratch = try container(entry.container)
    if let preimage = entry.preimage { try parent.synchronize(entry.name, as: preimage) }
    try emit(.stage(index, .preimageSynced))
    let staging = TransactionScratch.staging(for: entry)
    var staged: FileSnapshot?
    if let source {
      let sealed = try construct(
        source, expectation: expectation, named: staging.name(index), index: index,
        scratch: scratch, parent: parent)
      try emit(.stage(index, .constructed))
      let capture = try FileSnapshot.capture(staging.name(index), from: scratch)
      try verify(source, sealed, capture: capture)
      guard let snapshot = capture.snapshot else {
        throw conflict(index, "missing constructed object")
      }
      staged = snapshot
    } else {
      try emit(.stage(index, .constructed))
    }
    for slot in TransactionScratch.objectSlots where source == nil || slot != staging {
      guard try scratch.info(slot.name(index)) == nil else {
        throw CoreError.invalidState("unexpected private recovery slot before sealing")
      }
    }
    try scratch.sync()
    journal.entries[index].staged = staged
    try advance(index, to: .ready)
  }

  /// Returns the expectation the sealed staging must meet.
  private func construct(
    _ source: FileTransaction.Source, expectation: FileTransaction.Expectation,
    named name: String, index: Int, scratch: DirectoryHandle, parent: DirectoryHandle
  ) throws -> FileTransaction.Expectation {
    let entry = journal.entries[index]
    var expectation = expectation
    switch source {
    case .data(let data):
      let original = entry.preimage?.isRegular == true ? entry.preimage : nil
      expectation.mode = original?.mode ?? 0o600
      try scratch.write(
        name, data: data, preservingMetadataOf: original == nil ? nil : entry.name,
        originalParent: parent, syncParent: false,
        afterCreate: { try emit(.stage(index, .writeCreated)) })
    case .link(_, let destination):
      try scratch.link(name, destination: destination, syncParent: false)
    case .copy(let url):
      try copy(url, named: name, index: index, scratch: scratch)
    case .prepared(let produce):
      let work = TransactionScratch.work.name(index)
      try scratch.makeDirectory(work, syncParent: false)
      try emit(.stage(index, .workCreated))
      let root = scratch.url.appendingPathComponent(work)
      let url = try produce(root)
      guard PathSafety.isContained(url.resolvingSymlinksInPath(), in: root) else {
        throw CoreError.unsafePath("prepared content escapes transaction staging")
      }
      expectation = try FileTransaction.copyExpectation(url, hash: nil, flags: nil)
      try emit(.stage(index, .workPrepared))
      try copy(url, named: name, index: index, scratch: scratch)
    }
    return expectation
  }

  private func copy(_ source: URL, named name: String, index: Int, scratch: DirectoryHandle)
    throws
  {
    try Self.validateCopy(source)
    let origin = source.resolvingSymlinksInPath()
    try scratch.copy(
      name, from: DirectoryHandle(at: origin.deletingLastPathComponent()),
      named: origin.lastPathComponent, syncParent: false
    ) { try emit(.copy(index, $0)) }
  }

  private func verify(
    _ source: FileTransaction.Source, _ expectation: FileTransaction.Expectation,
    capture: FileSnapshot.Capture
  ) throws {
    let snapshot = capture.snapshot
    if let kind = expectation.kind, snapshot?.identity.kind != kind {
      throw CoreError.invalidState("staged content type mismatch")
    }
    if case .data = source, snapshot?.isRegular != true {
      throw CoreError.invalidState("staged content type mismatch")
    }
    if let mode = expectation.mode, snapshot?.mode != mode {
      throw CoreError.invalidState("staged content permissions mismatch")
    }
    var linked: URL?
    switch source {
    case .data(let data):
      guard snapshot?.digest == FileHash.sha256Hex(data: data) else {
        throw CoreError.invalidState("staged content bytes mismatch")
      }
    case .link(let url, let destination):
      guard snapshot?.isSymbolicLink == true,
        snapshot?.digest == FileHash.sha256Hex(data: Data(destination.utf8))
      else { throw CoreError.invalidState("staged symbolic link destination mismatch") }
      linked = url
    case .copy, .prepared: break
    }
    if let expected = expectation.hash {
      let actual = try linked.map(FileHash.folderHash) ?? capture.contentHash
      guard "sha256:" + actual == expected else {
        throw CoreError.invalidState("staged content digest mismatch")
      }
    }
    if let flags = expectation.executableFlags {
      let actual = try linked.map(FileHash.executableFlags) ?? capture.executableFlags
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
    // A stale preparation cancels from ready; rechecking after the intent narrows the race.
    try requirePreimage(index)
    try advance(index, to: .publishing)
    try requirePreimage(index)
    try emit(.publication(index, .validated))
    try grantDirectoryPermissions(index, layout: layout, purpose: .publicationGrant)
    if entry.action == .install {
      let exchange = entry.preimage != nil
      try scratch.move(
        TransactionScratch.staging(for: entry).name(index), to: parent, named: entry.name,
        mode: exchange ? .exchange : .exclusive
      ) {
        try emit(.publication(index, exchange ? .exchanged : .created))
      }
    } else if entry.preimage != nil {
      try parent.move(
        entry.name, to: scratch, named: TransactionScratch.deleted.name(index), mode: .exclusive
      ) {
        try emit(.publication(index, .quarantined))
      }
    }
    try emit(.publication(index, .synced))
    try restoreDirectoryPermissions(index, purpose: .publicationRestore)
    guard try distribution(index).kind == .installed else {
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
