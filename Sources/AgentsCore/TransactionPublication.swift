import Foundation

/// Construction, sealing and publication of a commit's operations.
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
      let container = try self.container(index)
      let device = try container.device
      guard !capableDevices.contains(device) else { continue }
      let names = TransactionSlot.probes
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
    let container = try self.container(entry.container)
    if let preimage = entry.preimage { try parent.synchronize(entry.name, as: preimage) }
    try emit(.stage(index, .preimageSynced))
    let staging = TransactionSlot.staging(for: entry)
    var staged: FileSnapshot?
    if let source {
      let sealed = try construct(
        source, expectation: expectation, named: staging.name(index), index: index,
        container: container, parent: parent)
      try emit(.stage(index, .constructed))
      let capture = try FileSnapshot.capture(staging.name(index), from: container)
      try verify(source, sealed, capture: capture)
      guard let snapshot = capture.snapshot else {
        throw conflict(index, "missing constructed object")
      }
      staged = snapshot
    } else {
      try emit(.stage(index, .constructed))
    }
    for slot in TransactionSlot.objectSlots where source == nil || slot != staging {
      guard try container.info(slot.name(index)) == nil else {
        throw CoreError.invalidState("unexpected private recovery slot before sealing")
      }
    }
    try container.sync()
    journal.entries[index].staged = staged
    try advance(index, to: .ready)
  }

  /// Returns the expectation the sealed staging must meet.
  private func construct(
    _ source: FileTransaction.Source, expectation: FileTransaction.Expectation,
    named name: String, index: Int, container: DirectoryHandle, parent: DirectoryHandle
  ) throws -> FileTransaction.Expectation {
    let entry = journal.entries[index]
    var expectation = expectation
    switch source {
    case .data(let data):
      let original = entry.preimage?.isRegular == true ? entry.preimage : nil
      expectation.mode = original?.mode ?? 0o600
      try container.write(
        name, data: data, preservingMetadataOf: original == nil ? nil : entry.name,
        originalParent: parent, syncParent: false,
        afterCreate: { try emit(.stage(index, .writeCreated)) })
    case .link(let url):
      let destination = expectation.linkDestination ?? url.path
      expectation.linkDestination = destination
      try container.link(name, destination: destination, syncParent: false)
    case .copy(let url):
      try copy(url, named: name, index: index, container: container)
    case .prepared(let produce):
      let work = TransactionSlot.work.name(index)
      try container.makeDirectory(work, syncParent: false)
      try emit(.stage(index, .workCreated))
      let root = container.url.appendingPathComponent(work)
      let url = try produce(root)
      guard PathSafety.isContained(url.resolvingSymlinksInPath(), in: root) else {
        throw CoreError.unsafePath("prepared content escapes transaction staging")
      }
      expectation = try FileTransaction.copyExpectation(
        url, hash: expectation.hash, flags: expectation.executableFlags)
      try emit(.stage(index, .workPrepared))
      try copy(url, named: name, index: index, container: container)
    }
    return expectation
  }

  private func copy(_ source: URL, named name: String, index: Int, container: DirectoryHandle)
    throws
  {
    try Self.validateCopy(source)
    let origin = source.resolvingSymlinksInPath()
    try container.copy(
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
    case .link(let url):
      guard snapshot?.isSymbolicLink == true, let destination = expectation.linkDestination,
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
    let container = try self.container(entry.container)
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
      try container.move(
        TransactionSlot.staging(for: entry).name(index), to: parent, named: entry.name,
        mode: exchange ? .exchange : .exclusive
      ) {
        try emit(.publication(index, exchange ? .exchanged : .created))
      }
    } else if entry.preimage != nil {
      try parent.move(
        entry.name, to: container, named: TransactionSlot.deleted.name(index), mode: .exclusive
      ) {
        try emit(.publication(index, .deleted))
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
