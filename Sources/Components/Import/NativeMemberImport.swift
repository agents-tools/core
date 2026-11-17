import AgentsCore
import AgentsManifest
import Foundation
import NativeDocuments

/// Native file bodies share the package-owned bounded YAML/TOML readers.
enum NativeMemberImport {
  static func read(
    _ input: SourceImportInput, container: String,
    kind explicitKind: DeclaredComponentKind? = nil, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics, admission supplied: NativeImportBudget? = nil,
    discoveryRoot: String? = nil, inPlugin: Bool = false
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
    var native: NativeConfiguration = [:]
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
      let parsed =
        try agent == .cursor && !isAgent && !inPlugin
        ? (header: Optional<ImportYAML>.none, body: bytes)
        : ImportFrontmatter.read(bytes, document: input.document, limits: limits)
      guard let text = String(data: parsed.body, encoding: .utf8) else {
        throw ImportReadFailure.invalid
      }
      // Gemini's native agent loader trims its body; the proposal represents that loaded value.
      body =
        agent == .geminiCLI && isAgent ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
      var fields: [String: NativeValue] = [:]
      if let header = parsed.header {
        origin = header.location
        fields = try nativeValue(header).importObject!
      }
      // All original frontmatter participates in preservation admission, even on refusal.
      if NativeImportInput.sensitive(.object(fields), at: origin, into: &diagnostics) {
        diagnostics.add(
          .unconverted, origin,
          "Native frontmatter credential slots require symbolic reconstruction.")
        return
      }
      if agent != .opencode {
        do {
          fields = try NativeComponentFieldsV1.markdown(
            surface: NativeImportSemantics.surface(input.profile),
            document: input.document, fieldPrefix: [], kind: isAgent ? .subagent : .command,
            name: fallback, fields: fields,
            inPlugin: inPlugin, budget: admission.parser)
        } catch let issue as NativeComponentFieldIssue {
          guard issue.document == input.document else { throw ImportReadFailure.invalid }
          var value = parsed.header
          for field in issue.field {
            guard let node = value else { break }
            if let child = node[field] {
              value = child
            } else if let index = Int(field), let items = node.items, items.indices.contains(index)
            {
              value = items[index]
            } else {
              break
            }
          }
          NativeImportSemantics.report(issue, at: value?.location ?? origin, into: &diagnostics)
          return
        }
      } else {
        let converted: Set<String> =
          isAgent ? ["name", "description", "model", "tools"] : ["description"]
        NativeImportInput.unknown(fields, allowed: converted, at: origin, into: &diagnostics)
        guard Set(fields.keys).isSubset(of: converted) else { return }
        for field in ["name", "description"] where fields[field] != nil {
          guard fields[field]?.importString != nil else {
            diagnostics.add(
              .invalidInput, parsed.header?[field]?.location ?? origin,
              "Native Markdown field requires a string value.")
            return
          }
        }
        if let value = fields["model"], value.importString == nil {
          NativeImportInput.unconverted(
            value, at: parsed.header?["model"]?.location ?? origin, into: &diagnostics)
          return
        }
      }
      name = fields["name"]?.importString ?? name
      model = fields["model"]?.importString
      if let value = fields["tools"] {
        if let values = value.importStrings {
          tools = values
        } else if let text = value.importString, agent == .claudeCode {
          tools = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
          throw ImportReadFailure.invalid
        }
      }
      description = fields["description"]?.importString ?? ""
      let converted: Set<String> =
        isAgent ? ["name", "description", "model", "tools"] : ["description"]
      let extras = fields.filter { !converted.contains($0.key) }
      if !extras.isEmpty { native[agent.rawValue] = extras }
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
          model: model, tools: tools, agents: [agent], native: native),
        selector: .subagent(name: name),
        origin: origin, container: container, profile: input.profile, into: &diagnostics,
        admission: admission)
    } else {
      NativeImportInput.emit(
        .command(
          name: name, description: description, prompt: .literal(body), agents: [agent],
          native: native),
        selector: .command(name: name), origin: origin, container: container,
        profile: input.profile, into: &diagnostics, admission: admission)
    }
    let relative =
      container == "." ? input.document : String(input.document.dropFirst(container.count + 1))
    try NativeImportInput.resource(
      relative, root: container, input: input, origin: origin, limits: limits, into: &diagnostics,
      admission: admission)
  }

  private static func nativeValue(_ yaml: ImportYAML) throws -> NativeValue {
    if let pairs = yaml.pairs {
      return .object(
        try pairs.map { ($0.0, try nativeValue($0.1)) }.reduce(into: [:]) { $0[$1.0] = $1.1 })
    }
    if let items = yaml.items { return .array(try items.map { try nativeValue($0) }) }
    if let text = yaml.string { return .string(text) }
    if let value = yaml.boolean { return .boolean(value) }
    if let value = yaml.integer { return .integer(value) }
    if let scalar = yaml.node.scalar {
      if scalar.decimalTag || YAMLScalar.classify(scalar.text) == .decimal {
        // Decimal spelling stays private until the finite field validator admits its domain.
        return .decimal(scalar.text)
      }
      if YAMLScalar.classify(scalar.text) == .null { return .null }
    }
    throw ImportLocatedFailure(location: yaml.location)
  }
}
