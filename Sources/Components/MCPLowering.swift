import AgentsCore
import Foundation
import NativeDocuments

/// Slots are relative to one server value, never to an arbitrary physical document.
package enum MCPValueStep: Equatable, Sendable {
  case key(String)
  case index(Int)
}

package struct MCPBindingPlacement: Equatable, Sendable {
  package let path: [MCPValueStep]
  package let binding: RuntimeBinding
  /// A reference needs the downstream client's environment, not the applying process's value.
  package let reference: Bool
}

package struct MCPResourcePlacement: Equatable, Sendable {
  package let path: [MCPValueStep]
  package let resource: String
}

/// One logical contribution. E combines physical documents and establishes regional ownership.
package struct NativeMCPContribution {
  package let descriptor: NativeMCPDescriptor
  package let component: String
  package let name: String
  package let occurrences: [Int]
  /// Intended readers of this region. The complete producer targeting stays on its ledger owner.
  package let recipients: [AgentID]
  package let bindings: [MCPBindingPlacement]
  package let resourcePlacements: [MCPResourcePlacement]
  package let value: LedgerValue
  package let resources: [String]

  /// Produces reference-safe native values. Literal binding and final resource placement are
  /// deliberately deferred to E's staged render using Core's sole provider/publication policy.
  package func referenceValue() throws -> NativeValue {
    if let binding = bindings.first(where: { !$0.reference }) {
      throw issue(binding.path.fields, "staged binding through Core is required")
    }
    if let resource = resourcePlacements.first {
      throw issue(resource.path.fields, "E must place this frozen resource before staged rendering")
    }
    return try nativeValue(value)
  }

  package func lowering(
    id: String, artifact: String, platform: DeclarationPlatform, deployments: [String] = []
  ) -> LockedLowering {
    .init(
      id: id, format: descriptor.format, inputs: [component], resources: resources,
      deployments: deployments,
      layout: .init(object: [
        "artifact": .init(artifact), "surface": .init(descriptor.request.surface.rawValue),
        "scope": .init(descriptor.request.scope.rawValue),
        "component": .init(component), "name": .init(name), "value": value,
        "occurrences": .init(array: occurrences.map { .init(integer: $0) }),
        "recipients": LedgerPayload.strings(recipients.map(\.rawValue)),
        "knownReaders": LedgerPayload.strings(
          descriptor.knownReaders.map(\.rawValue).sorted()),
        "bindings": .init(
          array: bindings.map { placement in
            .init(object: [
              "path": MCPLayoutV1.path(placement.path),
              "binding": MCPLayoutV1.binding(placement.binding),
              "reference": .init(boolean: placement.reference),
            ])
          }),
        "resourcePlacements": .init(
          array: resourcePlacements.map { placement in
            .init(object: [
              "path": MCPLayoutV1.path(placement.path), "resource": .init(placement.resource),
            ])
          }),
      ]), platform: platform.rawValue, artifacts: [])
  }

  private func issue(_ field: [String], _ detail: String) -> NativeAdapterIssue {
    .init(
      request: descriptor.request, component: name, field: field,
      reason: .integrationRequired, detail: detail)
  }

  private func nativeValue(_ value: LedgerValue) throws -> NativeValue {
    switch value.kind {
    case .string, .literal: return .string(value.text!)
    case .integer: return .integer(value.integer!)
    case .decimal: return .decimal(value.text!)
    case .boolean: return .boolean(value.boolean!)
    case .null: return .null
    case .array: return .array(try value.array!.map(nativeValue))
    case .object: return .object(try value.object!.mapValues(nativeValue))
    case .environment, .secret:
      throw issue(["value"], "staged binding through Core is required")
    }
  }
}

