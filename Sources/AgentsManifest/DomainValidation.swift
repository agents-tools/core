import AgentsCore
import AgentsDescription
import Foundation

final class DomainValidator {
  private let source: SourceText
  private let admission: Admission
  private let evaluation: Evaluation
  private var diagnostics: [ManifestDiagnostic] = []
  private var aliases: [String: ConstructionValue] = [:]
  private var groups: [String: EvaluatedValue] = [:]
  private var work = 0

  init(source: SourceText, admission: Admission, evaluation: Evaluation) {
    self.source = source
    self.admission = admission
    self.evaluation = evaluation
  }

  private func failure(
    _ message: String, _ value: EvaluatedValue, code: String = "manifest.domain",
    related: [SourceSpan] = []
  ) -> ManifestFailure {
    ManifestFailure(
      ManifestDiagnostic(
        code: code, message: message, span: source.span(admission.nodes[value.syntax].range),
        related: related))
  }

  func validate() throws -> [ManifestDiagnostic] {
    let root = evaluation.root
    let fields = root.value.fields
    var identities: [String: EvaluatedValue] = [:]
    let sources = root.field("sources")?.elementsForUse ?? []
    for value in sources {
      let f = value.value.fields
      let name = f["name"]?.text ?? ""
      guard !name.isEmpty, name != ".", !name.contains(":"), aliases[name] == nil else {
        throw failure("invalid or duplicate source alias", value)
      }
      aliases[name] = value.value
      let identity: String
      if let url = f["url"]?.text {
        let declaration = SourceDeclaration(kind: .git, location: url)
        do { identity = try declaration.transportIdentity() } catch {
          throw failure("invalid Git URL", value.field("url") ?? value)
        }
        if declaration.gitURL != url {
          let target = value.field("url") ?? value
          let range = admission.nodes[target.syntax].range
          if diagnostics.count < ManifestLimits.Diagnostics.warnings {
            diagnostics.append(
              ManifestDiagnostic(
                code: "manifest.domain", severity: .warning,
                message: "use the complete Git transport URL", span: source.span(range),
                fixIt: SourcePatch(
                  range: range, replacement: Array(quoted(declaration.gitURL).utf8))))
          } else if diagnostics.count == ManifestLimits.Diagnostics.warnings {
            diagnostics.append(
              ManifestDiagnostic(
                code: "manifest.diagnostics.truncated", severity: .warning,
                message: "further diagnostics omitted", span: source.span(range)))
          }
        }
      } else if let index = f["index"]?.text {
        do {
          identity = try SourceDeclaration(kind: .wellKnown, location: index).transportIdentity()
        } catch { throw failure("invalid index URL", value) }
      } else {
        let location = f["path"]?.text ?? ""
        if location.isEmpty || location.contains("\0") {
          throw failure("empty or invalid local source", value)
        }
        identity = "local:" + lexicalPath(location)
      }
      if let original = identities[identity] {
        throw failure(
          "two aliases normalize to the same source identity", value,
          related: [source.span(admission.nodes[original.syntax].range)])
      }
      identities[identity] = value
    }
    for value in root.field("groups")?.elementsForUse ?? [] {
      let name = value.value.fields["name"]?.text ?? ""
      if groups[name] != nil { throw failure("duplicate group name", value) }
      groups[name] = value
    }
    try unique(fields["exports"]?.array ?? [], at: root, message: "duplicate export")
    for name in fields["exports"]?.strings ?? [] where groups[name] == nil {
      throw failure("unknown exported group: \(name)", root, code: "manifest.group.missing")
    }
    try unique(fields["watch"]?.array ?? [], at: root, message: "duplicate watch subscription")
    for name in fields["watch"]?.strings ?? [] where aliases[name] == nil {
      throw failure("unknown watch source: \(name)", root)
    }
    // All definitions, including unused constants and inactive values, get domain checks.
    for value in evaluation.constants.values { try walk(value, anchor: value) }
    var completed = Set<String>()
    for (name, value) in groups {
      try cycle(name, stack: [], spans: [], value: value, completed: &completed)
    }
    return diagnostics.sorted { ($0.span.start, $0.code) < ($1.span.start, $1.code) }
  }

