import CPlatform
import Foundation

/// Closed physical routes; regional ownership and rendering belong to the native adapter.
enum FixedNativeTargetRoute: String, Codable, Sendable, CaseIterable {
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

  case claudeSettingsProject = "claude.settings.project"
  case claudeSettingsUser = "claude.settings.user"
  case codexHooksProject = "codex.hooks.project"
  case codexHooksUser = "codex.hooks.user"
  case cursorHooksProject = "cursor.hooks.project"
  case cursorHooksUser = "cursor.hooks.user"
  case geminiIgnoreProject = "gemini.ignore.project"
  case cursorIgnoreProject = "cursor.ignore.project"

  var shared: Bool {
    switch self {
    case .claudeMCPLocal, .claudeMCPUser, .codexMCPUser, .geminiMCPUser, .cursorMCPUser,
      .openCodeMCPUserJSON, .openCodeMCPUserJSONC, .claudeSettingsUser, .codexHooksUser,
      .cursorHooksUser:
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
    case .claudeSettingsProject, .claudeSettingsUser: "settings.json"
    case .codexHooksProject, .codexHooksUser, .cursorHooksProject, .cursorHooksUser: "hooks.json"
    case .geminiIgnoreProject: ".geminiignore"
    case .cursorIgnoreProject: ".cursorignore"
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
      .openCodeMCPUserJSON, .openCodeMCPUserJSONC, .claudeSettingsUser, .codexHooksUser,
      .cursorHooksUser,
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

  func logicalDirectory(_ environment: RuntimeEnvironment, validateExistingOverride: Bool = true)
    throws -> URL
  {
    func home() throws -> URL { try Self.absoluteDirectory(environment.homeDirectory) }
    func override(_ key: String) throws -> URL? {
      guard let value = environment.environment[key], !value.isEmpty else { return nil }
      guard value.hasPrefix("/"), !value.contains("\0") else {
        throw CoreError.unsafePath("registered " + key + " must be an absolute directory")
      }
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    switch self {
    case .claudeSettingsProject:
      return try Self.absoluteDirectory(environment.projectDirectory).appendingPathComponent(
        ".claude")
    case .claudeSettingsUser:
      return try override("CLAUDE_CONFIG_DIR") ?? home().appendingPathComponent(".claude")
    case .codexHooksProject: return try Self.codexMCPProject.logicalDirectory(environment)
    case .codexHooksUser:
      return try Self.codexMCPUser.logicalDirectory(
        environment, validateExistingOverride: validateExistingOverride)
    case .cursorHooksProject: return try Self.cursorMCPProject.logicalDirectory(environment)
    case .cursorHooksUser: return try Self.cursorMCPUser.logicalDirectory(environment)
    case .geminiIgnoreProject, .cursorIgnoreProject:
      return try Self.absoluteDirectory(environment.projectDirectory)
    case .claudeMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory)
    case .claudeMCPLocal, .claudeMCPUser:
      return try override("CLAUDE_CONFIG_DIR") ?? home()
    case .codexMCPProject:
      return try Self.absoluteDirectory(environment.projectDirectory).appendingPathComponent(
        ".codex")
    case .codexMCPUser:
      if let root = try override("CODEX_HOME") {
        if validateExistingOverride { _ = try DirectoryHandle(at: root.resolvingSymlinksInPath()) }
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
  static func absoluteDirectory(_ url: URL) throws -> URL {
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

/// A closed loader recipe. Named routes carry only validated native member names;
/// runtime directories remain owned by the recipe and explicit environment.
package struct NativeTargetRoute: RawRepresentable, Hashable, Codable, Sendable {
  package enum Member: String, Codable, Sendable, CaseIterable {
    case claudeCommand, claudeAgent, claudeSkillPlugin
    case codexAgent, geminiCommand, geminiAgent, geminiExtension
    case cursorCommand, cursorAgent, cursorLocalPlugin
  }
  package let rawValue: String
  private let fixed: FixedNativeTargetRoute?
  private let member: Member?
  private let memberScope: InstallScope?
  private let name: String?

  private init(_ fixed: FixedNativeTargetRoute) {
    self.fixed = fixed
    member = nil
    memberScope = nil
    name = nil
    rawValue = fixed.rawValue
  }
  package init?(rawValue: String) {
    if let fixed = FixedNativeTargetRoute(rawValue: rawValue) {
      self.init(fixed)
      return
    }
    let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let member = Member(rawValue: String(parts[0])),
      let scope = InstallScope(rawValue: String(parts[1])),
      let value = try? Self.named(member, scope: scope, name: String(parts[2]))
    else { return nil }
    self = value
  }
  /// `name` is the adapter's exact extension-free name, including command subdirectories.
  package static func named(_ member: Member, scope: InstallScope, name: String) throws -> Self {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    guard (member.rawValue + ":" + scope.rawValue + ":" + name).utf8.count <= 4096,
      !parts.isEmpty,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".."
          && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":")
          && !$0.hasPrefix(".agents-")
      }),
      member == .claudeCommand || member == .geminiCommand || parts.count == 1,
      !(member == .cursorCommand && scope != .project),
      !([Member.cursorLocalPlugin, .geminiExtension].contains(member) && scope != .user)
    else { throw CoreError.unsafePath("unregistered native member or scope") }
    return Self(member: member, scope: scope, name: name)
  }
  /// Accepts the adapter-owned relative file path, never an absolute destination.
  package static func file(_ member: Member, scope: InstallScope, relativePath: String) throws
    -> Self
  {
    let suffix: String
    switch member {
    case .claudeCommand, .claudeAgent, .cursorCommand, .cursorAgent, .geminiAgent: suffix = ".md"
    case .codexAgent, .geminiCommand: suffix = ".toml"
    default: throw CoreError.unsafePath("native container requires its registered bundle name")
    }
    guard relativePath.hasSuffix(suffix) else {
      throw CoreError.unsafePath("native member has the wrong filename extension")
    }
    return try named(member, scope: scope, name: String(relativePath.dropLast(suffix.count)))
  }
  private init(member: Member, scope: InstallScope, name: String) {
    fixed = nil
    self.member = member
    memberScope = scope
    self.name = name
    rawValue = member.rawValue + ":" + scope.rawValue + ":" + name
  }
  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let route = Self(rawValue: try container.decode(String.self)) else {
      throw CoreError.invalidState("unregistered native route")
    }
    self = route
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
  package static let claudeMCPProject = Self(.claudeMCPProject)
  package static let claudeMCPLocal = Self(.claudeMCPLocal)
  package static let claudeMCPUser = Self(.claudeMCPUser)
  package static let codexMCPProject = Self(.codexMCPProject)
  package static let codexMCPUser = Self(.codexMCPUser)
  package static let geminiMCPProject = Self(.geminiMCPProject)
  package static let geminiMCPUser = Self(.geminiMCPUser)
  package static let cursorMCPProject = Self(.cursorMCPProject)
  package static let cursorMCPUser = Self(.cursorMCPUser)
  package static let openCodeMCPProjectJSON = Self(.openCodeMCPProjectJSON)
  package static let openCodeMCPProjectJSONC = Self(.openCodeMCPProjectJSONC)
  package static let openCodeMCPUserJSON = Self(.openCodeMCPUserJSON)
  package static let openCodeMCPUserJSONC = Self(.openCodeMCPUserJSONC)
  package static let claudeSettingsProject = Self(.claudeSettingsProject)
  package static let claudeSettingsUser = Self(.claudeSettingsUser)
  package static let codexHooksProject = Self(.codexHooksProject)
  package static let codexHooksUser = Self(.codexHooksUser)
  package static let cursorHooksProject = Self(.cursorHooksProject)
  package static let cursorHooksUser = Self(.cursorHooksUser)
  package static let geminiIgnoreProject = Self(.geminiIgnoreProject)
  package static let cursorIgnoreProject = Self(.cursorIgnoreProject)
  package static var allCases: [Self] { FixedNativeTargetRoute.allCases.map(Self.init) }
  static var mcpRoutes: [Self] { allCases.filter { $0.rawValue.contains(".mcp.") } }
  static var sharedRoutes: [Self] {
    FixedNativeTargetRoute.sharedRoutes.filter { $0.rawValue.contains(".mcp.") }.map(Self.init)
  }
  static let projectRoot = FixedNativeTargetRoute.projectRoot
  static let globalRoot = FixedNativeTargetRoute.globalRoot
  static let metadataRoot = FixedNativeTargetRoute.metadataRoot
  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }
  package func hash(into hasher: inout Hasher) {
    for byte in rawValue.utf8 { hasher.combine(byte) }
  }
  package var shared: Bool { fixed?.shared ?? (memberScope == .user) }
  var isNamed: Bool { member != nil }
  package var isContainer: Bool {
    member.map { [.claudeSkillPlugin, .cursorLocalPlugin, .geminiExtension].contains($0) } ?? false
  }
  func permits(_ scope: InstallScope) -> Bool {
    if let memberScope { return memberScope == scope }
    if rawValue.contains(".mcp.") { return shared || scope == .project }
    return shared ? scope == .user : scope == .project
  }
  /// Known readers are a lower bound; plugin/custom-root exclusivity needs reader evidence.
  package var knownReaders: Set<AgentID> {
    if fixed == .claudeSettingsProject || fixed == .claudeSettingsUser || member == .claudeAgent {
      return [.claudeCode, .cursor]
    }
    let prefix = rawValue.lowercased()
    if prefix.hasPrefix("claude") { return [.claudeCode] }
    if prefix.hasPrefix("codex") { return [.codex] }
    if prefix.hasPrefix("gemini") { return [.geminiCLI] }
    if prefix.hasPrefix("cursor") { return [.cursor] }
    return [.opencode]
  }
  var root: String {
    fixed?.root ?? "native-member-" + rawValue.utf8.map { String(format: "%02x", $0) }.joined()
  }
  var metadata: String { fixed?.metadata ?? root + "-metadata" }
  var basename: String {
    if let fixed { return fixed.basename }
    let suffix: String
    switch member! {
    case .claudeCommand, .claudeAgent, .cursorCommand, .cursorAgent, .geminiAgent: suffix = ".md"
    case .codexAgent, .geminiCommand: suffix = ".toml"
    default: suffix = ""
    }
    return String(name!.split(separator: "/").last!) + suffix
  }
  private static func routeRoot(_ key: String) -> Self? {
    if let fixed = FixedNativeTargetRoute.allCases.first(where: { $0.root == key }) {
      return Self(fixed)
    }
    guard key.hasPrefix("native-member-") else { return nil }
    let hex = Array(key.dropFirst("native-member-".count).utf8)
    guard hex.count.isMultiple(of: 2), hex.count <= 8192 else { return nil }
    var bytes: [UInt8] = []
    for index in stride(from: 0, to: hex.count, by: 2) {
      guard let byte = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16)
      else { return nil }
      bytes.append(byte)
    }
    guard let raw = String(bytes: bytes, encoding: .utf8), let route = Self(rawValue: raw),
      route.root == key
    else { return nil }
    return route
  }
  static func targetRoute(_ path: String) -> Self? {
    routeRoot(String(path.split(separator: "/").first ?? ""))
  }
  static func sharedRoute(_ path: String) -> Self? {
    targetRoute(path).flatMap { $0.shared ? $0 : nil }
  }
  static func metadataRoute(_ path: String) -> Self? {
    let key = String(path.split(separator: "/").first ?? "")
    if key == metadataRoot { return .claudeMCPLocal }
    guard key.hasSuffix("-metadata"),
      let route = routeRoot(String(key.dropLast("-metadata".count))), route.shared
    else { return nil }
    return route
  }
  func rootAuthority(_ environment: RuntimeEnvironment, validateExistingOverride: Bool = true)
    throws -> NativeRootAuthority
  {
    if let fixed {
      return NativeRootAuthority(
        loader: try fixed.logicalDirectory(
          environment, validateExistingOverride: validateExistingOverride), descendants: [])
    }
    let base: FixedNativeTargetRoute
    switch member! {
    case .claudeCommand, .claudeAgent, .claudeSkillPlugin:
      base = memberScope == .project ? .claudeSettingsProject : .claudeSettingsUser
    case .codexAgent:
      base = memberScope == .project ? .codexMCPProject : .codexMCPUser
    case .geminiCommand, .geminiAgent, .geminiExtension:
      base = memberScope == .project ? .geminiMCPProject : .geminiMCPUser
    case .cursorCommand, .cursorAgent, .cursorLocalPlugin:
      base = memberScope == .project ? .cursorMCPProject : .cursorMCPUser
    }
    let container: [String]
    switch member! {
    case .claudeCommand, .geminiCommand, .cursorCommand: container = ["commands"]
    case .claudeAgent, .codexAgent, .geminiAgent, .cursorAgent: container = ["agents"]
    case .claudeSkillPlugin: container = ["skills"]
    case .cursorLocalPlugin: container = ["plugins", "local"]
    case .geminiExtension: container = ["extensions"]
    }
    return NativeRootAuthority(
      loader: try base.logicalDirectory(
        environment, validateExistingOverride: validateExistingOverride),
      descendants: container + name!.split(separator: "/").dropLast().map(String.init))
  }
  func logicalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try rootAuthority(environment).logicalDirectory
  }
  func physicalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try rootAuthority(environment).physicalDirectory()
  }

