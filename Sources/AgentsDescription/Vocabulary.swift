// Generated from Scripts/ManifestVocabulary.json. Run Scripts/generate-manifest-vocabulary.py.

public enum Agent: Sendable, Equatable {
  case claudeCode
  case codex
  case cursor
  case geminiCLI
  case openCode
}

extension Agent: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .claudeCode: .node(type: "Agent", member: "claudeCode", fields: [:])
    case .codex: .node(type: "Agent", member: "codex", fields: [:])
    case .cursor: .node(type: "Agent", member: "cursor", fields: [:])
    case .geminiCLI: .node(type: "Agent", member: "geminiCLI", fields: [:])
    case .openCode: .node(type: "Agent", member: "openCode", fields: [:])
    }
  }
}

public enum Scope: Sendable, Equatable {
  case project
  case user
}

extension Scope: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .project: .node(type: "Scope", member: "project", fields: [:])
    case .user: .node(type: "Scope", member: "user", fields: [:])
    }
  }
}

public enum Platform: Sendable, Equatable {
  case macOS
  case linux
}

extension Platform: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .macOS: .node(type: "Platform", member: "macOS", fields: [:])
    case .linux: .node(type: "Platform", member: "linux", fields: [:])
    }
  }
}

public enum InstallMode: Sendable, Equatable {
  case link
  case copy
  case edit
}

extension InstallMode: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .link: .node(type: "InstallMode", member: "link", fields: [:])
    case .copy: .node(type: "InstallMode", member: "copy", fields: [:])
    case .edit: .node(type: "InstallMode", member: "edit", fields: [:])
    }
  }
}

public enum RuntimeValue: Sendable, Equatable, ExpressibleByStringLiteral {
  case literal(String)
  case environment(String)
  case secret(String)
  public init(stringLiteral value: String) { self = .literal(value) }
}

extension RuntimeValue: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .literal(let value):
      .node(type: "RuntimeValue", member: "literal", fields: ["value": value.constructionValue])
    case .environment(let value):
      .node(type: "RuntimeValue", member: "environment", fields: ["value": value.constructionValue])
    case .secret(let value):
      .node(type: "RuntimeValue", member: "secret", fields: ["value": value.constructionValue])
    }
  }
}

public indirect enum ConfigurationValue: Sendable, Equatable, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  case string(String)
  case integer(Int)
  case decimal(String)
  case boolean(Bool)
  case null
  case array([ConfigurationValue])
  case object([String: ConfigurationValue])
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .integer(value) }
  public init(booleanLiteral value: Bool) { self = .boolean(value) }
  public init(nilLiteral: ()) { self = .null }
  public init(arrayLiteral elements: ConfigurationValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, ConfigurationValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

extension ConfigurationValue: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .string(let value):
      .node(
        type: "ConfigurationValue", member: "string", fields: ["value": value.constructionValue])
    case .integer(let value):
      .node(
        type: "ConfigurationValue", member: "integer", fields: ["value": value.constructionValue])
    case .decimal(let value):
      .node(
        type: "ConfigurationValue", member: "decimal", fields: ["value": value.constructionValue])
    case .boolean(let value):
      .node(
        type: "ConfigurationValue", member: "boolean", fields: ["value": value.constructionValue])
    case .null: .node(type: "ConfigurationValue", member: "null", fields: [:])
    case .array(let value):
      .node(type: "ConfigurationValue", member: "array", fields: ["value": value.constructionValue])
    case .object(let value):
      .node(
        type: "ConfigurationValue", member: "object", fields: ["value": value.constructionValue])
    }
  }
}

public enum HookEvent: Sendable, Equatable {
  case beforeTool
  case afterTool
  case sessionStart
  case sessionEnd
  case native(String)
}

extension HookEvent: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .beforeTool: .node(type: "HookEvent", member: "beforeTool", fields: [:])
    case .afterTool: .node(type: "HookEvent", member: "afterTool", fields: [:])
    case .sessionStart: .node(type: "HookEvent", member: "sessionStart", fields: [:])
    case .sessionEnd: .node(type: "HookEvent", member: "sessionEnd", fields: [:])
    case .native(let value):
      .node(type: "HookEvent", member: "native", fields: ["value": value.constructionValue])
    }
  }
}

public enum PermissionOperation: Sendable, Equatable {
  case read
  case write
  case execute
  case tool(String)
}

