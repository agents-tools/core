import AgentsCore
import AgentsManifest
import Foundation
import NativeDocuments

public enum LifecycleOperations {
  #if os(macOS)
    static let administratorDirectory = URL(fileURLWithPath: "/private/etc/agents/lifecycle.d")
  #else
    static let administratorDirectory = URL(fileURLWithPath: "/etc/agents/lifecycle.d")
  #endif

  // Tests supply an isolated path; production authority comes only from the system location.
  @TaskLocal package static var administratorDirectoryForTesting: URL?

  public static func list(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> LifecycleInspection {
    let context = LifecycleContext(scope: scope, environment: environment)
    let discovery = context.discover()
    let gate = LifecycleInvocation.policy(
      context: context, offline: false, expected: nil, requireInstallPreview: false)
    return context.inspection(discovery, policy: gate.withheld)
  }

  public static func validate(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> [LifecycleDiagnostic] {
    LifecycleContext(scope: scope, environment: environment).discover().diagnostics
  }
}

public struct LifecycleProjectIdentity: Codable, Equatable, Hashable, Sendable {
  public let canonicalPath: String
  let physicalIdentity: String

  init(_ directory: DirectoryHandle) throws {
    canonicalPath = directory.lifecycleDirectoryURL.path
    physicalIdentity = try directory.lifecycleIdentity
  }

  var key: String {
    // Separate the path and identity without relying on JSONEncoder's escaping.
    FileHash.sha256Hex(
      data: Data(
        ("agents.lifecycle.root.v1\0" + canonicalPath + "\0"
          + physicalIdentity).utf8))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canonicalPath.utf8.elementsEqual(rhs.canonicalPath.utf8)
      && lhs.physicalIdentity == rhs.physicalIdentity
  }

  public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct LifecycleContext: Sendable {
  let store: StateStore
  let adminDirectory: URL

  init(scope: InstallScope, environment: RuntimeEnvironment) {
    store = StateStore(scope: scope, environment: environment)
    adminDirectory =
      LifecycleOperations.administratorDirectoryForTesting
      ?? LifecycleOperations.administratorDirectory
  }

  var userStore: StateStore { .init(scope: .user, environment: store.environment) }
  var disabled: Bool {
    store.environment.environment["APM_NO_SCRIPTS"] == "1"
      || ProcessInfo.processInfo.environment["APM_NO_SCRIPTS"] == "1"
  }

  func openProject() throws -> DirectoryHandle {
    try DirectoryHandle.readDirectory(
      at: store.environment.projectDirectory.resolvingSymlinksInPath())
  }

  func openHome() throws -> DirectoryHandle? {
    let home = store.environment.homeDirectory
    if store.scope == .project {
      let project = Array(
        store.environment.projectDirectory.resolvingSymlinksInPath().path.utf8)
      let user = Array(home.resolvingSymlinksInPath().path.utf8)
      guard project != user, !user.starts(with: project + [47]), project != [47] else {
        throw CoreError.unsafePath("User lifecycle state is inside the consuming project.")
      }
    }
    return try DirectoryHandle.lifecycleDirectory(at: home, authority: .user)
  }

  func discover() -> LifecycleDiscovery {
    var result = LifecycleDiscovery()
    let admin = LifecycleSource(authority: .administrator, file: adminDirectory)
    do {
      if let directory = try DirectoryHandle.lifecycleDirectory(
        at: adminDirectory, authority: .administrator)
      {
        for name in try directory.names(maximumCount: 256) where name.hasSuffix(".json") {
          let source = LifecycleSource(
            authority: .administrator, file: adminDirectory.appendingPathComponent(name))
          do {
            guard
              let input = try directory.readLifecycleFile(
                name, authority: .administrator, maximumBytes: 256 * 1024)
            else { throw CoreError.invalidState("Administrator lifecycle file disappeared.") }
            try result.addAdmin(input: input, source: source)
          } catch {
            result.reject(source, "Administrator lifecycle file could not be admitted or parsed.")
          }
        }
      }
    } catch {
      result.reject(admin, "Administrator lifecycle directory could not be admitted or read.")
    }

    let user = LifecycleSource(authority: .user, file: userStore.declarationURL)
    do {
      if let directory = try openHome()?.lifecycleChild(".agents", authority: .user) {
        try result.addNative(directory: directory, source: user, authority: .user)
      }
    } catch {
      result.reject(user, "User lifecycle source could not be admitted or read.")
    }

    if store.scope == .project {
      let source = LifecycleSource(authority: .project, file: store.declarationURL)
      do {
        let root = try openProject()
        result.root = try LifecycleProjectIdentity(root)
        if let directory = try root.lifecycleChild(".agent", authority: .project) {
          try result.addNative(directory: directory, source: source, authority: .project)
        }
      } catch {
        result.reject(source, "Project lifecycle source could not be admitted or read.")
      }
    }
    return result
  }

  func inspection(
    _ discovery: LifecycleDiscovery, events: Set<LifecycleEvent>? = nil,
    policy: LifecycleWithholding? = nil,
    receipt observation: Result<LifecycleTrustRecord?, any Error>? = nil
  ) -> LifecycleInspection {
    let observation = observation ?? Result { try trustReceipt(discovery.root) }
    let receipt = try? observation.get()
    let trusted = discovery.projectDigest != nil && receipt?.digest == discovery.projectDigest
    let all: LifecycleWithholding? =
      disabled
      ? .disabled
      : discovery.administratorInvalid
        ? .administratorSourceInvalid
        : policy ?? (store.scope == .project && discovery.root == nil ? .projectChanged : nil)
    let actions = discovery.actions.filter { events?.contains($0.value.event) ?? true }
    return LifecycleInspection(
      actions: actions.map { action in
        let local: LifecycleWithholding?
        if case .failure = observation {
          local = .receiptUnavailable
        } else {
          local = trusted ? nil : .projectUntrusted
        }
        return action.summary(withheld: all ?? (action.source.authority == .project ? local : nil))
      }, diagnostics: discovery.diagnostics, project: discovery.root, projectTrusted: trusted,
      allStartsWithheld: all)
  }
}

struct LifecycleDiscovery: Sendable {
  var actions: [CapturedLifecycleAction] = []
  var diagnostics: [LifecycleDiagnostic] = []
  var root: LifecycleProjectIdentity?
  var projectDeclaration: DeclarationValue?
  var projectDigest: String?
  var administratorInvalid = false

  mutating func reject(_ source: LifecycleSource, _ message: String, field: String? = nil) {
    diagnostics.append(
      .init(source: source, event: nil, index: nil, field: field, message: message))
    if source.authority == .administrator { administratorInvalid = true }
  }

  mutating func addNative(
    directory: DirectoryHandle, source: LifecycleSource, authority: LifecycleFileAuthority
  ) throws {
    guard
      let input = try directory.readLifecycleFile(
        StateStore.declarationFileName, authority: authority, maximumBytes: 2 * 1024 * 1024)
    else { return }
    let document: DeclarationDocument
    do {
      document = try DeclarationDocument(
        bytes: Array(input.bytes), identity: DocumentIdentity(source.file.path))
    } catch let failure as ManifestFailure {
      for diagnostic in failure.diagnostics {
        if let issue = diagnostic.lifecycleIssue {
          add(issue, source: source)
        } else {
          reject(
            source, "Invalid manifest (\(diagnostic.code)) at line \(diagnostic.span.line).")
        }
      }
      return
    }
    guard let declaration = document.declaration.lifecycle else { return }
    let digest = try LifecycleDeclaration.digest(declaration)
    if source.authority == .project {
      projectDeclaration = declaration
      projectDigest = digest
    }
    append(
      LifecycleDeclaration(declaration), source: source, digest: digest,
      provenance: nil)
  }

  mutating func addAdmin(input: (bytes: Data, provenance: String), source: LifecycleSource) throws {
    let budget = NativeDocumentBudget(
      limits: .init(
        storage: 16 * 1024 * 1024, work: 32 * 1024 * 1024, nodes: 20_000, depth: 16,
        uninterruptedBytes: 256 * 1024))
    let doc = try NativeDocument(bytes: input.bytes, format: .json, budget: budget)
    guard case .object(let root) = try doc.read(.init(keys: []))?.value else {
      reject(source, "Expected an administrator lifecycle object.")
      return
    }
    let initial = diagnostics.count
    if root["version"] != .integer(1) {
      reject(source, "Expected administrator lifecycle version 1.", field: "version")
    }
    for key in root.keys.sorted() where key != "version" && key != "scripts" {
      reject(source, "Unknown administrator lifecycle field.", field: key)
    }
    guard let raw = root["scripts"] else {
      reject(source, "Missing administrator scripts mapping.", field: "scripts")
      return
    }
    let subtree = Self.declarationValue(raw)
    let declaration = LifecycleDeclaration(subtree)
    for issue in declaration.issues { add(issue, source: source) }
    guard diagnostics.count == initial else { return }
    append(
      declaration, source: source, digest: try LifecycleDeclaration.digest(subtree),
      provenance: input.provenance)
  }

  private mutating func add(_ issue: LifecycleDeclarationIssue, source: LifecycleSource) {
    diagnostics.append(
      .init(
        source: source, event: issue.event, index: issue.index,
        field: issue.field.isEmpty ? nil : issue.field, message: issue.message))
    if source.authority == .administrator { administratorInvalid = true }
  }

  private mutating func append(
    _ declaration: LifecycleDeclaration, source: LifecycleSource, digest: String,
    provenance: String?
  ) {
    for action in declaration.actions {
      actions.append(
        .init(source: source, value: action, digest: digest, provenance: provenance))
    }
  }

  private static func declarationValue(_ value: NativeValue) -> DeclarationValue {
    switch value {
    case .object(let entries): .dictionary(entries.mapValues(declarationValue))
    case .array(let entries): .array(entries.map(declarationValue))
    case .string(let text): .string(text)
    case .integer(let value): .integer(value)
    case .boolean(let value): .boolean(value)
    case .null, .decimal: .null
    }
  }
}

struct CapturedLifecycleAction: Sendable {
  let source: LifecycleSource
  let value: DeclaredLifecycleAction
  let digest: String
  let provenance: String?

  func summary(withheld: LifecycleWithholding? = nil) -> LifecycleActionSummary {
    let kind: LifecycleActionSummary.Kind
    let target: String
    switch value.body {
    case .command(let field, _, _):
      kind = .command
      target = field == .bash ? "/bin/bash" : "/bin/sh"
    case .http(let url, _, _):
      kind = .http
      var origin = URLComponents()
      origin.scheme = "https"
      origin.host = url.host
      origin.port = url.port
      target = origin.string ?? "https"
    }
    return .init(
      source: source, event: value.event, index: value.index, kind: kind, target: target,
      timeoutSeconds: value.timeout, withheld: withheld)
  }

  func matches(_ current: CapturedLifecycleAction) -> Bool {
    source == current.source && value.event == current.value.event
      && value.index == current.value.index
      && digest == current.digest && provenance == current.provenance
  }
}
