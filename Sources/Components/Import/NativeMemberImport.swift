import AgentsCore
import Foundation

/// Native file bodies share the package-owned bounded YAML/TOML readers.
enum NativeMemberImport {
  static func read(
    _ input: SourceImportInput, container: String,
    kind explicitKind: DeclaredComponentKind? = nil, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics, admission supplied: NativeImportBudget? = nil,
    discoveryRoot: String? = nil
  ) throws {
    let admission = try supplied ?? NativeImportBudget(limits)
    let agent = NativeImportInput.agent(input.profile)
    let isAgent =
      explicitKind == .subagent
      || [.claudeAgentV1, .geminiAgentV1, .openCodeAgentV2, .cursorAgentV1].contains(input.profile)
    let bytes = try ImportInput.bytes(input, limits: limits)
    try admission.document(bytes, path: input.document)
    let file = URL(fileURLWithPath: input.document)
    let stem = (input.document as NSString).deletingPathExtension
    let fallback =
      discoveryRoot.map {
        stem.hasPrefix($0 + "/")
          ? String(stem.dropFirst($0.count + 1)) : file.deletingPathExtension().lastPathComponent
      } ?? file.deletingPathExtension().lastPathComponent
    var origin = ImportLocation(document: input.document, pointer: "")
    var name = fallback
    let body: String
    let description: String
    var model: String?
    var tools: [String]?
    if input.profile == .geminiCommandV1 || (!isAgent && agent == .geminiCLI) {
      let parsed = try NativeImportDocument(
        input, format: .toml, limits: limits, admission: admission)
      origin = parsed.location()
      NativeImportInput.unknown(
        parsed.fields, allowed: ["description", "prompt"], at: origin, into: &diagnostics)
      guard Set(parsed.fields.keys).isSubset(of: ["description", "prompt"]),
        let prompt = parsed.fields["prompt"]?.importString,
        parsed.fields["description"] == nil || parsed.fields["description"]?.importString != nil
      else {
        diagnostics.add(
          .invalidInput, origin, "Native command requires its fixed prompt/description fields.")
        return
      }
      body = prompt
      description = parsed.fields["description"]?.importString ?? ""
    } else {
      let parsed = try ImportFrontmatter.read(bytes, document: input.document, limits: limits)
      guard let text = String(data: parsed.body, encoding: .utf8) else {
        throw ImportReadFailure.invalid
      }
      // Gemini's native agent loader trims its body; the proposal represents that loaded value.
      body =
        agent == .geminiCLI && isAgent ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
      let converted: Set<String> =
        isAgent ? ["name", "description", "model", "tools"] : ["description"]
      parsed.header?.unknown(converted, into: &diagnostics)
      let unknown = Set(parsed.header?.pairs?.map(\.0) ?? []).subtracting(converted)
      guard unknown.isEmpty else { return }
      if let header = parsed.header {
        origin = header.location
        guard
          header.validate(
            strings: isAgent ? ["name", "description", "model"] : ["description"],
            into: &diagnostics)
        else { return }
        if isAgent {
          name = header["name"]?.string ?? name
          model = header["model"]?.string
          if let value = header["tools"] {
            if let values = value.strings {
              tools = values
            } else if let value = value.string, agent == .claudeCode {
              tools = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
              diagnostics.add(
                .invalidInput, value.location,
                "Native tool selection cannot be represented as a string list.")
              return
            }
          }
        }
      }
      description = parsed.header?["description"]?.string ?? ""
      if isAgent,
        description.isEmpty
          || ([AgentID.claudeCode, .geminiCLI].contains(agent) && parsed.header?["name"] == nil)
      {
        diagnostics.add(
          .invalidInput, origin, "Native agent requires its producer name and description.")
        return
      }
      if !isAgent, agent == .claudeCode,
        body.contains("$ARGUMENTS")
          || body.range(of: #"\$[0-9]+"#, options: .regularExpression) != nil
      {
        diagnostics.add(
          .unconverted, origin,
          "Native command substitutions need explicit parameter conversion; no prompt parameters are guessed."
        )
        return
      }
    }
    guard
      name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        NativeImportInput.name(String($0))
      })
    else {
      diagnostics.add(
        .invalidInput, origin, "Native member name is not an admitted component identifier.")
      return
    }
    if isAgent {
      NativeImportInput.emit(
        .subagent(
          name: name, description: description, prompt: .literal(body),
          model: model, tools: tools, agents: [agent]), selector: .subagent(name: name),
        origin: origin, container: container, profile: input.profile, into: &diagnostics,
        admission: admission)
    } else {
      NativeImportInput.emit(
        .command(name: name, description: description, prompt: .literal(body), agents: [agent]),
        selector: .command(name: name), origin: origin, container: container,
        profile: input.profile, into: &diagnostics, admission: admission)
    }
    let relative =
      container == "." ? input.document : String(input.document.dropFirst(container.count + 1))
    try NativeImportInput.resource(
      relative, root: container, input: input, origin: origin, limits: limits, into: &diagnostics,
      admission: admission)
  }
}
