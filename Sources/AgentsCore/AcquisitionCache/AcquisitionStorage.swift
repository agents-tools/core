import CPlatform
import Foundation

extension AcquisitionCache {
  package struct Value: Sendable {
    package let data: Data
    package let metadata: Data
    package let publication: UUID
  }

  package enum WriteCondition: Sendable {
    case absent
    case publication(UUID)
  }

  private struct Record: Codable {
    let store: AcquisitionCacheStore
    let key: String
    let object: String
    let digest: String
    let size: Int
    let metadata: Data
    var publication: UUID
    let created: Date
    var revoked: Bool?
  }

  private struct Access: Codable {
    let generation: UUID
    let time: Date
  }

  private struct Entry {
    let directory: DirectoryHandle
    let record: Record
    let payload: stat
    let summary: AcquisitionCacheEntry
  }

  private struct Receipt: Codable {
    let id: UUID
    let record: Record
    let access: Access
    let identities: [String: FileObjectIdentity]
  }

  private static let marker = ".agents-acquisition-cache"
  private static let markerContents = Data("agents acquisition cache 1\n".utf8)
  private static let trash = ".trash"
  private static let leases = ".leases"
  private static let payload = "bytes"
  private static let manifest = "record.json"
  private static let nextManifest = "record.next"
  private static let access = "access.json"
  private static let nextAccess = "access.next"
  private static let recordLimit = 64 * 1024
  private static let typedFiles: Set<String> = [
    payload, manifest, nextManifest, access, nextAccess,
  ]

  package static func key(_ records: [(String, Data)]) -> String {
    FileHash.hashRecords(records)
  }

  package func read<T>(
    _ store: AcquisitionCacheStore, key: String, maximumBytes: Int,
    now: Date = Date(), touching: Bool = true, _ body: (Value) throws -> T
  ) throws -> T? {
    func openEntry(in root: DirectoryHandle?) throws -> (Entry, Lease)? {
      guard let root,
        let parent = try directory(store.rawValue, in: root),
        let entry = try entry(store, key: key, in: parent), entry.record.revoked != true,
        entry.record.size <= maximumBytes
      else { return nil }
      let lease = try entryLease(store, key: key, root: root, create: false, exclusive: false)
      return (entry, lease)
    }

    func verified(_ entry: Entry) throws -> Value {
      let data = try entry.directory.read(
        Self.payload, matching: entry.payload, maximumBytes: maximumBytes)
      guard data.count == entry.record.size,
        FileHash.sha256Hex(data: data) == entry.record.digest
      else { throw AcquisitionCacheError.invalidEntry }
      return .init(
        data: data, metadata: entry.record.metadata, publication: entry.record.publication)
    }

    // Registry reads copy their bounded response under root coordination. This keeps conditional
    // invalidation from racing a lease associated only with an in-memory HTTP representation.
    if store == .http {
      let value = try withRoot(exclusive: touching) { root in
        guard let (entry, lease) = try openEntry(in: root) else { return nil as Value? }
        return try withExtendedLifetime(lease) {
          let value = try verified(entry)
          if touching { try touch(entry, now: now) }
          return value
        }
      }
      return try value.map(body)
    }

    let found = try withRoot(exclusive: touching) { root in
      let found = try openEntry(in: root)
      if touching, let (entry, _) = found { try touch(entry, now: now) }
      return found
    }
    guard let (entry, lease) = found else { return nil }
    return try withExtendedLifetime(lease) { try body(verified(entry)) }
  }

  private func touch(_ entry: Entry, now: Date) throws {
    let access = Access(generation: UUID(), time: max(now, entry.summary.lastUsed))
    try entry.directory.replaceFile(
      Self.access, through: Self.nextAccess, with: Self.encode(access),
      afterWrite: {}, afterRename: {})
  }

  package func publication(_ store: AcquisitionCacheStore, key: String) throws -> UUID? {
    try withRoot { root in
      guard let root, let parent = try directory(store.rawValue, in: root) else { return nil }
      return try entry(store, key: key, in: parent)?.record.publication
    }
  }

