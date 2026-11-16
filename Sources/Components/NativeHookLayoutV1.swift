import AgentsCore

enum NativeHookLayoutV1 {
  static func render(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    let events: Set<String>
    let route: NativeComponentRoute
    switch input.request.surface {
    case .codexCLI:
      events = [
        "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact",
        "SessionStart", "SessionEnd", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop",
        "Interrupt",
      ]
      route = .codexHooks
    case .geminiCLI:
      events = [
        "BeforeTool", "AfterTool", "BeforeAgent", "Notification", "AfterAgent", "SessionStart",
        "SessionEnd",
        "PreCompress", "BeforeModel", "AfterModel", "BeforeToolSelection",
      ]
      route = .geminiSettings
    default:
      throw input.issue(
        ["event"], .unverified, "the native event/runner contract is not established")
    }
    guard let event = input.fields["event"]?.object?["native"]?.text else {
      throw input.issue(
        ["event"], .unverified,
        "portable event payload/output equivalence is not established; select an explicit native event"
      )
    }
    guard events.contains(event) else {
      throw input.issue(
        ["event"], .unsupported, "event is absent from the pinned native event enum")
    }
    if input.request.surface == .codexCLI, let matcher = input.fields["matcher"]?.text {
      guard !["UserPromptSubmit", "Stop", "Interrupt"].contains(event) else {
        throw input.issue(["matcher"], .unsupported, "this native event ignores matchers")
      }
      guard
        matcher.isEmpty || matcher == "*"
          || matcher.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
              || $0 == 124
          })
      else {
        throw input.issue(
          ["matcher"], .unverified,
          "exact Rust-regex syntax admission is required beyond the native literal/alternative matcher form"
        )
      }
    }
    let native = try input.checkedNative(
      input.request.surface == .geminiCLI ? ["sequential": .boolean] : [:])
    guard let run = input.fields["run"]?.object else {
      throw input.issue(["run"], .invalid, "missing frozen hook program")
    }
    var program = run
    program["executable"] = try NativeProgramV1.executable(run, input: input)
    if run["workingDirectory"] != nil {
      let index = run["executable"]?.text?.contains("/") == true ? 1 : 0
      guard input.record.resources.indices.contains(index) else {
        throw input.issue(["run", "workingDirectory"], .invalid, "missing frozen hook directory")
      }
      program["workingDirectory"] = .init(object: ["resource": .init(input.record.resources[index])]
      )
    }
    try NativeProgramV1.validateLiterals(.init(object: program), input: input, path: ["run"])
    var hook: [String: LedgerValue] = [
      "type": .init("command"), "command": .init(object: ["program": .init(object: program)]),
    ]
    if let seconds = input.fields["timeoutSeconds"]?.integer {
      let factor = input.request.surface == .geminiCLI ? 1000 : 1
      guard seconds > 0, seconds <= Int.max / factor else {
        throw input.issue(
          ["timeoutSeconds"], .invalid, "native timeout is outside its representable range")
      }
      if input.request.surface == .codexCLI, ["SessionEnd", "Interrupt"].contains(event),
        seconds > 3
      {
        throw input.issue(
          ["timeoutSeconds"], .unsupported,
          "the pinned native teardown hook clamps its timeout to three seconds")
      }
      if input.request.surface == .geminiCLI, seconds * factor > 2_147_483_647 {
        throw input.issue(
          ["timeoutSeconds"], .invalid,
          "native Node timer milliseconds exceed its representable range")
      }
      hook["timeout"] = .init(integer: seconds * factor)
    }
    var group: [String: LedgerValue] = ["hooks": .init(array: [.init(object: hook)])]
    group["matcher"] = input.fields["matcher"]
    group["sequential"] = native["sequential"]
    return try input.emitted(
      lowering,
      input.envelope(
        route: route,
        keys: ["hooks", event], selection: "hookGroup", value: .init(object: group)))
  }
}
