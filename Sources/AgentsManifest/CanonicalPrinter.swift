import AgentsCore
import AgentsDescription
import Foundation

func quoted(_ string: String) -> String {
  var result = "\""
  for scalar in string.unicodeScalars {
    switch scalar {
    case "\"": result += "\\\""
    case "\\": result += "\\\\"
    case "\n": result += "\\n"
    case "\r": result += "\\r"
    case "\t": result += "\\t"
    case "\0"..<" ", "\u{7F}"..."\u{9F}":
      result += "\\u{" + String(scalar.value, radix: 16) + "}"
    default: result.unicodeScalars.append(scalar)
    }
  }
  return result + "\""
}

struct PrintStyle {
  var indent = "  "
  var newline = "\n"
  var trailingComma = true
}

/// A layout reserves its exact UTF-8 size before allocating emitted source bytes.
private struct Printed {
  private indirect enum Content {
    case text(String)
    case quoted(String)
    case parts([Printed])
  }
  private let content: Content
  let count: Int

  init(_ text: String) {
    content = .text(text)
    count = text.utf8.count
  }
  init(quoting text: String) {
    content = .quoted(text)
    var size = 2
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"", "\\", "\n", "\r", "\t": size = ValueCost.add(size, 2)
      case "\0"..<" ", "\u{7F}"..."\u{9F}":
        size = ValueCost.add(size, 4 + String(scalar.value, radix: 16).utf8.count)
      default: size = ValueCost.add(size, scalar.utf8.count)
      }
    }
    count = size
  }
  init(_ parts: [Printed]) {
    content = .parts(parts)
    count = parts.reduce(0) { ValueCost.add($0, $1.count) }
  }
  func append(to result: inout String) {
    switch content {
    case .text(let text): result += text
    case .quoted(let text): result += quoted(text)
    case .parts(let parts): for part in parts { part.append(to: &result) }
    }
  }
  var string: String {
    var result = ""
    result.reserveCapacity(count)
    append(to: &result)
    return result
  }
}

struct CanonicalPrinter {
  var style = PrintStyle()

  func render(
    _ value: ConstructionValue, indentation: String = "", column: Int? = nil, trailing: Int = 1
  ) -> String {
    layout(
      value, indentation: indentation, column: column ?? indentation.utf8.count,
      trailing: trailing
    ).string
  }

  func manifest(_ value: ConstructionValue) throws -> [UInt8] {
    let prefix = "// agents-tools-version: 1.0\nimport AgentsDescription\n\nlet agents = "
    let result = Printed([
      Printed(prefix), layout(value, indentation: "", column: 13, trailing: 0), Printed("\n"),
    ])
    guard result.count <= ManifestLimits.Input.bytes else {
      throw ManifestFailure(
        ManifestDiagnostic(
          code: "manifest.limit", message: "generated source bytes",
          span: SourceSpan(
            document: DocumentIdentity("manifest"), start: 0, end: 0, line: 1, column: 1)))
    }
    return Array(result.string.utf8)
  }

  /// The parenthesized argument list of a call whose opening parenthesis is at `column`.
  func argumentList(
    _ arguments: [(String, ConstructionValue)], indentation: String, column: Int, trailing: Int
  ) -> String {
    call("", arguments: arguments, indentation: indentation, column: column, trailing: trailing)
      .string
  }

  private func layout(
    _ value: ConstructionValue, indentation: String, column: Int, trailing: Int
  ) -> Printed {
    switch value {
    case .text(let text): return Printed(quoting: text)
    case .integer(let value): return Printed(String(value))
    case .boolean(let value): return Printed(value ? "true" : "false")
    case .none: return Printed("nil")
    case .version(let version): return Printed(quoting: version.normalized)
    case .range(let range):
      let requirement = Lowering.requirement(range)
      if case .upToNextMajor(let lower) = requirement {
        return call(
          ".upToNextMajor", arguments: [("from", .text(lower))],
          indentation: indentation, column: column, trailing: trailing)
      }
      if case .upToNextMinor(let lower) = requirement {
        return call(
          ".upToNextMinor", arguments: [("from", .text(lower))],
          indentation: indentation, column: column, trailing: trailing)
      }
      return Printed([
        Printed(quoting: range.lowerBound.normalized), Printed("..<"),
        Printed(quoting: range.upperBound.normalized),
      ])
    case .array(let values):
      let parts = values.enumerated().map { index, value in
        layout(
          value, indentation: indentation + style.indent,
          column: (indentation + style.indent).utf8.count,
          trailing: style.trailingComma || index < values.count - 1 ? 1 : 0)
      }
      return collection(
        parts, dictionary: false, forceMultiline: values.contains(where: nested),
        indentation: indentation, column: column, trailing: trailing)
    case .object(let fields):
      let keys = fields.keys.sorted(by: utf8Less)
      let parts = keys.enumerated().map { index, key in
        let prefix = Printed([Printed(quoting: key), Printed(": ")])
        return Printed([
          prefix,
          layout(
            fields[key]!, indentation: indentation + style.indent,
            column: (indentation + style.indent).utf8.count + prefix.count,
            trailing: style.trailingComma || index < keys.count - 1 ? 1 : 0),
        ])
      }
      return collection(
        parts, dictionary: true, forceMultiline: fields.values.contains(where: nested),
        indentation: indentation, column: column, trailing: trailing)
    case .node(let type, let member, let fields):
      if type == "SkillSelection" {
        return member == "all"
          ? Printed(".all")
          : layout(fields["names"]!, indentation: indentation, column: column, trailing: trailing)
      }
      if type == "VersionRange", let lower = fields["from"] {
        return call(
          "." + member, arguments: [("from", lower)],
          indentation: indentation, column: column, trailing: trailing)
      }
      if type == "PromptContent" && member == "literal"
        || type == "RuntimeValue" && member == "literal"
      {
        return layout(
          fields["value"]!, indentation: indentation, column: column, trailing: trailing)
      }
      if ["SectionReference", "GroupReference"].contains(type),
        fields["source"] == ConstructionValue.none, fields["condition"] == ConstructionValue.none
      {
        return layout(fields["name"]!, indentation: indentation, column: column, trailing: trailing)
      }
      if type == "ConfigurationValue" {
        if member == "null" { return Printed("nil") }
        if member != "decimal" {
          return layout(
            fields["value"]!, indentation: indentation, column: column, trailing: trailing)
        }
      }
      if type == "Source" {
        return source(fields, indentation: indentation, column: column, trailing: trailing)
      }
      let signature = Vocabulary.signatures.first { signature in
        guard signature.type == type, signature.member == member else { return false }
        let names = Set(signature.parameters.map(\.name))
        guard fields.allSatisfy({ names.contains($0.key) || $0.value == .none }) else {
          return false
        }
        return signature.parameters.allSatisfy { parameter in
          guard let value = fields[parameter.name] else { return parameter.defaultValue != nil }
          if value == .none, parameter.defaultValue == nil {
            if case .optional = parameter.type { return true }
            return false
          }
          return true
        }
      }
      guard let signature else { return Printed(".\(member)") }
      var arguments: [(String, ConstructionValue)] = []
      for parameter in signature.parameters {
        guard let value = fields[parameter.name] else { continue }
        if let fallback = parameter.defaultValue, fallback == value { continue }
        arguments.append((parameter.label, value))
      }
      if !signature.callable { return Printed(".\(member)") }
      return call(
        type == "Agents" ? "Agents" : "." + member, arguments: arguments,
        indentation: indentation, column: column, trailing: trailing)
    }
  }