  /// Retains the previous generation if another request already advanced it.
  @discardableResult
  package func write(
    _ data: Data, store: AcquisitionCacheStore, key: String, object: String,
    metadata: Data = Data(), condition: WriteCondition = .absent, now: Date = Date(),
    totalLimit: Int64? = nil
  ) throws -> Bool {
    try withRoot(mutate: true) { root in
      guard let root else { throw AcquisitionCacheError.rootChanged }
      try Self.requireKey(key)
      let parent = try directory(store.rawValue, in: root, create: true)!
      let previous = try entry(store, key: key, in: parent)
      guard matches(previous, condition: condition) else { return false }
      let lease = try entryLease(store, key: key, root: root, create: true, exclusive: true)
      return try withExtendedLifetime(lease) {
        let record = Record(
          store: store, key: key, object: object, digest: FileHash.sha256Hex(data: data),
          size: data.count, metadata: metadata, publication: UUID(), created: now)
        try Self.validate(record, store: store, key: key)
        let encoded = try Self.encode(record)
        guard encoded.count <= Self.recordLimit else { throw AcquisitionCacheError.invalidEntry }
        if let totalLimit {
          try makeRoom(
            in: parent, root: root, store: store, keeping: key,
            incoming: Int64(data.count + encoded.count), limit: totalLimit)
        }
        if let previous {
          let detached = try detach(previous, parent: parent, root: root)
          _ = try dispose(detached, root: root)
        }
        try requireRootIdentity(root)
        return try parent.publishDirectory(
          named: key, files: [Self.manifest: encoded, Self.payload: data])
      }
    }
  }

  package func invalidate(
    _ store: AcquisitionCacheStore, key: String, publication: UUID
  ) throws {
    try withRoot(exclusive: true) { root in
      guard let root, let parent = try directory(store.rawValue, in: root),
        let current = try entry(store, key: key, in: parent),
        current.record.publication == publication
      else { return }
      let lease = try entryLease(store, key: key, root: root, create: false, exclusive: true)
      try withExtendedLifetime(lease) {
        // Revocation precedes reclamation. A permission error in trash must not leave a
        // reusable response or allow a concurrent validator to renew the retired publication.
        var revoked = current.record
        revoked.revoked = true
        revoked.publication = UUID()
        try current.directory.replaceFile(
          Self.manifest, through: Self.nextManifest, with: Self.encode(revoked),
          afterWrite: {}, afterRename: {})
        guard let retired = try entry(store, key: key, in: parent) else { return }
        if let detached = try? detach(retired, parent: parent, root: root) {
          _ = try? dispose(detached, root: root)
        }
      }
    }
  }

  private func matches(_ entry: Entry?, condition: WriteCondition) -> Bool {
    switch condition {
    case .absent: entry == nil
    case .publication(let old): entry?.record.publication == old
    }
  }

  private func makeRoom(
    in parent: DirectoryHandle, root: DirectoryHandle, store: AcquisitionCacheStore,
    keeping key: String, incoming: Int64, limit: Int64
  ) throws {
    guard incoming <= limit else { throw AcquisitionCacheError.invalidEntry }
    var remaining = try disposalBytes(store, root: root) + incoming
    let entries = try parent.names().filter { $0 != key }.compactMap {
      try entry(store, key: $0, in: parent)
    }.sorted { $0.summary.lastUsed < $1.summary.lastUsed }
    remaining += entries.reduce(0) { $0 + $1.summary.bytes }
    for entry in entries where remaining > limit {
      guard
        let lease = try? entryLease(
          store, key: entry.record.key, root: root, create: false, exclusive: true)
      else { continue }
      remaining -= try withExtendedLifetime(lease) {
        let detached = try detach(entry, parent: parent, root: root)
        return try dispose(detached, root: root)
      }
    }
    guard remaining <= limit else { throw AcquisitionCacheError.busy }
  }

