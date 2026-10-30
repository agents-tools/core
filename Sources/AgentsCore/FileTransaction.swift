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
    var executableFlags: [String: Bool]?
    var kind: mode_t?
    var mode: mode_t?
    /// The destination a staged symbolic link must contain.
    var linkDestination: String?
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
    let (path, evidence) = try request(destination, expecting: expecting)
    var expectation = Expectation(hash: expectedHash, executableFlags: executableFlags)
    switch source {
    case .copy(let url):
      expectation = try Self.copyExpectation(url, hash: expectedHash, flags: executableFlags)
    case .link(let url):
      expectation.linkDestination = Self.linkDestination(
        url, parent: destination.deletingLastPathComponent(), store: store)
    case .data, .prepared: break
    }
    requests.append(
      Request(path: path, evidence: evidence, source: source, expectation: expectation))
  }

  package func delete(_ destination: URL, expecting: TargetPrecondition? = nil) throws {
    let (path, evidence) = try request(destination, expecting: expecting)
    requests.append(Request(path: path, evidence: evidence, source: nil, expectation: .init()))
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
    path: String, evidence: TargetPrecondition
  ) {
    let path = try TransactionPaths(store: store).path(for: destination)
    guard !requests.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    let evidence = try expecting ?? TargetPrecondition(destination)
    guard evidence.url.path == destination.standardizedFileURL.path else {
      throw CoreError.invalidState("precondition belongs to another target")
    }
    return (path, evidence)
  }

  static func copyExpectation(
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
      try !TransactionJournal.isPresent(in: directory)
    else {
      throw CoreError.invalidState("transaction recovery is required")
    }
    try validateUnchanged()
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
      try validateUnchanged()
      try session.validatePreimages()
      outcome.disposition = .recoveryRequired
      for index in session.journal.entries.indices { try session.publish(index) }
      try validateUnchanged()
      try session.sealDisposal()
      try session.emit(.commitValidated)
      try session.finish(.committed)
      outcome.disposition = .committed
      try session.emit(.phase(.committed))
      try session.dispose()
    } catch {
      // Recovery names its checkpoints under `recovery.`, apart from the failed commit's.
      do {
        _ = try Self.recover(store: store, outcome: outcome) {
          try self.checkpoint("recovery." + $0)
        }
      } catch {
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
      try paths.parent(for: request.path, roots: roots, create: true) { step in
        try checkpoint(TransactionCheckpoint.parentAncestry(entry: index, step).name)
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