  private func source(
    _ fields: [String: ConstructionValue], indentation: String, column: Int, trailing: Int
  ) -> Printed {
    var args: [(String, ConstructionValue)] = [("name", fields["name"]!)]
    for key in ["url", "path", "index"] {
      if let value = fields[key] {
        args.append(
          (
            key,
            key == "url"
              ? .text(SourceDeclaration(kind: .git, location: value.text!).gitURL) : value
          ))
      }
    }
    if let requirement = fields["requirement"], requirement != .none {
      if case .range(let range) = requirement {
        if case .upToNextMajor(let lower) = Lowering.requirement(range) {
          args.append(("from", .version(Version(stringLiteral: lower))))
        } else {
          args.append(("_", requirement))
        }
      } else if case .node(_, let member, let payload) = requirement {
        args.append((member, payload["value"]!))
      }
    }
    if let subpath = fields["subpath"], subpath != .none { args.append(("subpath", subpath)) }
    return call(
      ".source", arguments: args, indentation: indentation, column: column, trailing: trailing)
  }

  private func call(
    _ callee: String, arguments: [(String, ConstructionValue)], indentation: String,
    column: Int, trailing: Int
  ) -> Printed {
    let parts = arguments.enumerated().map { index, argument in
      let (label, value) = argument
      let prefix = label == "_" ? "" : label + ": "
      return Printed([
        Printed(prefix),
        layout(
          value, indentation: indentation + style.indent,
          column: (indentation + style.indent).utf8.count + prefix.utf8.count,
          trailing: index < arguments.count - 1 ? 1 : 0),
      ])
    }
    let inline = joined(parts, open: callee + "(", close: ")", separator: ", ")
    if parts.isEmpty
      || !arguments.contains(where: { nested($0.1) })
        && column + inline.count + trailing <= 80
    {
      return inline
    }
    return multiline(
      parts, open: callee + "(", close: ")", indentation: indentation, collection: false)
  }

  private func collection(
    _ parts: [Printed], dictionary: Bool, forceMultiline: Bool, indentation: String,
    column: Int, trailing: Int
  ) -> Printed {
    if parts.isEmpty { return Printed(dictionary ? "[:]" : "[]") }
    let inline = joined(parts, open: "[", close: "]", separator: ", ")
    if !forceMultiline && column + inline.count + trailing <= 80 { return inline }
    return multiline(parts, open: "[", close: "]", indentation: indentation, collection: true)
  }

  private func joined(_ parts: [Printed], open: String, close: String, separator: String) -> Printed
  {
    var output = [Printed(open)]
    for (index, part) in parts.enumerated() {
      if index > 0 { output.append(Printed(separator)) }
      output.append(part)
    }
    output.append(Printed(close))
    return Printed(output)
  }

  private func multiline(
    _ parts: [Printed], open: String, close: String, indentation: String, collection: Bool
  ) -> Printed {
    var output = [Printed(open + style.newline)]
    for (index, part) in parts.enumerated() {
      output += [Printed(indentation + style.indent), part]
      if index < parts.count - 1 || collection && style.trailingComma {
        output.append(Printed(","))
      }
      output.append(Printed(style.newline))
    }
    output.append(Printed(indentation + close))
    return Printed(output)
  }

  private func nested(_ value: ConstructionValue) -> Bool {
    switch value {
    case .array, .object: return true
    case .node(let type, let member, let fields):
      if Vocabulary.scalarValues[type] != nil || type == "SkillSelection" && member == "all" {
        return false
      }
      if ["SectionReference", "GroupReference"].contains(type),
        fields["source"] == ConstructionValue.none, fields["condition"] == ConstructionValue.none
      {
        return false
      }
      if ["PromptContent", "RuntimeValue"].contains(type), member == "literal" { return false }
      if type == "ConfigurationValue" {
        if member == "null" { return false }
        if member != "decimal", let payload = fields["value"] { return nested(payload) }
      }
      return true
    case .range: return true
    default: return false
    }
  }
}

func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