  /// Detect closed user slots without creating a root or granting publication authority.
  static func userRoute(at destination: URL, environment: RuntimeEnvironment) throws -> Self? {
    let target = destination.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(destination.lastPathComponent)
    func matches(_ route: Self) throws -> Bool {
      guard route.basename.utf8.elementsEqual(target.lastPathComponent.utf8) else { return false }
      let authority = try route.rootAuthority(environment, validateExistingOverride: false)
      let planned = authority.plannedPhysicalDirectory
      let targetParent = target.deletingLastPathComponent()
      if planned.path.utf8.elementsEqual(targetParent.path.utf8) {
        _ = try authority.physicalDirectory()
        return true
      }
      if planned.resolvingSymlinksInPath().path.utf8.elementsEqual(targetParent.path.utf8) {
        _ = try authority.physicalDirectory()
        return true
      }
      // Unselected, disjoint roots do not impose access requirements on this target.
      // Openable aliases still compare by descriptor identity, including bind aliases.
      guard let candidate = try? DirectoryHandle(at: planned),
        let parent = try? DirectoryHandle(at: targetParent),
        try candidate.objectIdentity == parent.objectIdentity
      else { return false }
      _ = try authority.physicalDirectory()
      return true
    }
    for route in allCases
    where route.shared && route.basename.utf8.elementsEqual(target.lastPathComponent.utf8) {
      if try matches(route) { return route }
    }
    for member in Member.allCases {
      guard let probe = try? named(member, scope: .user, name: "probe") else { continue }
      let suffix = String(probe.basename.dropFirst("probe".count))
      guard target.lastPathComponent.hasSuffix(suffix) else { continue }
      let authority = try probe.rootAuthority(environment, validateExistingOverride: false)
      let container = authority.plannedPhysicalDirectory
      var ancestor = target.deletingLastPathComponent()
      var relativeParts = [target.lastPathComponent]
      let containerIdentity = try? DirectoryHandle(at: container).objectIdentity
      while ancestor.path != "/" {
        if let containerIdentity,
          let opened = try? DirectoryHandle(at: ancestor),
          try opened.objectIdentity == containerIdentity
        {
          break
        }
        relativeParts.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
      }
      let relative: String
      if ancestor.path != "/" {
        // Descriptor-equivalent container aliases retain the entire validated nested name.
        relative = relativeParts.joined(separator: "/")
      } else {
        let prefix = container.path + "/"
        let bytes = Array(target.path.utf8)
        guard bytes.starts(with: prefix.utf8) else { continue }
        relative = String(decoding: bytes.dropFirst(prefix.utf8.count), as: UTF8.self)
      }
      let candidate =
        probe.isContainer
        ? try? named(member, scope: .user, name: relative)
        : try? file(member, scope: .user, relativePath: relative)
      if let candidate, try matches(candidate) { return candidate }
    }
    return nil
  }
  static func globalLogicalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try claudeMCPLocal.logicalDirectory(environment)
  }
  static func globalDirectory(_ environment: RuntimeEnvironment) throws -> URL {
    try globalLogicalDirectory(environment).resolvingSymlinksInPath()
  }
}

