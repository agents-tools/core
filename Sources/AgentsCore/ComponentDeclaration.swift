import Foundation

/// Directories in which a source alias was declared. Linking must not reinterpret relative
/// paths using the importing document's directories. Process environment values are not captured.
public struct SourceEnvironment: Equatable, Sendable {
  public var projectDirectory: URL
  public var homeDirectory: URL

  public init(projectDirectory: URL, homeDirectory: URL) {
    self.projectDirectory = projectDirectory.standardizedFileURL
    self.homeDirectory = homeDirectory.standardizedFileURL
  }

  /// URL directory hints do not change the declaring directory's identity.
  public static func == (lhs: SourceEnvironment, rhs: SourceEnvironment) -> Bool {
    lhs.projectDirectory.standardizedFileURL.path == rhs.projectDirectory.standardizedFileURL.path
      && lhs.homeDirectory.standardizedFileURL.path == rhs.homeDirectory.standardizedFileURL.path
  }

  package var runtime: RuntimeEnvironment {
    RuntimeEnvironment(
      projectDirectory: projectDirectory, homeDirectory: homeDirectory, environment: [:])
  }
}

public struct NamedSourceDeclaration: Equatable, Sendable {
  public var name: String
  public var source: SourceDeclaration

  public init(name: String, source: SourceDeclaration) {
    self.name = name
    self.source = source
  }
}

public enum DeclarationPlatform: String, Equatable, Sendable {
  case macOS = "macos"
  case linux
}

/// Omitted dimensions impose no restriction; an explicit empty dimension matches nothing.
public struct DeclarationCondition: Equatable, Sendable {
  public var agents: [AgentID]?
  public var scopes: [InstallScope]?
  public var platforms: [DeclarationPlatform]?

  public init(
    agents: [AgentID]? = nil, scopes: [InstallScope]? = nil, platforms: [DeclarationPlatform]? = nil
  ) {
    self.agents = agents
    self.scopes = scopes
    self.platforms = platforms
  }
}

/// Values remain symbolic until binding at the consuming operation.
public enum RuntimeBinding: Equatable, Sendable {
  case literal(String)
  case environment(String)
  case secret(String)
}

public indirect enum NativeValue: Equatable, Sendable {
  case string(String)
  case integer(Int)
  case decimal(String)
  case boolean(Bool)
  case null
  case array([NativeValue])
  case object([String: NativeValue])
}

public typealias NativeConfiguration = [String: [String: NativeValue]]

public struct ResourceDeclaration: Equatable, Sendable {
  public var path: String
  public var source: String?

  public init(path: String, source: String? = nil) {
    self.path = path
    self.source = source
  }
}

public enum PromptBody: Equatable, Sendable {
  case literal(String)
  case file(ResourceDeclaration)
}

public struct ExecutableDeclaration: Equatable, Sendable {
  public var executable: String
  public var arguments: [String]
  public var environment: [String: RuntimeBinding]
  public var workingDirectory: ResourceDeclaration?

  public init(
    executable: String, arguments: [String] = [], environment: [String: RuntimeBinding] = [:],
    workingDirectory: ResourceDeclaration? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }
}

public enum MCPTransportDeclaration: Equatable, Sendable {
  case stdio(ExecutableDeclaration)
  case streamableHTTP(url: String, headers: [String: RuntimeBinding] = [:])
  case sse(url: String, headers: [String: RuntimeBinding] = [:])
}

public enum HookEventDeclaration: Equatable, Sendable {
  case beforeTool
  case afterTool
  case sessionStart
  case sessionEnd
  case native(String)
}

public struct PromptParameterDeclaration: Equatable, Sendable {
  public var name: String
  public var description: String
  public var defaultValue: String?

  public init(name: String, description: String, defaultValue: String? = nil) {
    self.name = name
    self.description = description
    self.defaultValue = defaultValue
  }
}

public enum PermissionOperationDeclaration: Equatable, Sendable {
  case read
  case write
  case execute
  case tool(String)
}

public enum PermissionRuleDeclaration: Equatable, Sendable {
  case allow(PermissionOperationDeclaration, String)
  case ask(PermissionOperationDeclaration, String)
  case deny(PermissionOperationDeclaration, String)
}

public enum IgnorePurposeDeclaration: String, Equatable, Sendable {
  case context
  case indexing
}

public enum PluginModeDeclaration: String, Equatable, Sendable {
  case native
  case components
}

public enum DeclaredComponentKind: String, CaseIterable, Equatable, Sendable {
  case skills, instructions, mcpServer, hook, subagent, command, lspServer, permissions, ignore,
    plugin
}

