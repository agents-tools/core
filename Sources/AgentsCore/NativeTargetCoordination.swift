import CPlatform
import Foundation

/// Closed physical routes; regional ownership and rendering belong to the native adapter.
package enum NativeTargetRoute: String, Codable, Sendable, CaseIterable {
  case claudeMCPProject = "claude.mcp.project"
  case claudeMCPLocal = "claude.mcp.local"
  case claudeMCPUser = "claude.mcp.user"
  case codexMCPProject = "codex.mcp.project"
  case codexMCPUser = "codex.mcp.user"
  case geminiMCPProject = "gemini.mcp.project"
  case geminiMCPUser = "gemini.mcp.user"
  case cursorMCPProject = "cursor.mcp.project"
  case cursorMCPUser = "cursor.mcp.user"
  case openCodeMCPProjectJSON = "opencode.mcp.project.json"
  case openCodeMCPProjectJSONC = "opencode.mcp.project.jsonc"
  case openCodeMCPUserJSON = "opencode.mcp.user.json"
  case openCodeMCPUserJSONC = "opencode.mcp.user.jsonc"

  var shared: Bool {
    switch self {
    case .claudeMCPLocal, .claudeMCPUser, .codexMCPUser, .geminiMCPUser, .cursorMCPUser,
      .openCodeMCPUserJSON, .openCodeMCPUserJSONC:
      true
    default: false
    }
  }
  static let projectRoot = "native-claude-project"
  static let globalRoot = "native-claude-global"
  static let metadataRoot = "native-claude-metadata"

  var root: String {
    switch self {
    case .claudeMCPProject: Self.projectRoot
    case .claudeMCPLocal, .claudeMCPUser: Self.globalRoot
    default:
      "native-"
        + rawValue.replacingOccurrences(of: ".mcp.", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    }
  }
  var metadata: String { root == Self.globalRoot ? Self.metadataRoot : root + "-metadata" }
  var basename: String {
    switch self {
    case .claudeMCPProject: ".mcp.json"
    case .claudeMCPLocal, .claudeMCPUser: ".claude.json"
    case .codexMCPProject, .codexMCPUser: "config.toml"
    case .geminiMCPProject, .geminiMCPUser: "settings.json"
    case .cursorMCPProject, .cursorMCPUser: "mcp.json"
    case .openCodeMCPProjectJSON, .openCodeMCPUserJSON: "opencode.json"
    case .openCodeMCPProjectJSONC, .openCodeMCPUserJSONC: "opencode.jsonc"
    }
  }
  static var sharedRoutes: [Self] {
    [
      .claudeMCPLocal, .codexMCPUser, .geminiMCPUser, .cursorMCPUser,
      .openCodeMCPUserJSON, .openCodeMCPUserJSONC,
    ]
  }
  static func targetRoute(_ path: String) -> Self? {
    let key = path.split(separator: "/").first.map(String.init)
    return allCases.first { $0.root == key }
  }
  static func sharedRoute(_ path: String) -> Self? {
    targetRoute(path).flatMap { $0.shared ? $0 : nil }
  }
  static func metadataRoute(_ path: String) -> Self? {
    let key = path.split(separator: "/").first.map(String.init)
    return sharedRoutes.first { $0.metadata == key }
  }

  func logicalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    func home() throws -> URL { try Self.absoluteDirectory(environment.homeDirectory) }
    func override(_ key: String) throws -> URL? {
      guard let value = environment.environment[key], !value.isEmpty else { return nil }
      guard value.hasPrefix("/"), !value.contains("\0") else {
        throw CoreError.unsafePath("registered " + key + " must be an absolute directory")
      }
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    switch self {
    case .claudeMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory)
    case .claudeMCPLocal, .claudeMCPUser:
      return try override("CLAUDE_CONFIG_DIR") ?? home()
    case .codexMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory).appendingPathComponent(
        ".codex")
    case .codexMCPUser:
      if let root = try override("CODEX_HOME") {
        _ = try DirectoryHandle(at: root.resolvingSymlinksInPath())
        return root
      }
      return try home().appendingPathComponent(".codex")
    case .geminiMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory).appendingPathComponent(
        ".gemini")
    case .geminiMCPUser:
      return try (override("GEMINI_CLI_HOME") ?? home()).appendingPathComponent(".gemini")
    case .cursorMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory).appendingPathComponent(
        ".cursor")
    case .cursorMCPUser:
      return try home().appendingPathComponent(".cursor")
    case .openCodeMCPProjectJSON, .openCodeMCPProjectJSONC:
      return try Self.absoluteDirectory(environment.projectDirectory)
    case .openCodeMCPUserJSON, .openCodeMCPUserJSONC:
      if environment.environment["OPENCODE_CONFIG_DIR"] == "" {
        throw CoreError.unsafePath(
          "empty OPENCODE_CONFIG_DIR does not establish a registered absolute root")
      }
      return try override("OPENCODE_CONFIG_DIR")
        ?? (override("XDG_CONFIG_HOME") ?? home().appendingPathComponent(".config"))
        .appendingPathComponent("opencode")
    }
  }
  private static func absoluteDirectory(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw CoreError.unsafePath("registered native root must be an absolute filesystem directory")
    }
    return url.standardizedFileURL
  }
  static func globalLogicalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try Self.claudeMCPLocal.logicalDirectory(environment)
  }
  static func globalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try globalLogicalDirectory(environment).resolvingSymlinksInPath()
  }
}

