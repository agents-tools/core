import AgentsCore

/// Converts validated YAML data into the syntax-independent complete declaration, recording
/// semantic indexed pointers while the concrete mapping keys are still available.
final class YAMLProjection {
  let source: SourceText
  private(set) var locations: [String: YAMLNode] = [:]
  private(set) var entries: [SourceMapEntry] = []
  private var budget = SourceMapBudget()
  private var entryIndexes: [String: Int] = [:]

  init(source: SourceText) { self.source = source }

  func declaration(_ root: YAMLNode) throws -> DeclarationIR {
    try mark(root, "")
    let fields = fields(root)
    let sources = try named(fields["sources"], at: "/sources", owner: root, role: "source")
    let components = try records(
      fields["components"], at: "/components", owner: root, role: "component")
    let groups = try named(fields["groups"], at: "/groups", owner: root, role: "group")
    let uses = try records(fields["uses"], at: "/uses", owner: root, role: "use")
    let defaults = try field(
      fields["defaultAgents"], at: "/defaultAgents", owner: root, default: .null)
    let exports = try field(fields["exports"], at: "/exports", owner: root, default: .array([]))
    let watch = try field(fields["watch"], at: "/watch", owner: root, default: .array([]))
    return DeclarationIR(
      defaultAgents: defaults.elements.map { $0.map { $0.string! } },
      exports: exports.elements!.map { $0.string! }, sources: sources, components: components,
      groups: groups, uses: uses, watch: watch.elements!.map { $0.string! })
  }

  private func fields(_ node: YAMLNode) -> [String: YAMLNode] {
    Dictionary(uniqueKeysWithValues: (node.pairs ?? []).map { ($0.key.text!, $0.value) })
  }

  private func mark(_ node: YAMLNode, _ pointer: String, defaulted: Bool = false) throws {
    let span = source.span(node.range)
    if let index = entryIndexes[pointer] {
      locations[pointer] = node
      entries[index] = SourceMapEntry(pointer: pointer, span: span, defaulted: defaulted)
      return
    }
    guard budget.consume(pointer: pointer, span: span, origins: []) else {
      throw source.failure("manifest.limit", "source map budget", node.range.lowerBound)
    }
    locations[pointer] = node
    entryIndexes[pointer] = entries.count
    entries.append(SourceMapEntry(pointer: pointer, span: span, defaulted: defaulted))
  }

  private func field(
    _ node: YAMLNode?, at pointer: String, owner: YAMLNode, default fallback: DeclarationValue
  ) throws -> DeclarationValue {
    guard let node else {
      try mark(owner, pointer, defaulted: true)
      return fallback
    }
    return try plain(node, at: pointer)
  }

  private func plain(_ node: YAMLNode, at pointer: String) throws -> DeclarationValue {
    try mark(node, pointer)
    switch node.data {
    case .scalar(let text, let quoted, _):
      if quoted { return .string(text) }
      switch YAMLScalar.classify(text) {
      case .integer: return .integer(YAMLScalar.integer(text)!)
      case .boolean: return .boolean(text.lowercased() == "true")
      case .null: return .null
      default: return .string(text)
      }
    case .sequence(let items):
      return try .array(
        items.enumerated().map { try plain($0.element, at: pointer + "/\($0.offset)") })
    case .mapping(let pairs):
      var result: [String: DeclarationValue] = [:]
      for pair in pairs {
        result[pair.key.text!] = try plain(
          pair.value, at: pointer + "/" + pointerEscape(pair.key.text!))
      }
      return .dictionary(result)
    }
  }

  private func records(_ node: YAMLNode?, at pointer: String, owner: YAMLNode, role: String) throws
    -> [DeclarationRecord]
  {
    try mark(node ?? owner, pointer, defaulted: node == nil)
    return try (node?.items ?? []).enumerated().map {
      try record($0.element, at: pointer + "/\($0.offset)", role: role)
    }
  }

  private func named(_ node: YAMLNode?, at pointer: String, owner: YAMLNode, role: String) throws
    -> [DeclarationRecord]
  {
    try mark(node ?? owner, pointer, defaulted: node == nil)
    return try (node?.pairs ?? []).enumerated().map { index, pair in
      let path = pointer + "/\(index)"
      var value = try record(pair.value, at: path, role: role).fields
      value["name"] = .string(pair.key.text!)
      try mark(pair.key, path + "/name")
      return DeclarationRecord(kind: kind(pair.value, role: role), fields: value)
    }
  }

  private func kind(_ node: YAMLNode, role: String) -> String {
    let f = fields(node)
    switch role {
    case "component", "transport", "reference": return f["kind"]!.text!
    case "source": return f["url"] != nil ? "git" : f["path"] != nil ? "local" : "index"
    case "use": return f["source"] == nil ? "local" : "exported"
    case "condition": return "when"
    case "section": return "section"
    case "group": return "group"
    case "override": return "skill"
    case "promptDeclaration": return "prompt"
    case "resource": return "path"
    case "run": return "executable"
    case "parameter": return "parameter"
    case "rule": return f["effect"]!.text!
    default: return role
    }
  }

