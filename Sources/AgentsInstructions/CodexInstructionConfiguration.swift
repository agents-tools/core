import AgentsCore
import Foundation

/// The top-level settings that determine instruction discovery; runtime profile and policy layers
/// belong to Codex. This reader does not interpret unrelated configuration values.
struct CodexInstructionConfiguration {
  var maxBytes = 32 * 1024
  var fallbackNames: [String] = []
  var rootMarkers = [".git"]

  init() {}

  init(_ data: Data) throws {
    guard let text = String(data: data, encoding: .utf8) else { throw InstructionError.invalidUTF8 }
    var multiline: String?
    var arrayKey: String?
    var arrayValue = ""
    var values: [String: String] = [:]
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if let delimiter = multiline {
        if line.contains(delimiter) { multiline = nil }
        continue
      }
      let content = Self.withoutComment(line).trimmingCharacters(in: .whitespaces)
      if let key = arrayKey {
        arrayValue += " " + content
        if content.hasSuffix("]") {
          values[key] = arrayValue
          arrayKey = nil
        }
        continue
      }
      if content.hasPrefix("[") { break }
      let parts = content.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
        if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
      }
      if value.hasPrefix("["), !value.hasSuffix("]") {
        arrayKey = key
        arrayValue = value
      } else {
        values[key] = value
      }
    }
    guard arrayKey == nil else { throw CoreError.invalidState("unterminated configuration array") }
    if let raw = values["project_doc_max_bytes"] {
      let value = raw.replacingOccurrences(of: "_", with: "")
      let number: Int?
      if value.hasPrefix("0x") {
        number = Int(value.dropFirst(2), radix: 16)
      } else if value.hasPrefix("0o") {
        number = Int(value.dropFirst(2), radix: 8)
      } else if value.hasPrefix("0b") {
        number = Int(value.dropFirst(2), radix: 2)
      } else {
        number = Int(value)
      }
      guard let number, number >= 0 else {
        throw CoreError.invalidState("invalid instruction byte limit")
      }
      maxBytes = number
    }
    if let value = values["project_doc_fallback_filenames"] {
      fallbackNames = try Self.names(value)
    }
    if let value = values["project_root_markers"] { rootMarkers = try Self.names(value) }
  }

  private static func withoutComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
        continue
      }
      if quote == "\"", character == "\\" {
        escaped = true
        continue
      }
      if character == quote {
        quote = nil
      } else if quote == nil, character == "\"" || character == "'" {
        quote = character
      } else if quote == nil, character == "#" {
        return String(line[..<index])
      }
    }
    return line
  }

  private static func names(_ value: String) throws -> [String] {
    guard value.hasPrefix("["), value.hasSuffix("]") else {
      throw CoreError.invalidState("instruction filenames must be a TOML string array")
    }
    var remaining = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)[...]
    var names: [String] = []
    while !remaining.isEmpty {
      guard let quote = remaining.first, quote == "\"" || quote == "'" else {
        throw CoreError.invalidState("invalid instruction filename")
      }
      var end = remaining.index(after: remaining.startIndex)
      var escaped = false
      while end < remaining.endIndex {
        let character = remaining[end]
        if !escaped, character == quote { break }
        if !escaped, quote == "\"", character == "\\" { escaped = true } else { escaped = false }
        end = remaining.index(after: end)
      }
      guard end < remaining.endIndex else { throw CoreError.invalidState("unterminated filename") }
      let token = String(remaining[...end])
      let name =
        try quote == "'"
        ? String(token.dropFirst().dropLast())
        : JSONDecoder().decode(String.self, from: Data(token.utf8))
      guard !name.isEmpty, name != ".", name != "..",
        !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
        !name.contains(where: \.isNewline)
      else { throw CoreError.unsafePath("instruction discovery requires filenames") }
      names.append(name)
      remaining =
        remaining[remaining.index(after: end)...].trimmingCharacters(in: .whitespaces)[...]
      if !remaining.isEmpty {
        guard remaining.first == "," else {
          throw CoreError.invalidState("missing filename separator")
        }
        remaining = remaining.dropFirst().trimmingCharacters(in: .whitespaces)[...]
      }
    }
    return names
  }
}
