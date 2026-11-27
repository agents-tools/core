import AgentsCore
import Foundation

extension OpenCodeAdapter {
  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    switch input.record.kind {
    case "command", "subagent":
      let fields = try definition(input, prompt: input.prompt())
      return try input.emitted(
        lowering,
        input.envelope(
          route: .openCodeConfig,
          keys: [input.record.kind == "command" ? "commands" : "agents", input.record.name],
          value: .init(object: fields)))
    case "permissions":
      _ = try input.checkedNative([:])
      let rules = try (input.fields["rules"]?.array ?? []).enumerated().map {
        index, rule -> LedgerValue in
        guard let fields = rule.object, let action = fields["action"]?.text,
          let operation = fields["operation"], let pattern = fields["pattern"]?.text
        else {
          throw input.issue(["rules", String(index)], .invalid, "invalid frozen permission rule")
        }
        guard let name = operation.object?["tool"]?.text else {
          throw input.issue(
            ["rules", String(index), "operation"], .unverified,
            "portable read/write/execute resource namespaces are not proved equivalent to native tool actions"
          )
        }
        try input.literal(name, field: ["rules", String(index), "operation"])
        try input.literal(pattern, field: ["rules", String(index), "pattern"])
        return .init(object: [
          "action": .init(name), "resource": .init(pattern), "effect": .init(action),
        ])
      }
      return try input.emitted(
        lowering,
        input.envelope(
          route: .openCodeConfig,
          keys: ["permissions"], selection: "orderedAppend", value: .init(array: rules)))
    case "lspServer": return try NativeLSPLayoutV1.openCode(lowering, input)
    default:
      throw input.issue(["kind"], .invalid, "component does not match this concrete native profile")
    }
  }

  /// Renderer and contribution decoder share the definition fields. A file-backed prompt body
  /// reaches the decoder through its sealed artifact; no source path is rediscovered there.
  static func definition(_ input: ComponentRenderInput, prompt: String) throws -> [String:
    LedgerValue]
  {
    try input.literal(prompt, field: ["prompt"], prompt: input.record.kind == "command")
    if input.record.kind == "command" {
      try input.noParameters()
      var fields = try input.checkedNative(["agent": .string, "subagent": .boolean])
      fields["description"] = .init(try input.text("description"))
      fields["template"] = .init(prompt)
      return fields
    }
    guard input.record.kind == "subagent" else {
      throw input.issue(["kind"], .invalid, "component is not an OpenCode definition")
    }
    guard input.fields["tools"] == nil else {
      throw input.issue(
        ["tools"], .unsupported,
        "OpenCode agent schema has permissions rather than a tool allowlist")
    }
    var fields = try input.checkedNative(["hidden": .boolean, "disabled": .boolean])
    fields["system"] = .init(prompt)
    fields["description"] = .init(try input.text("description"))
    fields["mode"] = .init("subagent")
    if let model = input.fields["model"]?.text {
      guard model.range(of: #"^[^/#]+/[^#]+(?:#[^#]+)?$"#, options: .regularExpression) != nil
      else {
        throw input.issue(
          ["model"], .invalid, "native model selection requires provider/model syntax")
      }
      try input.literal(model, field: ["model"])
      fields["model"] = .init(model)
    }
    return fields
  }

}