extension PermissionOperation: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .read: .node(type: "PermissionOperation", member: "read", fields: [:])
    case .write: .node(type: "PermissionOperation", member: "write", fields: [:])
    case .execute: .node(type: "PermissionOperation", member: "execute", fields: [:])
    case .tool(let value):
      .node(type: "PermissionOperation", member: "tool", fields: ["value": value.constructionValue])
    }
  }
}

public enum IgnorePurpose: Sendable, Equatable {
  case context
  case indexing
}

extension IgnorePurpose: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .context: .node(type: "IgnorePurpose", member: "context", fields: [:])
    case .indexing: .node(type: "IgnorePurpose", member: "indexing", fields: [:])
    }
  }
}

public enum PluginMode: Sendable, Equatable {
  case native
  case components
}

extension PluginMode: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .native: .node(type: "PluginMode", member: "native", fields: [:])
    case .components: .node(type: "PluginMode", member: "components", fields: [:])
    }
  }
}

public enum ComponentKind: Sendable, Equatable {
  case skills
  case instructions
  case mcpServer
  case hook
  case subagent
  case command
  case lspServer
  case permissions
  case ignore
  case plugin
}

extension ComponentKind: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .skills: .node(type: "ComponentKind", member: "skills", fields: [:])
    case .instructions: .node(type: "ComponentKind", member: "instructions", fields: [:])
    case .mcpServer: .node(type: "ComponentKind", member: "mcpServer", fields: [:])
    case .hook: .node(type: "ComponentKind", member: "hook", fields: [:])
    case .subagent: .node(type: "ComponentKind", member: "subagent", fields: [:])
    case .command: .node(type: "ComponentKind", member: "command", fields: [:])
    case .lspServer: .node(type: "ComponentKind", member: "lspServer", fields: [:])
    case .permissions: .node(type: "ComponentKind", member: "permissions", fields: [:])
    case .ignore: .node(type: "ComponentKind", member: "ignore", fields: [:])
    case .plugin: .node(type: "ComponentKind", member: "plugin", fields: [:])
    }
  }
}

public enum ComponentReference: Sendable, Equatable {
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

extension ComponentReference: ConstructionRepresentable {
  package var constructionValue: ConstructionValue {
    switch self {
    case .skill(let name):
      .node(type: "ComponentReference", member: "skill", fields: ["name": name.constructionValue])
    case .instruction(let name):
      .node(
        type: "ComponentReference", member: "instruction", fields: ["name": name.constructionValue])
    case .mcpServer(let name):
      .node(
        type: "ComponentReference", member: "mcpServer", fields: ["name": name.constructionValue])
    case .hook(let name):
      .node(type: "ComponentReference", member: "hook", fields: ["name": name.constructionValue])
    case .subagent(let name):
      .node(
        type: "ComponentReference", member: "subagent", fields: ["name": name.constructionValue])
    case .command(let name):
      .node(type: "ComponentReference", member: "command", fields: ["name": name.constructionValue])
    case .lspServer(let name):
      .node(
        type: "ComponentReference", member: "lspServer", fields: ["name": name.constructionValue])
    case .permissions(let name):
      .node(
        type: "ComponentReference", member: "permissions", fields: ["name": name.constructionValue])
    case .ignore(let name):
      .node(type: "ComponentReference", member: "ignore", fields: ["name": name.constructionValue])
    case .plugin(let name):
      .node(type: "ComponentReference", member: "plugin", fields: ["name": name.constructionValue])
    }
  }
}

public struct Condition: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func when(
    agents: [Agent]? = nil, scopes: [Scope]? = nil, platforms: [Platform]? = nil
  ) -> Condition {
    Self(
      value: ConstructionValue.construct(
        type: "Condition", member: "when",
        fields: [
          "agents": agents.constructionValue, "scopes": scopes.constructionValue,
          "platforms": platforms.constructionValue,
        ]))
  }
}
extension Condition: ConstructionRepresentable {}

