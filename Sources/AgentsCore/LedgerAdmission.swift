import Foundation

/// All counts are aggregate per ledger. The caller may reduce limits for a constrained operation.
package struct LedgerLimits: Sendable {
  package var encodedBytes: Int
  package var depth: Int
  package var nodes: Int
  package var objectBytes: Int
  package var entries: Int
  package var keyBytes: Int
  package var resourceBytes: Int
  package init(
    encodedBytes: Int, depth: Int, nodes: Int, objectBytes: Int, entries: Int, keyBytes: Int,
    resourceBytes: Int? = nil
  ) {
    self.encodedBytes = encodedBytes
    self.depth = depth
    self.nodes = nodes
    self.objectBytes = objectBytes
    self.entries = entries
    self.keyBytes = keyBytes
    self.resourceBytes = resourceBytes ?? objectBytes
  }
}

/// Grammar and aggregate bounds are checked before Foundation constructs a decoded object graph.
package enum LedgerAdmission {
  package static func check(_ data: Data, limits: LedgerLimits) throws {
    guard data.count <= limits.encodedBytes, limits.depth > 0, limits.nodes > 0,
      limits.objectBytes >= 0, limits.entries >= 0, limits.keyBytes > 0,
      String(data: data, encoding: .utf8) != nil, !data.starts(with: [239, 187, 191])
    else {
      throw CoreError.invalidState("ledger encoding or byte budget")
    }
    var scanner = Scanner(data: data, limits: limits)
    try scanner.value(depth: 0)
    scanner.space()
    guard scanner.index == data.count else { throw CoreError.invalidState("trailing ledger JSON") }
  }

  private struct Scanner {
    let data: Data
    let limits: LedgerLimits
    var index = 0
    var nodes = 0
    var objectBytes = 0
    var entries = 0

    var byte: UInt8? { index < data.count ? data[index] : nil }
    mutating func space() { while let byte, [9, 10, 13, 32].contains(byte) { index += 1 } }
    mutating func take(_ expected: UInt8) throws {
      guard byte == expected else { throw CoreError.invalidState("invalid ledger JSON") }
      index += 1
    }

    mutating func value(
      depth: Int, contentObjects: Bool = false, object: Bool = false, treeEntries: Bool = false
    ) throws {
      nodes += 1
      guard depth <= limits.depth, nodes <= limits.nodes else {
        throw CoreError.invalidState("ledger structure budget")
      }
      space()
      guard let current = byte else { throw CoreError.invalidState("truncated ledger JSON") }
      switch current {
      case 123:
        index += 1
        space()
        var keys = Set<String>()
        if byte == 125 {
          index += 1
          return
        }
        while true {
          let range = try string()
          guard range.count <= limits.keyBytes else {
            throw CoreError.invalidState("ledger key budget")
          }
          let contents = data[(range.lowerBound + 1)..<(range.upperBound - 1)]
          // The whole input is valid UTF-8 and string() has checked the token's grammar.
          let key =
            if contents.contains(92) {
              try JSONDecoder().decode(String.self, from: data.subdata(in: range))
            } else {
              String(decoding: contents, as: UTF8.self)
            }
          guard keys.insert(key).inserted else {
            throw CoreError.invalidState("duplicate ledger key")
          }
          space()
          try take(58)
          try value(
            depth: depth + 1, contentObjects: depth == 0 && key == "contentObjects",
            object: contentObjects, treeEntries: key == "entries" || key == "support")
          space()
          if byte == 125 {
            index += 1
            break
          }
          try take(44)
          space()
        }
      case 91:
        index += 1
        space()
        if byte == 93 {
          index += 1
          return
        }
        while true {
          if treeEntries {
            entries += 1
            guard entries <= limits.entries else {
              throw CoreError.invalidState("ledger entry budget")
            }
          }
          try value(depth: depth + 1)
          space()
          if byte == 93 {
            index += 1
            break
          }
          try take(44)
        }
      case 34:
        let range = try string()
        if object {
          let count = try base64Bytes(in: range)
          guard count <= limits.objectBytes - objectBytes else {
            throw CoreError.invalidState("ledger content byte budget")
          }
          objectBytes += count
        }
      case 116: try literal("true")
      case 102: try literal("false")
      case 110: try literal("null")
      case 45, 48...57: try number()
      default: throw CoreError.invalidState("invalid ledger JSON value")
      }
    }

    /// Counts the decoded Base64 spelling without allocating either the unescaped string or bytes.
    func base64Bytes(in range: Range<Int>) throws -> Int {
      var cursor = range.lowerBound + 1
      let end = range.upperBound - 1
      var length = 0
      var padding = 0
      while cursor < end {
        var scalar = Int(data[cursor])
        cursor += 1
        if scalar == 92 {
          let escaped = data[cursor]
          cursor += 1
          if escaped == 117 {
            scalar = 0
            for _ in 0..<4 {
              let hex = Int(data[cursor])
              scalar = scalar * 16 + (hex <= 57 ? hex - 48 : hex <= 70 ? hex - 55 : hex - 87)
              cursor += 1
            }
          } else if escaped == 47 {
            scalar = 47
          } else {
            throw CoreError.invalidState("invalid content encoding")
          }
        }
        length += 1
        if scalar == 61 {
          padding += 1
          guard padding <= 2 else { throw CoreError.invalidState("invalid content padding") }
        } else {
          guard padding == 0,
            (65...90).contains(scalar) || (97...122).contains(scalar)
              || (48...57).contains(scalar) || scalar == 43 || scalar == 47
          else {
            throw CoreError.invalidState("invalid content encoding")
          }
        }
      }
      guard length % 4 == 0 else { throw CoreError.invalidState("invalid content encoding") }
      return length / 4 * 3 - padding
    }

    mutating func literal(_ text: String) throws {
      for value in text.utf8 { try take(value) }
    }

    mutating func string() throws -> Range<Int> {
      let start = index
      try take(34)
      while let value = byte {
        index += 1
        if value == 34 { return start..<index }
        guard value >= 32 else { throw CoreError.invalidState("control byte in ledger string") }
        if value == 92 {
          guard let escaped = byte else { throw CoreError.invalidState("truncated ledger escape") }
          index += 1
          if escaped == 117 {
            for _ in 0..<4 {
              guard let hex = byte,
                (48...57).contains(hex) || (65...70).contains(hex)
                  || (97...102).contains(hex)
              else {
                throw CoreError.invalidState("invalid ledger Unicode escape")
              }
              index += 1
            }
          } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) {
            throw CoreError.invalidState("invalid ledger escape")
          }
        }
      }
      throw CoreError.invalidState("unterminated ledger string")
    }

    mutating func number() throws {
      if byte == 45 { index += 1 }
      if byte == 48 {
        index += 1
      } else {
        guard let byte, (49...57).contains(byte) else {
          throw CoreError.invalidState("invalid ledger number")
        }
        digits()
      }
      if byte == 46 {
        index += 1
        let start = index
        digits()
        guard index > start else { throw CoreError.invalidState("invalid ledger fraction") }
      }
      if byte == 101 || byte == 69 {
        index += 1
        if byte == 43 || byte == 45 { index += 1 }
        let start = index
        digits()
        guard index > start else { throw CoreError.invalidState("invalid ledger exponent") }
      }
    }
    mutating func digits() { while let byte, (48...57).contains(byte) { index += 1 } }
  }
}

extension LedgerLimits {
  package static let standard = LedgerLimits(
    encodedBytes: 256 * 1024 * 1024, depth: 128, nodes: 2_000_000,
    objectBytes: 128 * 1024 * 1024, entries: 100_000, keyBytes: 256 * 1024 * 1024)
}