package enum NativeMCPLowering {
  /// The frozen occurrence graph connects the linked identity to its exact durable component.
  /// Call once per requested recipient; this method never aggregates equal native values.
  package static func lower(
    _ linked: LinkedComponent, frozen: LedgerFreeze.Result, request: NativeMCPRequest
  ) throws -> NativeMCPContribution {
    let ledger = frozen.ledger
    let descriptor = try CapabilityRegistry.mcp(request, component: linked.key.name)
    func invalid(_ detail: String) -> NativeAdapterIssue {
      .init(
        request: request, component: linked.key.name, field: ["component"], reason: .invalid,
        detail: detail)
    }
    guard case .declaration(let declaration) = linked.payload,
      case .mcpServer(let name, let transport, _, _, let native) = declaration
    else {
      throw invalid("the linked component is not an MCP server")
    }
    let identity: (id: String, occurrences: [Int])
    do {
      identity = try FrozenNativeIdentity.match(
        linked, frozen: frozen,
        agent: request.surface.agent, scope: request.scope == .user ? .user : .project)
    } catch { throw invalid("linked component and frozen source identity do not match") }
    let id = identity.id
    let record = ledger.components[id]!
    let input = MCPInput(
      descriptor: descriptor, name: name, transport: transport,
      native: native[request.surface.agent.rawValue] ?? [:], resources: record.resources)
    let entry: MCPEntry
    switch request.surface {
    case .claudeCode: entry = try ClaudeAdapter.mcp(input)
    case .codexCLI: entry = try CodexAdapter.mcp(input)
    case .geminiCLI: entry = try GeminiAdapter.mcp(input)
    case .openCodeCLI: entry = try OpenCodeAdapter.mcp(input)
    case .cursorEditor, .cursorCLI, .cursorCloud: entry = try CursorAdapter.mcp(input)
    }
    return .init(
      descriptor: descriptor, component: id, name: name, occurrences: identity.occurrences,
      recipients: [request.surface.agent], bindings: entry.placements,
      resourcePlacements: entry.resourcePlacements, value: .init(object: entry.fields),
      resources: record.resources)
  }
}

struct MCPInput {
  let descriptor: NativeMCPDescriptor
  let name: String
  let transport: MCPTransportDeclaration
  let native: [String: NativeValue]
  let resources: [String]

  func issue(_ field: [String], _ reason: NativeAdapterIssue.Reason, _ detail: String)
    -> NativeAdapterIssue
  {
    .init(
      request: descriptor.request, component: name, field: field, reason: reason, detail: detail)
  }

  func rejectWorkingDirectory(_ run: ExecutableDeclaration) throws {
    guard run.workingDirectory == nil else {
      throw issue(
        ["transport", "workingDirectory"], .unverified,
        "this client contract does not establish an MCP working-directory field")
    }
  }

  func environmentName(_ name: String, field: [String]) throws {
    guard MCPReferenceSyntax.isName(name)
    else { throw issue(field, .invalid, "native environment reference needs a variable name") }
  }

  func literal(_ value: String, field: [String]) throws {
    try descriptor.validateLiteral(value, component: name, field: field)
  }
}

extension NativeMCPDescriptor {
  func validateLiteral(_ value: String, component: String, field: [String]) throws {
    func issue(_ reason: NativeAdapterIssue.Reason, _ detail: String) -> NativeAdapterIssue {
      .init(request: request, component: component, field: field, reason: reason, detail: detail)
    }
    guard !value.contains("\0") else { throw issue(.invalid, "NUL is not a native string") }
    if let first = field.first, ["headers", "http_headers"].contains(first),
      value.utf8.contains(13) || value.utf8.contains(10)
    {
      throw issue(.invalid, "native header value contains a line break")
    }
    let interpolates: Bool
    switch request.surface {
    case .claudeCode: interpolates = value.contains("${")
    case .geminiCLI:
      interpolates = value.range(of: #"\$(?:\w|\{)"#, options: .regularExpression) != nil
    case .openCodeCLI: interpolates = value.contains("{env:") || value.contains("{file:")
    case .cursorEditor, .cursorCLI, .cursorCloud: interpolates = value.contains("${")
    case .codexCLI: interpolates = false
    }
    guard !interpolates else {
      throw issue(
        .unverified, "literal preservation across native interpolation needs evidence")
    }
  }
}

enum MCPReferenceSyntax {
  case claude, gemini
  static func isName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard let first = bytes.first,
      first == 95 || (65...90).contains(first) || (97...122).contains(first)
    else { return false }
    return bytes.allSatisfy {
      $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
    }
  }

