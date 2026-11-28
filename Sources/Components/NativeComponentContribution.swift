import AgentsCore
import Foundation
import NativeDocuments

/// One frozen logical owner. Physical reader union and native ownership observations belong to E.
package struct NativeComponentContribution {
  package let format: String
  package let request: NativeComponentRequest
  package let component: String
  package let kind: DeclaredComponentKind
  package let name: String
  package let occurrences: [Int]
  package let recipients: [AgentID]
  package let knownReaders: [AgentID]
  package let resources: [String: LedgerResource]
  package let outputs: [NativeComponentOutput]
}

/// These are the concrete current native surfaces, not caller-programmable document edits.
package struct NativeComponentOutput {
  package let route: NativeComponentRoute
  package let content: Content

  package enum Content {
    /// Whole UTF8 file, with no executable bit. The relative name is admitted under the route by D.
    case file(path: String, bytes: Data)
    case member(NativeComponentMember, NativeComponentValue)
    /// One owned array occurrence. Preserve ordering; equal unmanaged occurrences confer no authority.
    case hook(NativeComponentHook)
    /// Last-match native tool/resource rules, appended in their declared order.
    case orderedPermissions([NativeComponentPermission])
    /// Native deny/ask/allow categories, not a portable ordered policy.
    case claudePermissions(NativeClaudePermissions)
    /// Ordered lines for E's existing managed ignore block, not independent line ownership.
    case ignore([String])
    /// One generated Claude plugin manifest and its coupled registered plugin directory.
    case generatedLSPPlugin(directory: String, manifestPath: String, manifest: NativeComponentValue)
    /// Complete opaque frozen tree. Entries retain file kinds, symlinks and executable bits.
    case nativePlugin(directory: String, resource: String, manifest: String)
  }
}

package enum NativeComponentMember {
  case antigravityHook(String)
  case openCodeCommand(String)
  case openCodeAgent(String)
  case openCodeLSP(String)
  /// The config_file points at the coupled codexAgent file output of this same owner.
  case codexAgent(String)

  package var keys: [String] {
    switch self {
    case .antigravityHook(let name): [name]
    case .openCodeCommand(let name): ["commands", name]
    case .openCodeAgent(let name): ["agents", name]
    case .openCodeLSP(let name): ["lsp", name]
    case .codexAgent(let name): ["agents", name]
    }
  }
}

package struct NativeComponentHook {
  package enum Layout: Equatable {
    /// An event array contains groups with matcher/sequential metadata and a hooks array.
    case group
    /// Cursor's event array contains handlers directly; the root must have version = 1.
    case cursorVersion1
  }
  package let event: String
  package let layout: Layout
  package let value: NativeComponentValue
  package var keys: [String] { ["hooks", event] }

  /// E supplies the staged value and a fresh array precondition. Ownership comes only from
  /// prepare's appendedOccurrences result, never from an equal existing handler.
  package func append(value: NativeValue, expected: NativeExpectedRegion) -> NativeRegionEdit {
    .append(region: NativeRegion(keys: keys), expected: expected, value: value)
  }
}

package struct NativeComponentPermission {
  package enum Effect: String { case allow, ask, deny }
  package let tool: String
  package let resource: String
  package let effect: Effect
}

package struct NativeClaudePermissions {
  /// nil differs from a supplied empty category. E must preserve that distinction.
  package let allow: [String]?
  package let ask: [String]?
  package let deny: [String]?
  package let defaultMode: String?
}

/// Slots identify only actual native program positions. They never address arbitrary settings data.
package enum NativeComponentSlot: Equatable {
  case executable
  case argument(Int)
  case environment(String)
  case workingDirectory
}

package struct NativeComponentBindingPlacement {
  package let slot: NativeComponentSlot
  package let binding: RuntimeBinding
}

package struct NativeComponentResourcePlacement {
  package let slot: NativeComponentSlot
  package let resource: String
}

/// A decoder-created native value. Its symbolic payload cannot be mutated or constructed by E.
package struct NativeComponentValue {
  package let bindings: [NativeComponentBindingPlacement]
  package let resourcePlacements: [NativeComponentResourcePlacement]
  private let envelope: LedgerValue
  private let requiresProgramConversion: Bool
  private let manifestProjection: Bool

  init(
    envelope: LedgerValue, bindings: [NativeComponentBindingPlacement],
    resourcePlacements: [NativeComponentResourcePlacement], requiresProgramConversion: Bool,
    manifestProjection: Bool
  ) {
    self.envelope = envelope
    self.bindings = bindings
    self.resourcePlacements = resourcePlacements
    self.requiresProgramConversion = requiresProgramConversion
    self.manifestProjection = manifestProjection
  }

  /// Invoke only in E/D's private render closure. Core values and final admitted paths are inputs;
  /// this operation never invokes a provider, writes a file or persists materialized bindings.
  package func stagedValue(
    bindings: RuntimeBindingValues, environment: RuntimeEnvironment,
    resourcePaths: [String: String], budget: NativeDocumentBudget,
    codexCommandShell: NativeProgramV1.CommandShell? = nil,
    cursorCommandShell: NativeProgramV1.CommandShell? = nil
  ) throws -> NativeValue {
    if requiresProgramConversion {
      let converted = try NativeProgramV1.stagedValue(
        envelope, bindings: bindings, environment: environment, resourcePaths: resourcePaths,
        budget: budget, codexCommandShell: codexCommandShell,
        cursorCommandShell: cursorCommandShell)
      if manifestProjection {
        guard case .object(let files) = converted,
          let manifest = files[".claude-plugin/plugin.json"]
        else {
          throw CoreError.invalidState("missing staged native plugin manifest")
        }
        return manifest
      }
      return converted
    }
    return try literalValue(envelope.object!["value"]!, budget: budget, depth: 0)
  }

  /// A key member with no program can be prepared without requesting any runtime values.
  package func referenceValue(budget: NativeDocumentBudget) throws -> NativeValue {
    guard !requiresProgramConversion else {
      let fields = envelope.object!
      throw NativeComponentIssue(
        request: .init(
          surface: NativeClientSurface(rawValue: fields["surface"]!.text!)!,
          scope: InstallScope(rawValue: fields["scope"]!.text!)!),
        kind: fields["kind"]!.text!, component: fields["name"]!.text!, field: ["value"],
        reason: .integrationRequired, detail: "private staged native program conversion is required"
      )
    }
    return try literalValue(envelope.object!["value"]!, budget: budget, depth: 0)
  }

  private func literalValue(_ value: LedgerValue, budget: NativeDocumentBudget, depth: Int) throws
    -> NativeValue
  {
    try budget.node(depth: depth)
    try budget.step()
    switch value.kind {
    case .string, .literal, .decimal:
      try budget.allocate(value.text!.utf8.count, stage: "native component string")
      try budget.step(value.text!.utf8.count)
      if value.kind == .decimal { return .decimal(value.text!) }
      return .string(value.text!)
    case .integer: return .integer(value.integer!)
    case .boolean: return .boolean(value.boolean!)
    case .null: return .null
    case .array:
      return .array(try value.array!.map { try literalValue($0, budget: budget, depth: depth + 1) })
    case .object:
      var result: [String: NativeValue] = [:]
      for (key, child) in value.object!.sorted(by: { $0.key < $1.key }) {
        try budget.allocate(key.utf8.count, stage: "native component key")
        try budget.step(key.utf8.count)
        result[key] = try literalValue(child, budget: budget, depth: depth + 1)
      }
      return .object(result)
    case .environment, .secret:
      throw CoreError.invalidState("symbolic value outside a native component program")
    }
  }
}