  private func record(_ node: YAMLNode, at pointer: String, role: String) throws
    -> DeclarationRecord
  {
    try mark(node, pointer)
    let input = fields(node)
    let kind = kind(node, role: role)
    if let explicit = input["kind"] {
      try mark(explicit, pointer + "/kind")
    } else if role == "source",
      let key = node.pairs?.first(where: { ["url", "path", "index"].contains($0.key.text!) })?.key
    {
      try mark(key, pointer + "/kind")
    } else if role == "rule", let effect = input["effect"] {
      try mark(effect, pointer + "/kind")
    } else {
      try mark(node, pointer + "/kind", defaulted: true)
    }
    var output: [String: DeclarationValue] = [:]
    var defaults: [String: DeclarationValue] = [:]
    if role == "component" {
      defaults = ["agents": .null, "condition": .null, "native": .dictionary([:])]
    }
    switch role == "component" ? kind : role {
    case "source": defaults = ["subpath": .null, "requirement": .null]
    case "condition": defaults = ["agents": .null, "scopes": .null, "platforms": .null]
    case "group": defaults = ["components": .array([]), "uses": .array([]), "condition": .null]
    case "use", "section": defaults = ["source": .null, "condition": .null]
    case "override": defaults = ["agents": .null, "mode": .null]
    case "promptDeclaration":
      defaults = ["sections": .array([]), "append": .null, "condition": .null]
    case "resource": defaults = ["source": .null]
    case "run", "transport":
      defaults = [
        "arguments": .array([]), "environment": .dictionary([:]), "workingDirectory": .null,
      ]
    case "parameter": defaults = ["defaultValue": .null]
    case "skills":
      defaults.merge([
        "select": .string("all"), "exclude": .array([]), "mode": .null, "overrides": .array([]),
      ]) { _, r in r }
    case "instructions":
      defaults.merge(["sections": .array([]), "chatGPT": .array([])]) { _, r in r }
    case "hook": defaults.merge(["matcher": .null, "timeoutSeconds": .null]) { _, r in r }
    case "subagent": defaults.merge(["model": .null, "tools": .null]) { _, r in r }
    case "command": defaults["parameters"] = .array([])
    case "lspServer": defaults["initializationOptions"] = .dictionary([:])
    case "ignore": defaults["purpose"] = .string("context")
    case "plugin":
      defaults.merge(["mode": .string("components"), "select": .null, "exclude": .array([])]) {
        _, r in r
      }
    default: break
    }
    if role == "transport", kind != "stdio" { defaults = ["headers": .dictionary([:])] }
    for (name, fallback) in defaults {
      let yamlName = name == "chatGPT" ? "chatgpt" : name
      if input[yamlName] == nil {
        try mark(node, pointer + "/" + name, defaulted: true)
        output[name] = fallback
      }
    }
    for (name, value) in input {
      if name == "kind" || role == "rule" && name == "effect" { continue }
      let field = name == "chatgpt" ? "chatGPT" : role == "use" && name == "group" ? "name" : name
      let path = pointer + "/" + pointerEscape(field)
      switch name {
      case "condition": output[field] = try .record(record(value, at: path, role: "condition"))
      case "components":
        output[field] = try .array(
          records(value, at: path, owner: node, role: "component").map(DeclarationValue.record))
      case "uses":
        output[field] = try .array(
          records(value, at: path, owner: node, role: "use").map(DeclarationValue.record))
      case "overrides":
        output[field] = try .array(
          named(value, at: path, owner: node, role: "override").map(DeclarationValue.record))
      case "chatgpt":
        output[field] = try .array(
          named(value, at: path, owner: node, role: "promptDeclaration").map(
            DeclarationValue.record))
      case "sections", "parameters", "rules":
        let childRole = name == "sections" ? "section" : name == "parameters" ? "parameter" : "rule"
        output[field] = try .array(
          records(value, at: path, owner: node, role: childRole).map(DeclarationValue.record))
      case "transport", "run", "workingDirectory":
        output[field] = try .record(
          record(value, at: path, role: name == "workingDirectory" ? "resource" : name))
      case "prompt": output[field] = try prompt(value, at: path)
      case "event", "operation": output[field] = try symbol(value, at: path, role: name)
      case "environment", "headers":
        try mark(value, path)
        var result: [String: DeclarationValue] = [:]
        for pair in value.pairs! {
          result[pair.key.text!] = try binding(
            pair.value, at: path + "/" + pointerEscape(pair.key.text!))
        }
        output[field] = .dictionary(result)
      case "native":
        try mark(value, path)
        var schemas: [String: DeclarationValue] = [:]
        for pair in value.pairs! {
          schemas[pair.key.text!] = try nativeDictionary(
            pair.value, at: path + "/" + pointerEscape(pair.key.text!))
        }
        output[field] = .dictionary(schemas)
      case "initializationOptions": output[field] = try nativeDictionary(value, at: path)
      case "exclude" where role == "component" && kind == "plugin":
        output[field] = try .array(
          records(value, at: path, owner: node, role: "reference").map(DeclarationValue.record))
      case "requirement":
        try mark(value, path)
        let requirement = fields(value)
        let text = requirement.values.first!.text!
        let parsed: SourceRequirement
        if let branch = requirement["branch"]?.text {
          parsed = .branch(branch)
        } else if let revision = requirement["revision"]?.text {
          parsed = .revision(revision)
        } else if let exact = requirement["exact"]?.text {
          parsed = .exact(exact)
        } else if let minor = requirement["upToNextMinor"]?.text {
          parsed = .upToNextMinor(from: minor)
        } else if let upper = requirement["to"]?.text {
          parsed = .range(from: requirement["from"]!.text!, to: upper)
        } else {
          parsed = .upToNextMajor(from: text)
        }
        let canonical = parsed.canonical
        output[field] = .requirement(canonical)
        let lower =
          requirement["from"] ?? requirement["upToNextMinor"] ?? requirement["branch"]
          ?? requirement["revision"] ?? requirement["exact"]!
        try mark(lower, path + "/value")
        try mark(value.pairs!.first!.key, path + "/kind")
        if canonical.upperBound != nil, let upper = requirement["to"] {
          try mark(upper, path + "/to")
        }
      case "url" where role == "source":
        try mark(value, path)
        output[field] = .string(SourceDeclaration(kind: .git, location: value.text!).gitURL)
      default: output[field] = try plain(value, at: path)
      }
    }
    return DeclarationRecord(kind: kind, fields: output)
  }

