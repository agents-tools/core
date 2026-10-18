import Foundation

/// Checks object identity before a dictionary decoder can discard duplicate keys.
enum JSONKeys {
  static func validate(_ data: Data) throws {
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var scanner = Scanner(bytes: Array(data))
    try scanner.value()
  }

  private struct Scanner {
    let bytes: [UInt8]
    var offset = 0

    mutating func whitespace() {
      while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func string() throws -> String {
      let start = offset
      offset += 1
      while bytes[offset] != 34 {
        if bytes[offset] == 92 { offset += 1 }
        offset += 1
      }
      offset += 1
      return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
    }

    mutating func value() throws {
      whitespace()
      switch bytes[offset] {
      case 123:
        offset += 1
        whitespace()
        var keys = Set<String>()
        while bytes[offset] != 125 {
          let key = try string()
          guard keys.insert(key).inserted else {
            throw CoreError.invalidState("duplicate JSON key: \(key)")
          }
          whitespace()
          offset += 1  // colon; syntax was validated before scanning
          try value()
          whitespace()
          if bytes[offset] == 44 {
            offset += 1
            whitespace()
          }
        }
        offset += 1
      case 91:
        offset += 1
        whitespace()
        while bytes[offset] != 93 {
          try value()
          whitespace()
          if bytes[offset] == 44 {
            offset += 1
            whitespace()
          }
        }
        offset += 1
      case 34: _ = try string()
      default:
        while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) {
          offset += 1
        }
      }
    }
  }
}
