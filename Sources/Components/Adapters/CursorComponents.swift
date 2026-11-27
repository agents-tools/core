import AgentsCore

extension CursorAdapter {
  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    switch input.record.kind {
    case "command":
      _ = try input.checkedNative([:])
      try input.noParameters()
      // The native file is a plain prompt; its schema has no description field.
      guard try input.text("description").isEmpty else {
        throw input.issue(
          ["description"], .unsupported, "plain Markdown command files have no description field")
      }
      let name = try input.filename()
      return try input.emitted(
        lowering,
        input.envelope(
          route: .cursorCommand,
          path: name + ".md", selection: "file", value: .init(try input.prompt())))
    case "subagent":
      guard input.fields["tools"] == nil else {
        throw input.issue(
          ["tools"], .unverified,
          "the documented subagent schema does not establish a tool allowlist")
      }
      var fields = try input.checkedNative(
        NativeComponentFieldsV1.markdownRules(.cursorEditor, kind: "subagent"))
      let name = try input.filename()
      fields["name"] = .init(name)
      fields["description"] = .init(try input.text("description"))
      fields["model"] = input.fields["model"]
      return try input.emitted(
        lowering,
        input.envelope(
          route: .cursorAgent,
          path: name + ".md", selection: "file",
          value: .init(try input.frontmatter(fields, body: input.prompt()))))
    case "hook":
      return try NativeDocumentedHooksV1.cursor(lowering, input)
    case "ignore":
      _ = try input.checkedNative([:])
      return try input.emitted(
        lowering,
        input.envelope(
          route: .cursorIgnore,
          selection: "managedIgnore",
          value: LedgerPayload.strings(try NativeIgnoreLayoutV1.patterns(input))))
    default:
      throw input.issue(["kind"], .invalid, "component does not match this concrete native profile")
    }
  }
}