  private func walk(_ value: EvaluatedValue, anchor: EvaluatedValue) throws {
    var pending = [(value, anchor)]
    while let (value, anchor) = pending.popLast() {
      work += 1
      if work > ManifestLimits.Domain.steps {
        throw failure("domain traversal budget", anchor, code: "manifest.limit")
      }
      if let referent = value.referent {
        pending.append((referent, value))
        continue
      }
      try check(value.value, at: value)
      let children =
        !value.fields.isEmpty
        ? Array(value.fields.values) : value.elements
      if children.isEmpty {
        try checkChildren(value.value, at: value)
      } else {
        for child in children { pending.append((child, anchor)) }
      }
    }
  }

  private func checkChildren(_ value: ConstructionValue, at anchor: EvaluatedValue) throws {
    let children: [ConstructionValue]
    switch value {
    case .node(_, _, let fields), .object(let fields): children = Array(fields.values)
    case .array(let values): children = values
    default: return
    }
    for child in children {
      work += 1
      if work > ManifestLimits.Domain.steps {
        throw failure("domain traversal budget", anchor, code: "manifest.limit")
      }
      try check(child, at: anchor)
      try checkChildren(child, at: anchor)
    }
  }

  private func check(_ value: ConstructionValue, at anchor: EvaluatedValue) throws {
    guard case .node(let type, let member, let f) = value else { return }
    if let agents = f["agents"]?.array {
      try unique(agents, at: anchor, message: "duplicate recipients")
    }
    switch type {
    case "Agents":
      if let defaults = f["defaultAgents"]?.array {
        try unique(defaults, at: anchor, message: "duplicate default recipients")
      }
    case "Condition":
      for dimension in ["agents", "scopes", "platforms"] {
        if let array = f[dimension]?.array {
          try unique(array, at: anchor, message: "duplicate condition member")
        }
      }
    case "Source":
      let alias = f["name"]?.text ?? ""
      if alias.isEmpty || alias == "." || alias.contains(":") {
        throw failure("invalid source alias", anchor)
      }
      if let url = f["url"]?.text {
        do { _ = try SourceDeclaration(kind: .git, location: url).transportIdentity() } catch {
          throw failure("invalid Git URL", anchor)
        }
      } else if let index = f["index"]?.text {
        do {
          _ = try SourceDeclaration(kind: .wellKnown, location: index).transportIdentity()
        } catch { throw failure("invalid index URL", anchor) }
      } else if let path = f["path"]?.text, path.isEmpty || path.contains("\0") {
        throw failure("invalid local source location", anchor)
      }
      if let path = f["subpath"]?.text { try resource(path, anchor) }
      if let requirement = f["requirement"] {
        if case .node(_, let kind, let fields) = requirement, ["branch", "revision"].contains(kind)
        {
          let text = fields["value"]?.text ?? ""
          if text.isEmpty || text.hasPrefix("-") || text.contains("\0") {
            throw failure("invalid source requirement", anchor)
          }
        }
      }
    case "SkillSelection":
      if let names = f["names"]?.strings { try skillNames(names, anchor) }
    case "SkillOverride": try skillNames([f["name"]?.text ?? ""], anchor)
    case "ComponentGroup": try name(f["name"]?.text ?? "", anchor)
    case "GroupReference":
      let group = f["name"]?.text ?? ""
      try name(group, anchor)
      if let alias = f["source"]?.text {
        try sourceAlias(alias, anchor)
      } else if groups[group] == nil {
        throw failure("unknown local group: \(group)", anchor, code: "manifest.group.missing")
      }
    case "SectionReference":
      if !Declaration.isInstructionName(f["name"]?.text ?? "") {
        throw failure("invalid instruction section name", anchor)
      }
      if let alias = f["source"]?.text { try sourceAlias(alias, anchor) }
    case "ChatGPTPrompt":
      if let append = f["append"]?.text { try resource(append, anchor) }
    case "Resource", "PromptContent":
      if let path = f["path"]?.text { try resource(path, anchor) }
      if let alias = f["source"]?.text { try sourceAlias(alias, anchor) }
    case "ExecutableInvocation", "MCPTransport":
      if let executable = f["executable"]?.text {
        if executable.isEmpty || executable.contains("\0") {
          throw failure("invalid executable", anchor)
        }
        if executable.contains("/") || executable.hasPrefix("~") {
          try resource(executable, anchor)
        }
      }
      if type == "MCPTransport" && member != "stdio" { try http(f["url"]?.text ?? "", anchor) }
    case "ConfigurationValue":
      if member == "decimal" {
        let text = f["value"]?.text ?? ""
        let valid =
          text.range(
            of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression)
          != nil
        if !valid || Double(text)?.isFinite != true {
          throw failure("decimal requires finite JSON-number text", anchor)
        }
      }
    case "PromptParameter":
      let n = f["name"]?.text ?? ""
      if n.isEmpty || n.contains("}") || n.contains(":") || n.contains("\0") {
        throw failure("invalid prompt parameter name", anchor)
      }
    case "ComponentReference": try name(f["name"]?.text ?? "", anchor)
    case "PermissionRule":
      if ["read", "write"].contains(f["operation"]?.member ?? "") {
        try resource(f["pattern"]?.text ?? "", anchor)
      }
    case "Component": try component(member, fields: f, anchor: anchor)
    default: break
    }
  }