  private func disposalBytes(_ store: AcquisitionCacheStore, root: DirectoryHandle) throws -> Int64
  {
    guard let trash = try directory(Self.trash, in: root) else { return 0 }
    return try trash.names().filter { $0.hasSuffix(".json") }.reduce(into: Int64(0)) {
      total, name in
      let entry = try pending(String(name.dropLast(5)), in: trash)
      if entry.store == store { total += entry.bytes }
    }
  }

  package func apply(
    _ preview: AcquisitionCachePreview, afterDetach: () throws -> Void
  ) throws -> AcquisitionCacheRemoval {
    guard root.path.utf8.elementsEqual(preview.root.path.utf8) else {
      throw AcquisitionCacheError.rootChanged
    }
    return try withRoot(exclusive: true) { root in
      guard try root?.objectIdentity == preview.rootIdentity else {
        throw AcquisitionCacheError.rootChanged
      }
      var removed: [AcquisitionCacheEntry] = []
      var skipped: [AcquisitionCacheEntry] = []
      var failed = preview.issues
      var reclaimed: Int64 = 0
      for candidate in preview.candidates {
        guard let root else { break }
        let path = candidate.pendingDisposal ? Self.trash : candidate.store.rawValue
        do {
          if candidate.pendingDisposal {
            guard let trash = try directory(Self.trash, in: root),
              try trash.info(candidate.id + ".json") != nil,
              try pending(candidate.id, in: trash) == candidate
            else {
              skipped.append(candidate)
              continue
            }
            try dispose(candidate.id, root: root, reclaimed: &reclaimed)
          } else {
            guard let parent = try directory(path, in: root),
              let entry = try entry(candidate.store, key: candidate.id, in: parent),
              entry.summary == candidate,
              preview.cutoff.map({ candidate.lastUsed < $0 && candidate.store == .git }) ?? true
            else {
              skipped.append(candidate)
              continue
            }
            let lease = try entryLease(
              candidate.store, key: candidate.id, root: root, create: false, exclusive: true)
            let name = try withExtendedLifetime(lease) {
              try detach(entry, parent: parent, root: root)
            }
            try afterDetach()
            try dispose(name, root: root, reclaimed: &reclaimed)
          }
          removed.append(candidate)
        } catch {
          failed.append(issue(path + "/" + candidate.id, error))
        }
      }
      return AcquisitionCacheRemoval(
        removed: removed, skipped: skipped, failures: failed, reclaimedBytes: reclaimed)
    }
  }

  func inventory(_ root: DirectoryHandle?) throws -> (
    report: AcquisitionCacheInventory, identity: FileObjectIdentity?
  ) {
    var entries: [AcquisitionCacheEntry] = []
    var issues: [AcquisitionCacheIssue] = []
    if let root, try root.info(Self.marker) != nil {
      func scan(_ name: String, _ inspect: (DirectoryHandle, String) throws -> Void) {
        do {
          guard let directory = try directory(name, in: root) else { return }
          for key in try directory.names() {
            do { try inspect(directory, key) } catch {
              issues.append(issue(name + "/" + key, error))
            }
          }
        } catch { issues.append(issue(name, error)) }
      }
      for store in AcquisitionCacheStore.allCases {
        scan(store.rawValue) { parent, key in
          if let entry = try entry(store, key: key, in: parent) { entries.append(entry.summary) }
        }
      }
      scan(Self.trash) { parent, key in
        if key.hasSuffix(".json") {
          entries.append(try pending(String(key.dropLast(5)), in: parent))
        } else {
          guard key.hasSuffix(".entry"),
            try parent.info(String(key.dropLast(6)) + ".json") != nil
          else { throw AcquisitionCacheError.invalidEntry }
        }
      }
      scan(Self.leases) { parent, key in
        let fields = key.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 2, AcquisitionCacheStore(rawValue: String(fields[0])) != nil,
          let info = try parent.info(key), Self.owned(info, kind: S_IFREG)
        else { throw AcquisitionCacheError.invalidEntry }
        try Self.requireKey(String(fields[1]))
      }
      let known = Set(AcquisitionCacheStore.allCases.map(\.rawValue))
        .union([Self.marker, Self.leases, Self.trash])
      for name in try root.names() where !known.contains(name) {
        issues.append(issue(name, AcquisitionCacheError.invalidEntry))
      }
    }
    return (.init(root: self.root, entries: entries, issues: issues), try root?.objectIdentity)
  }