/// Pathname authorization is checked separately. Neither route nor caller participates here.
struct SharedResourceIdentity: Codable, Equatable, Comparable {
  let parent: FileObjectIdentity
  let basename: String

  var orderingKey: String {
    "\(parent.device):\(parent.inode):\(parent.kind):\(basename.utf8.count):\(basename)"
  }
  var directoryName: String { FileHash.sha256Hex(data: Data(orderingKey.utf8)) }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.orderingKey < rhs.orderingKey }

  func validate() throws {
    guard parent.isDirectory,
      NativeTargetRoute.sharedRoutes.contains(where: { $0.basename == basename })
    else {
      throw CoreError.invalidState("unregistered shared transaction resource")
    }
  }
}

struct SharedReservation: Codable, Equatable {
  let version: Int
  let resource: SharedResourceIdentity
  let scope: String
  let owner: String
  let journal: UUID
}

/// An opened, verified physical coordination domain. Its lock inode is never removed.
final class SharedResource {
  static let metadataName = ".agents-native"
  let identity: SharedResourceIdentity
  let route: NativeTargetRoute
  let parent: DirectoryHandle
  let metadata: DirectoryHandle?
  let ancestry: DirectoryAccessEvidence
  let metadataAccess: FileAccessEvidence?
  let metadataAncestry: DirectoryAccessEvidence?
  let authorizedRoot: URL
  private var lockDescriptor: Int32?
  private var lockAccess: FileAccessEvidence?

  init(store: StateStore, route: NativeTargetRoute = .claudeMCPLocal, create: Bool) throws {
    guard route.shared else { throw CoreError.invalidState("project route has no shared resource") }
    self.route = NativeTargetRoute.sharedRoutes.first { $0.root == route.root }!
    authorizedRoot = try route.logicalDirectory(store.environment)
    let url = authorizedRoot.resolvingSymlinksInPath()
    parent = try DirectoryHandle(at: url, create: create)
    ancestry = try DirectoryAccessEvidence.capture(at: url)
    identity = SharedResourceIdentity(parent: try parent.objectIdentity, basename: route.basename)
    func child(_ parent: DirectoryHandle, _ name: String) throws -> DirectoryHandle? {
      if try parent.info(name) == nil {
        guard create else { return nil }
        return try parent.createPrivateDirectory(name)
      }
      let result = try parent.child(name)
      _ = try FileAccessEvidence.requirePrivate(descriptor: result.descriptor)
      return result
    }
    if let base = try child(parent, Self.metadataName) {
      metadata = try child(base, identity.directoryName)
    } else {
      metadata = nil
    }
    metadataAccess = try metadata?.accessEvidence()
    metadataAncestry = try metadata.map { try DirectoryAccessEvidence.capture(at: $0.url) }
  }