/// The configured loader boundary may be an admitted alias. Every descendant is no-follow.
struct NativeRootAuthority {
  let loader: URL
  let descendants: [String]
  var logicalDirectory: URL { descendants.reduce(loader) { $0.appendingPathComponent($1) } }
  var plannedPhysicalDirectory: URL {
    descendants.reduce(loader.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
  }
  func physicalDirectory() throws -> URL {
    var result = loader.resolvingSymlinksInPath()
    let ancestry = try DirectoryAccessEvidence.capture(at: result)
    var opened =
      ancestry.directories.count == result.pathComponents.count
      ? try DirectoryHandle(at: result) : nil
    for part in descendants {
      result.appendPathComponent(part)
      if let parent = opened, try parent.info(part) != nil {
        opened = try parent.child(part)
      } else {
        opened = nil
      }
    }
    return result
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
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.parent == rhs.parent && lhs.basename.utf8.elementsEqual(rhs.basename.utf8)
  }
  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.orderingKey.utf8.lexicographicallyPrecedes(rhs.orderingKey.utf8)
  }

  func validate() throws {
    guard parent.isDirectory,
      !basename.isEmpty, basename != ".", basename != "..",
      !basename.contains("/"), !basename.contains("\\"), !basename.contains("\0")
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
  let authority: NativeRootAuthority
  private var lockDescriptor: Int32?
  private var lockAccess: FileAccessEvidence?

  init(
    store: StateStore, route: NativeTargetRoute = .claudeMCPLocal, create: Bool,
    existingRoot: ExistingProjectRoot? = nil, projectRoot: DirectoryHandle? = nil
  ) throws {
    guard route.shared else { throw CoreError.invalidState("project route has no shared resource") }
    self.route = NativeTargetRoute.targetRoute(route.root)!
    authority = try route.rootAuthority(store.environment)
    let url = try authority.physicalDirectory()
    if let existingRoot, let projectRoot,
      let anchored = try existingRoot.descendant(at: url, from: projectRoot, create: create)
    {
      parent = anchored
    } else {
      parent = try DirectoryHandle(at: url, create: create)
    }
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
      try DirectoryHandle(at: authority.physicalDirectory()).objectIdentity
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

/// Absence has no physical resource key. Only read admission may carry this evidence;
/// a writer must create and open the real parent before deriving its coordination domain.
struct AbsentSharedRoot {
  let route: NativeTargetRoute
  let authority: NativeRootAuthority
  let physical: URL
  let ancestry: DirectoryAccessEvidence

  init?(store: StateStore, route: NativeTargetRoute) throws {
    authority = try route.rootAuthority(store.environment)
    physical = try authority.physicalDirectory()
    ancestry = try DirectoryAccessEvidence.capture(at: physical)
    guard ancestry.directories.count < physical.pathComponents.count else { return nil }
    self.route = route
  }

  func remainsAbsent() throws -> Bool {
    guard try authority.physicalDirectory().path.utf8.elementsEqual(physical.path.utf8) else {
      throw CoreError.invalidState("registered native root changed during inspection")
    }
    let current = try DirectoryAccessEvidence.capture(at: physical)
    guard current.directories.starts(with: ancestry.directories) else {
      throw CoreError.invalidState("registered native ancestry changed during inspection")
    }
    return current.directories.count < physical.pathComponents.count
  }
}

/// Synchronous, thread-confined admission. There is no lock acquisition inside a transaction.
final class TransactionLockContext {
  private static let threadKey = "agents.core.transaction-lock-context"
  let scopeURL: URL
  let resources: [SharedResource]
  var createdAncestry: [(URL, DirectoryAccessEvidence)] = []
  let admissions: [SharedResource]
  let requestedRoutes: Set<NativeTargetRoute>
  let writable: Bool
  let requestedShared: Bool
  let absentRoots: [AbsentSharedRoot]
  var existingProjectRoot: ExistingProjectRoot?
  var projectRootDirectory: DirectoryHandle?
  private var scopeDirectory: DirectoryHandle?
  private var scopeDescriptor: Int32?
  private var scopeLockIdentity: FileObjectIdentity?

  init(
    store: StateStore, resources: [SharedResource], writable: Bool, requestedShared: Bool,
    absentRoots: [AbsentSharedRoot] = [], admissions: [SharedResource] = [],
    requestedRoutes: Set<NativeTargetRoute> = []
  ) {
    scopeURL = store.directory.standardizedFileURL
    self.resources = resources
    self.admissions = admissions.isEmpty ? resources : admissions
    self.requestedRoutes = requestedRoutes
    self.writable = writable
    self.requestedShared = requestedShared
    self.absentRoots = absentRoots
  }

  static var currentForDisplay: TransactionLockContext? {
    Thread.current.threadDictionary[threadKey] as? TransactionLockContext
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
    try existingProjectRoot?.validate()
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
    guard let resource = admissions.first(where: { $0.route.root == route.root }) else {
      throw CoreError.invalidState("shared target is outside the held request footprint")
    }
    try resource.validate()
    return try self.resource(resource.identity)
  }

  func absentRoot(for route: NativeTargetRoute) throws -> AbsentSharedRoot? {
    guard !writable, let absent = absentRoots.first(where: { $0.route.root == route.root }) else {
      return nil
    }
    guard try absent.remainsAbsent() else { throw CoordinationReadmission.required }
    return absent
  }

  func targetDirectory(for route: NativeTargetRoute) throws -> URL {
    if let absent = try absentRoot(for: route) { return absent.physical }
    return try resource(for: route).parent.url
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
  func requireProjectNativeAuthority(at destination: URL) throws {
    if scope == .project,
      try NativeTargetRoute.userRoute(at: destination, environment: environment) != nil
    {
      throw CoreError.unsafePath("project target coincides with a registered shared user target")
    }
  }

  package func nativeTarget(for route: NativeTargetRoute) throws -> MaterializationTarget {
    guard route.permits(scope) else {
      throw CoreError.unsafePath("project native targets require their project scope")
    }
    if !route.shared, route.isNamed {
      let target = try route.physicalDirectory(environment).appendingPathComponent(route.basename)
      try requireProjectNativeAuthority(at: target)
      if route.isContainer {
        for shared in NativeTargetRoute.allCases where shared.shared {
          let parent = try shared.rootAuthority(environment, validateExistingOverride: false)
            .plannedPhysicalDirectory
          if parent.path.utf8.elementsEqual(target.path.utf8)
            || parent.path.utf8.starts(with: (target.path + "/").utf8)
          {
            throw CoreError.unsafePath("registered container encloses a shared native loader")
          }
        }
      }
    }
    var canonical = route
    let parent: URL
    if route.shared, let context = TransactionLockContext.current(self) {
      parent = try context.targetDirectory(for: route)
      if try context.absentRoot(for: route) == nil {
        canonical = try context.resource(for: route).route
      }
    } else {
      parent = try route.physicalDirectory(environment)
    }
    if !route.shared, let context = TransactionLockContext.current(self) {
      for candidate in context.requestedRoutes.filter({ !$0.shared && $0.permits(scope) }).sorted(
        by: {
          $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }) where candidate.basename.utf8.elementsEqual(route.basename.utf8)
      {
        if try candidate.physicalDirectory(environment).path.utf8.elementsEqual(parent.path.utf8) {
          canonical = candidate
          break
        }
      }
    }
    return MaterializationTarget(
      url: parent.appendingPathComponent(route.basename),
      path: canonical.root + "/" + canonical.basename, scope: directory)
  }

  /// Acquire the union before the scope lock. Re-admission never replays a delivered callback.
  func withCoordination<T>(
    routes: Set<NativeTargetRoute>, writable: Bool,
    checkpoint: (String) throws -> Void = { _ in },
    existingRoot: ExistingProjectRoot? = nil, projectRoot: DirectoryHandle? = nil,
    _ body: () throws -> T
  ) throws -> T {
    try existingRoot?.validate()
    if TransactionLockContext.isHeld {
      throw CoreError.invalidState("nested scope lock acquisition")
    }
    guard routes.allSatisfy({ $0.permits(scope) }) else {
      throw CoreError.unsafePath("registered native request belongs to another scope")
    }
    for route in routes where !route.shared && route.isNamed { _ = try nativeTarget(for: route) }
    while true {
      let before = try pendingCoordinationJournal(diagnosing: !writable)
      var resources: [SharedResource] = []
      var createdAncestry: [(URL, DirectoryAccessEvidence)] = []
      if writable {
        let evidence = try DirectoryAccessEvidence.capture(at: directory)
        if evidence.directories.count < directory.pathComponents.count {
          createdAncestry.append((directory, evidence))
        }
      }
      var absentRoots: [AbsentSharedRoot] = []
      let pending = before?.footprint ?? []
      var admissions: [SharedResource] = []
      let recoveryRoutes = Set(
        (before?.roots.keys.map { $0 } ?? []).compactMap {
          NativeTargetRoute.sharedRoute($0) ?? NativeTargetRoute.metadataRoute($0)
        })
      var requested = Set(routes.filter(\.shared).map { NativeTargetRoute.targetRoute($0.root)! })
      requested.formUnion(recoveryRoutes)
      let ordered = requested.sorted { left, right in
        let leftPending = recoveryRoutes.contains(left)
        let rightPending = recoveryRoutes.contains(right)
        return leftPending == rightPending ? left.rawValue < right.rawValue : leftPending
      }
      let physicalTargets = try ordered.map { route in
        try route.physicalDirectory(environment).appendingPathComponent(route.basename)
      }
      for parent in physicalTargets.map({ $0.deletingLastPathComponent() }) {
        var ancestor = parent
        while ancestor.path != "/" {
          if let enclosing = try NativeTargetRoute.userRoute(
            at: ancestor, environment: environment), enclosing.isContainer
          {
            throw CoreError.unsafePath("native coordination would be inside a registered container")
          }
          ancestor.deleteLastPathComponent()
        }
      }
      for (index, target) in physicalTargets.enumerated() {
        for (other, nested) in physicalTargets.enumerated() where index != other {
          let parent = nested.deletingLastPathComponent()
          if parent.path.utf8.elementsEqual(target.path.utf8)
            || parent.path.hasPrefix(target.path + "/")
          {
            throw CoreError.unsafePath("nested native coordination domains conflict")
          }
        }
      }
      for route in ordered {
        let recovering = recoveryRoutes.contains(route)
        if writable, !recovering, let absent = try AbsentSharedRoot(store: self, route: route) {
          createdAncestry.append((absent.physical, absent.ancestry))
        }
        if !writable, !recovering, let absent = try AbsentSharedRoot(store: self, route: route) {
          absentRoots.append(absent)
          continue
        }
        let resource: SharedResource
        do {
          resource = try SharedResource(
            store: self, route: route, create: writable && !recovering,
            existingRoot: existingRoot, projectRoot: projectRoot)
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
        admissions.append(resource)
        if !resources.contains(where: { $0.identity == resource.identity }) {
          resources.append(resource)
        }
      }
      guard pending.allSatisfy({ identity in resources.contains { $0.identity == identity } })
      else {
        throw CoreError.invalidState("shared recovery footprint has no registered runtime resource")
      }
      let context = TransactionLockContext(
        store: self, resources: resources.sorted { $0.identity < $1.identity }, writable: writable,
        requestedShared: routes.contains(where: \.shared), absentRoots: absentRoots,
        admissions: admissions, requestedRoutes: routes)
      context.createdAncestry = createdAncestry
      context.existingProjectRoot = existingRoot
      context.projectRootDirectory = projectRoot
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
        let result = Result { try context.run { try body() } }
        for absent in absentRoots where try !absent.remainsAbsent() { return nil }
        return try result.get()
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
    for admission in context.admissions { try admission.validate() }
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

/// Descriptor-derived physical file key. Absence deliberately has no fabricated key.
package struct NativeTargetIdentity: Hashable, Sendable {
  package let device: UInt64
  package let inode: UInt64
  package let kind: UInt32
  package let basename: String
  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.kind == rhs.kind
      && lhs.basename.utf8.elementsEqual(rhs.basename.utf8)
  }
  package func hash(into hasher: inout Hasher) {
    hasher.combine(device)
    hasher.combine(inode)
    hasher.combine(kind)
    for byte in basename.utf8 { hasher.combine(byte) }
  }
}

extension StateStore {
  package func nativeTargetIdentity(for route: NativeTargetRoute) throws -> NativeTargetIdentity? {
    let target = try nativeTarget(for: route)
    let parent = target.url.deletingLastPathComponent()
    let evidence = try DirectoryAccessEvidence.capture(at: parent)
    guard evidence.directories.count == parent.pathComponents.count else { return nil }
    let descriptor = try DirectoryHandle(at: parent)
    let identity = try descriptor.objectIdentity
    try evidence.validate(at: parent)
    return NativeTargetIdentity(
      device: identity.device, inode: identity.inode,
      kind: UInt32(identity.kind), basename: target.url.lastPathComponent)
  }
}
