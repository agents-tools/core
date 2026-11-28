import AgentsCore
import AgentsInstructions
import Foundation

enum AntigravityRuleV1 {
  static let byteLimit = 24_000
  static let format = InstructionLocations.antigravityFormat
  private static let include = try! NSRegularExpression(
    pattern: #"@\[[^\]\r\n]*\]\(([^()\r\n]+)\)"#)
  private static let unresolved = try! NSRegularExpression(
    pattern: #"@\[[^\]\r\n]*\]\("#)

  static func leaf(source: String, path: String) throws -> String {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let stem = String(
      name.lowercased().utf8.map {
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
          ? Character(UnicodeScalar($0)) : "-"
      }.prefix(60))
    let digest = try ResolvedLedgerCodec.digest([source, path])
    return "agents-\(stem)-\(digest.dropFirst(7)).md"
  }

  static func render(
    _ unit: Data, path: String, leaf: String, scope: InstallScope, read: (String) throws -> Data
  ) throws -> Data {
    let section = try Instructions.validateSource(unit, id: path, allowRestrictions: true)
    let paths = scope == .project ? section.paths : []
    guard
      paths.allSatisfy({
        !$0.contains(",") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
      })
    else { throw failure(leaf, "paths must fit Antigravity's comma-separated glob list") }
    let header =
      try frontmatter(section.description, paths: paths)
      + InstructionCompatibility.antigravityMarker(leaf) + "\n\n"
    var cache: [String: Expansion] = [:]
    var active: Set<String> = [path]
    func expand(_ text: String, path: String) throws -> Expansion {
      var output = Expansion()
      var start = text.startIndex
      for match in include.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        try Task.checkCancellation()
        guard let range = Range(match.range, in: text),
          let destination = Range(match.range(at: 1), in: text),
          range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] != "\\"
        else { throw failure(leaf, "unsupported file reference in \(path)") }
        let prefix = String(text[start..<range.lowerBound])
        try validateReferences(prefix, leaf: leaf, path: path)
        try output.append(Expansion(prefix))
        let target = try includePath(String(text[destination]), from: path, leaf: leaf)
        if let expanded = cache[target] {
          try output.append(expanded)
        } else {
          guard active.count < LedgerLimits.standard.depth, active.insert(target).inserted else {
            throw failure(leaf, "cyclic or too deeply nested file reference: \(target)")
          }
          let body = try includeBody(read(target), leaf: leaf, path: target)
          let expanded = try expand(body, path: target)
          active.remove(target)
          cache[target] = expanded
          try output.append(expanded)
        }
        start = range.upperBound
      }
      let suffix = String(text[start...])
      try validateReferences(suffix, leaf: leaf, path: path)
      try output.append(Expansion(suffix))
      return output
    }
    let body = try expand(section.content, path: path)
    let count = body.count.addingReportingOverflow(header.utf8.count + 1)
    guard !count.overflow else { throw failure(leaf, "expanded byte count overflow") }
    guard count.partialValue <= byteLimit else {
      throw failure(
        leaf, "\(count.partialValue) UTF-8 bytes after expansion, limit \(byteLimit) bytes")
    }
    try validateReferences(body.text, leaf: leaf, path: path)
    if let link = Instructions.localLinks(in: body.text).first {
      throw failure(leaf, "unresolved local link '\(link.destination)' in \(path)")
    }
    return Data((header + body.text + "\n").utf8)
  }

  private struct Expansion {
    var count: Int
    var text: String

    init(_ text: String = "") {
      count = text.utf8.count
      self.text = count <= byteLimit ? text : ""
    }

    mutating func append(_ other: Self) throws {
      let sum = count.addingReportingOverflow(other.count)
      guard !sum.overflow else { throw CoreError.invalidState("Antigravity expansion overflow") }
      count = sum.partialValue
      if count <= byteLimit { text += other.text } else { text = "" }
    }
  }

  private static func includePath(_ value: String, from path: String, leaf: String) throws -> String
  {
    guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\"),
      !value.contains("%"), !value.contains(":"), !value.contains("#"), !value.contains("?"),
      !value.contains("\0"), value == value.trimmingCharacters(in: .whitespaces)
    else { throw failure(leaf, "unsafe file reference '\(value)' in \(path)") }
    var parts = path.split(separator: "/").dropLast().map(String.init)
    for part in value.split(separator: "/", omittingEmptySubsequences: false) {
      switch part {
      case ".", "": continue
      case "..":
        guard parts.popLast() != nil else {
          throw failure(leaf, "file reference escapes its source: '\(value)' in \(path)")
        }
      case ".git": throw failure(leaf, "file reference crosses Git metadata: '\(value)' in \(path)")
      default: parts.append(String(part))
      }
    }
    guard !parts.isEmpty else { throw failure(leaf, "invalid file reference in \(path)") }
    return parts.joined(separator: "/")
  }

  private static func includeBody(_ bytes: Data, leaf: String, path: String) throws -> String {
    guard var text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
      throw failure(leaf, "included file is not UTF-8 text: \(path)")
    }
    if text.first == "\u{FEFF}" { text.removeFirst() }
    let lines = text.split(
      omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
    guard lines.first == "---" else { return text }
    guard let end = lines.dropFirst().firstIndex(of: "---") else {
      throw failure(leaf, "unterminated frontmatter in included file: \(path)")
    }
    let last = lines[end].endIndex
    return last == text.endIndex ? "" : String(text[text.index(after: last)...])
  }

  private static func validateReferences(_ text: String, leaf: String, path: String) throws {
    guard unresolved.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
    else {
      throw failure(leaf, "unresolved file reference in \(path); use @[label](relative/path)")
    }
  }

  private static func frontmatter(_ description: String, paths: [String] = []) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let quoted = String(decoding: try encoder.encode(description), as: UTF8.self)
    if paths.isEmpty { return "---\ntrigger: always_on\ndescription: \(quoted)\n---\n\n" }
    let globs = String(decoding: try encoder.encode(paths.joined(separator: ", ")), as: UTF8.self)
    return "---\ntrigger: glob\nglobs: \(globs)\ndescription: \(quoted)\n---\n\n"
  }

  static func legacyLeaf(path: String) -> String? {
    guard path.hasPrefix(".agent/instructions/") else { return nil }
    let name = "memex-" + (path as NSString).lastPathComponent
    return InstructionLocations.isAntigravityLeaf(name, legacy: true) ? name : nil
  }

  static func legacyBytes(unit: Data, path: String, revision: String) throws -> Data {
    let section = try Instructions.validateSource(unit, id: path, allowRestrictions: true)
    let marker =
      "<!-- Generated from Memex \(path) at \(revision); temporary standalone installation. -->"
    return Data(
      (try frontmatter(section.description) + marker + "\n\n" + section.content + "\n").utf8)
  }

  static func failure(_ leaf: String, _ reason: String) -> CoreError {
    .invalidState("Antigravity rule \(leaf): \(reason)")
  }
}