  func render(_ name: String) -> String {
    switch self {
    case .claude, .gemini: "${" + name + "}"
    }
  }
}

enum MCPNativeField {
  case boolean, falseOnly, string, strings, positiveNumber, positiveInteger, durationSeconds,
    environmentName
  case oneOf(Set<String>)
  case positiveIntegerObject(Set<String>)

  func accepts(_ value: NativeValue) -> Bool {
    switch (self, value) {
    case (.boolean, .boolean): true
    case (.falseOnly, .boolean(false)): true
    case (.string, .string), (.environmentName, .string): true
    case (.strings, .array(let array)):
      array.allSatisfy { if case .string = $0 { true } else { false } }
    case (.durationSeconds, .integer(let number)): number >= 0
    case (.durationSeconds, .decimal(let number)):
      // Rust Duration uses u64 seconds. The f64 immediately below 2^64 is 2048 seconds
      // smaller, so fractional nanosecond rounding cannot overflow an accepted f64.
      Double(number).map { $0 >= 0 && $0 < 0x1p64 } ?? false
    case (.positiveInteger, .integer(let number)): number > 0 && Double(exactly: number) != nil
    case (.positiveInteger, .decimal(let text)):
      Double(text).map { $0.isFinite && $0 > 0 && $0.rounded(.towardZero) == $0 } ?? false
    case (.positiveNumber, .integer(let number)): number > 0
    case (.positiveNumber, .decimal(let number)):
      Double(number).map { $0.isFinite && $0 > 0 } ?? false
    case (.oneOf(let allowed), .string(let text)): allowed.contains(text)
    case (.positiveIntegerObject(let allowed), .object(let object)):
      object.allSatisfy { key, value in
        allowed.contains(key) && { if case .integer(let i) = value { i > 0 } else { false } }()
      }
    default: false
    }
  }
}

struct MCPEntry {
  let input: MCPInput
  var fields: [String: LedgerValue] = [:]
  var placements: [MCPBindingPlacement] = []
  var resourcePlacements: [MCPResourcePlacement] = []
  init(_ input: MCPInput) { self.input = input }

  mutating func command(_ run: ExecutableDeclaration, argv: Bool = false) throws {
    guard !run.executable.isEmpty else {
      throw input.issue(["transport", "executable"], .invalid, "executable must not be empty")
    }
    let executable: LedgerValue
    if run.executable.contains("/") {
      guard let id = input.resources.first else {
        throw input.issue(
          ["transport", "executable"], .invalid, "missing frozen executable resource")
      }
      let path: [MCPValueStep] = argv ? [.key("command"), .index(0)] : [.key("command")]
      executable = .init(object: ["resource": .init(id)])
      resourcePlacements.append(.init(path: path, resource: id))
    } else {
      try input.literal(run.executable, field: ["transport", "executable"])
      executable = .init(run.executable)
    }
    for (index, argument) in run.arguments.enumerated() {
      try input.literal(argument, field: ["transport", "arguments", String(index)])
    }
    if argv {
      fields["command"] = .init(array: [executable] + run.arguments.map { .init($0) })
    } else {
      fields["command"] = executable
      fields["args"] = LedgerPayload.strings(run.arguments)
    }
  }

