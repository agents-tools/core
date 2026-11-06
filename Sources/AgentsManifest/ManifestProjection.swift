import AgentsCore

/// Static projection of the complete declaration. References and runtime bindings remain data;
/// this layer does not resolve sources, read resources or execute declared programs.
package enum ManifestProjection {
  package static func declaration(of document: DeclarationDocument, environment: RuntimeEnvironment)
    throws -> Declaration
  {
    let result = try draftDeclaration(of: document, environment: environment)
    try result.validate(environment: environment)
    return result
  }

  /// Converts statically typed values without domain validation for private edit composition.
  static func draftDeclaration(of document: DeclarationDocument, environment: RuntimeEnvironment)
    throws -> Declaration
  {
    let projection = Projection(document: document)
    let ir = document.declaration
    let sources = ir.sources.map { record in
      let kind: SourceKind =
        record.kind == "git" ? .git : record.kind == "local" ? .local : .wellKnown
      let location = record[kind == .git ? "url" : kind == .local ? "path" : "index"]!.string!
      var requirement: SourceRequirement?
      if case .requirement(let value) = record["requirement"] { requirement = value }
      return NamedSourceDeclaration(
        name: record["name"]!.string!,
        source: SourceDeclaration(
          kind: kind, location: location, requirement: requirement, path: record["subpath"]?.string,
          environment: SourceEnvironment(
            projectDirectory: environment.projectDirectory, homeDirectory: environment.homeDirectory
          )))
    }
    let result = Declaration(
      agents: ir.defaultAgents?.map { AgentID(rawValue: $0)! },
      sourceDeclarations: sources,
      components: try ir.components.map(projection.component),
      groups: try ir.groups.map { record in
        ComponentGroupDeclaration(
          name: record["name"]!.string!,
          components: try projection.records(record["components"]).map(projection.component),
          uses: try projection.records(record["uses"]).map(projection.use),
          condition: projection.condition(record["condition"]))
      }, uses: ir.uses.map(projection.use), exports: ir.exports,
      watch: ir.watch.isEmpty ? nil : ir.watch)
    return result
  }

  /// Source spelling is compared using its declaring directories. All ordered structures and
  /// every component field participate; absent recipients remain distinct from explicit empty.
  package static func equivalent(
    _ lhs: Declaration, _ rhs: Declaration, environment: RuntimeEnvironment
  ) -> Bool {
    guard sameRecipients(lhs.agents, rhs.agents), lhs.exports == rhs.exports,
      lhs.groups == rhs.groups, lhs.uses == rhs.uses, Set(lhs.watch ?? []) == Set(rhs.watch ?? []),
      lhs.sourceDeclarations.map(\.name) == rhs.sourceDeclarations.map(\.name),
      zip(lhs.sourceDeclarations, rhs.sourceDeclarations).allSatisfy({
        equivalent($0.source, $1.source, environment: environment)
      }),
      lhs.components.count == rhs.components.count
    else { return false }
    return zip(lhs.components, rhs.components).allSatisfy { left, right in
      switch (left, right) {
      case (.skills(let a, let x), .skills(let b, let y)): return a == b && equivalent(x, y)
      case (.instructions(let x), .instructions(let y)): return equivalent(x, y)
      default: return left == right
      }
    }
  }

  static func equivalent(
    _ lhs: SourceDeclaration, _ rhs: SourceDeclaration, environment: RuntimeEnvironment
  ) -> Bool {
    func identity(_ source: SourceDeclaration) -> String {
      (try? source.identity(environment: environment)) ?? source.location
    }
    func subpath(_ source: SourceDeclaration) -> String {
      source.path.map { (try? PathSafety.sanitizeSubpath($0)) ?? $0 } ?? "."
    }
    let requirements: Bool
    switch (lhs.requirement, rhs.requirement) {
    case (nil, nil): requirements = true
    case (let left?, let right?): requirements = left.declarationEquivalent(to: right)
    default: requirements = false
    }
    return lhs.kind == rhs.kind && requirements && identity(lhs) == identity(rhs)
      && subpath(lhs) == subpath(rhs)
  }

  static func equivalent(_ lhs: SkillDeclaration, _ rhs: SkillDeclaration) -> Bool {
    let selections: Bool
    switch (lhs.select, rhs.select) {
    case (.all, .all): selections = true
    case (.names(let left), .names(let right)): selections = Set(left) == Set(right)
    default: selections = false
    }
    let leftNames = lhs.overrideDeclarations.map(\.name)
    let rightNames = rhs.overrideDeclarations.map(\.name)
    guard Set(leftNames).count == leftNames.count, Set(rightNames).count == rightNames.count else {
      return false
    }
    let left = Dictionary(
      uniqueKeysWithValues: lhs.overrideDeclarations.map { ($0.name, $0.override) })
    let right = Dictionary(
      uniqueKeysWithValues: rhs.overrideDeclarations.map { ($0.name, $0.override) })
    return selections && Set(lhs.exclude ?? []) == Set(rhs.exclude ?? []) && lhs.mode == rhs.mode
      && sameRecipients(lhs.agents, rhs.agents) && left.keys == right.keys
      && left.allSatisfy { equivalent($1, right[$0]!) }
      && lhs.condition == rhs.condition && lhs.native == rhs.native
  }

  static func equivalent(_ lhs: SkillOverride, _ rhs: SkillOverride) -> Bool {
    lhs.mode == rhs.mode && sameRecipients(lhs.agents, rhs.agents)
  }

  static func equivalent(_ lhs: InstructionsDeclaration, _ rhs: InstructionsDeclaration) -> Bool {
    sameRecipients(lhs.agents, rhs.agents) && lhs.sectionReferences == rhs.sectionReferences
      && lhs.prompts == rhs.prompts && lhs.condition == rhs.condition && lhs.native == rhs.native
  }

  static func sameRecipients(_ lhs: [AgentID]?, _ rhs: [AgentID]?) -> Bool {
    lhs.map(Set.init) == rhs.map(Set.init)
  }
}

