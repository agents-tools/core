import Foundation

/// The layout of `agents.json` and `agents.resolved`, as Prettier writes JSON with its default
/// 80-column width: two-space indentation, `"key": value`, every non-empty object expanded one
/// member per line, empty containers as `{}` and `[]`, and an array on one line when it holds no
/// object and fits, else one element per line. Keys keep the encoder's sorted order and string
/// bytes are copied as encoded.
enum StateJSON {
  private static let width = 80

  private indirect enum Node {
    case object([(key: String, value: Node)])
    case array([Node])
    case scalar(String)
  }

  /// Lays out the compact JSON that `JSONEncoder` produced, ending with a newline.
  static func format(_ compact: Data) throws -> Data {
    var parser = Parser(bytes: Array(compact))
    let node = try parser.value()
    parser.skipWhitespace()
    guard parser.index == parser.bytes.count else { throw CoreError.invalidState("invalid JSON") }
    return Data((render(node, depth: 0, column: 0, trailing: 0) + "\n").utf8)
  }

  /// `column` is where the value starts; `trailing` counts the characters after it on its line.
  private static func render(_ node: Node, depth: Int, column: Int, trailing: Int) -> String {
    let indent = String(repeating: "  ", count: depth + 1)
    let closing = String(repeating: "  ", count: depth)
    switch node {
    case .scalar(let text):
      return text
    case .object(let members):
      guard !members.isEmpty else { return "{}" }
      let lines = members.enumerated().map { offset, member in
        let prefix = indent + member.key + ": "
        let comma = offset < members.count - 1 ? "," : ""
        return prefix
          + render(
            member.value, depth: depth + 1, column: prefix.count, trailing: comma.count) + comma
      }
      return "{\n" + lines.joined(separator: "\n") + "\n" + closing + "}"
    case .array(let elements):
      guard !elements.isEmpty else { return "[]" }
      if let flat = flat(node), column + flat.count + trailing <= width { return flat }
      let lines = elements.enumerated().map { offset, element in
        let comma = offset < elements.count - 1 ? "," : ""
        return indent
          + render(element, depth: depth + 1, column: indent.count, trailing: comma.count) + comma
      }
      return "[\n" + lines.joined(separator: "\n") + "\n" + closing + "]"
    }
  }

  /// The one-line form of an array without objects, or nil when it holds one.
  private static func flat(_ node: Node) -> String? {
    switch node {
    case .scalar(let text): return text
    case .object(let members): return members.isEmpty ? "{}" : nil
    case .array(let elements):
      var parts: [String] = []
      for element in elements {
        guard let part = flat(element) else { return nil }
        parts.append(part)
      }
      return "[" + parts.joined(separator: ", ") + "]"
    }
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func skipWhitespace() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> Node {
      skipWhitespace()
      guard index < bytes.count else { throw CoreError.invalidState("invalid JSON") }
      switch bytes[index] {
      case UInt8(ascii: "{"):
        index += 1
        var members: [(key: String, value: Node)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
          index += 1
          return .object(members)
        }
        while true {
          skipWhitespace()
          let key = try string()
          skipWhitespace()
          try expect(UInt8(ascii: ":"))
          members.append((key, try value()))
          skipWhitespace()
          if try separatorEnds(UInt8(ascii: "}")) { return .object(members) }
        }
      case UInt8(ascii: "["):
        index += 1
        var elements: [Node] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
          index += 1
          return .array(elements)
        }
        while true {
          elements.append(try value())
          skipWhitespace()
          if try separatorEnds(UInt8(ascii: "]")) { return .array(elements) }
        }
      case UInt8(ascii: "\""):
        return .scalar(try string())
      default:
        let start = index
        while index < bytes.count,
          ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), 9, 10, 13, 32].contains(
            bytes[index])
        {
          index += 1
        }
        guard index > start else { throw CoreError.invalidState("invalid JSON") }
        return .scalar(String(decoding: bytes[start..<index], as: UTF8.self))
      }
    }

    /// A string literal exactly as encoded, quotes and escapes included.
    mutating func string() throws -> String {
      try expect(UInt8(ascii: "\""))
      let start = index - 1
      while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
        index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
      }
      try expect(UInt8(ascii: "\""))
      return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Consumes `,` and returns false, or consumes `close` and returns true.
    mutating func separatorEnds(_ close: UInt8) throws -> Bool {
      guard index < bytes.count else { throw CoreError.invalidState("invalid JSON") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
        return false
      }
      try expect(close)
      return true
    }

    mutating func expect(_ byte: UInt8) throws {
      guard index < bytes.count, bytes[index] == byte else {
        throw CoreError.invalidState("invalid JSON")
      }
      index += 1
    }
  }
}