  mutating func workingDirectory(_ run: ExecutableDeclaration) throws {
    guard run.workingDirectory != nil else { return }
    let index = run.executable.contains("/") ? 1 : 0
    guard index < input.resources.count else {
      throw input.issue(
        ["transport", "workingDirectory"], .invalid, "missing frozen directory resource")
    }
    let id = input.resources[index]
    fields["cwd"] = .init(object: ["resource": .init(id)])
    resourcePlacements.append(.init(path: [.key("cwd")], resource: id))
  }

  mutating func url(_ url: String) throws {
    guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme),
      parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil
    else {
      throw input.issue(["transport", "url"], .invalid, "a credential-free HTTP URL is required")
    }
    try input.literal(url, field: ["transport", "url"])
    fields["url"] = .init(url)
  }

  mutating func bindings(
    _ bindings: [String: RuntimeBinding], field: String, reference: MCPReferenceSyntax?
  ) throws {
    if bindings.isEmpty { return }
    var values: [String: LedgerValue] = [:]
    for (key, value) in bindings.sorted(by: { $0.key < $1.key }) {
      values[key] = try binding(value, path: [.key(field), .key(key)], reference: reference)
    }
    fields[field] = .init(object: values)
  }

  mutating func binding(
    _ binding: RuntimeBinding, path: [MCPValueStep], reference: MCPReferenceSyntax?
  ) throws -> LedgerValue {
    if input.descriptor.request.surface == .openCodeCLI, case .key(let key) = path.last {
      try input.literal(key, field: path.fields + ["key"])
    }
    switch binding {
    case .literal(let text):
      try input.literal(text, field: path.fields)
      return .init(text)
    case .environment(let name):
      try input.environmentName(name, field: path.fields)
      placements.append(.init(path: path, binding: binding, reference: reference != nil))
      return reference.map { .init($0.render(name)) } ?? .init(name, kind: .environment)
    case .secret(let name):
      placements.append(.init(path: path, binding: binding, reference: false))
      return .init(name, kind: .secret)
    }
  }

  mutating func nativeFields(_ rules: [String: MCPNativeField]) throws {
    for (key, value) in input.native.sorted(by: { $0.key < $1.key }) {
      let path = ["native", input.descriptor.request.surface.agent.rawValue, key]
      guard fields[key] == nil else {
        throw input.issue(path, .invalid, "native field overlaps the portable MCP mapping")
      }
      guard let rule = rules[key] else {
        throw input.issue(path, .unverified, "no verified field mapping in this native schema")
      }
      guard rule.accepts(value) else {
        throw input.issue(path, .invalid, "value is outside the verified native field profile")
      }
      if case .environmentName = rule, case .string(let name) = value {
        try input.environmentName(name, field: path)
        placements.append(.init(path: [.key(key)], binding: .environment(name), reference: true))
      } else {
        try checkStrings(value, path: path)
      }
      fields[key] = ledgerValue(value)
    }
  }

  private func checkStrings(_ value: NativeValue, path: [String]) throws {
    switch value {
    case .string(let text): try input.literal(text, field: path)
    case .array(let array):
      for (i, value) in array.enumerated() { try checkStrings(value, path: path + [String(i)]) }
    case .object(let object):
      for (key, value) in object.sorted(by: { $0.key < $1.key }) {
        try checkStrings(value, path: path + [key])
      }
    default: break
    }
  }

  private func ledgerValue(_ value: NativeValue) -> LedgerValue {
    switch value {
    case .string(let text): .init(text)
    case .integer(let number): .init(integer: number)
    case .decimal(let number): .init(number, kind: .decimal)
    case .boolean(let boolean): .init(boolean: boolean)
    case .null: .init()
    case .array(let array): .init(array: array.map(ledgerValue))
    case .object(let object): .init(object: object.mapValues(ledgerValue))
    }
  }
}

extension Array where Element == MCPValueStep {
  var fields: [String] {
    map { step in
      switch step {
      case .key(let key): key
      case .index(let index): String(index)
      }
    }
  }
}