  private func issue(_ path: String, _ error: any Error) -> AcquisitionCacheIssue {
    .init(path: path, reason: error.localizedDescription)
  }

  private func entry(
    _ store: AcquisitionCacheStore, key: String, in parent: DirectoryHandle
  ) throws -> Entry? {
    try Self.requireKey(key)
    guard let directory = try directory(key, in: parent) else { return nil }
    let record = try Self.decode(Record.self, in: directory, named: Self.manifest)
    try Self.validate(record, store: store, key: key)
    let access =
      try directory.info(Self.access) == nil
      ? Access(generation: record.publication, time: record.created)
      : Self.decode(Access.self, in: directory, named: Self.access)
    let files = try members(directory)
    guard let payload = files.stats[Self.payload], payload.st_size == record.size,
      files.stats[Self.manifest] != nil
    else { throw AcquisitionCacheError.invalidEntry }
    let summary = AcquisitionCacheEntry(
      store: store, id: key, object: record.object, lastUsed: access.time, bytes: files.bytes,
      pendingDisposal: false, generation: access.generation, identities: files.identities,
      files: files.stats.mapValues { AcquisitionFileGeneration(info: $0) })
    return Entry(directory: directory, record: record, payload: payload, summary: summary)
  }

  private func detach(
    _ entry: Entry, parent: DirectoryHandle, root: DirectoryHandle
  ) throws -> String {
    try requireRootIdentity(root)
    let trash = try directory(Self.trash, in: root, create: true)!
    let id = UUID()
    let access = Access(generation: entry.summary.generation, time: entry.summary.lastUsed)
    let receipt = Receipt(
      id: id, record: entry.record, access: access, identities: entry.summary.identities)
    let bytes = try Self.encode(receipt)
    guard bytes.count <= Self.recordLimit * 2 else { throw AcquisitionCacheError.invalidEntry }
    try trash.write(id.uuidString + ".json", data: bytes)
    let key = entry.record.key
    guard try parent.info(key).map(FileObjectIdentity.init) == receipt.identities["."] else {
      throw AcquisitionCacheError.invalidEntry
    }
    try parent.move(key, to: trash, named: id.uuidString + ".entry", mode: .exclusive)
    return id.uuidString
  }

  private func pending(_ name: String, in trash: DirectoryHandle) throws -> AcquisitionCacheEntry {
    let receipt = try disposal(name, in: trash)
    var identities: [String: FileObjectIdentity] = [:]
    var files: [String: AcquisitionFileGeneration] = [:]
    var bytes: Int64 = 0
    if let entry = try directory(name + ".entry", in: trash) {
      let remaining = try members(entry)
      guard remaining.identities.allSatisfy({ receipt.identities[$0.key] == $0.value }) else {
        throw AcquisitionCacheError.invalidEntry
      }
      identities = remaining.identities
      files = remaining.stats.mapValues { AcquisitionFileGeneration(info: $0) }
      bytes = remaining.bytes
    }
    let receiptName = name + ".json"
    identities["receipt"] = try trash.info(receiptName).map(FileObjectIdentity.init)
    return .init(
      store: receipt.record.store, id: name, object: receipt.record.object,
      lastUsed: receipt.access.time, bytes: bytes, pendingDisposal: true,
      generation: receipt.access.generation, identities: identities, files: files)
  }

