import AgentsCore
import Foundation

extension NativeSourceImport {
  static func hooks(
    _ value: NativeValue, parsed: NativeImportDocument, keys: [String],
    container: String, limits: SourceImportLimits, into diagnostics: inout ImportDiagnostics
  ) throws {
    let agent = NativeImportInput.agent(parsed.input.profile)
    guard [.claudeCode, .cursor].contains(agent), let events = value.importObject else {
      NativeImportInput.unconverted(value, at: parsed.location(keys), into: &diagnostics)
      return
    }
    let admitted =
      agent == .claudeCode
      ? NativeDocumentedHooksV1.claudeEvents : NativeDocumentedHooksV1.cursorEvents
    for event in events.keys.sorted() {
      let location = parsed.location(keys + [event])
      guard admitted.contains(event), case .array(let groups) = events[event] else {
        NativeImportInput.unconverted(events[event]!, at: location, into: &diagnostics)
        continue
      }
      for (groupIndex, group) in groups.enumerated() {
        let groupLocation = location.appending(String(groupIndex))
        let handlers: [NativeValue]
        let matcher: String?
        if agent == .claudeCode {
          guard let fields = group.importObject,
            Set(fields.keys).isSubset(of: ["matcher", "hooks"]),
            case .array(let values) = fields["hooks"],
            fields["matcher"] == nil || fields["matcher"]?.importString != nil
          else {
            NativeImportInput.unconverted(group, at: groupLocation, into: &diagnostics)
            continue
          }
          handlers = values
          matcher = fields["matcher"]?.importString
        } else {
          handlers = [group]
          matcher = group.importObject?["matcher"]?.importString
        }
        if let matcher,
          !NativeDocumentedHooksV1.admittedMatcher(matcher)
            || (agent == .claudeCode
              && NativeDocumentedHooksV1.claudeWithoutMatcher.contains(event))
            || (agent == .cursor && !NativeDocumentedHooksV1.cursorMatcherEvents.contains(event))
        {
          diagnostics.add(
            .unconverted, groupLocation,
            "F's native event/matcher contract cannot preserve this matcher.")
          continue
        }
        for (handlerIndex, handler) in handlers.enumerated() {
          let origin = groupLocation.appending("hooks/\(handlerIndex)")
          guard let fields = handler.importObject else {
            NativeImportInput.unconverted(handler, at: origin, into: &diagnostics)
            continue
          }
          let allowed: Set<String> =
            agent == .cursor
            ? ["type", "command", "timeout", "matcher"] : ["type", "command", "timeout"]
          NativeImportInput.unknown(fields, allowed: allowed, at: origin, into: &diagnostics)
          guard Set(fields.keys).isSubset(of: allowed),
            fields["type"] == nil || fields["type"] == .string("command"),
            let command = fields["command"]?.importString, !command.isEmpty
          else {
            diagnostics.add(
              .unconverted, origin,
              "Native non-command handler or extra execution policy has no equivalent executable conversion."
            )
            continue
          }
          // A single executable token needs no shell splitting or inferred interpreter.
          guard command.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil else {
            diagnostics.add(
              .unconverted, origin.appending("command"),
              "Native shell syntax is not parsed or rewritten into argv.")
            continue
          }
          var timeout: Int?
          if let value = fields["timeout"] {
            guard case .integer(let seconds) = value, seconds > 0,
              !(agent == .claudeCode && event == "SessionEnd" && seconds > 60)
            else {
              NativeImportInput.unconverted(
                value, at: origin.appending("timeout"), into: &diagnostics)
              continue
            }
            timeout = seconds
          }
          var executable = command
          if command.hasPrefix("./") {
            let path = try nativePath(command, container: container)
            executable = path.contains("/") ? path : "./" + path
            try NativeImportInput.resource(
              path, root: container, input: parsed.input, origin: origin,
              limits: limits, into: &diagnostics, admission: parsed.admission)
          } else if command.contains("/") {
            diagnostics.add(
              .unconverted, origin,
              "Native hook outside its explicit root needs a selected authoring resource.")
            continue
          }
          let identity = event + "\0" + (matcher ?? "") + "\0" + executable
          let base = event + "-" + FileHash.sha256Hex(data: Data(identity.utf8))
          let occurrence = parsed.admission.memberOccurrences[base, default: 0] + 1
          parsed.admission.memberOccurrences[base] = occurrence
          let name = base + (occurrence == 1 ? "" : "-\(occurrence)")
          NativeImportInput.emit(
            .hook(
              name: name, event: .native(event), run: .init(executable: executable),
              matcher: matcher, timeoutSeconds: timeout, agents: [agent]),
            selector: .hook(name: name),
            origin: origin, container: container, profile: parsed.input.profile, into: &diagnostics,
            admission: parsed.admission)
        }
      }
    }
  }

