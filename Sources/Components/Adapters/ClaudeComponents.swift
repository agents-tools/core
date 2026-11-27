import AgentsCore
import Foundation

extension ClaudeAdapter {
  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    switch input.record.kind {
    case "command":
      try input.noParameters()
      var fields = try input.checkedNative(
        NativeComponentFieldsV1.markdownRules(.claudeCode, kind: "command"))
      for key in ["agent", "background"]
      where fields[key] != nil && fields["context"]?.text != "fork" {
        throw input.issue(
          ["native", "claude-code", key], .unsupported,
          "this native command field applies only with context fork")
      }
      fields["description"] = .init(try input.text("description"))
      let name = try input.relativeName()
      return try input.emitted(
        lowering,
        input.envelope(
          route: .claudeCommand, path: name + ".md", selection: "file",
          value: .init(try input.frontmatter(fields, body: input.prompt()))))
    case "subagent":
      if input.inPlugin, input.native["permissionMode"] != nil {
        throw input.issue(
          ["native", "claude-code", "permissionMode"], .unsupported,
          "native plugin agents ignore this permission field")
      }
      var fields = try input.checkedNative(
        NativeComponentFieldsV1.markdownRules(.claudeCode, kind: "subagent"))
      let name = try input.filename()
      guard name.count <= 256, !name.contains(":") else {
        throw input.issue(
          ["name"], .invalid, "native agent name is limited to 256 characters and excludes colon")
      }
      let description = try input.text("description")
      guard !description.isEmpty else {
        throw input.issue(["description"], .invalid, "native agent description is required")
      }
      fields["name"] = .init(name)
      fields["description"] = .init(description)
      fields["model"] = input.fields["model"]
      fields["tools"] = input.fields["tools"]
      return try input.emitted(
        lowering,
        input.envelope(
          route: .claudeAgent, path: name + ".md", selection: "file",
          value: .init(try input.frontmatter(fields, body: input.prompt()))))
    case "hook": return try NativeDocumentedHooksV1.claude(lowering, input)
    case "permissions":
      guard input.fields["rules"]?.array?.isEmpty ?? true else {
        throw input.issue(
          ["rules"], .unverified,
          "ordered last-match portable policy is not equivalent to native deny/ask/allow precedence; use explicit native categories"
        )
      }
      let fields = try input.checkedNative([
        "allow": .strings, "ask": .strings, "deny": .strings,
        "defaultMode": .oneOf([
          "default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan",
        ]),
      ])
      return try input.emitted(
        lowering,
        input.envelope(
          route: .claudeSettings, keys: ["permissions"], selection: "nativePolicy",
          value: .init(object: fields)))
    case "lspServer": return try NativeLSPLayoutV1.claude(lowering, input)
    default:
      throw input.issue(["kind"], .invalid, "component does not match this concrete native profile")
    }
  }
}
