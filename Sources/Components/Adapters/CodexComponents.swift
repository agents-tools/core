import AgentsCore

extension CodexAdapter {
  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    switch input.record.kind {
    case "subagent":
      _ = try input.checkedNative([:])
      guard input.fields["tools"] == nil else {
        throw input.issue(
          ["tools"], .unsupported, "role overrides do not represent a portable tool allowlist")
      }
      let name = try input.relativeName()
      let description = try input.text("description")
      guard !NativeComponentText.isBlank(description, rust: true) else {
        throw input.issue(["description"], .invalid, "native role description must not be blank")
      }
      guard NativeComponentText.isUntrimmed(description, rust: true) else {
        throw input.issue(["description"], .unsupported, "native role descriptions are trimmed")
      }
      let prompt = try input.prompt()
      guard !NativeComponentText.isBlank(prompt, rust: true) else {
        throw input.issue(["prompt"], .invalid, "native role instructions must not be blank")
      }
      var lines = ["developer_instructions = " + (try input.quoted(prompt))]
      if let model = input.fields["model"]?.text {
        lines.append("model = " + (try input.quoted(model)))
      }
      lines.append("")
      let file = input.envelope(
        route: .codexAgent, path: name + ".toml",
        selection: "file", value: .init(try input.joined(lines)))
      let registration = input.envelope(
        route: .codexConfig, keys: ["agents", name],
        value: .init(object: [
          "description": .init(description), "config_file": .init("./agents/" + name + ".toml"),
        ]))
      return try input.emitted(lowering, .init(array: [file, registration]))
    case "hook": return try NativeHookLayoutV1.render(lowering, input)
    default:
      throw input.issue(["kind"], .invalid, "component does not match this concrete native profile")
    }
  }
}
