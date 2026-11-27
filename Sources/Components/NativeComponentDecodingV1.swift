import AgentsCore
import Foundation
import NativeDocuments

extension NativeComponentLayoutsV1 {
  /// Decode exactly one sealed lowering's replay artifacts. Call inside LedgerReplay's closure:
  /// the ledger has passed Core admission, bundle trees are borrowed there, and replay verifies
  /// source bytes and executable bits. This is not a second whole-ledger admission operation.
  /// Sealing authenticates file bodies without introducing another native file parser in E.
  package static func contribution(
    _ lowering: LockedLowering, ledger: ResolvedLedger, artifacts: [ReplayedArtifact],
    limits: LedgerLimits
  ) throws -> NativeComponentContribution {
    guard ledger.lowerings.filter({ $0.id == lowering.id }) == [lowering],
      !lowering.artifacts.isEmpty, artifacts.count == lowering.artifacts.count,
      let component = lowering.inputs.first, ledger.components[component]?.payload.object != nil
    else { throw CoreError.invalidState("unsealed or mismatched native component lowering") }
    let input = try input(lowering, ledger: ledger, limits: limits)
    let decoder = NativeComponentDecoderV1(input: input)
    try decoder.admit(lowering.layout)
    if ["hook", "lspServer"].contains(input.record.kind) {
      try NativeProgramV1.validateFrozenRun(input)
    }
    guard artifacts.first?.kind == .ownedValues,
      artifacts.first?.name == lowering.id,
      (input.record.kind == "plugin" && artifacts.count == 2
        && artifacts[1].kind == .tree && artifacts[1].name == lowering.id + "/bundle")
        || (input.record.kind != "plugin" && artifacts.count == 1)
    else { throw decoder.invalid() }
    for artifact in artifacts {
      guard artifact.location == nil else { throw decoder.invalid() }
      if let value = artifact.values { try decoder.admit(value) }
    }
    guard try artifacts.map({ try $0.digest(limits: limits) }) == lowering.artifacts,
      artifacts[0].name == lowering.id, artifacts[0].kind == .ownedValues,
      let envelope = artifacts[0].values
    else { throw decoder.invalid() }
    let envelopes: [LedgerValue]
    if input.request.surface == .codexCLI, input.record.kind == "subagent" {
      guard let pair = envelope.array, pair.count == 2 else { throw decoder.invalid() }
      envelopes = pair
    } else {
      guard envelope.kind == .object else { throw decoder.invalid() }
      envelopes = [envelope]
    }
    let outputs = try envelopes.enumerated().map {
      try decoder.output($0.element, index: $0.offset)
    }
    // Reuse the production semantic validators for all programmable regional outputs. No native
    // event/field tables are copied into the decoder or importer. File bodies are pinned by seal.
    if ["hook", "permissions", "lspServer"].contains(input.record.kind) {
      let expected: [ReplayedArtifact]
      switch input.request.surface {
      case .antigravity: expected = try AntigravityAdapter.components(lowering, input)
      case .claudeCode: expected = try ClaudeAdapter.components(lowering, input)
      case .codexCLI: expected = try CodexAdapter.components(lowering, input)
      case .geminiCLI: expected = try GeminiAdapter.components(lowering, input)
      case .openCodeCLI: expected = try OpenCodeAdapter.components(lowering, input)
      case .cursorEditor, .cursorCLI, .cursorCloud:
        expected = try CursorAdapter.components(lowering, input)
      }
      guard expected.count == 1, expected[0].values == envelope else { throw decoder.invalid() }
    }
    if input.record.kind == "plugin" {
      guard artifacts.count == 2, artifacts[1].name == lowering.id + "/bundle",
        artifacts[1].kind == .tree, artifacts[1].tree != nil,
        artifacts[1].bytes == nil, artifacts[1].values == nil
      else { throw decoder.invalid() }
      let resource = ledger.resources[lowering.resources[0]]!
      let entries = resource.entries.map { entry in
        var entry = entry
        entry.object = nil
        return entry
      }
      guard
        lowering.artifacts[1].hash
          == (try ResolvedLedgerCodec.digest(
            NativeComponentTreeDigestV1(content: resource.hash, entries: entries)))
      else {
        throw decoder.invalid(["resources"])
      }
    } else {
      guard artifacts.count == 1 else { throw decoder.invalid() }
    }
    let kind = DeclaredComponentKind(rawValue: input.record.kind)!
    return .init(
      format: lowering.format, request: input.request, component: input.component, kind: kind,
      name: input.record.name, occurrences: input.occurrences,
      recipients: [input.request.surface.agent],
      knownReaders: CapabilityRegistry.componentReaders(input.request, kind: kind)
        .sorted { $0.rawValue < $1.rawValue },
      resources: lowering.resources.reduce(into: [:]) { $0[$1] = ledger.resources[$1]! },
      outputs: outputs)
  }
}