public struct Agents: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public init(
    defaultAgents: [Agent]? = nil, exports: [String] = [], sources: [Source] = [],
    components: [Component] = [], groups: [ComponentGroup] = [], uses: [GroupReference] = [],
    watch: [String] = []
  ) {
    self.init(
      value: ConstructionValue.construct(
        type: "Agents", member: "Agents",
        fields: [
          "defaultAgents": defaultAgents.constructionValue, "exports": exports.constructionValue,
          "sources": sources.constructionValue, "components": components.constructionValue,
          "groups": groups.constructionValue, "uses": uses.constructionValue,
          "watch": watch.constructionValue,
        ]))
  }
}
extension Agents: ConstructionRepresentable {}

public struct Source: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func source(name: String, url: String, subpath: String? = nil) -> Source {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, url: String, from: Version, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "from": from.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, url: String, exact: Version, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "exact": exact.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, url: String, branch: String, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "branch": branch.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, url: String, revision: String, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "revision": revision.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(
    name: String, url: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "url": url.constructionValue,
          "range": range.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, path: String, subpath: String? = nil) -> Source {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, path: String, from: Version, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "from": from.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, path: String, exact: Version, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "exact": exact.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, path: String, branch: String, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "branch": branch.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, path: String, revision: String, subpath: String? = nil)
    -> Source
  {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "revision": revision.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(
    name: String, path: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "range": range.constructionValue, "subpath": subpath.constructionValue,
        ]))
  }
  public static func source(name: String, index: String, subpath: String? = nil) -> Source {
    Self(
      value: ConstructionValue.construct(
        type: "Source", member: "source",
        fields: [
          "name": name.constructionValue, "index": index.constructionValue,
          "subpath": subpath.constructionValue,
        ]))
  }
}
extension Source: ConstructionRepresentable {}

public struct ComponentGroup: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func group(
    name: String, components: [Component] = [], uses: [GroupReference] = [],
    condition: Condition? = nil
  ) -> ComponentGroup {
    Self(
      value: ConstructionValue.construct(
        type: "ComponentGroup", member: "group",
        fields: [
          "name": name.constructionValue, "components": components.constructionValue,
          "uses": uses.constructionValue, "condition": condition.constructionValue,
        ]))
  }
}
extension ComponentGroup: ConstructionRepresentable {}

public struct GroupReference: Sendable, Equatable, ExpressibleByStringLiteral {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public init(stringLiteral value: String) {
    self.init(
      value: .construct(
        type: "GroupReference", member: "group",
        fields: ["name": .text(value), "source": .none, "condition": .none]))
  }
  public static func group(name: String, condition: Condition? = nil) -> GroupReference {
    Self(
      value: ConstructionValue.construct(
        type: "GroupReference", member: "group",
        fields: ["name": name.constructionValue, "condition": condition.constructionValue]))
  }
  public static func group(name: String, source: String, condition: Condition? = nil)
    -> GroupReference
  {
    Self(
      value: ConstructionValue.construct(
        type: "GroupReference", member: "group",
        fields: [
          "name": name.constructionValue, "source": source.constructionValue,
          "condition": condition.constructionValue,
        ]))
  }
}
extension GroupReference: ConstructionRepresentable {}

public struct SkillSelection: Sendable, Equatable, ExpressibleByArrayLiteral {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public init(arrayLiteral elements: String...) {
    self.init(
      value: .node(
        type: "SkillSelection", member: "names", fields: ["names": elements.constructionValue]))
  }
  public static var all: SkillSelection {
    Self(value: .node(type: "SkillSelection", member: "all", fields: [:]))
  }
}
extension SkillSelection: ConstructionRepresentable {}

public struct SkillOverride: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func skill(name: String, mode: InstallMode? = nil, agents: [Agent]? = nil)
    -> SkillOverride
  {
    Self(
      value: ConstructionValue.construct(
        type: "SkillOverride", member: "skill",
        fields: [
          "name": name.constructionValue, "mode": mode.constructionValue,
          "agents": agents.constructionValue,
        ]))
  }
}
extension SkillOverride: ConstructionRepresentable {}

public struct SectionReference: Sendable, Equatable, ExpressibleByStringLiteral {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public init(stringLiteral value: String) {
    self.init(
      value: .construct(
        type: "SectionReference", member: "section",
        fields: ["name": .text(value), "source": .none, "condition": .none]))
  }
  public static func section(name: String, source: String? = nil, condition: Condition? = nil)
    -> SectionReference
  {
    Self(
      value: ConstructionValue.construct(
        type: "SectionReference", member: "section",
        fields: [
          "name": name.constructionValue, "source": source.constructionValue,
          "condition": condition.constructionValue,
        ]))
  }
}
extension SectionReference: ConstructionRepresentable {}

