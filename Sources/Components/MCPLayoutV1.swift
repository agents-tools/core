import AgentsCore
import Foundation

/// Version 1 stores regional intentions, references and exact resource identities. Its renderer
/// does not choose a route, expand a binding or turn temporary replay trees into native paths.
/// The owned-values artifact is the complete region-intention envelope, so its digest also pins
/// targeting and binding placement. E decodes it to a contribution before native preparation.
package enum MCPLayoutV1 {
  static var renderers: [String: LedgerRenderer] {
    [
      "agents/claude-mcp@1": render,
      "agents/codex-mcp@1": render,
      "agents/gemini-mcp@1": render,
      "agents/opencode-mcp@1": render,
      "agents/cursor-mcp@1": render,
    ]
  }

  package static func contribution(
    _ lowering: LockedLowering, ledger: ResolvedLedger
  ) throws -> NativeMCPContribution {
    func invalid() -> CoreError { .invalidState("invalid version 1 MCP layout") }
    try lowering.layout.validate()
    guard let layout = lowering.layout.object,
      Set(layout.keys) == [
        "artifact", "surface", "scope", "component", "name", "value", "occurrences",
        "recipients", "knownReaders", "bindings", "resourcePlacements",
      ],
      let surfaceText = string(layout["surface"]),
      let surface = NativeClientSurface(rawValue: surfaceText),
      let scopeText = string(layout["scope"]), let scope = NativeMCPScope(rawValue: scopeText),
      let name = string(layout["name"]), !name.isEmpty,
      let component = string(layout["component"]), lowering.inputs == [component],
      let record = ledger.components[component], record.name == name, record.kind == "mcpServer",
      record.recipients.contains(surface.agent), lowering.resources == record.resources,
      let value = layout["value"], value.kind == .object,
      let artifact = string(layout["artifact"]), !artifact.isEmpty,
      layout["occurrences"]?.kind == .array, let occurrenceValues = layout["occurrences"]?.array,
      layout["bindings"]?.kind == .array, let bindingValues = layout["bindings"]?.array,
      layout["resourcePlacements"]?.kind == .array,
      let resourceValues = layout["resourcePlacements"]?.array
    else { throw invalid() }
    let descriptor = try CapabilityRegistry.mcp(
      .init(surface: surface, scope: scope), component: name)
    guard lowering.format == descriptor.format,
      layout["recipients"] == LedgerPayload.strings([surface.agent.rawValue]),
      layout["knownReaders"]
        == LedgerPayload.strings(descriptor.knownReaders.map(\.rawValue).sorted())
    else { throw invalid() }
    let occurrences = try occurrenceValues.map { value in
      guard value.kind == .integer, let id = value.integer else { throw invalid() }
      return id
    }
    guard !occurrences.isEmpty,
      Set(occurrences).count == occurrences.count,
      occurrences
        == ledger.occurrences.filter({
          $0.component == component && occurrences.contains($0.id)
        }).map(\.id)
    else { throw invalid() }
    let bindings: [MCPBindingPlacement] = try bindingValues.map { item in
      guard let fields = item.object, Set(fields.keys) == ["path", "binding", "reference"],
        let encoded = fields["binding"], let name = encoded.text,
        fields["reference"]?.kind == .boolean, let reference = fields["reference"]?.boolean
      else { throw invalid() }
      let binding: RuntimeBinding
      switch encoded.kind {
      case .environment: binding = .environment(name)
      case .secret where !reference: binding = .secret(name)
      default: throw invalid()
      }
      let steps = try steps(fields["path"])
      let slot = try at(steps, in: value)
      if reference {
        guard MCPReferenceSyntax.isName(name)
        else {
          throw invalid()
        }
        let expected: LedgerValue
        switch surface {
        case .claudeCode: expected = .init(MCPReferenceSyntax.claude.render(name))
        case .geminiCLI: expected = .init(MCPReferenceSyntax.gemini.render(name))
        case .openCodeCLI: expected = .init(MCPReferenceSyntax.openCode.render(name))
        case .codexCLI: expected = .init(name)
        case .cursorEditor, .cursorCLI, .cursorCloud: throw invalid()
        }
        guard slot == expected else { throw invalid() }
      } else {
        guard slot == encoded else { throw invalid() }
      }
      return .init(path: steps, binding: binding, reference: reference)
    }
    let resourcePlacements: [MCPResourcePlacement] = try resourceValues.map { item in
      guard let fields = item.object, Set(fields.keys) == ["path", "resource"],
        let resource = string(fields["resource"]), lowering.resources.contains(resource)
      else { throw invalid() }
      let steps = try steps(fields["path"])
      guard try at(steps, in: value) == .init(object: ["resource": .init(resource)]) else {
        throw invalid()
      }
      return .init(path: steps, resource: resource)
    }
    var paths: [[MCPValueStep]] = []
    for path in bindings.map(\.path) + resourcePlacements.map(\.path) {
      guard !paths.contains(where: { $0.starts(with: path) || path.starts(with: $0) }) else {
        throw invalid()
      }
      paths.append(path)
    }
    return .init(
      descriptor: descriptor, component: component, name: name, occurrences: occurrences,
      recipients: [surface.agent], bindings: bindings, resourcePlacements: resourcePlacements,
      value: value, resources: lowering.resources)
  }

  static func path(_ path: [MCPValueStep]) -> LedgerValue {
    .init(
      array: path.map { step in
        switch step {
        case .key(let key): .init(object: ["key": .init(key)])
        case .index(let index): .init(object: ["index": .init(integer: index)])
        }
      })
  }

  static func binding(_ binding: RuntimeBinding) -> LedgerValue {
    switch binding {
    case .literal(let value): .init(value, kind: .literal)
    case .environment(let name): .init(name, kind: .environment)
    case .secret(let name): .init(name, kind: .secret)
    }
  }

  private static func string(_ value: LedgerValue?) -> String? {
    value?.kind == .string ? value?.text : nil
  }

  private static func steps(_ value: LedgerValue?) throws -> [MCPValueStep] {
    guard value?.kind == .array, let array = value?.array, !array.isEmpty else {
      throw CoreError.invalidState("invalid MCP slot path")
    }
    return try array.map { item in
      guard let object = item.object, object.count == 1 else {
        throw CoreError.invalidState("invalid MCP slot step")
      }
      if let key = string(object["key"]) { return .key(key) }
      if let index = object["index"], index.kind == .integer, let i = index.integer, i >= 0 {
        return .index(i)
      }
      throw CoreError.invalidState("invalid MCP slot step")
    }
  }

  private static func at(_ path: [MCPValueStep], in root: LedgerValue) throws -> LedgerValue {
    var value = root
    for step in path {
      switch step {
      case .key(let key):
        guard let next = value.object?[key] else {
          throw CoreError.invalidState("missing MCP slot")
        }
        value = next
      case .index(let index):
        guard let array = value.array, array.indices.contains(index) else {
          throw CoreError.invalidState("missing MCP slot")
        }
        value = array[index]
      }
    }
    return value
  }

  private static func render(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    _ = try contribution(lowering, ledger: ledger)
    guard lowering.resources.allSatisfy({ resources[$0] != nil }) else {
      throw CoreError.invalidState("missing frozen MCP resource")
    }
    return [
      .init(
        name: lowering.layout.object!["artifact"]!.text!, kind: .ownedValues,
        values: lowering.layout)
    ]
  }
}
