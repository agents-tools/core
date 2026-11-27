import AgentsCore
import AgentsInstructions
import Foundation

package enum DeploymentConstruction {
  package static func validateCopiedSkill(_ tree: URL) throws {
    guard let real = PathSafety.realPath(tree.path),
      let children = FileManager.default.enumerator(
        at: tree, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let child as URL in children
    where try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      guard try PathSafety.linkStaysInside(child, root: real) else {
        throw CoreError.unsafePath("copied skill link escapes its installed subtree")
      }
    }
  }

  package struct Result {
    package let ledger: ResolvedLedger
    package let inputs: [TargetPrecondition]
  }
  package static func routes(_ ledger: ResolvedLedger) throws -> Set<NativeTargetRoute> {
    var result = Set<NativeTargetRoute>()
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-mcp@1") {
      let contribution = try MCPLayoutV1.contribution(lowering, ledger: ledger)
      let route = try route(contribution)
      result.insert(route)
      if contribution.descriptor.request.surface == .openCodeCLI {
        result.insert(
          contribution.descriptor.request.scope == .project
            ? .openCodeMCPProjectJSONC : .openCodeMCPUserJSONC)
      }
    }
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-components@1") {
      let input = try NativeComponentLayoutsV1.input(lowering, ledger: ledger, limits: .standard)
      let scope = input.request.scope
      let name = input.record.name
      switch (input.request.surface, input.record.kind) {
      case (.antigravity, "hook"):
        result.insert(scope == .project ? .antigravityHooksProject : .antigravityHooksUser)
      case (.claudeCode, "command"):
        result.insert(try .named(.claudeCommand, scope: scope, name: name))
      case (.claudeCode, "subagent"):
        result.insert(try .named(.claudeAgent, scope: scope, name: name))
      case (.claudeCode, "lspServer"), (.claudeCode, "plugin"):
        result.insert(try .named(.claudeSkillPlugin, scope: scope, name: name))
      case (.claudeCode, _):
        result.insert(scope == .project ? .claudeSettingsProject : .claudeSettingsUser)
      case (.codexCLI, "subagent"):
        result.insert(try .named(.codexAgent, scope: scope, name: name))
        result.insert(scope == .project ? .codexMCPProject : .codexMCPUser)
      case (.codexCLI, _): result.insert(scope == .project ? .codexHooksProject : .codexHooksUser)
      case (.geminiCLI, "command"):
        result.insert(try .named(.geminiCommand, scope: scope, name: name))
      case (.geminiCLI, "subagent"):
        result.insert(try .named(.geminiAgent, scope: scope, name: name))
      case (.geminiCLI, "plugin"):
        result.insert(try .named(.geminiExtension, scope: scope, name: name))
      case (.geminiCLI, "ignore"): result.insert(.geminiIgnoreProject)
      case (.geminiCLI, _): result.insert(scope == .project ? .geminiMCPProject : .geminiMCPUser)
      case (.cursorEditor, "command"):
        result.insert(try .named(.cursorCommand, scope: scope, name: name))
      case (.cursorEditor, "subagent"):
        result.insert(try .named(.cursorAgent, scope: scope, name: name))
      case (.cursorEditor, "plugin"):
        result.insert(try .named(.cursorLocalPlugin, scope: scope, name: name))
      case (.cursorEditor, "ignore"): result.insert(.cursorIgnoreProject)
      case (.cursorEditor, _):
        result.insert(scope == .project ? .cursorHooksProject : .cursorHooksUser)
      case (.openCodeCLI, _):
        result.insert(scope == .project ? .openCodeMCPProjectJSON : .openCodeMCPUserJSON)
        result.insert(scope == .project ? .openCodeMCPProjectJSONC : .openCodeMCPUserJSONC)
      default: throw CoreError.invalidState("native surface has no integrated closed route")
      }
    }
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-generated-plugin@1") {
      result.insert(try generatedRoute(lowering, ledger: ledger))
    }
    return result
  }

  package static func generatedRoute(_ lowering: LockedLowering, ledger: ResolvedLedger) throws
    -> NativeTargetRoute
  {
    guard let surface = lowering.layout.object?["surface"]?.text,
      let scopeText = lowering.layout.object?["scope"]?.text,
      let scope = InstallScope(rawValue: scopeText),
      let id = lowering.inputs.first, let component = ledger.components[id]
    else {
      throw CoreError.invalidState("invalid generated native route")
    }
    switch NativeClientSurface(rawValue: surface) {
    case .claudeCode: return try .named(.claudeSkillPlugin, scope: scope, name: component.name)
    case .cursorEditor: return try .named(.cursorLocalPlugin, scope: scope, name: component.name)
    case .geminiCLI: return try .named(.geminiExtension, scope: scope, name: component.name)
    default: throw CoreError.invalidState("unregistered generated native route")
    }
  }

  private static func surface(_ agent: AgentID) -> NativeClientSurface {
    switch agent {
    case .claudeCode: .claudeCode
    case .codex: .codexCLI
    case .cursor: .cursorEditor
    case .geminiCLI: .geminiCLI
    case .opencode: .openCodeCLI
    case .antigravity: .antigravity
    }
  }

  /// Checks the native entry without reading resources or resolving any runtime binding.
  package static func validateMCP(
    _ transport: MCPTransportDeclaration, named name: String, agent: AgentID, scope: InstallScope,
    native: NativeConfiguration = [:], requiresSymbolicBindings: Bool
  ) throws {
    let request = NativeMCPRequest(
      surface: surface(agent), scope: scope == .user ? .user : .project)
    let descriptor = try CapabilityRegistry.mcp(request, component: name)
    var resources: [String] = []
    if case .stdio(let run) = transport {
      if run.executable.contains("/") { resources.append(run.executable) }
      if let directory = run.workingDirectory { resources.append(directory.path) }
    }
    let entry = try NativeMCPLowering.entry(
      transport, named: name, descriptor: descriptor, native: native[agent.rawValue] ?? [:],
      resources: resources)
    if requiresSymbolicBindings, let literal = entry.placements.first(where: { !$0.reference }) {
      throw NativeAdapterIssue(
        request: request, component: name, field: literal.path.fields, reason: .unsupported,
        detail: "the client cannot keep this MCP registry binding symbolic")
    }
  }

  private static func direct(_ component: LinkedComponent, ledger: ResolvedLedger, agent: AgentID)
    throws -> LinkedComponent
  {
    let surface = surface(agent)
    let parents = Set(
      ledger.lowerings.filter {
        $0.format.hasSuffix("-generated-plugin@1")
          && $0.layout.object?["surface"]?.text == surface.rawValue
      }.flatMap { $0.layout.object?["occurrences"]?.array?.compactMap(\.integer) ?? [] })
    let consumed = Set(
      ledger.occurrences.filter { $0.pluginMember.map { parents.contains($0.parent) } ?? false }
        .map(\.id))
    var result = component
    result.origins.removeAll { consumed.contains($0.occurrence) }
    return result
  }

  package static func physicalRoute(
    _ route: NativeTargetRoute, ledger: ResolvedLedger, store: StateStore
  ) throws -> NativeTargetRoute {
    let alternate: NativeTargetRoute
    if route == .openCodeMCPProjectJSON {
      alternate = .openCodeMCPProjectJSONC
    } else if route == .openCodeMCPUserJSON {
      alternate = .openCodeMCPUserJSONC
    } else {
      return route
    }
    let recorded = ledger.deployments.filter { $0.route.hasPrefix("agents/opencode-") }
    let names = Set(recorded.map { ($0.target.path as NSString).lastPathComponent })
    if names.contains("opencode.jsonc"), !names.contains("opencode.json") { return alternate }
    if names.contains("opencode.json"), !names.contains("opencode.jsonc") { return route }
    let json = try store.nativeTarget(for: route)
    let jsonc = try store.nativeTarget(for: alternate)
    let hasJSON = FileManager.default.fileExists(atPath: json.url.path)
    let hasJSONC = FileManager.default.fileExists(atPath: jsonc.url.path)
    guard !(hasJSON && hasJSONC) else {
      throw CoreError.invalidState(
        "multiple OpenCode configuration files require an explicit native target decision")
    }
    return hasJSONC ? alternate : route
  }

  package static func route(_ output: NativeComponentOutput, request: NativeComponentRequest) throws
    -> NativeTargetRoute
  {
    let project = request.scope == .project
    let path: String
    switch output.content {
    case .file(let name, _): path = name
    case .generatedLSPPlugin(let directory, _, _), .nativePlugin(let directory, _, _):
      path = directory
    default: path = ""
    }
    switch output.route {
    case .claudeCommand: return try .file(.claudeCommand, scope: request.scope, relativePath: path)
    case .claudeAgent: return try .file(.claudeAgent, scope: request.scope, relativePath: path)
    case .codexAgent: return try .file(.codexAgent, scope: request.scope, relativePath: path)
    case .geminiCommand: return try .file(.geminiCommand, scope: request.scope, relativePath: path)
    case .geminiAgent: return try .file(.geminiAgent, scope: request.scope, relativePath: path)
    case .cursorCommand: return try .file(.cursorCommand, scope: request.scope, relativePath: path)
    case .cursorAgent: return try .file(.cursorAgent, scope: request.scope, relativePath: path)
    case .claudeSkillPlugin: return try .named(.claudeSkillPlugin, scope: request.scope, name: path)
    case .cursorLocalPlugin: return try .named(.cursorLocalPlugin, scope: request.scope, name: path)
    case .geminiExtension: return try .named(.geminiExtension, scope: request.scope, name: path)
    case .claudeSettings: return project ? .claudeSettingsProject : .claudeSettingsUser
    case .codexHooks: return project ? .codexHooksProject : .codexHooksUser
    case .cursorHooks: return project ? .cursorHooksProject : .cursorHooksUser
    case .antigravityHooks: return project ? .antigravityHooksProject : .antigravityHooksUser
    case .geminiIgnore: return .geminiIgnoreProject
    case .cursorIgnore: return .cursorIgnoreProject
    case .geminiSettings: return project ? .geminiMCPProject : .geminiMCPUser
    case .codexConfig: return project ? .codexMCPProject : .codexMCPUser
    case .openCodeConfig: return project ? .openCodeMCPProjectJSON : .openCodeMCPUserJSON
    }
  }

  package static func route(_ contribution: NativeMCPContribution) throws -> NativeTargetRoute {
    let project = contribution.descriptor.request.scope == .project
    switch contribution.descriptor.request.surface {
    case .claudeCode:
      switch contribution.descriptor.request.scope {
      case .project: return .claudeMCPProject
      case .local: return .claudeMCPLocal
      case .user: return .claudeMCPUser
      }
    case .codexCLI: return project ? .codexMCPProject : .codexMCPUser
    case .geminiCLI: return project ? .geminiMCPProject : .geminiMCPUser
    case .antigravity: return project ? .antigravityMCPProject : .antigravityMCPUser
    case .cursorEditor: return project ? .cursorMCPProject : .cursorMCPUser
    case .openCodeCLI: return project ? .openCodeMCPProjectJSON : .openCodeMCPUserJSON
    case .cursorCLI, .cursorCloud:
      throw NativeAdapterIssue(
        request: contribution.descriptor.request, component: contribution.name, field: ["route"],
        reason: .integrationRequired, detail: "this surface has no accepted registered route")
    }
  }

  package static func lowerNative(
    linked: LinkedComponents, frozen: LedgerFreeze.Result, scope: InstallScope,
    platform: DeclarationPlatform
  ) throws -> ResolvedLedger {
    var ledger = frozen.ledger
    for parent in linked.components where parent.key.kind == .plugin {
      guard case .declaration = parent.payload,
        let id = frozen.ledger.occurrences.first(where: { $0.id == parent.origins[0].occurrence })?
          .component,
        let record = frozen.ledger.components[id],
        record.payload.object?["mode"] == .init("components")
      else { continue }
      _ = record
      for agent in parent.recipients.sorted(by: { $0.rawValue < $1.rawValue }) {
        ledger.lowerings.append(
          try NativeGeneratedPluginLayoutV1.lower(
            parent, members: linked.components, frozen: frozen,
            request: .init(surface: surface(agent), scope: scope),
            id: "plugin:" + String(parent.origins[0].occurrence) + ":" + agent.rawValue,
            platform: platform))
      }
    }
    for original in linked.components {
      guard case .declaration = original.payload else { continue }
      if original.key.kind == .plugin,
        ledger.lowerings.contains(where: {
          $0.format.hasSuffix("-generated-plugin@1")
            && $0.layout.object?["occurrences"]?.array?.contains(
              .init(integer: original.origins[0].occurrence)) == true
        })
      {
        continue
      }
      for agent in original.recipients.sorted(by: { $0.rawValue < $1.rawValue }) {
        let component = try direct(original, ledger: ledger, agent: agent)
        guard !component.origins.isEmpty else { continue }
        let surface = surface(agent)
        if component.key.kind != .mcpServer {
          ledger.lowerings.append(
            try NativeComponentLowering.lower(
              component, frozen: frozen,
              request: .init(surface: surface, scope: scope),
              id: "native:" + String(component.origins[0].occurrence) + ":" + agent.rawValue,
              platform: platform))
          continue
        }
        var contribution = try NativeMCPLowering.lower(
          component, frozen: frozen,
          request: .init(surface: surface, scope: scope == .user ? .user : .project))
        if scope == .project, surface == .claudeCode,
          contribution.bindings.contains(where: { !$0.reference })
        {
          contribution = try NativeMCPLowering.lower(
            component, frozen: frozen, request: .init(surface: surface, scope: .local))
        }
        let id = "mcp:" + String(component.origins[0].occurrence) + ":" + agent.rawValue
        ledger.lowerings.append(contribution.lowering(id: id, artifact: id, platform: platform))
      }
    }
    return ledger
  }

  package static func complete(
    _ native: ResolvedLedger, linked: LinkedComponents, store: StateStore,
    previous: ResolvedLedger, platform: DeclarationPlatform, roots: [String: URL],
    session: SourceResolutionSession
  ) throws -> Result {
    var ledger = native
    var inputs: [TargetPrecondition] = []
    let owners = Dictionary(uniqueKeysWithValues: ledger.occurrences.map { ($0.id, $0.component) })
    func owner(_ component: LinkedComponent) -> String { owners[component.origins[0].occurrence]! }
    func add(
      id: String, format: String, inputs: [String], resources: [String], location: LedgerLocation?,
      agents: [AgentID], hash: String, layout: [String: LedgerValue],
      ownership: LedgerDeployment.Ownership = .generated, created: Bool = false,
      reference: String? = nil
    ) {
      let deployment = location.map { location in
        LedgerDeployment(
          id: id, target: location, route: format, owners: inputs, recipients: agents,
          ownership: ownership, expectedHash: hash, created: created,
          importReference: reference, headingOffset: ownership == .generated ? 0 : nil)
      }
      if let deployment { ledger.deployments.append(deployment) }
      ledger.lowerings.append(
        .init(
          id: id, format: format, inputs: inputs, resources: resources,
          deployments: deployment == nil ? [] : [id], layout: .init(object: layout),
          platform: platform.rawValue, artifacts: []))
    }
    for component in linked.components {
      guard case .skill(_, _, _) = component.payload else { continue }
      let key = owner(component)
      let record = ledger.components[key]!
      let resource = ledger.resources[record.resources[0]]!
      for agent in component.recipients.sorted(by: { $0.rawValue < $1.rawValue }) {
        let directComponent = try direct(component, ledger: ledger, agent: agent)
        guard let origin = directComponent.origins.first else { continue }
        let id = "skill:" + String(origin.occurrence) + ":" + agent.rawValue
        add(
          id: id, format: "agents/skill@1", inputs: [key], resources: record.resources,
          location: .init(
            kind: .registered, root: "skills-" + agent.rawValue,
            path: PathSafety.sanitizeName(component.key.name)),
          agents: [agent], hash: resource.hash,
          layout: ["name": .init(id), "mode": record.payload.object!["mode"]!])
      }
    }
    let instructions = linked.components.filter {
      if case .instruction = $0.payload { true } else { false }
    }
    let old = try previous.domainProjection(roots: roots).instructions
    var merged: [String: (LockedTarget, [String], [String])] = [:]
    var ruleOwners: [String: (String, String)] = [:]
    for component in instructions where component.recipients.contains(.antigravity) {
      guard case .instruction(let unit, _, _) = component.payload else { continue }
      let key = owner(component)
      let record = ledger.components[key]!
      let leaf = try AntigravityRuleV1.leaf(source: component.snapshot.source, path: unit.path)
      _ = try InstructionLocations.antigravityLeaf(leaf, store: store)
      if let (priorSource, priorUnit) = ruleOwners[leaf] {
        guard priorSource == record.source, priorUnit == record.resources[0] else {
          throw AntigravityRuleV1.failure(leaf, "incompatible selections share this rule")
        }
        continue
      }
      ruleOwners[leaf] = (record.source, record.resources[0])
      let bytes = try AntigravityRuleV1.render(
        unit.bytes, path: unit.path, leaf: leaf, scope: store.scope
      ) {
        try FileSystem.read(at: session.resource(snapshot: component.snapshot, path: $0))
      }
      let id = "antigravity:" + leaf
      add(
        id: id, format: AntigravityRuleV1.format, inputs: [key], resources: record.resources,
        location: .init(
          kind: .registered, root: InstructionLocations.ruleRoot(in: store.scope), path: leaf),
        agents: [.antigravity], hash: Instructions.hash(bytes), layout: ["name": .init(id)])
    }
    for agent in AgentID.allCases
    where agent != .antigravity && agent.supportsInstructions(in: store.scope) {
      let selected = instructions.filter { $0.recipients.contains(agent) }
      let sections = selected.compactMap { component in
        if case .instruction(let unit, _, _) = component.payload { return unit.section }
        return nil
      }
      guard !sections.isEmpty else { continue }
      let planned = try InstructionTargets(store: store).plan(
        sections: sections, agents: [agent], previous: old)
      for (id, source) in ledger.sources where source.kind == .local && source.location != nil {
        let identity = try ledger.sourceIdentity(id, roots: roots)
        let roots = ledger.sourceUses.filter { $0.source == id }.map(\.root)
        for root in roots.isEmpty ? ["."] : roots {
          try InstructionTargets.validateSourceDirectories(
            planned.changes,
            sources: [identity: LockedSource(kind: .local, path: root == "." ? nil : root)])
        }
      }
      inputs += try planned.expectations.values.map { try $0.capturingPublicationAccess() }
      let targets = planned.targets
      for (path, target) in targets {
        let selected = selected.filter { component in
          if target.import != nil { return true }
          if case .instruction(let unit, _, _) = component.payload {
            let directory = store.scope == .project ? unit.section.directory : ""
            return store.scope == .user || (path as NSString).deletingLastPathComponent == directory
              || (directory.isEmpty && !(path.contains("/")))
          }
          return false
        }
        let owners = selected.map(owner)
        let resources = owners.map { ledger.components[$0]!.resources[0] }
        if var existing = merged[path] {
          guard existing.0.blockHash == target.blockHash, existing.2 == resources else {
            throw CoreError.invalidState(
              "instruction recipients require incompatible shared output: \(path)")
          }
          existing.0.agents += target.agents
          var knownOwners = Set(existing.1)
          existing.1 += owners.filter { knownOwners.insert($0).inserted }
          merged[path] = existing
        } else {
          merged[path] = (target, owners, resources)
        }
      }
    }
    for path in merged.keys.sorted() {
      let (target, owners, resources) = merged[path]!
      let file = try InstructionLocations.file(for: path, store: store)
      let location: LedgerLocation
      if store.scope == .project {
        location = .init(kind: .registered, root: "project", path: path)
      } else if let agent = target.agents.first {
        location = .init(
          kind: .registered, root: "instructions-" + agent.rawValue, path: file.lastPathComponent)
      } else {
        throw CoreError.invalidState("missing instruction recipient")
      }
      let id = "instructions:" + path
      let format = target.import == nil ? "agents/instructions@1" : "agents/claude-import@1"
      add(
        id: id, format: format, inputs: owners, resources: target.import == nil ? resources : [],
        location: location, agents: Array(Set(target.agents)).sorted { $0.rawValue < $1.rawValue },
        hash: target.blockHash,
        layout: [
          "name": .init(target.import == nil ? id : path), "headingOffset": .init(integer: 0),
        ],
        ownership: target.import == nil ? .generated : .importBlock,
        created: target.created, reference: target.import)
    }
    var prompts: [String: [LinkedComponent]] = [:]
    for component in instructions where component.chatGPT {
      if case .instruction(_, let prompt?, _) = component.payload {
        prompts[prompt, default: []].append(component)
      }
    }
    for name in prompts.keys.sorted() {
      let selected = prompts[name]!
      let owners = selected.map(owner)
      var resources = owners.map { ledger.components[$0]!.resources[0] }
      if let append = ledger.components[owners[0]]!.resources.dropFirst().first {
        resources.append(append)
      }
      add(
        id: "prompt:" + name, format: "agents/chatgpt@1", inputs: owners, resources: resources,
        location: nil, agents: [], hash: "sha256:" + String(repeating: "0", count: 64),
        layout: ["name": .init("prompt:" + name), "sectionCount": .init(integer: selected.count)])
    }
    for recipient in [InstructionRecipient.chatGPTApp, .geminiApp] {
      let selected = instructions.filter { $0.copyRecipients.contains(recipient) }
      guard !selected.isEmpty else { continue }
      let id = "instruction-copy:" + recipient.rawValue
      let owners = selected.map(owner)
      add(
        id: id, format: LockedLowering.instructionCopyFormat, inputs: owners,
        resources: owners.map { ledger.components[$0]!.resources[0] },
        location: nil, agents: [], hash: "",
        layout: [
          "name": .init(id), "recipient": .init(recipient.rawValue),
          "sectionCount": .init(integer: selected.count),
        ])
    }
    return Result(ledger: ledger, inputs: inputs)
  }
}