public struct ChatGPTPrompt: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func prompt(
    name: String, sections: [SectionReference], append: String? = nil, condition: Condition? = nil
  ) -> ChatGPTPrompt {
    Self(
      value: ConstructionValue.construct(
        type: "ChatGPTPrompt", member: "prompt",
        fields: [
          "name": name.constructionValue, "sections": sections.constructionValue,
          "append": append.constructionValue, "condition": condition.constructionValue,
        ]))
  }
}
extension ChatGPTPrompt: ConstructionRepresentable {}

public struct Resource: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func path(_ path: String, source: String? = nil) -> Resource {
    Self(
      value: ConstructionValue.construct(
        type: "Resource", member: "path",
        fields: ["path": path.constructionValue, "source": source.constructionValue]))
  }
}
extension Resource: ConstructionRepresentable {}

public struct PromptContent: Sendable, Equatable, ExpressibleByStringLiteral {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public init(stringLiteral value: String) {
    self.init(
      value: .node(type: "PromptContent", member: "literal", fields: ["value": .text(value)]))
  }
  public static func file(_ path: String, source: String? = nil) -> PromptContent {
    Self(
      value: ConstructionValue.construct(
        type: "PromptContent", member: "file",
        fields: ["path": path.constructionValue, "source": source.constructionValue]))
  }
}
extension PromptContent: ConstructionRepresentable {}

public struct ExecutableInvocation: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func executable(
    _ executable: String, arguments: [String] = [], environment: [String: RuntimeValue] = [:],
    workingDirectory: Resource? = nil
  ) -> ExecutableInvocation {
    Self(
      value: ConstructionValue.construct(
        type: "ExecutableInvocation", member: "executable",
        fields: [
          "executable": executable.constructionValue, "arguments": arguments.constructionValue,
          "environment": environment.constructionValue,
          "workingDirectory": workingDirectory.constructionValue,
        ]))
  }
}
extension ExecutableInvocation: ConstructionRepresentable {}

public struct MCPTransport: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func stdio(
    _ executable: String, arguments: [String] = [], environment: [String: RuntimeValue] = [:],
    workingDirectory: Resource? = nil
  ) -> MCPTransport {
    Self(
      value: ConstructionValue.construct(
        type: "MCPTransport", member: "stdio",
        fields: [
          "executable": executable.constructionValue, "arguments": arguments.constructionValue,
          "environment": environment.constructionValue,
          "workingDirectory": workingDirectory.constructionValue,
        ]))
  }
  public static func streamableHTTP(url: String, headers: [String: RuntimeValue] = [:])
    -> MCPTransport
  {
    Self(
      value: ConstructionValue.construct(
        type: "MCPTransport", member: "streamableHTTP",
        fields: ["url": url.constructionValue, "headers": headers.constructionValue]))
  }
  public static func sse(url: String, headers: [String: RuntimeValue] = [:]) -> MCPTransport {
    Self(
      value: ConstructionValue.construct(
        type: "MCPTransport", member: "sse",
        fields: ["url": url.constructionValue, "headers": headers.constructionValue]))
  }
}
extension MCPTransport: ConstructionRepresentable {}

public struct PromptParameter: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func parameter(name: String, description: String, defaultValue: String? = nil)
    -> PromptParameter
  {
    Self(
      value: ConstructionValue.construct(
        type: "PromptParameter", member: "parameter",
        fields: [
          "name": name.constructionValue, "description": description.constructionValue,
          "defaultValue": defaultValue.constructionValue,
        ]))
  }
}
extension PromptParameter: ConstructionRepresentable {}

