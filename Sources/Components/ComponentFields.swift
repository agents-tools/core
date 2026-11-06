import AgentsCore

extension ComponentDeclaration {
  var name: String? {
    switch self {
    case .skills, .instructions: nil
    case .mcpServer(let name, _, _, _, _), .hook(let name, _, _, _, _, _, _, _),
      .subagent(let name, _, _, _, _, _, _, _), .command(let name, _, _, _, _, _, _),
      .lspServer(let name, _, _, _, _, _, _), .permissions(let name, _, _, _, _),
      .ignore(let name, _, _, _, _, _), .plugin(let name, _, _, _, _, _, _, _, _):
      name
    }
  }

  var agents: [AgentID]? {
    switch self {
    case .skills(_, let value): value.agents
    case .instructions(let value): value.agents
    case .mcpServer(_, _, let agents, _, _), .hook(_, _, _, _, _, let agents, _, _),
      .subagent(_, _, _, _, _, let agents, _, _), .command(_, _, _, _, let agents, _, _),
      .lspServer(_, _, _, _, let agents, _, _), .permissions(_, _, let agents, _, _),
      .ignore(_, _, _, let agents, _, _), .plugin(_, _, _, _, _, _, let agents, _, _):
      agents
    }
  }

  var condition: DeclarationCondition? {
    switch self {
    case .skills(_, let value): value.condition
    case .instructions(let value): value.condition
    case .mcpServer(_, _, _, let condition, _), .hook(_, _, _, _, _, _, let condition, _),
      .subagent(_, _, _, _, _, _, let condition, _), .command(_, _, _, _, _, let condition, _),
      .lspServer(_, _, _, _, _, let condition, _), .permissions(_, _, _, let condition, _),
      .ignore(_, _, _, _, let condition, _), .plugin(_, _, _, _, _, _, _, let condition, _):
      condition
    }
  }

  var resources: [ResourceDeclaration] {
    func run(_ value: ExecutableDeclaration) -> [ResourceDeclaration] {
      let executable =
        value.executable.contains("/") ? [ResourceDeclaration(path: value.executable)] : []
      return executable + (value.workingDirectory.map { [$0] } ?? [])
    }
    func prompt(_ value: PromptBody) -> [ResourceDeclaration] {
      if case .file(let resource) = value { return [resource] }
      return []
    }
    switch self {
    case .mcpServer(_, .stdio(let value), _, _, _): return run(value)
    case .hook(_, _, let value, _, _, _, _, _), .lspServer(_, let value, _, _, _, _, _):
      return run(value)
    case .subagent(_, _, let value, _, _, _, _, _), .command(_, _, let value, _, _, _, _):
      return prompt(value)
    case .plugin(_, let path, let source, _, _, _, _, _, _):
      return [ResourceDeclaration(path: path, source: source)]
    default: return []
    }
  }

  /// Content comparison uses resolved resource evidence and effective targets separately.
  var comparisonPayload: ComponentDeclaration {
    func run(_ value: ExecutableDeclaration) -> ExecutableDeclaration {
      var result = value
      if let path = value.workingDirectory {
        result.workingDirectory = ResourceDeclaration(path: path.path)
      }
      return result
    }
    func body(_ value: PromptBody) -> PromptBody {
      if case .file(let path) = value { return .file(ResourceDeclaration(path: path.path)) }
      return value
    }
    switch self {
    case .mcpServer(let name, let transport, _, _, let native):
      let resolved: MCPTransportDeclaration
      if case .stdio(let value) = transport {
        resolved = .stdio(run(value))
      } else {
        resolved = transport
      }
      return .mcpServer(name: name, transport: resolved, native: native)
    case .hook(let name, let event, let invocation, let matcher, let timeout, _, _, let native):
      return .hook(
        name: name, event: event, run: run(invocation), matcher: matcher, timeoutSeconds: timeout,
        native: native)
    case .subagent(let name, let description, let prompt, let model, let tools, _, _, let native):
      return .subagent(
        name: name, description: description, prompt: body(prompt), model: model, tools: tools,
        native: native)
    case .command(let name, let description, let prompt, let parameters, _, _, let native):
      return .command(
        name: name, description: description, prompt: body(prompt), parameters: parameters,
        native: native
      )
    case .lspServer(let name, let invocation, let languages, let options, _, _, let native):
      return .lspServer(
        name: name, run: run(invocation), languages: languages, initializationOptions: options,
        native: native)
    case .permissions(let name, let rules, _, _, let native):
      return .permissions(name: name, rules: rules, native: native)
    case .ignore(let name, let patterns, let purpose, _, _, let native):
      return .ignore(name: name, patterns: patterns, purpose: purpose, native: native)
    case .plugin(
      let name, let path, _, let mode, let select, let exclude, _, _, let native):
      return .plugin(
        name: name, path: path, source: ".", mode: mode, select: select, exclude: exclude,
        native: native)
    case .skills, .instructions: return self
    }
  }
}
