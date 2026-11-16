import AgentsCore

/// Native event names retain the client's own stdin/stdout contract, not portable event aliases.
enum NativeDocumentedHooksV1 {
  static let claudeEvents: Set<String> = [
    "SessionStart", "Setup", "InstructionsLoaded", "UserPromptSubmit", "UserPromptExpansion",
    "MessageDisplay", "PreToolUse", "PermissionRequest", "PermissionDenied", "PostToolUse",
    "PostToolUseFailure", "PostToolBatch", "Notification", "SubagentStart", "SubagentStop",
    "Stop", "StopFailure", "TeammateIdle", "TaskCreated", "TaskCompleted", "ConfigChange",
    "CwdChanged", "DirectoryAdded", "FileChanged", "WorktreeCreate", "WorktreeRemove",
    "PreCompact", "PostCompact", "PreModelSwitch", "PostModelSwitch", "Elicitation",
    "ElicitationResult", "SessionEnd",
  ]
  static let claudeWithoutMatcher: Set<String> = [
    "CwdChanged", "UserPromptSubmit", "PostToolBatch", "Stop", "TeammateIdle", "TaskCreated",
    "TaskCompleted", "WorktreeCreate", "WorktreeRemove", "MessageDisplay",
  ]
  static let cursorEvents: Set<String> = [
    "sessionStart", "sessionEnd", "preToolUse", "postToolUse", "postToolUseFailure",
    "subagentStart", "subagentStop", "beforeShellExecution", "afterShellExecution",
    "beforeMCPExecution", "afterMCPExecution", "beforeReadFile", "afterFileEdit",
    "beforeSubmitPrompt", "preCompact", "stop", "afterAgentResponse", "afterAgentThought",
    "beforeTabFileRead", "afterTabFileEdit", "workspaceOpen",
  ]
  static let cursorCloudEvents: Set<String> = [
    "beforeShellExecution", "afterShellExecution", "beforeReadFile", "afterFileEdit",
    "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop",
    "beforeSubmitPrompt", "preCompact", "afterAgentResponse", "afterAgentThought", "stop",
  ]
  static let cursorMatcherEvents: Set<String> = [
    "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop",
    "beforeShellExecution", "afterShellExecution", "beforeReadFile", "afterFileEdit",
    "beforeTabFileRead", "afterTabFileEdit", "beforeSubmitPrompt", "stop",
    "afterAgentResponse", "afterAgentThought",
  ]
  /// These fragments are valid in the native JavaScript regex engine without substituting
  /// a different engine's syntax or matching behavior. More complex syntax stays explicit.
  static func admittedMatcher(_ matcher: String) -> Bool {
    if matcher.isEmpty || matcher == "*" { return true }
    return matcher.split(separator: "|", omittingEmptySubsequences: false).allSatisfy { part in
      var part = part[...]
      if part.hasPrefix("^") { part = part.dropFirst() }
      if part.hasSuffix("$") { part = part.dropLast() }
      if part.hasSuffix(".*") { part = part.dropLast(2) }
      return !part.contains(where: { "\\[]{}()+?*^$".contains($0) })
    }
  }

  static func event(_ input: ComponentRenderInput, allowed: Set<String>) throws -> String {
    guard let event = input.fields["event"]?.object?["native"]?.text else {
      throw input.issue(
        ["event"], .unverified,
        "portable event payload/output equivalence is not established; select an explicit native event"
      )
    }
    guard allowed.contains(event) else {
      throw input.issue(
        ["event"], .unsupported, "event is absent from this documented native surface")
    }
    return event
  }

  static func program(_ input: ComponentRenderInput) throws -> LedgerValue {
    guard let run = input.fields["run"]?.object else {
      throw input.issue(["run"], .invalid, "missing frozen hook program")
    }
    var result = run
    result["executable"] = try NativeProgramV1.executable(run, input: input)
    if run["workingDirectory"] != nil {
      let index = run["executable"]?.text?.contains("/") == true ? 1 : 0
      guard input.record.resources.indices.contains(index) else {
        throw input.issue(["run", "workingDirectory"], .invalid, "missing frozen hook directory")
      }
      result["workingDirectory"] = .init(object: ["resource": .init(input.record.resources[index])])
    }
    try NativeProgramV1.validateLiterals(.init(object: result), input: input, path: ["run"])
    return .init(object: ["program": .init(object: result)])
  }