public enum ComponentReferenceDeclaration: Equatable, Sendable {
  case skill(name: String)
  case instruction(name: String)
  case mcpServer(name: String)
  case hook(name: String)
  case subagent(name: String)
  case command(name: String)
  case lspServer(name: String)
  case permissions(name: String)
  case ignore(name: String)
  case plugin(name: String)
}

public struct SectionDeclaration: Equatable, Sendable {
  public var name: String
  public var source: String?
  public var condition: DeclarationCondition?

  public init(name: String, source: String? = nil, condition: DeclarationCondition? = nil) {
    self.name = name
    self.source = source
    self.condition = condition
  }

  public init(reference: String) {
    if let colon = reference.firstIndex(of: ":") {
      self.init(
        name: String(reference[reference.index(after: colon)...]),
        source: String(reference[..<colon]))
    } else {
      self.init(name: reference)
    }
  }

  public var reference: String {
    guard let source, source != "." else { return name }
    return source + ":" + name
  }
}

public struct NamedPromptDeclaration: Equatable, Sendable {
  public var name: String
  public var prompt: PromptDeclaration

  public init(name: String, prompt: PromptDeclaration) {
    self.name = name
    self.prompt = prompt
  }
}

public struct GroupUseDeclaration: Equatable, Sendable {
  public var name: String
  public var source: String?
  public var condition: DeclarationCondition?

  public init(name: String, source: String? = nil, condition: DeclarationCondition? = nil) {
    self.name = name
    self.source = source
    self.condition = condition
  }
}

public struct ComponentGroupDeclaration: Equatable, Sendable {
  public var name: String
  public var components: [ComponentDeclaration]
  public var uses: [GroupUseDeclaration]
  public var condition: DeclarationCondition?

  public init(
    name: String, components: [ComponentDeclaration] = [], uses: [GroupUseDeclaration] = [],
    condition: DeclarationCondition? = nil
  ) {
    self.name = name
    self.components = components
    self.uses = uses
    self.condition = condition
  }
}

/// One authored occurrence. Repeated logical names and conditional occurrences are retained;
/// they are not merged into a deployment selection while parsing.
public enum ComponentDeclaration: Equatable, Sendable {
  case skills(source: String, SkillDeclaration)
  case instructions(InstructionsDeclaration)
  case mcpServer(
    name: String, transport: MCPTransportDeclaration, agents: [AgentID]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:])
  case hook(
    name: String, event: HookEventDeclaration, run: ExecutableDeclaration, matcher: String? = nil,
    timeoutSeconds: Int? = nil, agents: [AgentID]? = nil, condition: DeclarationCondition? = nil,
    native: NativeConfiguration = [:])
  case subagent(
    name: String, description: String, prompt: PromptBody, model: String? = nil,
    tools: [String]? = nil, agents: [AgentID]? = nil, condition: DeclarationCondition? = nil,
    native: NativeConfiguration = [:])
  case command(
    name: String, description: String, prompt: PromptBody,
    parameters: [PromptParameterDeclaration] = [], agents: [AgentID]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:])
  case lspServer(
    name: String, run: ExecutableDeclaration, languages: [String: String],
    initializationOptions: [String: NativeValue] = [:], agents: [AgentID]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:])
  case permissions(
    name: String, rules: [PermissionRuleDeclaration], agents: [AgentID]? = nil,
    condition: DeclarationCondition? = nil, native: NativeConfiguration = [:])
  case ignore(
    name: String, patterns: [String], purpose: IgnorePurposeDeclaration = .context,
    agents: [AgentID]? = nil, condition: DeclarationCondition? = nil,
    native: NativeConfiguration = [:])
  case plugin(
    name: String, path: String, source: String, mode: PluginModeDeclaration = .components,
    select: [DeclaredComponentKind]? = nil, exclude: [ComponentReferenceDeclaration] = [],
    agents: [AgentID]? = nil, condition: DeclarationCondition? = nil,
    native: NativeConfiguration = [:])

  public var kind: DeclaredComponentKind {
    switch self {
    case .skills: .skills
    case .instructions: .instructions
    case .mcpServer: .mcpServer
    case .hook: .hook
    case .subagent: .subagent
    case .command: .command
    case .lspServer: .lspServer
    case .permissions: .permissions
    case .ignore: .ignore
    case .plugin: .plugin
    }
  }
}

public struct NamedSkillOverrideDeclaration: Equatable, Sendable {
  public var name: String
  public var override: SkillOverride

  public init(name: String, override: SkillOverride) {
    self.name = name
    self.override = override
  }
}
