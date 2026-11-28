import AgentsCore

extension GeminiAdapter {
  static func components(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    switch input.record.kind {
    case "command":
      _ = try input.checkedNative([:])
      try input.noParameters()
      let name = try input.relativeName()
      let description = try input.quoted(input.text("description"))
      let prompt = try input.quoted(input.prompt())
      let file = try input.joined(["description = " + description, "prompt = " + prompt, ""])
      return try input.emitted(
        lowering,
        input.envelope(
          route: .geminiCommand,
          path: name + ".toml", selection: "file", value: .init(file)))
    case "subagent":
      let native = try input.checkedNative(
        NativeComponentFieldsV1.markdownRules(.geminiCLI, kind: "subagent"))
      let name = try input.filename()
      guard name.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil else {
        throw input.issue(["name"], .invalid, "Gemini agent names must be lowercase slugs")
      }
      let body = try input.prompt()
      guard NativeComponentText.isUntrimmed(body, rust: false) else {
        throw input.issue(
          ["prompt"], .unsupported, "the native agent loader trims the system prompt")
      }
      var fields = native
      fields["name"] = .init(name)
      let description = try input.text("description")
      guard !description.isEmpty else {
        throw input.issue(["description"], .invalid, "native agent description must not be empty")
      }
      fields["description"] = .init(description)
      fields["model"] = input.fields["model"]
      if let tools = input.fields["tools"]?.array {
        for (index, value) in tools.enumerated() {
          guard let name = value.text, validAgentTool(name) else {
            throw input.issue(
              ["tools", String(index)], .invalid, "tool name is outside the pinned agent schema")
          }
        }
      }
      fields["tools"] = input.fields["tools"]
      let file = try input.frontmatter(fields, body: body)
      return try input.emitted(
        lowering,
        input.envelope(
          route: .geminiAgent,
          path: name + ".md", selection: "file", value: .init(file)))
    case "hook": return try NativeHookLayoutV1.render(lowering, input)
    case "ignore":
      _ = try input.checkedNative([:])
      let patterns = try NativeIgnoreLayoutV1.patterns(input)
      return try input.emitted(
        lowering,
        input.envelope(
          route: .geminiIgnore,
          selection: "managedIgnore", value: LedgerPayload.strings(patterns)))
    default:
      throw input.issue(["kind"], .invalid, "component does not match this concrete native profile")
    }
  }
}

extension GeminiAdapter {
  static func validAgentTool(_ name: String) -> Bool {
    let builtins: Set<String> = [
      "activate_skill",
      "ask_user",
      "complete_task",
      "enter_plan_mode",
      "exit_plan_mode",
      "get_internal_docs",
      "glob",
      "google_web_search",
      "grep_search",
      "invoke_agent",
      "list_directory",
      "list_mcp_resources",
      "read_file",
      "read_many_files",
      "read_mcp_resource",
      "replace",
      "run_shell_command",
      "tracker_add_dependency",
      "tracker_create_task",
      "tracker_get_task",
      "tracker_list_tasks",
      "tracker_update_task",
      "tracker_visualize",
      "update_topic",
      "web_fetch",
      "write_file",
      "write_todos",
    ]
    if builtins.contains(name) || name == "search_file_content"
      || name.hasPrefix("discovered_tool_") || name == "*" || name == "mcp_*"
    {
      return true
    }
    guard name.hasPrefix("mcp_"), !name.hasPrefix("mcp__") else { return false }
    let parts = name.dropFirst(4).split(
      separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
    let slug = #"^[a-zA-Z0-9_.:-]+$"#
    guard String(parts[0]).range(of: slug, options: .regularExpression) != nil else { return false }
    if parts[1] == "*" { return true }
    return !parts[1].allSatisfy({ $0 == "_" })
      && String(parts[1]).range(of: slug, options: .regularExpression) != nil
  }
}
