import AgentsCore

enum NativeLSPLayoutV1 {
  static func openCode(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    guard input.fields["languages"]?.object?.isEmpty ?? true else {
      throw input.issue(
        ["languages"], .unverified,
        "native extensions do not encode extension-to-language IDs; runtime equivalence is not established"
      )
    }
    var fields = try input.checkedNative(["extensions": .strings, "disabled": .boolean])
    guard let run = input.fields["run"]?.object else {
      throw input.issue(["run"], .invalid, "missing frozen LSP executable")
    }
    guard run["workingDirectory"] == nil else {
      throw input.issue(
        ["run", "workingDirectory"], .unsupported,
        "the pinned LSP schema has no working-directory field")
    }
    fields["command"] = .init(
      array: [try NativeProgramV1.executable(run, input: input)] + (run["arguments"]?.array ?? []))
    if let environment = run["environment"]?.object, !environment.isEmpty {
      fields["env"] = .init(object: environment)
    }
    fields["initialization"] = input.fields["initializationOptions"]
    // OpenCode performs raw JSON substitution on every string in the native document.
    try NativeProgramV1.validateLiterals(.init(object: fields), input: input, path: [])
    return try input.emitted(
      lowering,
      input.envelope(
        route: .openCodeConfig,
        keys: ["lsp", input.record.name], selection: "lsp", value: .init(object: fields)))
  }
}