  func bindLock(_ descriptor: Int32) throws {
    guard descriptor >= 0 else { return }
    lockDescriptor = descriptor
    lockAccess = try FileAccessEvidence.requirePrivate(descriptor: descriptor)
    try validate()
  }

  func validate() throws {
    if let descriptor = lockDescriptor, let access = lockAccess {
      guard let metadata,
        try metadata.info("lock").map(FileObjectIdentity.init) == access.identity
      else {
        throw CoreError.invalidState("held shared coordination lock identity changed")
      }
      try access.validate(descriptor: descriptor)
    }
    try ancestry.validate(at: parent.url)
    guard
      try DirectoryHandle(at: authorizedRoot.resolvingSymlinksInPath()).objectIdentity
        == identity.parent,
      try DirectoryHandle(at: parent.url).objectIdentity == identity.parent
    else {
      throw CoreError.invalidState("shared target parent identity changed")
    }
    if let metadata {
      try metadataAncestry?.validate(at: metadata.url)
      let current = try DirectoryHandle(at: metadata.url)
      guard try current.objectIdentity == metadata.objectIdentity else {
        throw CoreError.invalidState("shared coordination directory changed")
      }
      _ = try FileAccessEvidence.requirePrivate(descriptor: current.descriptor)
      try metadataAccess?.validate(descriptor: current.descriptor)
    }
  }

  func reservation() throws -> SharedReservation? {
    try validate()
    guard let metadata, try metadata.info("reservation") != nil else { return nil }
    let access = try metadata.requirePrivateAccess("reservation")
    let value: SharedReservation
    do {
      value = try StateStore.decode(
        metadata.read("reservation", maximumBytes: 16_384), as: SharedReservation.self)
    } catch { throw CoreError.invalidState("invalid shared reservation; owner action required") }
    guard value.version == 1, value.resource == identity, !value.scope.isEmpty,
      !value.owner.isEmpty
    else { throw CoreError.invalidState("invalid shared reservation ownership") }
    _ = try metadata.requirePrivateAccess("reservation", matching: access)
    return value
  }

  static func temporaryName(_ journal: UUID) -> String { "reservation-\(journal.uuidString).new" }

  func inspect(journal: TransactionJournal?, scope: String) throws {
    try validate()
    guard let metadata else { return }
    let own = journal.map { Self.temporaryName($0.id) }
    for name in try metadata.names() where name.hasPrefix("reservation-") {
      guard name == own, journal?.footprint.contains(identity) == true else {
        throw CoreError.invalidState(
          "pending shared reservation construction; owner action required")
      }
      // A durable intent owns the exact slot even when its bytes are incomplete.
      _ = try metadata.requirePrivateAccess(name)
    }
    if let reservation = try reservation() {
      guard reservation.scope == scope, reservation.journal == journal?.id,
        journal?.footprint.contains(identity) == true
      else {
        throw CoreError.recoveryPending(
          "Shared target requires recovery by \(reservation.owner), journal \(reservation.journal.uuidString)"
        )
      }
    } else if journal?.reservationsReady == true, journal?.finalized == false,
      journal?.footprint.contains(identity) == true
    {
      throw CoreError.invalidState("ready shared transaction is missing its reservation")
    }
  }

  func reserve(_ journal: TransactionJournal, owner: String, checkpoint: (String) throws -> Void)
    throws
  {
    guard let metadata, journal.footprint.contains(identity), !journal.reservationsReady else {
      throw CoreError.invalidState("missing durable shared reservation intent")
    }
    try inspect(journal: journal, scope: journal.scope)
    guard try reservation() == nil else { return }
    let name = Self.temporaryName(journal.id)
    guard try metadata.info(name) == nil else {
      throw CoreError.invalidState("unfinished shared reservation needs recovery")
    }
    let file = try metadata.createPrivateFile(name)
    try checkpoint("reservation.created")
    let record = SharedReservation(
      version: 1, resource: identity, scope: journal.scope, owner: owner, journal: journal.id)
    let bytes = try StateStore.encode(record)
    let middle = bytes.count / 2
    try file.write(bytes.prefix(middle))
    try checkpoint("reservation.halfWritten")
    try file.write(bytes.suffix(from: middle))
    try checkpoint("reservation.written")
    try metadata.move(name, to: metadata, named: "reservation", mode: .exclusive) {
      try checkpoint("reservation.published")
    }
    try checkpoint("reservation.synced")
  }