private struct NativeComponentTreeDigestV1: Encodable {
  let content: String
  let entries: [LedgerEntry]
}

private struct NativeComponentDecoderV1 {
  let input: ComponentRenderInput
  func invalid(_ field: [String] = ["output"]) -> NativeComponentIssue {
    input.issue(field, .invalid, "invalid sealed native component contribution")
  }

  /// Charge decoded values before validation, equality, hashing, copying or staging.
  func admit(_ value: LedgerValue, depth: Int = 0) throws {
    try input.budget.node(depth: depth)
    try input.budget.step()
    if let text = value.text {
      try input.budget.allocate(text.utf8.count, stage: "native contribution string")
      try input.budget.step(text.utf8.count)
      guard !text.utf8.contains(0) else { throw invalid() }
      if value.kind == .decimal,
        text.range(
          of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
          options: .regularExpression) == nil
      {
        throw invalid(["value"])
      }
    }
    for child in value.array ?? [] { try admit(child, depth: depth + 1) }
    for (key, child) in value.object ?? [:] {
      try input.budget.allocate(key.utf8.count, stage: "native contribution key")
      try input.budget.step(key.utf8.count)
      guard !key.utf8.contains(0) else { throw invalid() }
      try admit(child, depth: depth + 1)
    }
    // Children have already been bounded; validate this node's tag without recursive validation.
    var node = value
    if node.array != nil { node.array = [] }
    if node.object != nil { node.object = [:] }
    try node.validate()
  }

  func text(_ value: LedgerValue?) throws -> String {
    guard value?.kind == .string, let text = value?.text else { throw invalid() }
    return text
  }
  func strings(_ value: LedgerValue?) throws -> [String] {
    guard let items = value?.array else { throw invalid() }
    return try items.map { try text($0) }
  }