  private func disposal(_ name: String, in trash: DirectoryHandle) throws -> Receipt {
    guard let id = UUID(uuidString: name), id.uuidString == name else {
      throw AcquisitionCacheError.invalidEntry
    }
    let receipt = try Self.decode(
      Receipt.self, in: trash, named: name + ".json", maximumBytes: Self.recordLimit * 2)
    guard receipt.id == id, receipt.identities["."]?.isDirectory == true,
      Set(receipt.identities.keys).isSubset(of: Self.typedFiles.union(["."]))
    else { throw AcquisitionCacheError.invalidEntry }
    try Self.validate(receipt.record, store: receipt.record.store, key: receipt.record.key)
    return receipt
  }

  private func dispose(_ name: String, root: DirectoryHandle) throws -> Int64 {
    var reclaimed: Int64 = 0
    try dispose(name, root: root, reclaimed: &reclaimed)
    return reclaimed
  }

  private func dispose(_ name: String, root: DirectoryHandle, reclaimed: inout Int64) throws {
    try requireRootIdentity(root)
    guard let trash = try directory(Self.trash, in: root) else {
      throw AcquisitionCacheError.invalidEntry
    }
    let expected = try pending(name, in: trash)
    let entryName = name + ".entry"
    if let entry = try directory(entryName, in: trash) {
      for file in try entry.names() {
        guard let info = try entry.info(file),
          FileObjectIdentity(info) == expected.identities[file],
          try entry.objectIdentity == expected.identities["."]
        else { throw AcquisitionCacheError.invalidEntry }
        guard unlinkat(entry.descriptor, file, 0) == 0 else {
          throw FileSystem.posixError(
            errno, at: entry.url.appendingPathComponent(file),
            otherwise: .invalidState("cannot remove cache file"))
        }
        reclaimed += info.st_size
      }
      try entry.sync()
      guard try trash.info(entryName).map(FileObjectIdentity.init) == expected.identities["."]
      else {
        throw AcquisitionCacheError.invalidEntry
      }
      try trash.removeEmptyDirectory(entryName)
    }
    try trash.remove(name + ".json", identity: expected.identities["receipt"])
  }

  private func members(_ directory: DirectoryHandle) throws -> (
    stats: [String: stat], identities: [String: FileObjectIdentity], bytes: Int64
  ) {
    var stats: [String: stat] = [:]
    var identities = [".": try directory.objectIdentity]
    var bytes: Int64 = 0
    for name in try directory.names() {
      guard Self.typedFiles.contains(name),
        let info = try directory.info(name), Self.owned(info, kind: S_IFREG), info.st_size >= 0
      else { throw AcquisitionCacheError.invalidEntry }
      if name != Self.payload, info.st_size > Self.recordLimit {
        throw AcquisitionCacheError.invalidEntry
      }
      stats[name] = info
      identities[name] = FileObjectIdentity(info)
      let sum = bytes.addingReportingOverflow(info.st_size)
      guard !sum.overflow else { throw AcquisitionCacheError.invalidEntry }
      bytes = sum.partialValue
    }
    return (stats, identities, bytes)
  }

  private func directory(
    _ name: String, in parent: DirectoryHandle, create: Bool = false
  ) throws -> DirectoryHandle? {
    guard let info = try parent.info(name) else {
      return try create ? parent.makeDirectory(name) : nil
    }
    guard Self.owned(info, kind: S_IFDIR) else { throw AcquisitionCacheError.invalidEntry }
    let opened = try parent.child(name)
    guard try opened.objectIdentity == FileObjectIdentity(info) else {
      throw AcquisitionCacheError.invalidEntry
    }
    return opened
  }