  func validateFinalized(_ journal: TransactionJournal) throws {
    try validate()
    guard let metadata else { throw CoreError.invalidState("shared metadata is missing") }
    let name = Self.temporaryName(journal.id)
    if try metadata.info(name) != nil { _ = try metadata.requirePrivateAccess(name) }
    if let record = try reservation(), record.journal == journal.id,
      record.scope != journal.scope
    {
      throw CoreError.invalidState("finalized reservation owner changed")
    }
  }

  /// Finalized journals may encounter a newer owner's final reservation. Never remove it.
  func release(_ journal: TransactionJournal, checkpoint: (String) throws -> Void) throws {
    try validate()
    guard let metadata else { throw CoreError.invalidState("shared metadata is missing") }
    let name = Self.temporaryName(journal.id)
    if try metadata.info(name) != nil {
      let access = try metadata.requirePrivateAccess(name)
      try metadata.remove(name, identity: access.identity)
    }
    if let record = try reservation(), record.journal == journal.id {
      guard record.scope == journal.scope, record.resource == identity else {
        throw CoreError.invalidState("shared reservation owner changed")
      }
      let access = try metadata.requirePrivateAccess("reservation")
      try metadata.remove("reservation", identity: access.identity)
      try checkpoint("reservation.removed")
    } else if !journal.finalized, journal.reservationsReady {
      throw CoreError.invalidState("ready shared transaction lost its reservation")
    }
    try metadata.sync()
  }
}

/// Synchronous, thread-confined admission. There is no lock acquisition inside a transaction.
final class TransactionLockContext {
  private static let threadKey = "agents.core.transaction-lock-context"
  let scopeURL: URL
  let resources: [SharedResource]
  let writable: Bool
  let requestedShared: Bool
  private var scopeDirectory: DirectoryHandle?
  private var scopeDescriptor: Int32?
  private var scopeLockIdentity: FileObjectIdentity?

  init(store: StateStore, resources: [SharedResource], writable: Bool, requestedShared: Bool) {
    scopeURL = store.directory.standardizedFileURL
    self.resources = resources
    self.writable = writable
    self.requestedShared = requestedShared
  }

  static var isHeld: Bool { Thread.current.threadDictionary[threadKey] != nil }

  static func current(_ store: StateStore) -> TransactionLockContext? {
    let context = Thread.current.threadDictionary[threadKey] as? TransactionLockContext
    return context?.scopeURL.path == store.directory.standardizedFileURL.path ? context : nil
  }

  func run<T>(_ body: () throws -> T) throws -> T {
    guard Thread.current.threadDictionary[Self.threadKey] == nil else {
      throw CoreError.invalidState("nested scope operations cannot acquire transaction locks")
    }
    Thread.current.threadDictionary[Self.threadKey] = self
    defer { Thread.current.threadDictionary.removeObject(forKey: Self.threadKey) }
    return try body()
  }

  static func validateHeldScope(_ identity: String) throws {
    guard let context = Thread.current.threadDictionary[threadKey] as? TransactionLockContext else {
      return
    }
    try context.validateScope()
    if let directory = context.scopeDirectory, try directory.identity != identity {
      throw CoreError.invalidState("transaction belongs to another held scope")
    }
  }

  func bindScope(_ directory: DirectoryHandle, descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      try directory.info(".agents.lock").map(FileObjectIdentity.init) == FileObjectIdentity(info)
    else { throw CoreError.invalidState("scope lock changed during admission") }
    scopeDirectory = directory
    scopeDescriptor = descriptor
    scopeLockIdentity = FileObjectIdentity(info)
    try validateScope()
  }

