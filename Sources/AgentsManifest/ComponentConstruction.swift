import AgentsCore
import AgentsDescription

extension DeclarationConstruction {
  static func condition(_ condition: DeclarationCondition?) -> Condition? {
    condition.map {
      .when(
        agents: $0.agents.map { $0.map(agent) },
        scopes: $0.scopes.map { $0.map { $0 == .project ? .project : .user } },
        platforms: $0.platforms.map { $0.map { $0 == .macOS ? .macOS : .linux } })
    }
  }

  static func nativeValue(_ value: NativeValue) -> ConfigurationValue {
    switch value {
    case .string(let v): .string(v)
    case .integer(let v): .integer(v)
    case .decimal(let v): .decimal(v)
    case .boolean(let v): .boolean(v)
    case .null: .null
    case .array(let v): .array(v.map(nativeValue))
    case .object(let v): .object(v.mapValues(nativeValue))
    }
  }

  static func native(_ native: AgentsCore.NativeConfiguration)
    -> AgentsDescription.NativeConfiguration
  { native.mapValues { $0.mapValues(nativeValue) } }

  static func binding(_ value: RuntimeBinding) -> RuntimeValue {
    switch value {
    case .literal(let v): .literal(v)
    case .environment(let v): .environment(v)
    case .secret(let v): .secret(v)
    }
  }
  static func resource(_ value: ResourceDeclaration) -> Resource {
    .path(value.path, source: value.source)
  }
  static func promptBody(_ value: PromptBody) -> PromptContent {
    switch value {
    case .literal(let v): PromptContent(stringLiteral: v)
    case .file(let v): .file(v.path, source: v.source)
    }
  }
  static func executable(_ value: ExecutableDeclaration) -> ExecutableInvocation {
    .executable(
      value.executable, arguments: value.arguments,
      environment: value.environment.mapValues(binding),
      workingDirectory: value.workingDirectory.map(resource))
  }
  static func transport(_ value: MCPTransportDeclaration) -> MCPTransport {
    switch value {
    case .stdio(let v):
      .stdio(
        v.executable, arguments: v.arguments, environment: v.environment.mapValues(binding),
        workingDirectory: v.workingDirectory.map(resource))
    case .streamableHTTP(let url, let headers):
      .streamableHTTP(url: url, headers: headers.mapValues(binding))
    case .sse(let url, let headers): .sse(url: url, headers: headers.mapValues(binding))
    }
  }
  static func event(_ value: HookEventDeclaration) -> HookEvent {
    switch value {
    case .beforeTool: .beforeTool
    case .afterTool: .afterTool
    case .sessionStart: .sessionStart
    case .sessionEnd: .sessionEnd
    case .native(let v): .native(v)
    }
  }
  static func operation(_ value: PermissionOperationDeclaration) -> PermissionOperation {
    switch value {
    case .read: .read
    case .write: .write
    case .execute: .execute
    case .tool(let v): .tool(v)
    }
  }
  static func rule(_ value: PermissionRuleDeclaration) -> PermissionRule {
    switch value {
    case .allow(let op, let pattern): .allow(operation(op), pattern)
    case .ask(let op, let pattern): .ask(operation(op), pattern)
    case .deny(let op, let pattern): .deny(operation(op), pattern)
    }
  }
  static func reference(_ value: ComponentReferenceDeclaration) -> ComponentReference {
    switch value {
    case .skill(let n): .skill(name: n)
    case .instruction(let n): .instruction(name: n)
    case .mcpServer(let n): .mcpServer(name: n)
    case .hook(let n): .hook(name: n)
    case .subagent(let n): .subagent(name: n)
    case .command(let n): .command(name: n)
    case .lspServer(let n): .lspServer(name: n)
    case .permissions(let n): .permissions(name: n)
    case .ignore(let n): .ignore(name: n)
    case .plugin(let n): .plugin(name: n)
    }
  }
  static func kind(_ value: DeclaredComponentKind) -> AgentsDescription.ComponentKind {
    switch value {
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
  static func use(_ value: GroupUseDeclaration) -> GroupReference {
    if let source = value.source {
      return .group(name: value.name, source: source, condition: condition(value.condition))
    }
    return .group(name: value.name, condition: condition(value.condition))
  }
  static func group(_ value: ComponentGroupDeclaration) -> ComponentGroup {
    .group(
      name: value.name, components: value.components.map(component), uses: value.uses.map(use),
      condition: condition(value.condition))
  }
  static func component(_ value: ComponentDeclaration) -> Component {
    switch value {
    case .skills(let source, let v): return skills(alias: source, v)
    case .instructions(let v): return instructions(v)
    case .mcpServer(let name, let v, let agents, let when, let config):
      return .mcpServer(
        name: name, transport: transport(v), agents: agents.map { $0.map(agent) },
        condition: condition(when), native: native(config))
    case .hook(let name, let e, let run, let matcher, let timeout, let agents, let when, let config):
      return .hook(
        name: name, event: event(e), run: executable(run), matcher: matcher,
        timeoutSeconds: timeout, agents: agents.map { $0.map(agent) }, condition: condition(when),
        native: native(config))
    case .subagent(
      let name, let description, let prompt, let model, let tools, let agents, let when, let config):
      return .subagent(
        name: name, description: description, prompt: promptBody(prompt), model: model,
        tools: tools, agents: agents.map { $0.map(agent) }, condition: condition(when),
        native: native(config))
    case .command(
      let name, let description, let prompt, let parameters, let agents, let when, let config):
      return .command(
        name: name, description: description, prompt: promptBody(prompt),
        parameters: parameters.map {
          .parameter(name: $0.name, description: $0.description, defaultValue: $0.defaultValue)
        }, agents: agents.map { $0.map(agent) }, condition: condition(when), native: native(config))
    case .lspServer(let name, let run, let languages, let options, let agents, let when, let config):
      return .lspServer(
        name: name, run: executable(run), languages: languages,
        initializationOptions: options.mapValues(nativeValue), agents: agents.map { $0.map(agent) },
        condition: condition(when), native: native(config))
    case .permissions(let name, let rules, let agents, let when, let config):
      return .permissions(
        name: name, rules: rules.map(rule), agents: agents.map { $0.map(agent) },
        condition: condition(when), native: native(config))
    case .ignore(let name, let patterns, let purpose, let agents, let when, let config):
      return .ignore(
        name: name, patterns: patterns, purpose: purpose == .context ? .context : .indexing,
        agents: agents.map { $0.map(agent) }, condition: condition(when), native: native(config))
    case .plugin(
      let name, let path, let source, let mode, let select, let exclude, let agents, let when,
      let config):
      return .plugin(
        name: name, path: path, source: source, mode: mode == .native ? .native : .components,
        select: select.map { $0.map(kind) }, exclude: exclude.map(reference),
        agents: agents.map { $0.map(agent) }, condition: condition(when), native: native(config))
    }
  }
}