  func withRoot<T>(
    mutate: Bool = false, exclusive: Bool = false, _ body: (DirectoryHandle?) throws -> T
  ) throws -> T {
    try requireSafeRoot()
    guard let handle = try existingRoot(create: mutate) else { return try body(nil) }
    let lock = try Lease(handle.descriptor, exclusive: mutate || exclusive)
    return try withExtendedLifetime(lock) {
      try requireRootIdentity(handle)
      var info = stat()
      guard fstat(handle.descriptor, &info) == 0, Self.owned(info, kind: S_IFDIR) else {
        throw AcquisitionCacheError.unsafeRoot(root.path)
      }
      if let marker = try handle.info(Self.marker) {
        guard Self.owned(marker, kind: S_IFREG),
          try handle.read(Self.marker, matching: marker, maximumBytes: 128) == Self.markerContents
        else { throw AcquisitionCacheError.unsafeRoot(root.path) }
      } else {
        guard try handle.names().isEmpty else { throw AcquisitionCacheError.unsafeRoot(root.path) }
        if mutate { try handle.write(Self.marker, data: Self.markerContents) }
      }
      return try body(handle)
    }
  }

  private func existingRoot(create: Bool = false) throws -> DirectoryHandle? {
    var parent = try DirectoryHandle(at: URL(fileURLWithPath: "/"))
    for (index, name) in root.pathComponents.dropFirst().enumerated() {
      if create, try parent.info(name) == nil {
        do { _ = try parent.makeDirectory(name) } catch {
          if try parent.info(name) == nil { throw error }
        }
      }
      guard let info = try parent.info(name) else { return nil }
      if index == 0 && platform_system_alias(name) {
        parent = try DirectoryHandle(at: parent.url.appendingPathComponent(name))
      } else {
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw AcquisitionCacheError.unsafeRoot(root.path)
        }
        let child = try parent.child(name)
        guard try child.objectIdentity == FileObjectIdentity(info) else {
          throw AcquisitionCacheError.rootChanged
        }
        parent = child
      }
    }
    return parent
  }

  private func requireRootIdentity(_ handle: DirectoryHandle) throws {
    try requireSafeRoot()
    guard try existingRoot()?.objectIdentity == handle.objectIdentity else {
      throw AcquisitionCacheError.rootChanged
    }
  }

  private func requireSafeRoot() throws {
    guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0) else {
      throw AcquisitionCacheError.unsafeRoot(root.path)
    }
    let home = environment.homeDirectory
    let project = environment.projectDirectory
    var protected = environment.protectedAcquisitionPaths
    for scope in [InstallScope.project, .user] {
      protected.append(StateStore(scope: scope, environment: environment).directory)
      protected.append(
        AgentRegistry.canonicalSkillsDirectory(scope: scope, environment: environment))
      protected += AgentID.allCases.map {
        AgentRegistry.skillsDirectory(for: $0, scope: scope, environment: environment)
      }
    }
    let clientRoots = [
      ".agents", ".codex", ".claude", ".gemini", ".cursor", ".opencode", ".antigravity",
    ]
    protected += clientRoots.flatMap {
      [home.appendingPathComponent($0), project.appendingPathComponent($0)]
    }
    for name in ["CODEX_HOME", "CODEX_SQLITE_HOME", "CLAUDE_CONFIG_DIR"] {
      if let path = environment.environment[name], path.hasPrefix("/") {
        protected.append(URL(fileURLWithPath: path))
      }
    }
    if let path = environment.environment["GEMINI_CLI_HOME"], path.hasPrefix("/") {
      let gemini = URL(fileURLWithPath: path)
      protected += [
        gemini.appendingPathComponent(".gemini"), gemini.appendingPathComponent(".agents"),
      ]
    }
    let roots = Self.pathSpellings(root)
    guard
      !roots.contains(where: { candidate in
        candidate == "/"
          || Self.pathSpellings(home).contains(where: { Self.contains(candidate, $0) })
          || protected.contains(where: { url in
            Self.pathSpellings(url).contains {
              Self.contains(candidate, $0) || Self.contains($0, candidate)
            }
          })
      })
    else { throw AcquisitionCacheError.unsafeRoot(root.path) }
  }

  private static func pathSpellings(_ url: URL) -> [String] {
    let original = url.standardizedFileURL
    var existing = original
    var tail: [String] = []
    if let path = PathSafety.realPath(existing.path) { return [original.path, path] }
    while existing.path != "/" {
      tail.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
      if let path = PathSafety.realPath(existing.path) {
        return [
          original.path,
          tail.reversed().reduce(URL(fileURLWithPath: path)) {
            $0.appendingPathComponent($1)
          }.path,
        ]
      }
    }
    return [original.path]
  }

  private static func contains(_ root: String, _ path: String) -> Bool {
    #if os(macOS)
      let root = root.lowercased()
      let path = path.lowercased()
    #endif
    return root == path || path.hasPrefix(root == "/" ? root : root + "/")
  }

  private func entryLease(
    _ store: AcquisitionCacheStore, key: String, root: DirectoryHandle, create: Bool,
    exclusive: Bool
  ) throws -> Lease {
    guard let leases = try directory(Self.leases, in: root, create: create) else {
      throw AcquisitionCacheError.invalidEntry
    }
    let name = store.rawValue + "-" + key
    let descriptor = openat(
      leases.descriptor, name,
      (create ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw FileSystem.posixError(
        errno, at: leases.url.appendingPathComponent(name), otherwise: .unsafePath("cache lease"))
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, Self.owned(info, kind: S_IFREG),
      try leases.info(name).map(FileObjectIdentity.init) == FileObjectIdentity(info)
    else { throw AcquisitionCacheError.invalidEntry }
    if create { try leases.sync() }
    return try Lease(descriptor, exclusive: exclusive, nonblocking: true)
  }

  private final class Lease {
    private let descriptor: Int32

    init(_ original: Int32, exclusive: Bool, nonblocking: Bool = false) throws {
      descriptor = fcntl(original, F_DUPFD_CLOEXEC, 3)
      guard descriptor >= 0 else { throw AcquisitionCacheError.invalidEntry }
      let operation = (exclusive ? LOCK_EX : LOCK_SH) | (nonblocking ? LOCK_NB : 0)
      while flock(descriptor, operation) != 0 {
        let code = errno
        if code == EINTR { continue }
        close(descriptor)
        if code == EWOULDBLOCK { throw AcquisitionCacheError.busy }
        throw AcquisitionCacheError.invalidEntry
      }
    }

    deinit {
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
  }

  private static func requireKey(_ key: String) throws {
    guard key.utf8.count == 64,
      key.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else { throw AcquisitionCacheError.invalidEntry }
  }

  private static func validate(
    _ record: Record, store: AcquisitionCacheStore, key: String
  ) throws {
    try requireKey(key)
    try requireKey(record.digest)
    let limit: Int
    switch store {
    case .git: limit = record.object.hasPrefix("ref:") ? 1024 : GitAcquisition.packLimit
    case .http: limit = registryResponseLimit
    case .deployed: limit = deployedFileLimit
    }
    guard record.store == store, record.key == key, (0...limit).contains(record.size),
      !record.object.isEmpty, record.object.utf8.count <= 256,
      record.created.timeIntervalSinceReferenceDate.isFinite
    else { throw AcquisitionCacheError.invalidEntry }
  }

  private static func owned(_ info: stat, kind: mode_t) -> Bool {
    info.st_mode & S_IFMT == kind && info.st_uid == geteuid()
      && info.st_mode & (S_IWGRP | S_IWOTH) == 0 && (kind != S_IFREG || info.st_nlink == 1)
  }

  private static func encode(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
  }

  private static func decode<T: Decodable>(
    _ type: T.Type, in parent: DirectoryHandle, named name: String,
    maximumBytes: Int = recordLimit
  ) throws -> T {
    guard let info = try parent.info(name), owned(info, kind: S_IFREG) else {
      throw AcquisitionCacheError.invalidEntry
    }
    return try JSONDecoder().decode(
      type, from: parent.read(name, matching: info, maximumBytes: maximumBytes))
  }
}