  func validateScope() throws {
    guard let directory = scopeDirectory else { return }
    var info = stat()
    guard let descriptor = scopeDescriptor, let identity = scopeLockIdentity,
      fstat(descriptor, &info) == 0, FileObjectIdentity(info) == identity,
      try DirectoryHandle(at: directory.url).identity == directory.identity,
      try directory.info(".agents.lock").map(FileObjectIdentity.init) == identity
    else { throw CoreError.invalidState("held transaction scope or lock identity changed") }
  }

  func requireWriterScope() throws {
    guard writable, scopeDirectory != nil else {
      throw CoreError.invalidState("shared commit requires a held scope writer descriptor")
    }
    try validateScope()
  }

  func resource(_ identity: SharedResourceIdentity? = nil) throws -> SharedResource {
    try validateScope()
    guard identity != nil || resources.count == 1,
      let resource = resources.first(where: { identity == nil || $0.identity == identity })
    else {
      throw CoreError.invalidState("shared target is outside the held request footprint")
    }
    try resource.validate()
    return resource
  }

  func resource(for route: NativeTargetRoute) throws -> SharedResource {
    guard let resource = resources.first(where: { $0.route.root == route.root }) else {
      throw CoreError.invalidState("shared target is outside the held request footprint")
    }
    return try self.resource(resource.identity)
  }

  func validate(_ journal: TransactionJournal, scope: DirectoryHandle) throws {
    try journal.validateCoordination()
    try validateScope()
    guard try scope.identity == journal.scope else {
      throw CoreError.invalidState("transaction scope identity changed")
    }
    for identity in journal.footprint {
      let resource = try resource(identity)
      if !journal.finalized { try resource.inspect(journal: journal, scope: journal.scope) }
    }
  }
}

extension StateStore {
  package func nativeTarget(for route: NativeTargetRoute) throws -> MaterializationTarget {
    guard route.shared || scope == .project else {
      throw CoreError.unsafePath("project native targets require their project scope")
    }
    let logical = try route.logicalDirectory(environment)
    let parent: URL
    if route.shared, let context = TransactionLockContext.current(self) {
      parent = try context.resource(for: route).parent.url
    } else {
      parent = logical.resolvingSymlinksInPath()
    }
    return MaterializationTarget(
      url: parent.appendingPathComponent(route.basename),
      path: route.root + "/" + route.basename, scope: directory)
  }