/// Static evaluation checks vocabulary and field types before conversion, including in drafts.
private struct Projection {
  let document: DeclarationDocument

  func records(_ value: DeclarationValue?) -> [DeclarationRecord] {
    (value?.elements ?? []).map { $0.record! }
  }
  func strings(_ value: DeclarationValue?) -> [String] {
    (value?.elements ?? []).map { $0.string! }
  }
  func recipients(_ value: DeclarationValue?) -> [AgentID]? {
    value?.elements.map { $0.map { AgentID(rawValue: $0.string!)! } }
  }
  func dictionary(_ value: DeclarationValue?) -> [String: DeclarationValue] {
    if case .dictionary(let values) = value { return values }
    return [:]
  }
  func condition(_ value: DeclarationValue?) -> DeclarationCondition? {
    guard let r = value?.record else { return nil }
    return DeclarationCondition(
      agents: recipients(r["agents"]),
      scopes: r["scopes"]?.elements.map { $0.map { InstallScope(rawValue: $0.string!)! } },
      platforms: r["platforms"]?.elements.map {
        $0.map { DeclarationPlatform(rawValue: $0.string!)! }
      })
  }
  func use(_ r: DeclarationRecord) -> GroupUseDeclaration {
    GroupUseDeclaration(
      name: r["name"]!.string!, source: r["source"]?.string, condition: condition(r["condition"]))
  }
  func section(_ r: DeclarationRecord) -> SectionDeclaration {
    SectionDeclaration(
      name: r["name"]!.string!, source: r["source"]?.string, condition: condition(r["condition"]))
  }
  func resource(_ r: DeclarationRecord) -> ResourceDeclaration {
    ResourceDeclaration(path: r["path"]!.string!, source: r["source"]?.string)
  }
  func binding(_ value: DeclarationValue) -> RuntimeBinding {
    let r = value.record!
    let text = r["value"]!.string!
    switch r.kind {
    case "environment": return .environment(text)
    case "secret": return .secret(text)
    default: return .literal(text)
    }
  }
  func executable(_ r: DeclarationRecord) -> ExecutableDeclaration {
    ExecutableDeclaration(
      executable: r["executable"]!.string!, arguments: strings(r["arguments"]),
      environment: dictionary(r["environment"]).mapValues(binding),
      workingDirectory: r["workingDirectory"]?.record.map(resource))
  }
  func prompt(_ r: DeclarationRecord) -> PromptBody {
    r.kind == "literal" ? .literal(r["value"]!.string!) : .file(resource(r))
  }
  func nativeValue(_ value: DeclarationValue) -> NativeValue {
    let r = value.record!
    switch r.kind {
    case "string": return .string(r["value"]!.string!)
    case "integer": if case .integer(let v) = r["value"] { return .integer(v) }
    case "decimal": return .decimal(r["value"]!.string!)
    case "boolean": if case .boolean(let v) = r["value"] { return .boolean(v) }
    case "null": return .null
    case "array": return .array((r["value"]?.elements ?? []).map(nativeValue))
    case "object": return .object(dictionary(r["value"]).mapValues(nativeValue))
    default: break
    }
    preconditionFailure("statically typed configuration value")
  }
  func native(_ value: DeclarationValue?) -> AgentsCore.NativeConfiguration {
    dictionary(value).mapValues { dictionary($0).mapValues(nativeValue) }
  }
  func event(_ r: DeclarationRecord) -> HookEventDeclaration {
    switch r.kind {
    case "beforeTool": return .beforeTool
    case "afterTool": return .afterTool
    case "sessionStart": return .sessionStart
    case "sessionEnd": return .sessionEnd
    default: return .native(r["value"]!.string!)
    }
  }
  func operation(_ r: DeclarationRecord) -> PermissionOperationDeclaration {
    switch r.kind {
    case "read": return .read
    case "write": return .write
    case "execute": return .execute
    default: return .tool(r["value"]!.string!)
    }
  }
  func rule(_ r: DeclarationRecord) -> PermissionRuleDeclaration {
    let op = operation(r["operation"]!.record!)
    let pattern = r["pattern"]!.string!
    switch r.kind {
    case "allow": return .allow(op, pattern)
    case "ask": return .ask(op, pattern)
    default: return .deny(op, pattern)
    }
  }
  func reference(_ r: DeclarationRecord) -> ComponentReferenceDeclaration {
    let name = r["name"]!.string!
    switch r.kind {
    case "skill": return .skill(name: name)
    case "instruction": return .instruction(name: name)
    case "mcpServer": return .mcpServer(name: name)
    case "hook": return .hook(name: name)
    case "subagent": return .subagent(name: name)
    case "command": return .command(name: name)
    case "lspServer": return .lspServer(name: name)
    case "permissions": return .permissions(name: name)
    case "ignore": return .ignore(name: name)
    default: return .plugin(name: name)
    }
  }
  func component(_ r: DeclarationRecord) throws -> ComponentDeclaration {
    let agents = recipients(r["agents"])
    let condition = condition(r["condition"])
    let native = native(r["native"])
    let name = r["name"]?.string ?? ""
    switch r.kind {
    case "skills":
      let overrides = records(r["overrides"]).map { record in
        (
          record["name"]!.string!,
          SkillOverride(
            agents: recipients(record["agents"]),
            mode: record["mode"]?.string.flatMap(InstallMode.init(rawValue:)))
        )
      }
      var result = SkillDeclaration(
        select: r["select"]?.elements.map { .names($0.map { $0.string! }) } ?? .all,
        exclude: strings(r["exclude"]).isEmpty ? nil : strings(r["exclude"]), agents: agents,
        mode: r["mode"]?.string.flatMap(InstallMode.init(rawValue:)),
        overrides: nil, condition: condition, native: native)
      result.overrideDeclarations = overrides.map {
        NamedSkillOverrideDeclaration(name: $0.0, override: $0.1)
      }
      return .skills(source: r["source"]!.string!, result)
    case "instructions":
      var result = InstructionsDeclaration(agents: agents, condition: condition, native: native)
      result.sectionReferences = records(r["sections"]).map(section)
      result.prompts = records(r["chatGPT"]).map { record in
        var prompt = PromptDeclaration(
          sections: [], append: record["append"]?.string,
          condition: self.condition(record["condition"]))
        prompt.sectionReferences = records(record["sections"]).map(section)
        return NamedPromptDeclaration(name: record["name"]!.string!, prompt: prompt)
      }
      return .instructions(result)
    case "mcpServer":
      let record = r["transport"]!.record!
      let transport: MCPTransportDeclaration
      switch record.kind {
      case "stdio": transport = .stdio(executable(record))
      case "streamableHTTP":
        transport = .streamableHTTP(
          url: record["url"]!.string!, headers: dictionary(record["headers"]).mapValues(binding))
      default:
        transport = .sse(
          url: record["url"]!.string!, headers: dictionary(record["headers"]).mapValues(binding))
      }
      return .mcpServer(
        name: name, transport: transport, agents: agents, condition: condition, native: native)
    case "hook":
      var timeout: Int?
      if case .integer(let v) = r["timeoutSeconds"] { timeout = v }
      return .hook(
        name: name, event: event(r["event"]!.record!), run: executable(r["run"]!.record!),
        matcher: r["matcher"]?.string, timeoutSeconds: timeout, agents: agents,
        condition: condition, native: native)
    case "subagent":
      return .subagent(
        name: name, description: r["description"]!.string!, prompt: prompt(r["prompt"]!.record!),
        model: r["model"]?.string,
        tools: r["tools"]?.elements.map { $0.map { $0.string! } }, agents: agents,
        condition: condition, native: native)
    case "command":
      return .command(
        name: name, description: r["description"]!.string!, prompt: prompt(r["prompt"]!.record!),
        parameters: records(r["parameters"]).map {
          PromptParameterDeclaration(
            name: $0["name"]!.string!, description: $0["description"]!.string!,
            defaultValue: $0["defaultValue"]?.string)
        }, agents: agents, condition: condition, native: native)
    case "lspServer":
      return .lspServer(
        name: name, run: executable(r["run"]!.record!),
        languages: dictionary(r["languages"]).mapValues { $0.string! },
        initializationOptions: dictionary(r["initializationOptions"]).mapValues(nativeValue),
        agents: agents, condition: condition, native: native)
    case "permissions":
      return .permissions(
        name: name, rules: records(r["rules"]).map(rule), agents: agents, condition: condition,
        native: native)
    case "ignore":
      return .ignore(
        name: name, patterns: strings(r["patterns"]),
        purpose: IgnorePurposeDeclaration(rawValue: r["purpose"]!.string!)!, agents: agents,
        condition: condition, native: native)
    case "plugin":
      return .plugin(
        name: name, path: r["path"]!.string!, source: r["source"]!.string!,
        mode: PluginModeDeclaration(rawValue: r["mode"]!.string!)!,
        select: r["select"]?.elements.map {
          $0.map { DeclaredComponentKind(rawValue: $0.string!)! }
        }, exclude: records(r["exclude"]).map(reference), agents: agents, condition: condition,
        native: native)
    default:
      throw ManifestFailure(
        ManifestDiagnostic(
          code: "manifest.unsupported", message: "unknown component family: \(r.kind)",
          span: document.source.span(0..<0)))
    }
  }
}
