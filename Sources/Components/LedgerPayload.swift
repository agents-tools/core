import AgentsCore

/// Converts typed symbolic payloads to the ledger's explicit tagged vocabulary.
package enum LedgerPayload {
  package static func component(_ component: ComponentDeclaration) throws -> LedgerValue {
    var fields: [String: LedgerValue]
    let agents: [AgentID]?
    let condition: DeclarationCondition?
    let native: NativeConfiguration
    switch component {
    case .mcpServer(let name, let transport, let a, let c, let n, _):
      fields = ["name": .init(name), "transport": self.transport(transport)]
      (agents, condition, native) = (a, c, n)
    case .hook(let name, let event, let run, let matcher, let timeout, let a, let c, let n):
      let eventValue: LedgerValue
      switch event {
      case .beforeTool: eventValue = .init("beforeTool")
      case .afterTool: eventValue = .init("afterTool")
      case .sessionStart: eventValue = .init("sessionStart")
      case .sessionEnd: eventValue = .init("sessionEnd")
      case .native(let value): eventValue = .init(object: ["native": .init(value)])
      }
      fields = ["name": .init(name), "event": eventValue, "run": executable(run)]
      fields["matcher"] = matcher.map { .init($0) }
      fields["timeoutSeconds"] = timeout.map { .init(integer: $0) }
      (agents, condition, native) = (a, c, n)
    case .subagent(let name, let description, let body, let model, let tools, let a, let c, let n):
      fields = ["name": .init(name), "description": .init(description), "prompt": prompt(body)]
      fields["model"] = model.map { .init($0) }
      fields["tools"] = tools.map(strings)
      (agents, condition, native) = (a, c, n)
    case .command(let name, let description, let body, let parameters, let a, let c, let n):
      fields = [
        "name": .init(name), "description": .init(description), "prompt": prompt(body),
        "parameters": .init(
          array: parameters.map { parameter in
            var value = [
              "name": LedgerValue(parameter.name), "description": .init(parameter.description),
            ]
            value["defaultValue"] = parameter.defaultValue.map { .init($0) }
            return .init(object: value)
          }),
      ]
      (agents, condition, native) = (a, c, n)
    case .lspServer(let name, let run, let languages, let options, let a, let c, let n):
      fields = [
        "name": .init(name), "run": executable(run),
        "languages": .init(object: languages.mapValues { .init($0) }),
        "initializationOptions": .init(object: options.mapValues(value)),
      ]
      (agents, condition, native) = (a, c, n)
    case .permissions(let name, let rules, let a, let c, let n):
      fields = ["name": .init(name), "rules": .init(array: rules.map(rule))]
      (agents, condition, native) = (a, c, n)
    case .ignore(let name, let patterns, let purpose, let a, let c, let n):
      fields = [
        "name": .init(name), "patterns": strings(patterns), "purpose": .init(purpose.rawValue),
      ]
      (agents, condition, native) = (a, c, n)
    case .plugin(
      let name, let path, let source, let mode, let select, let exclude, let a, let c, let n):
      fields = [
        "name": .init(name), "path": .init(path), "source": .init(source),
        "mode": .init(mode.rawValue),
        "exclude": .init(array: exclude.map(reference)),
      ]
      fields["select"] = select.map { strings($0.map(\.rawValue)) }
      (agents, condition, native) = (a, c, n)
    case .skills, .instructions:
      throw CoreError.invalidState("selected content requires its frozen payload")
    }
    fields["agents"] = agents.map { strings($0.map(\.rawValue)) }
    fields["condition"] = condition.map(self.condition)
    fields["native"] = self.native(native)
    return .init(object: fields)
  }

  static func native(_ native: NativeConfiguration) -> LedgerValue {
    .init(object: native.mapValues { .init(object: $0.mapValues(value)) })
  }

  static func condition(_ condition: DeclarationCondition) -> LedgerValue {
    var fields: [String: LedgerValue] = [:]
    fields["agents"] = condition.agents.map { strings($0.map(\.rawValue)) }
    fields["scopes"] = condition.scopes.map { strings($0.map(\.rawValue)) }
    fields["platforms"] = condition.platforms.map { strings($0.map(\.rawValue)) }
    return .init(object: fields)
  }

  static func strings(_ values: [String]) -> LedgerValue { .init(array: values.map { .init($0) }) }

  private static func value(_ value: NativeValue) -> LedgerValue {
    switch value {
    case .string(let text): .init(text)
    case .integer(let integer): .init(integer: integer)
    case .decimal(let decimal): .init(decimal, kind: .decimal)
    case .boolean(let boolean): .init(boolean: boolean)
    case .null: .init()
    case .array(let array): .init(array: array.map(self.value))
    case .object(let object): .init(object: object.mapValues(self.value))
    }
  }

  private static func binding(_ binding: RuntimeBinding) -> LedgerValue {
    switch binding {
    case .literal(let value): .init(value, kind: .literal)
    case .environment(let value): .init(value, kind: .environment)
    case .secret(let value): .init(value, kind: .secret)
    }
  }

  private static func resource(_ resource: ResourceDeclaration) -> LedgerValue {
    var fields = ["path": LedgerValue(resource.path)]
    fields["source"] = resource.source.map { .init($0) }
    return .init(object: fields)
  }

  private static func executable(_ run: ExecutableDeclaration) -> LedgerValue {
    var fields: [String: LedgerValue] = [
      "executable": .init(run.executable), "arguments": strings(run.arguments),
      "environment": .init(object: run.environment.mapValues(binding)),
    ]
    fields["executableSource"] = run.executableSource.map { .init($0) }
    fields["workingDirectory"] = run.workingDirectory.map(resource)
    return .init(object: fields)
  }

  private static func transport(_ transport: MCPTransportDeclaration) -> LedgerValue {
    switch transport {
    case .stdio(let run): return .init(object: ["kind": .init("stdio"), "run": executable(run)])
    case .streamableHTTP(let url, let headers):
      return .init(object: [
        "kind": .init("streamableHTTP"), "url": .init(url),
        "headers": .init(object: headers.mapValues(binding)),
      ])
    case .sse(let url, let headers):
      return .init(object: [
        "kind": .init("sse"), "url": .init(url),
        "headers": .init(object: headers.mapValues(binding)),
      ])
    }
  }

  private static func prompt(_ prompt: PromptBody) -> LedgerValue {
    switch prompt {
    case .literal(let text): .init(text, kind: .literal)
    case .file(let file): .init(object: ["file": resource(file)])
    }
  }

  private static func rule(_ rule: PermissionRuleDeclaration) -> LedgerValue {
    let action: String
    let operation: PermissionOperationDeclaration
    let pattern: String
    switch rule {
    case .allow(let op, let p): (action, operation, pattern) = ("allow", op, p)
    case .ask(let op, let p): (action, operation, pattern) = ("ask", op, p)
    case .deny(let op, let p): (action, operation, pattern) = ("deny", op, p)
    }
    let op: LedgerValue
    switch operation {
    case .read: op = .init("read")
    case .write: op = .init("write")
    case .execute: op = .init("execute")
    case .tool(let name): op = .init(object: ["tool": .init(name)])
    }
    return .init(object: ["action": .init(action), "operation": op, "pattern": .init(pattern)])
  }

  static func reference(_ reference: ComponentReferenceDeclaration) -> LedgerValue {
    let kind: String
    let name: String
    switch reference {
    case .skill(let value): (kind, name) = ("skills", value)
    case .instruction(let value): (kind, name) = ("instructions", value)
    case .mcpServer(let value): (kind, name) = ("mcpServer", value)
    case .hook(let value): (kind, name) = ("hook", value)
    case .subagent(let value): (kind, name) = ("subagent", value)
    case .command(let value): (kind, name) = ("command", value)
    case .lspServer(let value): (kind, name) = ("lspServer", value)
    case .permissions(let value): (kind, name) = ("permissions", value)
    case .ignore(let value): (kind, name) = ("ignore", value)
    case .plugin(let value): (kind, name) = ("plugin", value)
    }
    return .init(object: ["kind": .init(kind), "name": .init(name)])
  }
}