public struct PermissionRule: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func allow(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule {
    Self(
      value: ConstructionValue.construct(
        type: "PermissionRule", member: "allow",
        fields: ["operation": operation.constructionValue, "pattern": pattern.constructionValue]))
  }
  public static func ask(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule {
    Self(
      value: ConstructionValue.construct(
        type: "PermissionRule", member: "ask",
        fields: ["operation": operation.constructionValue, "pattern": pattern.constructionValue]))
  }
  public static func deny(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule {
    Self(
      value: ConstructionValue.construct(
        type: "PermissionRule", member: "deny",
        fields: ["operation": operation.constructionValue, "pattern": pattern.constructionValue]))
  }
}
extension PermissionRule: ConstructionRepresentable {}

public struct Component: Sendable, Equatable {
  private let storage: ConstructionValue
  package var constructionValue: ConstructionValue { storage }
  package init(value: ConstructionValue) { storage = value }
  public static func skills(
    source: String, select: SkillSelection = .all, exclude: [String] = [], mode: InstallMode? = nil,
    overrides: [SkillOverride] = [], agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "skills",
        fields: [
          "source": source.constructionValue, "select": select.constructionValue,
          "exclude": exclude.constructionValue, "mode": mode.constructionValue,
          "overrides": overrides.constructionValue, "agents": agents.constructionValue,
          "condition": condition.constructionValue, "native": native.constructionValue,
        ]))
  }
  public static func instructions(
    sections: [SectionReference] = [], chatGPT: [ChatGPTPrompt] = [], agents: [Agent]? = nil,
    condition: Condition? = nil, native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "instructions",
        fields: [
          "sections": sections.constructionValue, "chatGPT": chatGPT.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
  public static func mcpServer(
    name: String, transport: MCPTransport, agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "mcpServer",
        fields: [
          "name": name.constructionValue, "transport": transport.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
  public static func hook(
    name: String, event: HookEvent, run: ExecutableInvocation, matcher: String? = nil,
    timeoutSeconds: Int? = nil, agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "hook",
        fields: [
          "name": name.constructionValue, "event": event.constructionValue,
          "run": run.constructionValue, "matcher": matcher.constructionValue,
          "timeoutSeconds": timeoutSeconds.constructionValue, "agents": agents.constructionValue,
          "condition": condition.constructionValue, "native": native.constructionValue,
        ]))
  }
  public static func subagent(
    name: String, description: String, prompt: PromptContent, model: String? = nil,
    tools: [String]? = nil, agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "subagent",
        fields: [
          "name": name.constructionValue, "description": description.constructionValue,
          "prompt": prompt.constructionValue, "model": model.constructionValue,
          "tools": tools.constructionValue, "agents": agents.constructionValue,
          "condition": condition.constructionValue, "native": native.constructionValue,
        ]))
  }
  public static func command(
    name: String, description: String, prompt: PromptContent, parameters: [PromptParameter] = [],
    agents: [Agent]? = nil, condition: Condition? = nil, native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "command",
        fields: [
          "name": name.constructionValue, "description": description.constructionValue,
          "prompt": prompt.constructionValue, "parameters": parameters.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
  public static func lspServer(
    name: String, run: ExecutableInvocation, languages: [String: String],
    initializationOptions: [String: ConfigurationValue] = [:], agents: [Agent]? = nil,
    condition: Condition? = nil, native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "lspServer",
        fields: [
          "name": name.constructionValue, "run": run.constructionValue,
          "languages": languages.constructionValue,
          "initializationOptions": initializationOptions.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
  public static func permissions(
    name: String, rules: [PermissionRule], agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "permissions",
        fields: [
          "name": name.constructionValue, "rules": rules.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
  public static func ignore(
    name: String, patterns: [String], purpose: IgnorePurpose = .context, agents: [Agent]? = nil,
    condition: Condition? = nil, native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "ignore",
        fields: [
          "name": name.constructionValue, "patterns": patterns.constructionValue,
          "purpose": purpose.constructionValue, "agents": agents.constructionValue,
          "condition": condition.constructionValue, "native": native.constructionValue,
        ]))
  }
  public static func plugin(
    name: String, path: String, source: String, mode: PluginMode = .components,
    select: [ComponentKind]? = nil, exclude: [ComponentReference] = [], agents: [Agent]? = nil,
    condition: Condition? = nil, native: NativeConfiguration = [:]
  ) -> Component {
    Self(
      value: ConstructionValue.construct(
        type: "Component", member: "plugin",
        fields: [
          "name": name.constructionValue, "path": path.constructionValue,
          "source": source.constructionValue, "mode": mode.constructionValue,
          "select": select.constructionValue, "exclude": exclude.constructionValue,
          "agents": agents.constructionValue, "condition": condition.constructionValue,
          "native": native.constructionValue,
        ]))
  }
}
extension Component: ConstructionRepresentable {}

public typealias NativeConfiguration = [String: [String: ConfigurationValue]]
