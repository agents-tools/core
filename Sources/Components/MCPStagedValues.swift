import AgentsCore
import Foundation
import NativeDocuments

extension NativeMCPContribution {
  /// Call only in E/D's private render closure. The caller admits final registered resource
  /// paths and supplies its immutable environment snapshot; this method never invokes a provider.
  /// The returned value is ephemeral and must not enter a lowering, ledger or public report.
  package func stagedValue(
    bindings supplied: RuntimeBindingValues, environment: RuntimeEnvironment,
    resourcePaths: [String: String], budget: NativeDocumentBudget
  ) throws -> NativeValue {
    func failure(_ path: [MCPValueStep], _ detail: String) -> NativeAdapterIssue {
      .init(
        request: descriptor.request, component: name, field: path.fields,
        reason: .invalid, detail: detail)
    }
    func literal(_ text: String, at path: [MCPValueStep]) throws -> NativeValue {
      try budget.allocate(text.utf8.count, stage: "staged native string")
      try budget.step(text.utf8.count)
      try descriptor.validateLiteral(text, component: name, field: path.fields)
      if case .key(let field) = path.first,
        ["headers", "http_headers"].contains(field),
        text.utf8.contains(13) || text.utf8.contains(10)
      {
        throw failure(path, "native header value contains a line break")
      }
      return .string(text)
    }
    func convert(_ value: LedgerValue, path: [MCPValueStep], depth: Int) throws -> NativeValue {
      try budget.node(depth: depth)
      try budget.step(bindings.count + resourcePlacements.count + 1)
      if let placement = bindings.first(where: { $0.path == path }), !placement.reference {
        let text: String
        switch placement.binding {
        case .environment(let variable):
          guard let found = environment.environment[variable] else {
            throw failure(path, "required native environment value is unavailable")
          }
          text = found
        case .secret(let binding):
          let bytes: Data
          do { bytes = try supplied.value(for: binding) } catch {
            throw failure(path, "required native binding is unavailable")
          }
          try budget.allocate(bytes.count, stage: "staged native UTF8")
          try budget.step(bytes.count)
          guard let decoded = String(data: bytes, encoding: .utf8) else {
            throw failure(path, "native binding is not UTF8")
          }
          text = decoded
        case .literal(let found): text = found
        }
        return try literal(text, at: path)
      }
      if let placement = resourcePlacements.first(where: { $0.path == path }) {
        guard let final = resourcePaths[placement.resource], !final.isEmpty else {
          throw failure(path, "final registered resource placement is required")
        }
        return try literal(final, at: path)
      }
      switch value.kind {
      case .string, .literal:
        try budget.allocate(value.text!.utf8.count, stage: "native string")
        return .string(value.text!)
      case .integer: return .integer(value.integer!)
      case .decimal: return .decimal(value.text!)
      case .boolean: return .boolean(value.boolean!)
      case .null: return .null
      case .array:
        try budget.allocate(value.array!.count, stage: "native array")
        return .array(
          try value.array!.enumerated().map { index, value in
            try convert(value, path: path + [.index(index)], depth: depth + 1)
          })
      case .object:
        var fields: [String: NativeValue] = [:]
        for (key, value) in value.object!.sorted(by: { $0.key < $1.key }) {
          try budget.allocate(key.utf8.count, stage: "native key")
          fields[key] = try convert(value, path: path + [.key(key)], depth: depth + 1)
        }
        return .object(fields)
      case .environment, .secret:
        throw failure(path, "native symbolic slot has no binding placement")
      }
    }
    return try convert(value, path: [], depth: 0)
  }
}