  private func component(
    _ kind: String, fields f: [String: ConstructionValue], anchor: EvaluatedValue
  ) throws {
    if let n = f["name"]?.text { try name(n, anchor) }
    if kind == "skills" {
      let alias = f["source"]?.text ?? ""
      try sourceAlias(alias, anchor)
      let selection = f["select"]!
      let names = selection.fields["names"]?.strings
      try skillNames(f["exclude"]?.strings ?? [], anchor)
      let overrides = f["overrides"]?.array ?? []
      try uniqueNames(overrides, anchor)
      for override in overrides {
        let n = override.fields["name"]?.text ?? ""
        if let names, !names.contains(n) {
          throw failure("override is outside explicit skill selection", anchor)
        }
      }
      let modes = [f["mode"]].compactMap { $0 } + overrides.compactMap { $0.fields["mode"] }
      if modes.contains(where: { $0.member == "edit" }) {
        if alias != ".", let source = aliases[alias],
          source.fields["path"]?.text == nil
            || source.fields["requirement"] != ConstructionValue.none
        {
          throw failure("edit mode needs a local source without a requirement", anchor)
        }
      }
    }
    if kind == "instructions" { try uniqueNames(f["chatGPT"]?.array ?? [], anchor) }
    if kind == "hook" {
      if case .integer(let timeout) = f["timeoutSeconds"], timeout <= 0 {
        throw failure("hook timeout must be positive", anchor)
      }
      if f["event"]?.member == "native", f["agents"]?.array?.count != 1 {
        throw failure("native hook event requires exactly one explicit recipient", anchor)
      }
    }
    if kind == "plugin" {
      try sourceAlias(f["source"]?.text ?? "", anchor)
      try resource(f["path"]?.text ?? "", anchor)
      if f["mode"]?.member == "native" {
        if f["agents"]?.array?.count != 1 || f["select"] != ConstructionValue.none
          || !(f["exclude"]?.array ?? []).isEmpty
        {
          throw failure(
            "native plugin requires one explicit recipient and no selection/exclusions", anchor)
        }
      }
      if let selection = f["select"]?.array {
        try unique(selection, at: anchor, message: "duplicate plugin selection")
      }
      try unique(f["exclude"]?.array ?? [], at: anchor, message: "duplicate plugin exclusion")
    }
    if kind == "lspServer", case .object(let languages) = f["languages"] {
      if languages.keys.contains(where: {
        !$0.hasPrefix(".") || $0.count <= 1 || $0.contains("/") || $0.contains("\0")
      }) || languages.values.contains(where: { $0.text?.isEmpty != false }) {
        throw failure("invalid language extension mapping", anchor)
      }
    }
    if kind == "command" {
      let parameters = f["parameters"]?.array ?? []
      try uniqueNames(parameters, anchor)
      let declared = Set(parameters.compactMap { $0.fields["name"]?.text })
      if f["prompt"]?.member == "literal", let prompt = f["prompt"]?.fields["value"]?.text {
        let bytes = Array(prompt.utf8)
        var i = 0
        let escapedInput = Array("$${input:".utf8)
        let input = Array("${input:".utf8)
        while i < bytes.count {
          if bytes[i...].starts(with: escapedInput) {
            i += 2
            while i < bytes.count && bytes[i] != UInt8(ascii: "}") { i += 1 }
          } else if bytes[i...].starts(with: input) {
            let first = i + 8
            i = first
            while i < bytes.count && bytes[i] != UInt8(ascii: "}") { i += 1 }
            if i == bytes.count
              || !declared.contains(String(decoding: bytes[first..<i], as: UTF8.self))
            {
              throw failure("undeclared or malformed input token", anchor)
            }
          }
          i += 1
        }
      }
    }
  }

