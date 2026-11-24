import AgentsCore

enum NativeLSPLayoutV1 {
  static let openCodeNativeFields: [String: MCPNativeField] = [
    "extensions": .strings, "disabled": .boolean,
  ]

  static func claude(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    let name = try input.filename()
    guard NativePluginFieldsV1.validClaudeName(name) else {
      throw input.issue(
        ["name"], .invalid, "generated native plugin identifier contains a forbidden character")
    }
    guard let languages = input.fields["languages"]?.object, !languages.isEmpty,
      languages.allSatisfy({ $0.key.hasPrefix(".") && $0.value.text?.isEmpty == false })
    else {
      throw input.issue(
        ["languages"], .invalid,
        "native extensionToLanguage requires nonempty dot-prefixed extensions and language IDs")
    }
    guard let run = input.fields["run"]?.object else {
      throw input.issue(["run"], .invalid, "missing native LSP program")
    }
    guard run["workingDirectory"] == nil else {
      throw input.issue(
        ["run", "workingDirectory"], .unsupported,
        "native LSP workspaceFolder is not a process working-directory setting")
    }
    var config = try input.checkedNative([
      "transport": .oneOf(["stdio", "socket"]), "workspaceFolder": .string,
      "startupTimeout": .positiveInteger, "shutdownTimeout": .positiveInteger,
      "requestTimeout": .positiveInteger, "restartOnCrash": .boolean, "diagnostics": .boolean,
      "maxRestarts": .nonnegativeInteger, "settings": .object,
    ])
    config["command"] = try NativeProgramV1.executable(run, input: input)
    if let command = config["command"]?.text, command.contains(" ") && !command.hasPrefix("/") {
      throw input.issue(
        ["run", "executable"], .invalid, "native LSP command with spaces must be absolute")
    }
    config["args"] = run["arguments"]
    config["env"] = run["environment"]
    config["extensionToLanguage"] = .init(object: languages)
    config["initializationOptions"] = input.fields["initializationOptions"]
    try NativeProgramV1.validateLiterals(.init(object: config), input: input, path: [])
    for key in ["command", "args", "env"] {
      if let value = config[key] { try validateExpansion(value, input, path: ["run", key]) }
    }
    let manifest: LedgerValue = .init(object: [
      "name": .init(name), "lspServers": .init(object: [name: .init(object: config)]),
    ])
    return try input.emitted(
      lowering,
      input.envelope(
        route: .claudeSkillPlugin, path: name, selection: "generatedPlugin",
        value: .init(object: [".claude-plugin/plugin.json": manifest])))
  }

  private static func validateExpansion(
    _ value: LedgerValue, _ input: ComponentRenderInput, path: [String]
  ) throws {
    if let text = value.text, value.kind == .string || value.kind == .literal, text.contains("${") {
      throw input.issue(
        path, .unverified,
        "literal preservation across native LSP placeholders needs an exact representation")
    }
    for (index, child) in (value.array ?? []).enumerated() {
      try validateExpansion(child, input, path: path + [String(index)])
    }
    for (key, child) in value.object ?? [:] {
      try validateExpansion(child, input, path: path + [key])
    }
  }

  static func openCode(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    guard input.fields["languages"]?.object?.isEmpty ?? true else {
      throw input.issue(
        ["languages"], .unverified,
        "native extensions do not encode extension-to-language IDs; runtime equivalence is not established"
      )
    }
    var fields = try input.checkedNative(openCodeNativeFields)
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
