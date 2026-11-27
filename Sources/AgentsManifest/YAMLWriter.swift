import AgentsCore

/// Canonical output is used for new documents and owned replacement values. Existing documents
/// are changed through concrete ranges; their unrelated bytes are never reprinted.
enum YAMLWriter {
  static func manifest(_ value: DeclarationIR) -> [UInt8] {
    var result = "version: 1\n"
    if let agents = value.defaultAgents {
      result += "defaultAgents: " + flow(YAMLConstruction.strings(agents)) + "\n"
    }
    if !value.sources.isEmpty { result += namedBlock("sources", value.sources) }
    if !value.packages.isEmpty { result += namedBlock("packages", value.packages) }
    if !value.components.isEmpty {
      result += "components:\n"
      for component in value.components { result += "  - " + flow(.record(component)) + "\n" }
    }
    if !value.groups.isEmpty { result += namedBlock("groups", value.groups) }
    if !value.uses.isEmpty {
      result += "uses: " + flow(.array(value.uses.map(DeclarationValue.record))) + "\n"
    }
    if !value.exports.isEmpty {
      result += "exports: " + flow(YAMLConstruction.strings(value.exports)) + "\n"
    }
    if let lifecycle = value.lifecycle { result += "lifecycle: " + flow(lifecycle) + "\n" }
    if !value.watch.isEmpty {
      result += "watch: " + flow(YAMLConstruction.strings(value.watch)) + "\n"
    }
    return Array(result.utf8)
  }

  private static func namedBlock(_ field: String, _ records: [DeclarationRecord]) -> String {
    field + ":\n"
      + records.map {
        "  " + quote($0["name"]!.string!) + ": " + flow(.record($0), field: field) + "\n"
      }.joined()
  }

  static func quote(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\0"..<" ", "\u{7F}"..."\u{9F}", "\u{2028}", "\u{2029}", "\u{FFFE}", "\u{FFFF}":
        let hex = String(scalar.value, radix: 16)
        result += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
      default: result += String(scalar)
      }
    }
    return result + "\""
  }

  static func flow(_ value: DeclarationValue, field: String = "") -> String {
    switch value {
    case .null: return "null"
    case .string(let value): return quote(value)
    case .integer(let value): return String(value)
    case .boolean(let value): return value ? "true" : "false"
    case .dictionary(let values):
      return mapping(values.keys.sorted(by: utf8Less).map { ($0, flow(values[$0]!, field: $0)) })
    case .array(let values):
      if ["sources", "packages", "groups", "overrides", "chatGPT"].contains(field) {
        return mapping(
          values.map { value in
            let record = value.record!
            return (record["name"]!.string!, flow(value, field: field))
          })
      }
      return "[" + values.map { flow($0) }.joined(separator: ", ") + "]"
    case .requirement(let value):
      let key: String
      switch value {
      case .branch: key = "branch"
      case .revision: key = "revision"
      case .exact: key = "exact"
      case .upToNextMajor, .range: key = "from"
      case .upToNextMinor: key = "upToNextMinor"
      }
      var fields = [(key, quote(value.value))]
      if let upper = value.upperBound { fields.append(("to", quote(upper))) }
      return mapping(fields)
    case .record(let record):
      let f = record.fields
      if ["string", "integer", "boolean", "array", "object"].contains(record.kind),
        let payload = f["value"]
      {
        return flow(payload)
      }
      if record.kind == "decimal" { return "!!float " + quote(f["value"]!.string!) }
      if record.kind == "null" { return "null" }
      if record.kind == "literal" { return quote(f["value"]!.string!) }
      if ["environment", "secret", "native", "tool"].contains(record.kind) {
        return mapping([
          (record.kind == "environment" ? "env" : record.kind, quote(f["value"]!.string!))
        ])
      }
      if record.kind == "file" {
        return mapping([("file", flow(.record(DeclarationRecord(kind: "path", fields: f))))])
      }
      if f.isEmpty { return quote(record.kind) }
      let componentKinds = [
        "skills", "instructions", "mcpServer", "hook", "subagent", "command", "lspServer",
        "permissions", "ignore", "plugin",
      ]
      var pairs: [(String, String)] = []
      if componentKinds.contains(record.kind)
        || ["stdio", "streamableHTTP", "sse"].contains(record.kind)
      {
        pairs.append(("kind", quote(record.kind)))
      }
      if ["allow", "ask", "deny"].contains(record.kind) {
        pairs.append(("effect", quote(record.kind)))
      }
      let named = ["sources", "packages", "groups", "overrides", "chatGPT"].contains(field)
      let order = [
        "name", "source", "url", "path", "index", "requirement", "subpath", "select", "exclude",
        "mode", "overrides", "sections", "chatGPT", "description", "prompt", "model", "tools",
        "parameters", "transport", "event", "run", "matcher", "timeoutSeconds", "executable",
        "executableSource", "arguments", "environment", "workingDirectory", "headers", "languages",
        "initializationOptions", "rules", "operation", "pattern", "patterns", "purpose",
        "components", "uses", "append", "agents", "recipients", "scopes", "platforms", "condition",
        "native",
      ]
      let keys = f.keys.sorted { left, right in
        let a = order.firstIndex(of: left) ?? order.count
        let b = order.firstIndex(of: right) ?? order.count
        return a == b ? utf8Less(left, right) : a < b
      }
      for key in keys where f[key] != .null && !(named && key == "name") {
        let yamlKey =
          key == "chatGPT"
          ? "chatgpt"
          : ["local", "exported"].contains(record.kind) && f["path"] == nil && key == "name"
            ? "group" : key
        pairs.append((yamlKey, flow(f[key]!, field: key)))
      }
      return mapping(pairs)
    }
  }

  static func mapping(_ values: [(String, String)]) -> String {
    "{" + values.map { quote($0.0) + ": " + $0.1 }.joined(separator: ", ") + "}"
  }
}