  static func claude(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    let event = try event(input, allowed: claudeEvents)
    try commandType(input)
    if input.fields["matcher"] != nil, claudeWithoutMatcher.contains(event) {
      throw input.issue(["matcher"], .unsupported, "this native event ignores matchers")
    }
    if let matcher = input.fields["matcher"]?.text, !admittedMatcher(matcher) {
      throw input.issue(
        ["matcher"], .unverified,
        "exact native JavaScript regex admission is required beyond this fragment profile")
    }
    var hook = try input.checkedNative([
      "type": .oneOf(["command"]), "statusMessage": .string,
      "async": .boolean, "asyncRewake": .boolean, "if": .string,
      "onFailure": .oneOf(["continue", "block"]),
    ])
    let toolEvents: Set<String> = [
      "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    ]
    if hook["if"] != nil, !toolEvents.contains(event) {
      throw input.issue(
        ["native", "claude-code", "if"], .unsupported, "native if filters never run on this event")
    }
    if hook["onFailure"] != nil {
      guard hook["async"]?.boolean != true, hook["asyncRewake"]?.boolean != true else {
        throw input.issue(
          ["native", "claude-code", "onFailure"], .unsupported,
          "native background hooks ignore this failure policy")
      }
      guard ["PreToolUse", "PermissionRequest", "UserPromptSubmit"].contains(event) else {
        throw input.issue(
          ["native", "claude-code", "onFailure"], .unverified,
          "failure blocking is not verified for this event")
      }
    }
    if let timeout = input.fields["timeoutSeconds"] {
      guard timeout.integer.map({ $0 > 0 }) == true else {
        throw input.issue(["timeoutSeconds"], .invalid, "native timeout must be positive seconds")
      }
      guard hook["async"]?.boolean != true, hook["asyncRewake"]?.boolean != true else {
        throw input.issue(
          ["timeoutSeconds"], .unsupported, "native background hooks do not enforce this timeout")
      }
      if event == "SessionEnd", timeout.integer! > 60 {
        throw input.issue(
          ["timeoutSeconds"], .unsupported, "native SessionEnd budget is capped at sixty seconds")
      }
      hook["timeout"] = timeout
    }
    hook["type"] = .init("command")
    hook["command"] = try program(input)
    var group: [String: LedgerValue] = ["hooks": .init(array: [.init(object: hook)])]
    group["matcher"] = input.fields["matcher"]
    return try input.emitted(
      lowering,
      input.envelope(
        route: .claudeSettings, keys: ["hooks", event], selection: "hookGroup",
        value: .init(object: group)))
  }

  static func cursor(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    let allowed: Set<String>
    switch input.request.surface {
    case .cursorCloud: allowed = cursorCloudEvents
    case .cursorCLI: allowed = cursorEvents.subtracting(["beforeTabFileRead", "afterTabFileEdit"])
    default: allowed = cursorEvents
    }
    let event = try event(input, allowed: allowed)
    try commandType(input)
    if input.fields["matcher"] != nil, !cursorMatcherEvents.contains(event) {
      throw input.issue(
        ["matcher"], .unverified, "the documented matcher target is not established for this event")
    }
    if let matcher = input.fields["matcher"]?.text, !admittedMatcher(matcher) {
      throw input.issue(
        ["matcher"], .unverified,
        "exact native JavaScript regex admission is required beyond this fragment profile")
    }
    var hook = try input.checkedNative([
      "type": .oneOf(["command"]), "failClosed": .boolean, "loop_limit": .numberOrNull,
    ])
    if let loop = input.native["loop_limit"] {
      // Only these two event callers consume the field. Unknown/ignored fields are never dropped.
      guard ["stop", "subagentStop"].contains(event) else {
        throw input.issue(
          ["native", "cursor", "loop_limit"], .unsupported,
          "only stop/subagentStop consume loop_limit")
      }
      hook["loop_limit"] = loop
    }
    if hook["failClosed"]?.boolean == true, event == "sessionStart" {
      throw input.issue(
        ["native", "cursor", "failClosed"], .unsupported,
        "sessionStart is fire-and-forget and cannot block creation")
    }
    hook["type"] = .init("command")
    hook["command"] = try program(input)
    hook["matcher"] = input.fields["matcher"]
    hook["timeout"] = input.fields["timeoutSeconds"]
    if let seconds = input.fields["timeoutSeconds"]?.integer, seconds <= 0 {
      throw input.issue(["timeoutSeconds"], .invalid, "native timeout must be positive seconds")
    }
    var envelope = input.envelope(
      route: .cursorHooks, keys: ["hooks", event], selection: "cursorHook",
      value: .init(object: hook)
    ).object!
    envelope["rootRequirements"] = .init(object: ["version": .init(integer: 1)])
    return try input.emitted(lowering, .init(object: envelope))
  }

  private static func commandType(_ input: ComponentRenderInput) throws {
    guard let type = input.native["type"] else { return }
    guard let name = type.text else {
      throw input.issue(
        ["native", input.request.surface.agent.rawValue, "type"], .invalid,
        "native handler type requires a string")
    }
    guard name == "command" else {
      throw input.issue(
        ["native", input.request.surface.agent.rawValue, "type"], .unsupported,
        "an executable hook declaration cannot replace its run with a native prompt, agent, HTTP or MCP handler"
      )
    }
  }
}
