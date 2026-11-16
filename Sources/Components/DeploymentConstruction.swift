import AgentsCore
import AgentsInstructions
import Foundation

package enum DeploymentConstruction {
  package struct Result {
    package let ledger: ResolvedLedger
    package let inputs: [TargetPrecondition]
  }
  package static func routes(_ ledger: ResolvedLedger) throws -> Set<NativeTargetRoute> {
    var result = Set<NativeTargetRoute>()
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-mcp@1") {
      let contribution = try MCPLayoutV1.contribution(lowering, ledger: ledger)
      result.insert(try route(contribution))
    }
    return result
  }

  package static func route(_ contribution: NativeMCPContribution) throws -> NativeTargetRoute {
    guard contribution.descriptor.request.surface == .claudeCode else {
      throw NativeAdapterIssue(
        request: contribution.descriptor.request, component: contribution.name, field: ["route"],
        reason: .integrationRequired, detail: "Core registered route is pending integration")
    }
    switch contribution.descriptor.request.scope {
    case .project: return .claudeMCPProject
    case .local: return .claudeMCPLocal
    case .user: return .claudeMCPUser
    }
  }

  package static func lowerNative(
    linked: LinkedComponents, frozen: LedgerFreeze.Result, scope: InstallScope,
    platform: DeclarationPlatform
  ) throws -> ResolvedLedger {
    var ledger = frozen.ledger
    for component in linked.components {
      guard case .declaration = component.payload else { continue }
      guard component.key.kind == .mcpServer else {
        if !component.recipients.isEmpty {
          throw CoreError.invalidState(
            "\(component.key.kind.rawValue)/\(component.key.name): production adapter integration is pending"
          )
        }
        continue
      }
      for agent in component.recipients.sorted(by: { $0.rawValue < $1.rawValue }) {
        let surface: NativeClientSurface
        switch agent {
        case .claudeCode: surface = .claudeCode
        case .codex: surface = .codexCLI
        case .cursor: surface = .cursorEditor
        case .geminiCLI: surface = .geminiCLI
        case .opencode: surface = .openCodeCLI
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
    previous: ResolvedLedger, platform: DeclarationPlatform
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
        let id = "skill:" + String(component.origins[0].occurrence) + ":" + agent.rawValue
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
    let old = try previous.domainProjection(roots: store.ledgerRoots).instructions
    var merged: [String: (LockedTarget, [String], [String])] = [:]
    for agent in AgentID.allCases {
      let selected = instructions.filter { $0.recipients.contains(agent) }
      let sections = selected.compactMap { component in
        if case .instruction(let unit, _, _) = component.payload { return unit.section }
        return nil
      }
      guard !sections.isEmpty else { continue }
      let planned = try InstructionTargets(store: store).plan(
        sections: sections, agents: [agent], previous: old)
      for (id, source) in ledger.sources where source.kind == .local && source.location != nil {
        let identity = try ledger.sourceIdentity(id, roots: store.ledgerRoots)
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
          guard existing.0.blockHash == target.blockHash, existing.1 == owners else {
            throw CoreError.invalidState(
              "instruction recipients require incompatible shared output: \(path)")
          }
          existing.0.agents += target.agents
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
    return Result(ledger: ledger, inputs: inputs)
  }
}