  private func cycle(
    _ name: String, stack: [String], spans: [SourceSpan], value: EvaluatedValue,
    completed: inout Set<String>
  ) throws {
    if stack.contains(name) {
      throw failure(
        "local group reference cycle: \((stack + [name]).joined(separator: " -> "))", value,
        code: "manifest.group.cycle", related: spans)
    }
    if completed.contains(name) { return }
    if stack.count == ManifestLimits.Groups.activeReferences {
      throw failure("local group reference depth", value, code: "manifest.limit")
    }
    for reference in value.field("uses")?.elementsForUse ?? []
    where reference.value.fields["source"] == ConstructionValue.none {
      let next = reference.value.fields["name"]?.text ?? ""
      if let child = groups[next] {
        try cycle(
          next, stack: stack + [name],
          spans: spans + [source.span(admission.nodes[reference.syntax].range)], value: child,
          completed: &completed)
      }
    }
    completed.insert(name)
  }

  private func sourceAlias(_ alias: String, _ anchor: EvaluatedValue) throws {
    if alias != "." && aliases[alias] == nil {
      throw failure("unknown source alias: \(alias)", anchor)
    }
  }
  private func unique(_ values: [ConstructionValue], at anchor: EvaluatedValue, message: String)
    throws
  {
    var seen = Set<String>()
    for value in values {
      let key = value.text ?? value.member + ":" + (value.fields["name"]?.text ?? "")
      if !seen.insert(key).inserted { throw failure(message, anchor) }
    }
  }
  private func uniqueNames(_ values: [ConstructionValue], _ anchor: EvaluatedValue) throws {
    try unique(
      values.map { .text($0.fields["name"]?.text ?? "") }, at: anchor,
      message: "duplicate named member")
  }
  private func skillNames(_ names: [String], _ anchor: EvaluatedValue) throws {
    do { try Declaration.validateNames(names) } catch {
      throw failure("invalid or duplicate skill names", anchor)
    }
  }
  private func name(_ value: String, _ anchor: EvaluatedValue) throws {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      || value.contains(":") || value.contains("\\")
      || value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    {
      throw failure("invalid relative name", anchor)
    }
  }
  private func resource(_ path: String, _ anchor: EvaluatedValue) throws {
    if path == "~" || path.hasPrefix("~/") {
      throw failure("resource needs a safe relative path", anchor)
    }
    do { _ = try PathSafety.sanitizeSubpath(path) } catch {
      throw failure("resource needs a safe relative path", anchor)
    }
  }
  private func http(_ text: String, _ anchor: EvaluatedValue) throws {
    guard let url = URLComponents(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil
    else { throw failure("transport needs an HTTP(S) URL without credentials or fragment", anchor) }
  }
  private func lexicalPath(_ path: String) -> String {
    let prefix = path.hasPrefix("/") ? "/" : path.hasPrefix("~/") ? "~/" : ""
    let body = prefix.isEmpty ? path[...] : path.dropFirst(prefix.count)
    var parts: [Substring] = []
    for part in body.split(separator: "/") {
      if part == "." { continue }
      if part == "..", let last = parts.last, last != ".." {
        parts.removeLast()
      } else {
        parts.append(part)
      }
    }
    return prefix + parts.joined(separator: "/")
  }
}
