import CPlatform
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Independent of shared acquisitions and any project location. Only ZIPs constitute recovery
/// authority. Each scope reservation protects both its visible generation and the pending one.
struct PrivateSourceRecovery {
  struct Reference: Hashable, Sendable {
    let transport: String
    let archive: SourceArchiveEvidence

    var key: String {
      AcquisitionCache.key([
        ("repository", Data(transport.utf8)),
        ("request", Data(archive.effectiveURL.absoluteString.utf8)),
        ("flavor", Data(archive.flavor.rawValue.utf8)),
        ("tree", Data(archive.treeDigest.utf8)),
        ("representation", Data((archive.requiredArchiveDigest ?? "tree").utf8)),
      ])
    }
  }

  let environment: RuntimeEnvironment

  private var root: URL {
    environment.homeDirectory.appendingPathComponent(".agents-source-recovery", isDirectory: true)
  }

  static func makeWorkspace(prefix: String) throws -> DirectoryHandle {
    let parent = try DirectoryHandle(
      at: FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
    return try parent.createPrivateDirectory(prefix + UUID().uuidString)
  }

  func requirePublicationAccess() throws {
    let home = root.deletingLastPathComponent()
    let parent = try DirectoryHandle(at: home)
    _ = try DirectoryAccessEvidence.capture(at: home)
    guard platform_access(parent.descriptor, ".", W_OK | X_OK) == 0 else {
      throw SourceAccessError.recoveryUnavailable
    }
    if let store = try directory(create: false),
      platform_access(store.descriptor, ".", W_OK | X_OK) != 0
    {
      throw SourceAccessError.recoveryUnavailable
    }
  }

  func treeURL(_ reference: Reference) -> URL {
    root.appendingPathComponent(reference.key).appendingPathComponent("tree", isDirectory: true)
  }

  func read(_ reference: Reference) throws -> (Data, VerifiedVCSArchive)? {
    guard let store = try directory(create: false),
      try store.info(reference.key) != nil
    else { return nil }
    _ = try store.requirePrivateAccess(reference.key)
    return try read(reference, entry: store.child(reference.key))
  }

  private func read(
    _ reference: Reference, entry: DirectoryHandle
  ) throws -> (Data, VerifiedVCSArchive)? {
    guard try entry.info("archive") != nil else { return nil }
    let access = try entry.requirePrivateAccess("archive")
    guard access.mode == 0o600 else { throw SourceAccessError.recoveryUnavailable }
    let stored = try entry.read("archive", maximumBytes: VerifiedVCSArchive.compressedLimit + 71)
    guard stored.count >= 71 else { throw SourceAccessError.invalidArchive }
    let digest = String(decoding: stored.prefix(71), as: UTF8.self)
    let bytes = Data(stored.dropFirst(71))
    guard "sha256:" + FileHash.sha256Hex(data: bytes) == digest else {
      throw SourceAccessError.invalidArchive
    }
    let verified = try VerifiedVCSArchive(bytes)
    try reference.archive.verify(verified)
    return (bytes, verified)
  }

  func withPublication<T>(
    store scope: StateStore, previous: Set<Reference>, next: Set<Reference>,
    captures: GitAcquisitionCaptures?, policy: EffectiveSourcePolicy,
    offline: Bool, checkpoint: (String) throws -> Void, _ body: () throws -> T
  ) throws -> T {
    guard !previous.isEmpty || !next.isEmpty || FileManager.default.fileExists(atPath: root.path)
    else {
      return try body()
    }
    let store = try directory(create: true)!
    return try FileLock.withLock(in: store, named: "lock") {
      let reservation = reservationName(scope)
      for (index, reference) in next.sorted(by: { $0.key < $1.key }).enumerated() {
        let route = try SourceRoute(
          SourceDeclaration(kind: .git, location: reference.transport),
          environment: environment, policy: policy)
        guard let request = try route.requireRecordedArchive(reference.archive) else {
          throw SourceAccessError.routeChanged
        }
        let entry =
          try store.info(reference.key) == nil
          ? store.createPrivateDirectory(reference.key) : store.child(reference.key)
        _ = try store.requirePrivateAccess(reference.key)
        let verified: VerifiedVCSArchive
        if let (_, existing) = try read(reference, entry: entry) {
          verified = existing
        } else {
          let bytes: Data
          if let captured = try captures?.readArchive(reference) {
            bytes = captured
          } else {
            guard !offline else { throw SourceAccessError.recoveryUnavailable }
            bytes = try Self.download(request, route: route, environment: environment)
          }
          verified = try VerifiedVCSArchive(bytes)
          try reference.archive.verify(verified)
          try entry.removeFiles(["archive-next"])
          let file = try entry.createPrivateFile("archive-next")
          try file.write(Data(verified.byteDigest.utf8) + bytes)
          guard renameat(entry.descriptor, "archive-next", entry.descriptor, "archive") == 0 else {
            throw SourceAccessError.recoveryUnavailable
          }
          try entry.sync()
        }
        try checkpoint("archive.recovery.\(index).bytes")
        let tree = entry.url.appendingPathComponent("tree")
        if try !verified.matches(tree) {
          let staging = "tree-" + UUID().uuidString
          _ = try verified.extract(named: staging, in: entry, environment: environment)
          try entry.replaceRecoveryTree(staging: staging)
        }
      }
      // Keep both generations until the scope transaction has committed. A crashed publish
      // leaves the superset; only this scope reconciles it after its journal is recovered.
      try record(previous.union(next), name: reservation, in: store)
      try checkpoint("archive.recovery.reserved")
      let result = try body()
      try record(next, name: reservation, in: store)
      try checkpoint("archive.recovery.committed")
      try prune(store)
      return result
    }
  }

  func reconcile(scope: StateStore) throws {
    guard FileManager.default.fileExists(atPath: root.path),
      let store = try directory(create: false)
    else { return }
    try FileLock.withLock(in: store, named: "lock") {
      let name = reservationName(scope)
      guard try store.info(name) != nil else { return }
      try record(scope.retentionReferences().archives, name: name, in: store)
      try prune(store)
    }
  }

  private func reservationName(_ scope: StateStore) -> String {
    let directory = scope.directory.resolvingSymlinksInPath().standardizedFileURL
    return "scope-" + FileHash.sha256Hex(data: Data(directory.path.utf8))
  }

  private func record(_ references: Set<Reference>, name: String, in store: DirectoryHandle) throws
  {
    if references.isEmpty {
      try store.removeFiles([name])
    } else {
      let keys = Set(references.map(\.key)).sorted()
      try store.replaceFile(
        name, through: name + ".next", with: StateStore.encode(keys),
        afterWrite: {}, afterRename: {})
    }
  }

  private func prune(_ store: DirectoryHandle) throws {
    let names = try store.names()
    var retained = Set<String>()
    for name in names where name.hasPrefix("scope-") && name.count == 70 {
      _ = try store.requirePrivateAccess(name)
      let bytes = try store.read(name, maximumBytes: LedgerLimits.standard.encodedBytes)
      let keys = try JSONDecoder().decode([String].self, from: bytes)
      guard keys.allSatisfy(Self.isKey) else { throw SourceAccessError.recoveryUnavailable }
      retained.formUnion(keys)
    }
    for name in names where Self.isKey(name) && !retained.contains(name) {
      _ = try store.requirePrivateAccess(name)
      try FileManager.default.removeItem(at: store.url.appendingPathComponent(name))
    }
    try store.sync()
  }

  private static func isKey(_ name: String) -> Bool {
    name.utf8.count == 64
      && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private func directory(create: Bool) throws -> DirectoryHandle? {
    let home = root.deletingLastPathComponent()
    _ = try DirectoryAccessEvidence.capture(at: home)
    guard let parent = try? DirectoryHandle(at: home) else {
      if create { throw SourceAccessError.recoveryUnavailable }
      return nil
    }
    let name = root.lastPathComponent
    if try parent.info(name) == nil {
      guard create else { return nil }
      do { _ = try parent.createPrivateDirectory(name) } catch {
        guard try parent.info(name) != nil else { throw error }
      }
    }
    let access = try parent.requirePrivateAccess(name)
    guard access.mode == 0o700 else { throw SourceAccessError.recoveryUnavailable }
    return try parent.child(name)
  }

  static func download(
    _ request: VCSArchiveRequest, route: SourceRoute, environment: RuntimeEnvironment
  ) throws -> Data {
    var get = URLRequest(url: request.url)
    get.httpMethod = "GET"
    get.setValue("application/zip", forHTTPHeaderField: "Accept")
    if let binding = try route.credential(environment.sourceAccess) {
      get.setValue("Bearer " + (try binding.value()), forHTTPHeaderField: "Authorization")
    }
    let response = try PackageSourceHTTP.read(get, maximumBytes: VerifiedVCSArchive.compressedLimit)
    guard response.status == 200 else { throw SourceAccessError.requestFailed }
    return response.body
  }
}

extension DirectoryHandle {
  fileprivate func replaceRecoveryTree(staging: String) throws {
    if try info("tree") == nil {
      guard renameat(descriptor, staging, descriptor, "tree") == 0 else {
        throw SourceAccessError.recoveryUnavailable
      }
    } else {
      guard platform_exchange(descriptor, staging, descriptor, "tree") == 0 else {
        throw SourceAccessError.recoveryUnavailable
      }
      try FileManager.default.removeItem(at: url.appendingPathComponent(staging))
    }
    try sync()
  }
}