  private func prompt(_ node: YAMLNode, at pointer: String) throws -> DeclarationValue {
    if let text = node.text {
      try mark(node, pointer)
      try mark(node, pointer + "/kind", defaulted: true)
      try mark(node, pointer + "/value")
      return .record(DeclarationRecord(kind: "literal", fields: ["value": .string(text)]))
    }
    let resource = try record(fields(node)["file"]!, at: pointer, role: "resource")
    try mark(node.pairs!.first!.key, pointer + "/kind")
    return .record(DeclarationRecord(kind: "file", fields: resource.fields))
  }

  private func symbol(_ node: YAMLNode, at pointer: String, role: String) throws -> DeclarationValue
  {
    try mark(node, pointer)
    try mark(node, pointer + "/kind")
    if let text = node.text { return .record(DeclarationRecord(kind: text, fields: [:])) }
    let pair = node.pairs!.first!
    try mark(pair.value, pointer + "/value")
    return .record(
      DeclarationRecord(kind: pair.key.text!, fields: ["value": .string(pair.value.text!)]))
  }

  private func binding(_ node: YAMLNode, at pointer: String) throws -> DeclarationValue {
    try mark(node, pointer)
    let kind: String
    let value: YAMLNode
    if node.text != nil {
      kind = "literal"
      value = node
    } else {
      let pair = node.pairs!.first!
      kind = pair.key.text == "env" ? "environment" : "secret"
      value = pair.value
    }
    try mark(value, pointer + "/value")
    try mark(node, pointer + "/kind", defaulted: node.text != nil)
    return .record(DeclarationRecord(kind: kind, fields: ["value": .string(value.text!)]))
  }

  private func nativeDictionary(_ node: YAMLNode, at pointer: String) throws -> DeclarationValue {
    try mark(node, pointer)
    var values: [String: DeclarationValue] = [:]
    for pair in node.pairs! {
      values[pair.key.text!] = try native(
        pair.value, at: pointer + "/" + pointerEscape(pair.key.text!))
    }
    return .dictionary(values)
  }

  private func native(_ node: YAMLNode, at pointer: String) throws -> DeclarationValue {
    try mark(node, pointer)
    try mark(node, pointer + "/kind")
    let kind: String
    let payload: DeclarationValue?
    switch node.data {
    case .scalar(let text, let quoted, let tag):
      switch tag ? YAMLScalar.decimal : quoted ? .string : YAMLScalar.classify(text) {
      case .string:
        kind = "string"
        payload = .string(text)
      case .integer:
        kind = "integer"
        payload = .integer(YAMLScalar.integer(text)!)
      case .boolean:
        kind = "boolean"
        payload = .boolean(text.lowercased() == "true")
      case .null:
        kind = "null"
        payload = nil
      case .decimal:
        kind = "decimal"
        payload = .string(YAMLScalar.decimal(text, explicit: tag)!)
      }
    case .sequence(let items):
      kind = "array"
      payload = try .array(
        items.enumerated().map { try native($0.element, at: pointer + "/value/\($0.offset)") })
    case .mapping:
      kind = "object"
      payload = try nativeDictionary(node, at: pointer + "/value")
    }
    if payload != nil { try mark(node, pointer + "/value") }
    return .record(DeclarationRecord(kind: kind, fields: payload.map { ["value": $0] } ?? [:]))
  }
}
