import Foundation

/// The fixed front matter of an instructions file: a required `description` and optional `paths`.
/// It is a strict subset of YAML: plain, double-quoted or single-quoted scalars, and `paths` as a
/// flow list of double-quoted strings or a block list. Unknown and repeated keys are errors.
struct InstructionFrontMatter: Equatable {
  let description: String
  let paths: [String]

  struct Failure: Error {
    let reason: String
  }

  static func parse(_ lines: [String]) throws -> Self {
    var description: String?
    var paths: [String]?
    var index = 0
    func fail(_ reason: String) -> Failure { Failure(reason: reason) }
    while index < lines.count {
      let line = lines[index]
      index += 1
      if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
      guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t")
      else { throw fail("front matter line \(index + 1) is not a 'key: value' entry.") }
      let key = String(line[..<colon])
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      switch key {
      case "description":
        guard description == nil else { throw fail("'description' appears more than once.") }
        description = try scalar(value, key: key)
      case "paths":
        guard paths == nil else { throw fail("'paths' appears more than once.") }
        if value.isEmpty {
          var items: [String] = []
          while index < lines.count {
            let item = lines[index].trimmingCharacters(in: .whitespaces)
            guard item.hasPrefix("- "), lines[index].first == " " || lines[index].first == "\t"
            else { break }
            items.append(
              try scalar(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces), key: key))
            index += 1
          }
          paths = items
        } else {
          guard value.hasPrefix("["),
            let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String]
          else { throw fail("'paths' must be a list of double-quoted strings or a block list.") }
          paths = list
        }
        guard paths?.isEmpty == false else { throw fail("'paths' must list at least one pattern.") }
      default:
        throw fail("unknown front matter key '\(key)'; only 'description' and 'paths' are allowed.")
      }
    }
    guard let description, !description.isEmpty else {
      throw fail("front matter needs a non-empty 'description'.")
    }
    return Self(description: description, paths: paths ?? [])
  }

  private static func scalar(_ value: String, key: String) throws -> String {
    if value.hasPrefix("\"") {
      guard value.count >= 2, value.hasSuffix("\""),
        let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
      else { throw Failure(reason: "'\(key)' has an invalid double-quoted string.") }
      return decoded
    }
    if value.hasPrefix("'") {
      let inner = value.dropFirst().dropLast()
      guard value.count >= 2, value.hasSuffix("'"),
        !inner.replacingOccurrences(of: "''", with: "").contains("'")
      else { throw Failure(reason: "'\(key)' has an invalid single-quoted string.") }
      return inner.replacingOccurrences(of: "''", with: "'")
    }
    let indicators = Set("[]{},&*!|>%@`#")
    guard let first = value.first, !indicators.contains(first), !value.contains(": "),
      !value.contains(" #")
    else { throw Failure(reason: "quote the value of '\(key)'.") }
    return value
  }
}
