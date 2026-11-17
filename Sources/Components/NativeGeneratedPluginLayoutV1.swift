import AgentsCore
import Foundation

/// A fixed closure of native members. Cold rendering consumes sealed layouts, never import input.
package enum NativeGeneratedPluginLayoutV1 {
  package static func format(_ surface: NativeClientSurface) -> String {
    "agents/\(surface.agent.rawValue)-generated-plugin@1"
  }

  static func renderers(limits: LedgerLimits) -> [String: LedgerRenderer] {
    Dictionary(
      uniqueKeysWithValues: [NativeClientSurface.claudeCode, .cursorEditor, .geminiCLI].map {
        (
          format($0),
          { lowering, ledger, resources in
            try render(lowering, ledger: ledger, resources: resources, limits: limits)
          } as LedgerRenderer
        )
      })
  }

  /// Members must be the actual linked graph frozen by C, including independent occurrences.
  /// Only origins reachable through this parent's complete frozen closure enter this lowering.
  package static func lower(
    _ parent: LinkedComponent, members: [LinkedComponent], frozen: LedgerFreeze.Result,
    request: NativeComponentRequest, id: String, platform: DeclarationPlatform
  ) throws -> LockedLowering {
    let identity = try FrozenNativeIdentity.match(
      parent, frozen: frozen, agent: request.surface.agent, scope: request.scope)
    let ledger = frozen.ledger
    let record = ledger.components[identity.id]!
    let input = ComponentRenderInput(
      record: record, component: identity.id, request: request, occurrences: identity.occurrences,
      resources: [:], ledger: ledger, limits: .standard)
    _ = try recipe(input)
    guard record.payload.object?["mode"] == .init("components") else {
      throw input.issue(["mode"], .invalid, "generated native plugins require typed component mode")
    }
    let closure = try selectedChildren(input, platform: platform.rawValue)
    let grouped = Dictionary(grouping: closure, by: \.component)
    var byOrigin: [Int: LinkedComponent] = [:]
    for member in members {
      for origin in member.origins {
        try input.budget.step()
        guard byOrigin.updateValue(member, forKey: origin.occurrence) == nil else {
          throw input.issue(["children"], .invalid, "duplicate linked native occurrence")
        }
      }
    }
    var childLayouts: [LedgerValue] = []
    var inputs = [identity.id]
    var resources: [String] = []
    var resourceSet = Set<String>()
    var seen = Set<String>()
    for occurrence in closure {
      guard seen.insert(occurrence.component).inserted else { continue }
      let owners = grouped[occurrence.component]!.map(\.id)
      let child = ledger.components[occurrence.component]!
      guard
        ["skills", "mcpServer", "command", "subagent", "hook", "lspServer"].contains(child.kind)
      else {
        throw input.issue(
          ["children", child.kind], .unverified,
          "this component has no established generated native container field")
      }
      inputs.append(occurrence.component)
      for resource in child.resources where resourceSet.insert(resource).inserted {
        resources.append(resource)
      }
      let childID = id + "/member/" + String(childLayouts.count)
      try input.budget.step(ledger.occurrences.count + ledger.components.count)
      let linked = byOrigin[occurrence.id]
      guard let linked else {
        throw input.issue(["children"], .invalid, "frozen member has no paired linked input")
      }
      let lowering: LockedLowering
      if child.kind == "skills" {
        let paired = try FrozenNativeIdentity.match(
          linked, frozen: frozen, agent: request.surface.agent, scope: request.scope)
        guard case .skill(_, let mode, _) = linked.payload, mode != .edit,
          paired.id == occurrence.component, child.resources.count == 1
        else {
          throw input.issue(
            ["children", "skills"], .invalid, "generated native skill requires frozen content")
        }
        lowering = .init(
          id: childID, format: "native/skill-resource@1", inputs: [occurrence.component],
          resources: child.resources, deployments: [], layout: .init(), platform: platform.rawValue,
          artifacts: [])
      } else if child.kind == "mcpServer" {
        let contribution = try NativeMCPLowering.lower(
          linked, frozen: frozen,
          request: .init(surface: request.surface, scope: request.scope == .user ? .user : .project)
        )
        var value = contribution.lowering(id: childID, artifact: childID, platform: platform)
        value.layout.object!["occurrences"] = .init(array: owners.map { .init(integer: $0) })
        lowering = value
      } else {
        let paired = try FrozenNativeIdentity.match(
          linked, frozen: frozen, agent: request.surface.agent, scope: request.scope)
        guard paired.id == occurrence.component else {
          throw input.issue(["children"], .invalid, "frozen native member identity mismatch")
        }
        let childInput = ComponentRenderInput(
          record: child, component: occurrence.component, request: request, occurrences: owners,
          resources: [:], ledger: ledger, limits: .standard, inPlugin: true)
        try childInput.validateProfile()
        lowering = .init(
          id: childID, format: NativeComponentLayoutsV1.format(request.surface),
          inputs: [occurrence.component], resources: child.resources, deployments: [],
          layout: .init(object: [
            "surface": .init(request.surface.rawValue), "scope": .init(request.scope.rawValue),
            "occurrences": .init(array: owners.map { .init(integer: $0) }),
            "inPlugin": .init(boolean: true),
          ]), platform: platform.rawValue, artifacts: [])
      }
      childLayouts.append(encode(lowering, owners: owners))
    }
    return .init(
      id: id, format: format(request.surface), inputs: inputs, resources: resources,
      deployments: [],
      layout: .init(object: [
        "surface": .init(request.surface.rawValue), "scope": .init(request.scope.rawValue),
        "occurrences": .init(array: identity.occurrences.map { .init(integer: $0) }),
        "members": .init(array: childLayouts),
      ]), platform: platform.rawValue, artifacts: [])
  }

  static func recipe(_ input: ComponentRenderInput) throws -> (NativeComponentRoute, String) {
    switch input.request.surface {
    case .claudeCode: return (.claudeSkillPlugin, ".claude-plugin/plugin.json")
    case .cursorEditor where input.request.scope == .user:
      return (.cursorLocalPlugin, ".cursor-plugin/plugin.json")
    case .geminiCLI where input.request.scope == .user:
      return (.geminiExtension, "gemini-extension.json")
    default:
      throw input.issue(
        ["scope"], .unverified,
        "generated native container registration is not established for this surface/scope")
    }
  }

  static func selectedChildren(_ input: ComponentRenderInput, platform: String) throws
    -> [LedgerOccurrence]
  {
    var byID: [Int: LedgerOccurrence] = [:]
    for occurrence in input.ledger.occurrences {
      try input.budget.step()
      guard byID.updateValue(occurrence, forKey: occurrence.id) == nil else {
        throw input.issue(["occurrences"], .invalid, "duplicate frozen native occurrence identity")
      }
    }
    var result: [LedgerOccurrence] = []
    for parent in input.occurrences {
      try input.budget.step()
      guard let owner = byID[parent], owner.component == input.component,
        let expansion = owner.pluginExpansion,
        ["native/claudePluginV1@1", "native/cursorPluginV1@1", "native/geminiExtensionV1@1"]
          .contains(expansion.input.format),
        expansion.input.adapterVersion == "1"
      else {
        throw input.issue(
          ["children"], .invalid, "complete frozen native expansion evidence is required")
      }
      for id in expansion.children {
        try input.budget.node(depth: 1)
        try input.budget.step()
        guard let child = byID[id], child.pluginMember?.parent == parent,
          let record = input.ledger.components[child.component],
          record.containerRoot.map({ Data($0.utf8) }) == Data(expansion.containerRoot.utf8),
          record.source == expansion.source
        else { throw input.issue(["children"], .invalid, "invalid frozen native member relation") }
        if child.recipients.contains(input.request.surface.agent),
          child.condition.scopes?.contains(input.request.scope) ?? true,
          child.condition.platforms?.contains(platform) ?? true,
          child.condition.agents?.contains(input.request.surface.agent) ?? true
        {
          result.append(child)
        }
      }
    }
    return result
  }

  static func encode(_ lowering: LockedLowering, owners: [Int]) -> LedgerValue {
    .init(object: [
      "id": .init(lowering.id), "format": .init(lowering.format),
      "inputs": LedgerPayload.strings(lowering.inputs),
      "resources": LedgerPayload.strings(lowering.resources), "layout": lowering.layout,
      "occurrences": .init(array: owners.map { .init(integer: $0) }),
    ])
  }

  static func decode(
    _ lowering: LockedLowering, ledger: ResolvedLedger, limits: LedgerLimits
  ) throws -> (ComponentRenderInput, [LockedLowering], [[Int]]) {
    func invalid() -> CoreError { .invalidState("invalid sealed generated native plugin layout") }
    guard let fields = lowering.layout.object,
      Set(fields.keys) == ["surface", "scope", "occurrences", "members"],
      let surface = fields["surface"]?.text.flatMap(NativeClientSurface.init(rawValue:)),
      let scope = fields["scope"]?.text.flatMap(InstallScope.init(rawValue:)),
      lowering.format == format(surface), let parent = lowering.inputs.first,
      let record = ledger.components[parent], record.kind == "plugin",
      record.payload.object?["mode"] == .init("components"), record.resources.isEmpty,
      let ids = fields["occurrences"]?.array, ids.allSatisfy({ $0.kind == .integer }),
      !ids.isEmpty, let encoded = fields["members"]?.array
    else { throw invalid() }
    let owners = ids.compactMap(\.integer)
    let ownerSet = Set(owners)
    guard ownerSet.count == owners.count,
      owners
        == ledger.occurrences.filter({ $0.component == parent && ownerSet.contains($0.id) }).map(
          \.id),
      ledger.occurrences.filter({ ownerSet.contains($0.id) }).allSatisfy({
        $0.recipients.contains(surface.agent) && ($0.condition.scopes?.contains(scope) ?? true)
          && ($0.condition.agents?.contains(surface.agent) ?? true)
          && ($0.condition.platforms?.contains(lowering.platform) ?? true)
      })
    else { throw invalid() }
    let input = ComponentRenderInput(
      record: record, component: parent, request: .init(surface: surface, scope: scope),
      occurrences: owners, resources: [:], ledger: ledger, limits: limits)
    try input.validateProfile()
    _ = try recipe(input)
    // Charge the complete layout before indexing/copying child layouts.
    try NativeGeneratedPluginContribution.admit(lowering.layout, budget: input.budget)
    let closure = try selectedChildren(input, platform: lowering.platform)
    let grouped = Dictionary(grouping: closure, by: \.component)
    var expected: [String] = []
    var seen = Set<String>()
    for item in closure where seen.insert(item.component).inserted {
      expected.append(item.component)
    }
    guard lowering.inputs == [parent] + expected, encoded.count == expected.count else {
      throw invalid()
    }
    var nested: [LockedLowering] = []
    var memberOwners: [[Int]] = []
    var resources: [String] = []
    var resourceSet = Set<String>()
    for (index, value) in encoded.enumerated() {
      let component = expected[index]
      let record = ledger.components[component]!
      let owners = grouped[component]!.map(\.id)
      guard let child = value.object,
        Set(child.keys) == ["id", "format", "inputs", "resources", "layout", "occurrences"],
        child["id"] == .init(lowering.id + "/member/" + String(index)),
        child["inputs"] == LedgerPayload.strings([component]),
        child["resources"] == LedgerPayload.strings(record.resources),
        child["occurrences"] == .init(array: owners.map { .init(integer: $0) }),
        let format = child["format"]?.text, let layout = child["layout"]
      else { throw invalid() }
      let childLowering = LockedLowering(
        id: child["id"]!.text!, format: format, inputs: [component], resources: record.resources,
        deployments: [], layout: layout, platform: lowering.platform, artifacts: [])
      if record.kind == "skills" {
        guard format == "native/skill-resource@1", layout == .init(), record.resources.count == 1,
          record.payload.object?["mode"] != .init("edit")
        else { throw invalid() }
      } else if record.kind == "mcpServer" {
        let contribution = try MCPLayoutV1.contribution(childLowering, ledger: ledger)
        guard contribution.occurrences == owners,
          contribution.descriptor.request.surface == surface,
          contribution.descriptor.request.scope == (scope == .user ? .user : .project)
        else { throw invalid() }
      } else {
        let parsed = try NativeComponentLayoutsV1.input(
          childLowering, ledger: ledger, limits: limits)
        guard parsed.inPlugin, parsed.occurrences == owners, parsed.request == input.request,
          ["command", "subagent", "hook", "lspServer"].contains(record.kind)
        else { throw invalid() }
      }
      nested.append(childLowering)
      memberOwners.append(owners)
      for resource in record.resources where resourceSet.insert(resource).inserted {
        resources.append(resource)
      }
    }
    guard resources == lowering.resources else { throw invalid() }
    return (input, nested, memberOwners)
  }

  static func render(
    _ lowering: LockedLowering, ledger: ResolvedLedger, resources: [String: URL],
    limits: LedgerLimits
  ) throws -> [ReplayedArtifact] {
    let (input, members, _) = try decode(lowering, ledger: ledger, limits: limits)
    let table = NativeComponentLayoutsV1.renderers(limits: limits).merging(MCPLayoutV1.renderers) {
      a, _ in a
    }
    let values = try members.map { member -> LedgerValue in
      if member.format == "native/skill-resource@1" { return .init() }
      guard let renderer = table[member.format] else {
        throw CoreError.invalidState("unknown native member renderer")
      }
      let artifacts = try renderer(member, ledger, resources)
      guard artifacts.count == 1, artifacts[0].kind == .ownedValues, let value = artifacts[0].values
      else {
        throw CoreError.invalidState("invalid generated native member output")
      }
      return value
    }
    return [
      .init(name: lowering.id, kind: .ownedValues, values: try envelope(input, members: values))
    ]
  }
  static func envelope(_ input: ComponentRenderInput, members: [LedgerValue]) throws -> LedgerValue
  {
    let (route, manifest) = try recipe(input)
    let metadata = try input.checkedNative(["version": .string, "description": .string])
    return .init(object: [
      "component": .init(input.component), "directory": .init(try input.filename()),
      "route": .init(route.rawValue), "manifest": .init(manifest),
      "metadata": .init(object: metadata),
      "occurrences": .init(array: input.occurrences.map { .init(integer: $0) }),
      "members": .init(array: members),
    ])
  }

}