  func output(_ envelope: LedgerValue, index: Int) throws -> NativeComponentOutput {
    let kind = DeclaredComponentKind(rawValue: input.record.kind)!
    guard let fields = envelope.object,
      Set(fields.keys).subtracting(["path", "rootRequirements"]) == [
        "route", "surface", "scope", "kind", "name", "component", "occurrences",
        "recipients", "knownReaders", "keys", "selection", "value",
      ],
      fields["surface"] == .init(input.request.surface.rawValue),
      fields["scope"] == .init(input.request.scope.rawValue),
      fields["kind"] == .init(input.record.kind), fields["name"] == .init(input.record.name),
      fields["component"] == .init(input.component),
      fields["occurrences"] == .init(array: input.occurrences.map { .init(integer: $0) }),
      fields["recipients"] == LedgerPayload.strings([input.request.surface.agent.rawValue]),
      fields["knownReaders"]
        == LedgerPayload.strings(
          CapabilityRegistry.componentReaders(input.request, kind: kind).map(\.rawValue).sorted()),
      let route = NativeComponentRoute(rawValue: try text(fields["route"])),
      let value = fields["value"]
    else { throw invalid(["identity"]) }
    let keys = try strings(fields["keys"])
    let selection = try text(fields["selection"])
    let path = try fields["path"].map { try text($0) }
    if let path {
      do {
        guard path != ".", try PathSafety.sanitizeSubpath(path) == path else {
          throw invalid(["path"])
        }
      } catch { throw invalid(["path"]) }
    }
    if selection != "cursorHook", fields["rootRequirements"] != nil { throw invalid() }
    let content: NativeComponentOutput.Content
    switch selection {
    case "file":
      guard keys.isEmpty, let path, [.command, .subagent].contains(kind), index == 0,
        value.kind == .string
      else { throw invalid() }
      let expectedRoute: NativeComponentRoute
      let suffix: String
      switch (input.request.surface, kind) {
      case (.claudeCode, .command):
        expectedRoute = .claudeCommand
        suffix = ".md"
      case (.claudeCode, .subagent):
        expectedRoute = .claudeAgent
        suffix = ".md"
      case (.geminiCLI, .command):
        expectedRoute = .geminiCommand
        suffix = ".toml"
      case (.geminiCLI, .subagent):
        expectedRoute = .geminiAgent
        suffix = ".md"
      case (.codexCLI, .subagent):
        expectedRoute = .codexAgent
        suffix = ".toml"
      case (.cursorEditor, .command):
        expectedRoute = .cursorCommand
        suffix = ".md"
      case (.cursorEditor, .subagent), (.cursorCLI, .subagent):
        expectedRoute = .cursorAgent
        suffix = ".md"
      default: throw invalid(["route"])
      }
      let nested =
        (input.request.surface == .claudeCode && kind == .command)
        || (input.request.surface == .geminiCLI && kind == .command)
        || (input.request.surface == .codexCLI && kind == .subagent)
      let name = try nested ? input.relativeName() : input.filename()
      guard route == expectedRoute, path == name + suffix else { throw invalid(["path"]) }
      let text = try text(value)
      try input.budget.allocate(text.utf8.count, stage: "native contribution file")
      content = .file(path: path, bytes: Data(text.utf8))
    case "key", "lsp":
      guard path == nil, value.kind == .object else { throw invalid() }
      let member: NativeComponentMember
      switch (input.request.surface, kind, selection) {
      case (.openCodeCLI, .command, "key"):
        member = .openCodeCommand(input.record.name)
        guard value.object?["template"]?.kind == .string,
          value.object?["description"]?.kind == .string
        else { throw invalid() }
      case (.openCodeCLI, .subagent, "key"):
        member = .openCodeAgent(input.record.name)
        guard value.object?["system"]?.kind == .string,
          value.object?["description"]?.kind == .string,
          value.object?["mode"] == .init("subagent")
        else { throw invalid() }
      case (.openCodeCLI, .lspServer, "lsp"): member = .openCodeLSP(input.record.name)
      case (.codexCLI, .subagent, "key"):
        member = .codexAgent(input.record.name)
        guard index == 1,
          value
            == .init(object: [
              "description": input.fields["description"]!,
              "config_file": .init("./agents/" + input.record.name + ".toml"),
            ])
        else { throw invalid() }
      default: throw invalid(["route"])
      }
      guard keys == member.keys,
        route == (input.request.surface == .codexCLI ? .codexConfig : .openCodeConfig)
      else { throw invalid(["route"]) }
      if input.request.surface == .openCodeCLI, kind == .command || kind == .subagent {
        let body = try text(value.object?[kind == .command ? "template" : "system"])
        guard value == .init(object: try OpenCodeAdapter.definition(input, prompt: body)) else {
          throw invalid(["value"])
        }
      }
      content = .member(member, try template(envelope, selection: selection))
    case "antigravityHook":
      guard kind == .hook, input.request.surface == .antigravity, route == .antigravityHooks,
        path == nil, keys == [input.record.name], !input.record.name.isEmpty
      else { throw invalid() }
      content = .member(
        .antigravityHook(input.record.name), try template(envelope, selection: selection))
    case "hookGroup", "cursorHook":
      guard kind == .hook, path == nil, keys.count == 2, keys[0] == "hooks",
        keys[1] == input.fields["event"]?.object?["native"]?.text
      else { throw invalid() }
      let expected: NativeComponentRoute
      switch input.request.surface {
      case .claudeCode: expected = .claudeSettings
      case .codexCLI: expected = .codexHooks
      case .geminiCLI: expected = .geminiSettings
      case .cursorEditor, .cursorCLI, .cursorCloud: expected = .cursorHooks
      default: throw invalid(["route"])
      }
      guard route == expected, (selection == "cursorHook") == (expected == .cursorHooks) else {
        throw invalid(["route"])
      }
      if selection == "cursorHook" {
        guard fields["rootRequirements"] == .init(object: ["version": .init(integer: 1)]) else {
          throw invalid()
        }
      }
      content = .hook(
        .init(
          event: keys[1], layout: selection == "cursorHook" ? .cursorVersion1 : .group,
          value: try template(envelope, selection: selection)))
    case "orderedAppend":
      guard kind == .permissions, input.request.surface == .openCodeCLI,
        route == .openCodeConfig, path == nil, keys == ["permissions"], let rules = value.array
      else { throw invalid() }
      content = .orderedPermissions(
        try rules.map { rule in
          guard let fields = rule.object, Set(fields.keys) == ["action", "resource", "effect"],
            let effect = NativeComponentPermission.Effect(rawValue: try text(fields["effect"]))
          else { throw invalid() }
          return .init(
            tool: try text(fields["action"]), resource: try text(fields["resource"]), effect: effect
          )
        })
    case "nativePolicy":
      guard kind == .permissions, input.request.surface == .claudeCode,
        route == .claudeSettings, path == nil, keys == ["permissions"], let policy = value.object,
        Set(policy.keys).isSubset(of: ["allow", "ask", "deny", "defaultMode"])
      else { throw invalid() }
      content = .claudePermissions(
        .init(
          allow: try policy["allow"].map { try strings($0) },
          ask: try policy["ask"].map { try strings($0) },
          deny: try policy["deny"].map { try strings($0) },
          defaultMode: try policy["defaultMode"].map { try text($0) }))
    case "managedIgnore":
      guard kind == .ignore, path == nil, keys.isEmpty,
        (input.request.surface == .geminiCLI && route == .geminiIgnore)
          || (input.request.surface == .cursorEditor && route == .cursorIgnore),
        value == LedgerPayload.strings(try NativeIgnoreLayoutV1.patterns(input))
      else { throw invalid() }
      content = .ignore(try strings(value))
    case "generatedPlugin":
      guard kind == .lspServer, input.request.surface == .claudeCode,
        route == .claudeSkillPlugin, path == input.record.name, keys.isEmpty,
        Set(value.object?.keys.map { $0 } ?? []) == [".claude-plugin/plugin.json"]
      else { throw invalid() }
      _ = try input.filename()
      content = .generatedLSPPlugin(
        directory: input.record.name, manifestPath: ".claude-plugin/plugin.json",
        manifest: try template(envelope, selection: selection))
    case "nativePlugin":
      guard kind == .plugin, input.fields["mode"] == .init("native"),
        path == input.record.name, keys.isEmpty, input.record.resources.count == 1,
        let resource = input.record.resources.first,
        let frozen = input.ledger.resources[resource],
        input.record.recipients == [input.request.surface.agent]
      else { throw invalid() }
      let manifest: String
      switch (input.request.surface, input.request.scope, route) {
      case (.claudeCode, _, .claudeSkillPlugin): manifest = ".claude-plugin/plugin.json"
      case (.cursorEditor, .user, .cursorLocalPlugin): manifest = ".cursor-plugin/plugin.json"
      case (.geminiCLI, .user, .geminiExtension): manifest = "gemini-extension.json"
      default: throw invalid(["route"])
      }
      guard frozen.entries.contains(where: { $0.path == manifest && $0.kind == .file }),
        value == .init(object: ["resource": .init(resource), "manifest": .init(manifest)])
      else { throw invalid(["resources"]) }
      _ = try input.filename()
      content = .nativePlugin(directory: input.record.name, resource: resource, manifest: manifest)
    default: throw invalid(["selection"])
    }
    return .init(route: route, content: content)
  }

