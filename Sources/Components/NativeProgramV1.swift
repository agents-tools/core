import AgentsCore
import Foundation
import NativeDocuments

/// Native command strings use the pinned clients' POSIX shell runner on supported platforms.
/// Each argument is quoted as one word. Source scripts remain frozen files, never inline code.
package enum NativeProgramV1 {
  /// E supplies this only after verifying the native client's command runner, independently
  /// of the applying process's environment. Gemini's pinned Unix runner selects bash itself.
  package enum CommandShell { case posix }

  /// Frozen program shape is still the typed declaration's run, not native settings data.
  static func validateFrozenRun(_ input: ComponentRenderInput) throws {
    guard let run = input.fields["run"]?.object,
      Set(run.keys).subtracting(["workingDirectory", "executableSource"]) == [
        "executable", "arguments", "environment",
      ],
      run["executable"]?.kind == .string, run["executable"]?.text?.isEmpty == false,
      let arguments = run["arguments"]?.array, arguments.allSatisfy({ $0.kind == .string }),
      let environment = run["environment"]?.object,
      environment.allSatisfy({
        !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0)
          && [.literal, .environment, .secret].contains($0.value.kind)
          && ($0.value.kind == .literal || $0.value.text?.isEmpty == false)
      })
    else { throw input.issue(["run"], .invalid, "invalid frozen typed native program") }
    if let source = run["executableSource"] {
      guard source.kind == .string, source.text?.isEmpty == false,
        run["executable"]!.text!.contains("/")
      else {
        throw input.issue(
          ["run", "executableSource"], .invalid, "invalid executable source coordinate")
      }
    }
    if let cwd = run["workingDirectory"] {
      guard let fields = cwd.object, Set(fields.keys).isSubset(of: ["path", "source"]),
        fields["path"]?.kind == .string, fields["path"]?.text?.isEmpty == false,
        fields["source"] == nil || fields["source"]?.kind == .string
      else {
        throw input.issue(
          ["run", "workingDirectory"], .invalid, "invalid frozen directory resource")
      }
    }
  }

  static func executable(_ run: [String: LedgerValue], input: ComponentRenderInput) throws
    -> LedgerValue
  {
    guard let executable = run["executable"]?.text, !executable.isEmpty else {
      throw input.issue(["run", "executable"], .invalid, "missing native executable")
    }
    if executable.contains("/") {
      guard let resource = input.record.resources.first else {
        throw input.issue(["run", "executable"], .invalid, "missing frozen executable resource")
      }
      return .init(object: ["resource": .init(resource)])
    }
    try input.literal(executable, field: ["run", "executable"])
    return .init(executable)
  }

  static func validateLiterals(_ value: LedgerValue, input: ComponentRenderInput, path: [String])
    throws
  {
    if value.kind == .string || value.kind == .literal {
      try input.literal(value.text!, field: path)
    }
    for (index, item) in (value.array ?? []).enumerated() {
      try validateLiterals(item, input: input, path: path + [String(index)])
    }
    for (key, item) in value.object ?? [:] {
      try input.literal(key, field: path + ["key"])
      try validateLiterals(item, input: input, path: path + [key])
    }
  }

  /// The strict contribution decoder supplies the envelope; package callers use its typed value.
  static func stagedValue(
    _ envelope: LedgerValue, bindings: RuntimeBindingValues,
    environment: RuntimeEnvironment, resourcePaths: [String: String], budget: NativeDocumentBudget,
    codexCommandShell: CommandShell? = nil, cursorCommandShell: CommandShell? = nil
  ) throws -> NativeValue {
    guard let metadata = envelope.object,
      let surface = metadata["surface"]?.text.flatMap(NativeClientSurface.init(rawValue:)),
      let scope = metadata["scope"]?.text.flatMap(InstallScope.init(rawValue:)),
      let kind = metadata["kind"]?.text, let component = metadata["name"]?.text,
      let value = metadata["value"], let selection = metadata["selection"]?.text,
      ["hookGroup", "cursorHook", "antigravityHook", "lsp", "generatedPlugin"].contains(selection)
    else { throw CoreError.invalidState("invalid staged native program intention") }
    func issue(_ path: [String], _ detail: String, _ reason: NativeAdapterIssue.Reason = .invalid)
      -> NativeComponentIssue
    {
      .init(
        request: .init(surface: surface, scope: scope), kind: kind, component: component,
        field: path, reason: reason, detail: detail)
    }
    if surface == .codexCLI {
      guard codexCommandShell == .posix
      else {
        throw NativeComponentIssue(
          request: .init(surface: surface, scope: scope), kind: kind,
          component: component, field: ["run"], reason: .integrationRequired,
          detail:
            "E must supply the verified native POSIX command-shell contract; the apply environment is not that evidence"
        )
      }
    }
    if [.cursorEditor, .cursorCLI, .cursorCloud].contains(surface), cursorCommandShell != .posix {
      throw NativeComponentIssue(
        request: .init(surface: surface, scope: scope), kind: kind,
        component: component, field: ["run"], reason: .integrationRequired,
        detail:
          "E must supply the verified native POSIX command-shell contract for this Cursor surface")
    }
    func check(_ text: String, path: [String]) throws -> String {
      try budget.allocate(text.utf8.count, stage: "native program string")
      try budget.step(text.utf8.count)
      guard !text.utf8.contains(0) else { throw issue(path, "NUL is not a native string") }
      if surface == .openCodeCLI, text.contains("{env:") || text.contains("{file:") {
        throw issue(path, "literal cannot cross native interpolation exactly")
      }
      if surface == .claudeCode, text.contains("${"),
        selection == "hookGroup"
          || (selection == "generatedPlugin" && path.count >= 4
            && ["command", "args", "env"].contains(path[3]))
      {
        throw issue(path, "literal cannot cross native placeholders exactly", .unverified)
      }
      if [.cursorEditor, .cursorCLI, .cursorCloud].contains(surface), text.contains("${") {
        throw issue(
          path, "exact literal preservation across Cursor command preprocessing needs evidence",
          .unverified)
      }
      // Settings expand environment tokens before the hook runner sees shell quoting.
      if surface == .geminiCLI,
        text.range(of: #"\$(?:[A-Za-z0-9_]+|\{[^}]+?(?::-[^}]*)?\})"#, options: .regularExpression)
          != nil
      {
        throw issue(path, "literal cannot cross native settings interpolation exactly")
      }
      return text
    }
    func string(_ value: LedgerValue, path: [String]) throws -> String {
      if let resource = value.object?["resource"]?.text {
        guard let final = resourcePaths[resource], !final.isEmpty else {
          throw issue(path, "final registered resource placement is required")
        }
        return try check(final, path: path)
      }
      switch value.kind {
      case .string, .literal: return try check(value.text!, path: path)
      case .environment:
        guard let text = environment.environment[value.text!] else {
          throw issue(path, "required environment value is unavailable")
        }
        return try check(text, path: path)
      case .secret:
        let data: Data
        do { data = try bindings.value(for: value.text!) } catch {
          throw issue(path, "required binding is unavailable")
        }
        try budget.allocate(data.count, stage: "native program UTF8")
        guard let text = String(data: data, encoding: .utf8) else {
          throw issue(path, "native binding is not UTF8")
        }
        return try check(text, path: path)
      default: throw issue(path, "expected native program string")
      }
    }
    func quote(_ text: String) throws -> String {
      guard text.utf8.count <= (Int.max - 2) / 4 else {
        throw issue(["run"], "native command exceeds budget")
      }
      try budget.allocate(text.utf8.count * 4 + 2, stage: "native shell word")
      return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    func program(_ run: [String: LedgerValue]) throws -> String {
      var words: [String] = []
      if let cwd = run["workingDirectory"] {
        // Working directories are frozen resources; original authored paths never become native paths.
        guard let resource = cwd.object?["resource"]?.text, let final = resourcePaths[resource],
          !final.isEmpty
        else {
          throw issue(
            ["run", "workingDirectory"], "final registered directory placement is required")
        }
        words.append(
          "cd -- " + (try quote(check(final, path: ["run", "workingDirectory"]))) + " &&")
      }
      if let env = run["environment"]?.object, !env.isEmpty {
        words.append("env")
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
          guard MCPReferenceSyntax.isName(key) else {
            throw issue(["run", "environment"], "native environment key is invalid")
          }
          words.append(try quote(key + "=" + string(value, path: ["run", "environment", key])))
        }
      }
      guard let executable = run["executable"] else {
        throw issue(["run", "executable"], "missing executable")
      }
      words.append(try quote(string(executable, path: ["run", "executable"])))
      for (index, argument) in (run["arguments"]?.array ?? []).enumerated() {
        words.append(try quote(string(argument, path: ["run", "arguments", String(index)])))
      }
      var size = 0
      for word in words {
        guard word.utf8.count < Int.max - size else {
          throw issue(["run"], "native command exceeds budget")
        }
        size += word.utf8.count + 1
      }
      try budget.allocate(size, stage: "native command")
      return words.joined(separator: " ")
    }
    let namedHookCommand =
      selection == "antigravityHook"
      ? AntigravityAdapter.commandPath(in: value) : nil
    func convert(_ value: LedgerValue, path: [String], depth: Int) throws -> NativeValue {
      try budget.node(depth: depth)
      try budget.step()
      if (selection == "hookGroup" && path == ["hooks", "0", "command"])
        || path == namedHookCommand
      {
        guard let run = value.object?["program"]?.object else {
          throw issue(path, "missing native hook program")
        }
        return .string(try program(run))
      }
      if selection == "cursorHook", path == ["command"] {
        guard let run = value.object?["program"]?.object else {
          throw issue(path, "missing native Cursor hook program")
        }
        return .string(try program(run))
      }
      let generatedLSP =
        selection == "generatedPlugin"
        && path.count >= 3
        && Array(path.prefix(3)) == [".claude-plugin/plugin.json", "lspServers", component]
      if generatedLSP, path == [".claude-plugin/plugin.json", "lspServers", component, "command"],
        value.object?["resource"] != nil
      {
        return .string(try string(value, path: path))
      }
      if selection == "lsp", path == ["command", "0"], value.object?["resource"] != nil {
        return .string(try string(value, path: path))
      }
      if value.kind == .environment || value.kind == .secret {
        guard
          (selection == "lsp" && path.count == 2 && path.first == "env")
            || (generatedLSP && path.count == 5 && path[3] == "env")
        else {
          throw issue(path, "symbolic binding is outside a native environment slot")
        }
        return .string(try string(value, path: path))
      }
      switch value.kind {
      case .string, .literal: return .string(try string(value, path: path))
      case .integer: return .integer(value.integer!)
      case .boolean: return .boolean(value.boolean!)
      case .decimal: return .decimal(value.text!)
      case .null: return .null
      case .array:
        return .array(
          try value.array!.enumerated().map {
            try convert($0.element, path: path + [String($0.offset)], depth: depth + 1)
          })
      case .object:
        var fields: [String: NativeValue] = [:]
        for (key, value) in value.object!.sorted(by: { $0.key < $1.key }) {
          try budget.allocate(key.utf8.count, stage: "native program key")
          try budget.step(key.utf8.count)
          fields[key] = try convert(value, path: path + [key], depth: depth + 1)
        }
        return .object(fields)
      case .environment, .secret: throw issue(path, "invalid symbolic value")
      }
    }
    return try convert(value, path: [], depth: 0)
  }
}
