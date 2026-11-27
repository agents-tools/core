import AgentsCore

/// Complete domain-to-IR construction. Optional recipients and condition dimensions retain
/// their presence; only dictionary-backed convenience inputs use canonical key ordering.
enum YAMLConstruction {
  static func root(_ value: Declaration) -> DeclarationIR {
    DeclarationIR(
      defaultAgents: value.agents.map { $0.map(\.rawValue) }, exports: value.exports,
      sources: value.sourceDeclarations.map(source), components: value.components.map(component),
      groups: value.groups.map(group), uses: value.uses.map(use), watch: value.watch ?? [],
      packages: value.packages.map(packageRecord) + value.marketplaceRoots.map(packageRecord),
      lifecycle: value.lifecycle)
  }
  static func record(_ kind: String, _ fields: [String: DeclarationValue]) -> DeclarationRecord {
    DeclarationRecord(kind: kind, fields: fields)
  }
  static func text(_ value: String?) -> DeclarationValue {
    value.map(DeclarationValue.string) ?? .null
  }
  static func strings(_ values: [String]) -> DeclarationValue {
    .array(values.map(DeclarationValue.string))
  }
  static func agents(_ values: [AgentID]?) -> DeclarationValue {
    values.map { strings($0.map(\.rawValue)) } ?? .null
  }
  static func condition(_ value: DeclarationCondition?) -> DeclarationValue {
    value.map {
      .record(
        record(
          "when",
          [
            "agents": agents($0.agents),
            "scopes": $0.scopes.map { strings($0.map(\.rawValue)) } ?? .null,
            "platforms": $0.platforms.map { strings($0.map(\.rawValue)) } ?? .null,
          ]))
    } ?? .null
  }
  static func source(_ value: NamedSourceDeclaration) -> DeclarationRecord {
    let source = value.source
    return record(
      source.kind == .git ? "git" : source.kind == .local ? "local" : "index",
      [
        "name": .string(value.name),
        source.kind == .git ? "url" : source.kind == .local ? "path" : "index": .string(
          source.kind == .git ? source.gitURL : source.location),
        "subpath": text(source.path),
        "requirement": source.requirement.map(DeclarationValue.requirement) ?? .null,
      ])
  }
  static func packageRecord(_ value: MarketplaceDependency) -> DeclarationRecord {
    record(
      "package",
      [
        "name": .string(value.name), "package": .string(value.coordinate.package),
        "version": .string(value.coordinate.version), "catalog": catalog(value.catalog),
      ])
  }
  static func packageRecord(_ value: MarketplaceRoot) -> DeclarationRecord {
    var fields: [String: DeclarationValue] = [
      "name": .string(value.name), "package": .string(value.package),
      "requirement": .requirement(value.requirement), "catalog": catalog(value.catalog),
    ]
    if !value.selections.isEmpty {
      fields["selections"] = .array(
        value.selections.map { selection in
          var fields: [String: DeclarationValue] = [
            "package": .string(selection.package),
            "member": .dictionary([
              "kind": .string(selection.member.kind.rawValue),
              "name": .string(selection.member.name),
            ]),
            "targets": strings(selection.targets.map(\.rawValue)),
          ]
          fields["catalog"] = selection.catalog.map(catalog)
          return .dictionary(fields)
        })
    }
    return record("package", fields)
  }
  private static func catalog(_ origin: MarketplaceOrigin) -> DeclarationValue {
    var fields: [String: DeclarationValue] = [
      "kind": .string(origin.kind.rawValue), "location": .string(origin.location),
    ]
    fields["ref"] = origin.ref.map(DeclarationValue.string)
    fields["subpath"] = origin.subpath.map(DeclarationValue.string)
    return .dictionary(fields)
  }
  static func use(_ value: GroupUseDeclaration) -> DeclarationRecord {
    record(
      value.source == nil ? "local" : "exported",
      [
        "name": .string(value.name), "source": text(value.source),
        "condition": condition(value.condition),
      ])
  }
  static func group(_ value: ComponentGroupDeclaration) -> DeclarationRecord {
    record(
      "group",
      [
        "name": .string(value.name),
        "components": .array(value.components.map { .record(component($0)) }),
        "uses": .array(value.uses.map { .record(use($0)) }),
        "condition": condition(value.condition),
      ])
  }
  static func section(_ value: SectionDeclaration) -> DeclarationRecord {
    record(
      "section",
      [
        "name": .string(value.name), "source": text(value.source),
        "condition": condition(value.condition),
        "recipients": value.recipients.map { .array($0.map { .string($0.rawValue) }) } ?? .null,
      ])
  }
  static func promptDeclaration(_ value: NamedPromptDeclaration) -> DeclarationRecord {
    record(
      "prompt",
      [
        "name": .string(value.name),
        "sections": .array(value.prompt.sectionReferences.map { .record(section($0)) }),
        "append": text(value.prompt.append), "condition": condition(value.prompt.condition),
      ])
  }
  static func override(_ value: NamedSkillOverrideDeclaration) -> DeclarationRecord {
    record(
      "skill",
      [
        "name": .string(value.name), "agents": agents(value.override.agents),
        "mode": text(value.override.mode?.rawValue),
      ])
  }
  static func nativeValue(_ value: NativeValue) -> DeclarationValue {
    let kind: String
    let payload: DeclarationValue?
    switch value {
    case .string(let value):
      kind = "string"
      payload = .string(value)
    case .integer(let value):
      kind = "integer"
      payload = .integer(value)
    case .decimal(let value):
      kind = "decimal"
      payload = .string(value)
    case .boolean(let value):
      kind = "boolean"
      payload = .boolean(value)
    case .null:
      kind = "null"
      payload = nil
    case .array(let value):
      kind = "array"
      payload = .array(value.map(nativeValue))
    case .object(let value):
      kind = "object"
      payload = .dictionary(value.mapValues(nativeValue))
    }
    return .record(record(kind, payload.map { ["value": $0] } ?? [:]))
  }
  static func native(_ value: NativeConfiguration) -> DeclarationValue {
    .dictionary(value.mapValues { .dictionary($0.mapValues(nativeValue)) })
  }
  static func binding(_ value: RuntimeBinding) -> DeclarationValue {
    let kind: String
    let text: String
    switch value {
    case .literal(let value):
      kind = "literal"
      text = value
    case .environment(let value):
      kind = "environment"
      text = value
    case .secret(let value):
      kind = "secret"
      text = value
    }
    return .record(record(kind, ["value": .string(text)]))
  }
  static func resource(_ value: ResourceDeclaration) -> DeclarationRecord {
    record("path", ["path": .string(value.path), "source": text(value.source)])
  }
  static func prompt(_ value: PromptBody) -> DeclarationValue {
    switch value {
    case .literal(let value): return .record(record("literal", ["value": .string(value)]))
    case .file(let value): return .record(record("file", resource(value).fields))
    }
  }
  static func run(_ value: ExecutableDeclaration, kind: String = "executable") -> DeclarationRecord
  {
    record(
      kind,
      [
        "executable": .string(value.executable), "executableSource": text(value.executableSource),
        "arguments": strings(value.arguments),
        "environment": .dictionary(value.environment.mapValues(binding)),
        "workingDirectory": value.workingDirectory.map { .record(resource($0)) } ?? .null,
      ])
  }
  static func transport(_ value: MCPTransportDeclaration) -> DeclarationValue {
    switch value {
    case .stdio(let value): return .record(run(value, kind: "stdio"))
    case .streamableHTTP(let url, let headers):
      return .record(
        record(
          "streamableHTTP",
          ["url": .string(url), "headers": .dictionary(headers.mapValues(binding))]))
    case .sse(let url, let headers):
      return .record(
        record("sse", ["url": .string(url), "headers": .dictionary(headers.mapValues(binding))]))
    }
  }
  static func event(_ value: HookEventDeclaration) -> DeclarationValue {
    let kind: String
    switch value {
    case .beforeTool: kind = "beforeTool"
    case .afterTool: kind = "afterTool"
    case .sessionStart: kind = "sessionStart"
    case .sessionEnd: kind = "sessionEnd"
    case .native(let value): return .record(record("native", ["value": .string(value)]))
    }
    return .record(record(kind, [:]))
  }
  static func operation(_ value: PermissionOperationDeclaration) -> DeclarationValue {
    let kind: String
    switch value {
    case .read: kind = "read"
    case .write: kind = "write"
    case .execute: kind = "execute"
    case .tool(let value): return .record(record("tool", ["value": .string(value)]))
    }
    return .record(record(kind, [:]))
  }
  static func rule(_ value: PermissionRuleDeclaration) -> DeclarationValue {
    switch value {
    case .allow(let op, let pattern):
      return .record(record("allow", ["operation": operation(op), "pattern": .string(pattern)]))
    case .ask(let op, let pattern):
      return .record(record("ask", ["operation": operation(op), "pattern": .string(pattern)]))
    case .deny(let op, let pattern):
      return .record(record("deny", ["operation": operation(op), "pattern": .string(pattern)]))
    }
  }
  static func reference(_ value: ComponentReferenceDeclaration) -> DeclarationValue {
    let kind: String
    let name: String
    switch value {
    case .skill(let value):
      kind = "skill"
      name = value
    case .instruction(let value):
      kind = "instruction"
      name = value
    case .mcpServer(let value):
      kind = "mcpServer"
      name = value
    case .hook(let value):
      kind = "hook"
      name = value
    case .subagent(let value):
      kind = "subagent"
      name = value
    case .command(let value):
      kind = "command"
      name = value
    case .lspServer(let value):
      kind = "lspServer"
      name = value
    case .permissions(let value):
      kind = "permissions"
      name = value
    case .ignore(let value):
      kind = "ignore"
      name = value
    case .plugin(let value):
      kind = "plugin"
      name = value
    }
    return .record(record(kind, ["name": .string(name)]))
  }
  static func component(_ value: ComponentDeclaration) -> DeclarationRecord {
    let kind: String
    var fields: [String: DeclarationValue]
    let recipients: [AgentID]?
    let when: DeclarationCondition?
    let config: NativeConfiguration
    switch value {
    case .skills(let source, let value):
      kind = "skills"
      recipients = value.agents
      when = value.condition
      config = value.native
      let selection: DeclarationValue
      switch value.select {
      case .all: selection = .string("all")
      case .names(let values): selection = strings(values)
      }
      fields = [
        "source": .string(source), "path": text(value.path), "select": selection,
        "exclude": strings(value.exclude ?? []),
        "mode": text(value.mode?.rawValue),
        "overrides": .array(value.overrideDeclarations.map { .record(override($0)) }),
      ]
    case .instructions(let value):
      kind = "instructions"
      recipients = value.agents
      when = value.condition
      config = value.native
      fields = [
        "sections": .array(value.sectionReferences.map { .record(section($0)) }),
        "chatGPT": .array(value.prompts.map { .record(promptDeclaration($0)) }),
      ]
    case .mcpServer(let name, let value, let a, let c, let n, let registry):
      kind = "mcpServer"
      recipients = a
      when = c
      config = n
      fields = ["name": .string(name), "transport": transport(value)]
      if let registry {
        var evidence: [String: DeclarationValue] = [
          "registry": .string(registry.registry), "server": .string(registry.server),
          "version": .string(registry.version), "origin": .string(registry.origin),
        ]
        evidence["package"] = registry.package.map(DeclarationValue.string)
        evidence["invocationDigest"] = registry.invocationDigest.map(DeclarationValue.string)
        evidence["portableBindings"] = registry.portableBindings.map {
          .dictionary($0.mapValues(DeclarationValue.string))
        }
        fields["registry"] = .record(record("mcpRegistry", evidence))
      }
    case .hook(let name, let e, let r, let matcher, let timeout, let a, let c, let n):
      kind = "hook"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "event": event(e), "run": .record(run(r)), "matcher": text(matcher),
        "timeoutSeconds": timeout.map(DeclarationValue.integer) ?? .null,
      ]
    case .subagent(let name, let description, let p, let model, let tools, let a, let c, let n):
      kind = "subagent"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "description": .string(description), "prompt": prompt(p),
        "model": text(model), "tools": tools.map(strings) ?? .null,
      ]
    case .command(let name, let description, let p, let parameters, let a, let c, let n):
      kind = "command"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "description": .string(description), "prompt": prompt(p),
        "parameters": .array(
          parameters.map {
            .record(
              record(
                "parameter",
                [
                  "name": .string($0.name), "description": .string($0.description),
                  "defaultValue": text($0.defaultValue),
                ]))
          }),
      ]
    case .lspServer(let name, let r, let languages, let options, let a, let c, let n):
      kind = "lspServer"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "run": .record(run(r)),
        "languages": .dictionary(languages.mapValues(DeclarationValue.string)),
        "initializationOptions": .dictionary(options.mapValues(nativeValue)),
      ]
    case .permissions(let name, let rules, let a, let c, let n):
      kind = "permissions"
      recipients = a
      when = c
      config = n
      fields = ["name": .string(name), "rules": .array(rules.map(rule))]
    case .ignore(let name, let patterns, let purpose, let a, let c, let n):
      kind = "ignore"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "patterns": strings(patterns), "purpose": .string(purpose.rawValue),
      ]
    case .plugin(
      let name, let path, let source, let mode, let select, let exclude, let a, let c, let n):
      kind = "plugin"
      recipients = a
      when = c
      config = n
      fields = [
        "name": .string(name), "path": .string(path), "source": .string(source),
        "mode": .string(mode.rawValue),
        "select": select.map { strings($0.map(\.rawValue)) } ?? .null,
        "exclude": .array(exclude.map(reference)),
      ]
    }
    fields["agents"] = agents(recipients)
    fields["condition"] = condition(when)
    fields["native"] = native(config)
    return record(kind, fields)
  }
}