  func template(_ envelope: LedgerValue, selection: String) throws -> NativeComponentValue {
    let value = envelope.object!["value"]!
    var bindings: [NativeComponentBindingPlacement] = []
    var resources: [NativeComponentResourcePlacement] = []
    func string(_ value: LedgerValue, slot: NativeComponentSlot, resource: Bool = false) throws {
      switch value.kind {
      case .string, .literal: break
      case .environment:
        guard let name = value.text, !name.isEmpty else {
          throw invalid(["bindings"])
        }
        bindings.append(.init(slot: slot, binding: .environment(name)))
      case .secret:
        guard let name = value.text, !name.isEmpty else { throw invalid(["bindings"]) }
        bindings.append(.init(slot: slot, binding: .secret(name)))
      case .object where resource:
        guard Set(value.object!.keys) == ["resource"],
          let id = value.object?["resource"], id.kind == .string,
          input.record.resources.contains(id.text!), input.ledger.resources[id.text!] != nil
        else { throw invalid(["resources"]) }
        resources.append(.init(slot: slot, resource: id.text!))
      default: throw invalid(["bindings"])
      }
    }
    func environment(_ value: LedgerValue?) throws {
      guard let value else { return }
      guard let fields = value.object else { throw invalid(["bindings"]) }
      for (key, item) in fields.sorted(by: { $0.key < $1.key }) {
        guard !key.isEmpty, !key.contains("="),
          !["hookGroup", "cursorHook", "antigravityHook"].contains(selection)
            || MCPReferenceSyntax.isName(key)
        else { throw invalid(["bindings"]) }
        try string(item, slot: .environment(key))
      }
    }
    let program: [String: LedgerValue]?
    if selection == "hookGroup" {
      program = value.object?["hooks"]?.array?.first?.object?["command"]?.object?["program"]?.object
    } else if selection == "cursorHook" {
      program = value.object?["command"]?.object?["program"]?.object
    } else if selection == "antigravityHook", let path = AntigravityAdapter.commandPath(in: value) {
      let command = path.reduce(Optional(value)) { current, step in
        step == "0" ? current?.array?.first : current?.object?[step]
      }
      program = command?.object?["program"]?.object
    } else {
      program = nil
    }
    if ["hookGroup", "cursorHook", "antigravityHook"].contains(selection) {
      guard let program,
        Set(program.keys).isSubset(of: [
          "executable", "arguments", "environment", "workingDirectory",
        ]),
        let executable = program["executable"], let arguments = program["arguments"]?.array
      else { throw invalid(["program"]) }
      try string(executable, slot: .executable, resource: true)
      for (index, item) in arguments.enumerated() { try string(item, slot: .argument(index)) }
      try environment(program["environment"])
      if let cwd = program["workingDirectory"] {
        guard cwd.kind == .object else { throw invalid(["resources"]) }
        try string(cwd, slot: .workingDirectory, resource: true)
      }
    } else if selection == "lsp" || selection == "generatedPlugin" {
      let config: [String: LedgerValue]?
      if selection == "generatedPlugin" {
        config =
          value.object?[".claude-plugin/plugin.json"]?.object?["lspServers"]?.object?[
            input.record.name]?.object
      } else {
        config = value.object
      }
      guard let config else { throw invalid(["program"]) }
      if selection == "lsp" {
        guard let command = config["command"]?.array, let executable = command.first else {
          throw invalid(["program"])
        }
        try string(executable, slot: .executable, resource: true)
        for (index, item) in command.dropFirst().enumerated() {
          try string(item, slot: .argument(index))
        }
      } else {
        guard let executable = config["command"] else { throw invalid(["program"]) }
        try string(executable, slot: .executable, resource: true)
      }
      try environment(config["env"])
    } else {
      func literal(_ value: LedgerValue) throws {
        guard value.kind != .environment, value.kind != .secret else { throw invalid(["bindings"]) }
        for item in value.array ?? [] { try literal(item) }
        for item in value.object?.values ?? [:].values { try literal(item) }
      }
      try literal(value)
    }
    func symbolicCount(_ value: LedgerValue) -> Int {
      if value.kind == .environment || value.kind == .secret { return 1 }
      return (value.array ?? []).reduce(0) { $0 + symbolicCount($1) }
        + (value.object?.values ?? [:].values).reduce(0) { $0 + symbolicCount($1) }
    }
    guard symbolicCount(value) == bindings.count else { throw invalid(["bindings"]) }
    return .init(
      envelope: envelope, bindings: bindings, resourcePlacements: resources,
      requiresProgramConversion: [
        "hookGroup", "cursorHook", "antigravityHook", "lsp", "generatedPlugin",
      ].contains(
        selection), manifestProjection: selection == "generatedPlugin")
  }
}