  static func lsp(
    _ value: NativeValue, parsed: NativeImportDocument, keys: [String],
    container: String, limits: SourceImportLimits, into diagnostics: inout ImportDiagnostics
  ) throws {
    let agent = NativeImportInput.agent(parsed.input.profile)
    guard [.claudeCode, .opencode].contains(agent), let servers = value.importObject else {
      NativeImportInput.unconverted(value, at: parsed.location(keys), into: &diagnostics)
      return
    }
    try classifyMembers(value, parsed: parsed, keys: keys, into: &diagnostics)
    for name in servers.keys.sorted() {
      let origin = try parsed.memberLocation(keys, name: name)
      guard NativeImportInput.name(name), let fields = servers[name]?.importObject else {
        NativeImportInput.unconverted(servers[name]!, at: origin, into: &diagnostics)
        continue
      }
      let allowed: Set<String> =
        agent == .claudeCode
        ? ["command", "args", "env", "extensionToLanguage", "initializationOptions"]
        : ["command", "env", "extensions", "disabled", "initialization"]
      NativeImportInput.unknown(fields, allowed: allowed, at: origin, into: &diagnostics)
      guard Set(fields.keys).isSubset(of: allowed) else { continue }
      let executable: String
      let arguments: [String]
      var languages: [String: String] = [:]
      var native: NativeConfiguration = [:]
      if agent == .claudeCode {
        guard let command = fields["command"]?.importString,
          let mapping = fields["extensionToLanguage"]?.importObject, !mapping.isEmpty,
          mapping.allSatisfy({ $0.key.hasPrefix(".") && $0.value.importString?.isEmpty == false }),
          fields["args"] == nil || fields["args"]?.importStrings != nil
        else {
          diagnostics.add(
            .invalidInput, origin, "Native LSP command/language mapping is malformed.")
          continue
        }
        executable = command
        arguments = fields["args"]?.importStrings ?? []
        languages = mapping.mapValues { $0.importString! }
      } else {
        guard let argv = fields["command"]?.importStrings, let command = argv.first,
          !command.isEmpty,
          fields["extensions"] == nil || MCPNativeField.strings.accepts(fields["extensions"]!),
          fields["disabled"] == nil || MCPNativeField.boolean.accepts(fields["disabled"]!)
        else {
          diagnostics.add(.invalidInput, origin, "Native LSP argv/extensions are malformed.")
          continue
        }
        executable = command
        arguments = Array(argv.dropFirst())
        for key in ["extensions", "disabled"] where fields[key] != nil {
          native[agent.rawValue, default: [:]][key] = fields[key]
        }
      }
      guard !executable.isEmpty, !executable.contains("\0"), !executable.contains("${"),
        !arguments.contains(where: {
          $0.contains("${") || ($0.contains("://") && !ImportInput.safeLocator($0))
        })
      else {
        diagnostics.add(
          .unconverted, origin,
          "Native LSP interpolation/arguments require explicit resource or binding conversion.")
        continue
      }
      var credentialArgument = false
      for (index, argument) in arguments.enumerated() {
        let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        if ImportInput.credentialField(flag) {
          diagnostics.binding(origin.appending("args/\(index)"))
          credentialArgument = true
        }
      }
      if credentialArgument {
        diagnostics.add(
          .unconverted, origin, "Native LSP credential arguments require symbolic reconstruction.")
        continue
      }
      let optionsKey = agent == .claudeCode ? "initializationOptions" : "initialization"
      let options = fields[optionsKey]?.importObject ?? [:]
      if fields[optionsKey] != nil && fields[optionsKey]?.importObject == nil {
        diagnostics.add(
          .invalidInput, origin.appending(optionsKey),
          "Native initialization options require an object.")
        continue
      }
      if NativeImportInput.sensitive(
        .object(options), at: origin.appending(optionsKey), into: &diagnostics)
      {
        diagnostics.add(
          .unconverted, origin,
          "Native initialization data contains literal credential slots without a typed binding representation."
        )
        continue
      }
      let environment = try NativeImportInput.bindings(
        fields["env"], at: origin.appending("env"), into: &diagnostics,
        profile: parsed.input.profile)
      var program = executable
      if executable.hasPrefix("./") {
        let path = try nativePath(executable, container: container)
        program = path.contains("/") ? path : "./" + path
        try NativeImportInput.resource(
          path, root: container, input: parsed.input, origin: origin,
          limits: limits, into: &diagnostics, admission: parsed.admission)
      } else if executable.contains("/") {
        diagnostics.add(
          .unconverted, origin,
          "Native LSP executable outside its source requires a selected resource.")
        continue
      }
      NativeImportInput.emit(
        .lspServer(
          name: name,
          run: .init(executable: program, arguments: arguments, environment: environment),
          languages: languages, initializationOptions: options, agents: [agent], native: native),
        selector: .lspServer(name: name),
        origin: origin, container: container, profile: parsed.input.profile, into: &diagnostics,
        admission: parsed.admission)
    }
  }
}