  /// Acquire the union before the scope lock. Re-admission never replays a delivered callback.
  func withCoordination<T>(
    routes: Set<NativeTargetRoute>, writable: Bool,
    checkpoint: (String) throws -> Void = { _ in }, _ body: () throws -> T
  ) throws -> T {
    if TransactionLockContext.isHeld {
      throw CoreError.invalidState("nested scope lock acquisition")
    }
    while true {
      let before = try pendingCoordinationJournal(diagnosing: !writable)
      var resources: [SharedResource] = []
      let pending = before?.footprint ?? []
      var requested = Set(
        routes.filter(\.shared).map { route in
          NativeTargetRoute.sharedRoutes.first { $0.root == route.root }!
        })
      for identity in pending {
        try identity.validate()
        guard
          let route = NativeTargetRoute.sharedRoutes.first(where: {
            $0.basename == identity.basename
          })
        else {
          throw CoreError.invalidState("unregistered shared recovery resource")
        }
        requested.insert(route)
      }
      // Validate every original recovery domain before creating any newly requested metadata.
      let ordered = requested.sorted { left, right in
        let leftPending = pending.contains { $0.basename == left.basename }
        let rightPending = pending.contains { $0.basename == right.basename }
        return leftPending == rightPending ? left.rawValue < right.rawValue : leftPending
      }
      for route in ordered {
        let recovering = pending.contains { $0.basename == route.basename }
        let resource: SharedResource
        do {
          resource = try SharedResource(store: self, route: route, create: writable && !recovering)
        } catch {
          if recovering {
            throw CoreError.invalidState(
              "shared recovery requires the original registered runtime context and verifiable coordination metadata"
            )
          }
          throw error
        }
        if recovering {
          guard pending.contains(resource.identity), let metadata = resource.metadata,
            try metadata.info("lock") != nil
          else {
            throw CoreError.invalidState(
              "shared recovery requires the original runtime context and coordination lock")
          }
        }
        if !resources.contains(where: { $0.identity == resource.identity }) {
          resources.append(resource)
        }
      }
      let context = TransactionLockContext(
        store: self, resources: resources.sorted { $0.identity < $1.identity }, writable: writable,
        requestedShared: routes.contains(where: \.shared))
      func locked(_ index: Int) throws -> T? {
        if index < context.resources.count {
          let resource = context.resources[index]
          guard let metadata = resource.metadata else {
            // No metadata means no prior registered writer. Recheck after the unlocked read.
            let result = Result { try locked(index + 1) }
            let after = try SharedResource(store: self, route: resource.route, create: false)
            guard after.metadata == nil else { return nil }
            return try result.get()
          }
          let url = metadata.url.appendingPathComponent("lock")
          if writable {
            if try metadata.info("lock") == nil {
              _ = try metadata.createPrivateFile("lock")
            }
            _ = try metadata.requirePrivateAccess("lock")
          }
          return try FileLock.withCoordinationDescriptor(
            at: url, writable: writable,
            checkpoint: { try checkpoint("shared.\(index).lock." + $0) },
            { descriptor in
              try resource.bindLock(descriptor)
              try resource.validate()
              return try locked(index + 1)
            })
        }
        return try context.run { try body() }
      }
      // The scope-lock body checks that the preflight footprint still covers the journal.
      do {
        if let result = try locked(0) { return result }
      } catch CoordinationReadmission.required { continue }
    }
  }

  func pendingCoordinationJournal(diagnosing: Bool = false) throws -> TransactionJournal? {
    guard let directory = try openDirectoryIfPresent() else { return nil }
    let primary = try directory.info(TransactionJournal.fileName) != nil
    let name = primary ? TransactionJournal.fileName : TransactionJournal.incompleteFileName
    guard try directory.info(name) != nil else { return nil }
    do {
      guard let info = try directory.info(name), let limit = Int(exactly: info.st_size), limit >= 0
      else {
        throw CoreError.invalidState("cannot bound pending journal generation")
      }
      let bytes = try directory.read(name, matching: info, maximumBytes: limit)
      if !primary, (try? JSONSerialization.jsonObject(with: bytes)) == nil { return nil }
      let journal = try FileTransaction.readJournal(bytes)
      try journal.validateCoordination()
      return journal
    } catch {
      // A corrupt journal admits no data callback. The read boundary still takes the
      // scope lock and routes to its pending-recovery diagnostic without writes.
      if diagnosing { return nil }
      throw error
    }
  }

  func verifyCoordinationAdmission() throws {
    guard let context = TransactionLockContext.current(self) else {
      throw CoreError.invalidState("missing held scope coordination context")
    }
    let journal = try pendingCoordinationJournal(diagnosing: !context.writable)
    let held = context.resources.map(\.identity)
    if let journal, !journal.footprint.allSatisfy(held.contains) {
      throw CoordinationReadmission.required
    }
    if !context.requestedShared, journal?.footprint.isEmpty != false, !held.isEmpty {
      throw CoordinationReadmission.required
    }
    let directory = try openDirectoryIfPresent()
    if let journal, context.writable {
      guard let directory else { throw CoreError.invalidState("missing transaction scope") }
      try context.validate(journal, scope: directory)
    }
    for resource in context.resources {
      if journal?.finalized != true && (context.writable || journal == nil) {
        try resource.inspect(journal: journal, scope: directory?.identity ?? "")
      }
    }
  }

}

enum CoordinationReadmission: Error { case required }

extension Optional where Wrapped == TransactionLockContext {
  func requiredResource(_ identity: SharedResourceIdentity? = nil) throws -> SharedResource {
    guard let context = self else {
      throw CoreError.invalidState("shared target requires a held request footprint")
    }
    return try context.resource(identity)
  }
}
