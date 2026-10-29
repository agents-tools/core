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
    case "\0"..<" ", "\u{7F}": result += "\\u{" + String(scalar.value, radix: 16) + "}"
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

struct CanonicalPrinter {
  var style = PrintStyle()

  func render(_ value: ConstructionValue, indentation: String = "") -> String {
    switch value {
    case .text(let text): return quoted(text)
    case .integer(let value): return String(value)
    case .boolean(let value): return value ? "true" : "false"
    case .none: return "nil"
    case .version(let version): return quoted(version.normalized)
    case .range(let range):
      let requirement = Lowering.requirement(range)
      if case .upToNextMajor(let lower) = requirement {
        return ".upToNextMajor(from: \(quoted(lower)))"
      }
      if case .upToNextMinor(let lower) = requirement {
        return ".upToNextMinor(from: \(quoted(lower)))"
      }
      return quoted(range.lowerBound.normalized) + "..<" + quoted(range.upperBound.normalized)
    case .array(let values):
      return collection(
        values.map { render($0, indentation: indentation + style.indent) }, dictionary: false,
        forceMultiline: values.contains(where: nested), indentation: indentation)
    case .object(let fields):
      let keys = fields.keys.sorted(by: utf8Less)
      return collection(
        keys.map {
          quoted($0) + ": " + render(fields[$0]!, indentation: indentation + style.indent)
        }, dictionary: true, forceMultiline: fields.values.contains(where: nested),
        indentation: indentation)
    case .node(let type, let member, let fields):
      if type == "SkillSelection" {
        return member == "all" ? ".all" : render(fields["names"]!, indentation: indentation)
      }
      if type == "VersionRange", let lower = fields["from"] {
        return ".\(member)(from: \(render(lower, indentation: indentation)))"
      }
      if type == "PromptContent" && member == "literal"
        || type == "RuntimeValue" && member == "literal"
      {
        return render(fields["value"]!, indentation: indentation)
      }
      if ["SectionReference", "GroupReference"].contains(type),
        fields["source"] == ConstructionValue.none, fields["condition"] == ConstructionValue.none
      {
        return render(fields["name"]!, indentation: indentation)
      }
      if type == "ConfigurationValue" {
        if member == "null" { return "nil" }
        if member != "decimal" { return render(fields["value"]!, indentation: indentation) }
      }
      if type == "Source" { return source(fields, indentation: indentation) }
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
      guard let signature else { return ".\(member)" }
      var arguments: [(String, ConstructionValue)] = []
      for parameter in signature.parameters {
        guard let value = fields[parameter.name] else { continue }
        if let fallback = parameter.defaultValue, fallback == value { continue }
        arguments.append((parameter.label, value))
      }
      if !signature.callable { return ".\(member)" }
      return call(
        type == "Agents" ? "Agents" : "." + member, arguments: arguments, indentation: indentation)
    }
  }

  private func source(_ fields: [String: ConstructionValue], indentation: String) -> String {
    var args: [(String, ConstructionValue)] = [("name", fields["name"]!)]
    for key in ["url", "path", "index"] {
      if let value = fields[key] {
        if key == "url", let url = value.text {
          args.append((key, .text(SourceDeclaration(kind: .git, location: url).gitURL)))
        } else {
          args.append((key, value))
        }
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
    return call(".source", arguments: args, indentation: indentation)
  }

  private func call(_ callee: String, arguments: [(String, ConstructionValue)], indentation: String)
    -> String
  {
    let parts = arguments.map { label, value in
      (label == "_" ? "" : label + ": ") + render(value, indentation: indentation + style.indent)
    }
    let inline = callee + "(" + parts.joined(separator: ", ") + ")"
    if !arguments.contains(where: { nested($0.1) })
      && indentation.utf8.count + inline.utf8.count + 1 <= 80
    {
      return inline
    }
    if parts.isEmpty { return inline }
    return callee + "(" + style.newline
      + parts.enumerated().map { index, part in
        indentation + style.indent + part + (index == parts.count - 1 ? "" : ",")
      }.joined(separator: style.newline) + style.newline + indentation + ")"
  }

  private func collection(
    _ parts: [String], dictionary: Bool, forceMultiline: Bool, indentation: String
  ) -> String {
    if parts.isEmpty { return dictionary ? "[:]" : "[]" }
    let inline = "[" + parts.joined(separator: ", ") + "]"
    if !forceMultiline && indentation.utf8.count + inline.utf8.count + 1 <= 80 { return inline }
    return "[" + style.newline
      + parts.enumerated().map { index, part in
        indentation + style.indent + part
          + (style.trailingComma || index < parts.count - 1 ? "," : "")
      }.joined(separator: style.newline) + style.newline + indentation + "]"
  }

  private func nested(_ value: ConstructionValue) -> Bool {
    switch value {
    case .array, .object: return true
    case .node(let type, let member, _):
      return Vocabulary.scalarValues[type] == nil
        && !(type == "SkillSelection" && member == "all")
    case .range: return true
    default: return false
    }
  }
}

func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
