import Foundation

/// Maps a parser-validated literal to its source spelling. The decoded value is
/// authoritative. An unfamiliar spelling falls back to the decoded coordinates.
enum ContentAuditSourceMap {
  static func offsets(
    in bytes: [UInt8], range: Range<Int>, decoded: String, toml: Bool, requested: Set<Int>
  ) -> [Int: Int] {
    guard !requested.isEmpty, range.lowerBound >= 0, range.upperBound <= bytes.count,
      range.count >= 2
    else { return [:] }
    let quote = bytes[range.lowerBound]
    guard quote == 34 || (toml && quote == 39) else { return [:] }
    let multiline =
      toml && range.count >= 6
      && bytes[range.lowerBound..<range.lowerBound + 3].allSatisfy { $0 == quote }
    let delimiters = multiline ? 3 : 1
    let end = range.upperBound - delimiters
    guard bytes[end..<range.upperBound].allSatisfy({ $0 == quote }) else { return [:] }
    var source = range.lowerBound + delimiters
    if multiline {
      if source + 1 < end && bytes[source] == 13 && bytes[source + 1] == 10 {
        source += 2
      } else if source < end && bytes[source] == 10 {
        source += 1
      }
    }
    var result: [Int: Int] = [:]
    var offset = 0
    for scalar in decoded.unicodeScalars {
      if multiline && quote == 34, let continued = continuation(bytes, from: source, end: end) {
        source = continued
      }
      let start = source
      guard source < end else { return [:] }
      if quote == 34 && bytes[source] == 92 {
        guard let (value, next) = escaped(bytes, from: source, end: end, toml: toml),
          value == scalar.value
        else { return [:] }
        source = next
      } else if multiline && scalar == "\n", source + 1 < end,
        bytes[source] == 13 && bytes[source + 1] == 10
      {
        source += 2
      } else {
        let length = scalar.utf8.count
        guard source + length <= end,
          bytes[source..<source + length].elementsEqual(scalar.utf8)
        else { return [:] }
        source += length
      }
      if requested.contains(offset) { result[offset] = start }
      offset += scalar.utf8.count
    }
    if multiline && quote == 34, let continued = continuation(bytes, from: source, end: end) {
      source = continued
    }
    return source == end ? result : [:]
  }

  private static func continuation(_ bytes: [UInt8], from start: Int, end: Int) -> Int? {
    guard start < end, bytes[start] == 92 else { return nil }
    var next = start + 1
    while next < end && (bytes[next] == 32 || bytes[next] == 9) { next += 1 }
    guard next < end, bytes[next] == 10 || bytes[next] == 13 else { return nil }
    while next < end && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
    return next
  }

  private static func escaped(
    _ bytes: [UInt8], from start: Int, end: Int, toml: Bool
  ) -> (UInt32, Int)? {
    guard start + 1 < end else { return nil }
    let symbol = bytes[start + 1]
    switch symbol {
    case 34, 47, 92: return (UInt32(symbol), start + 2)
    case 98: return (8, start + 2)
    case 101: return (27, start + 2)
    case 102: return (12, start + 2)
    case 110: return (10, start + 2)
    case 114: return (13, start + 2)
    case 116: return (9, start + 2)
    case 117, 85, 120:
      let width = symbol == 117 ? 4 : symbol == 85 ? 8 : 2
      let firstEnd = start + 2 + width
      guard firstEnd <= end,
        let first = UInt32(String(decoding: bytes[start + 2..<firstEnd], as: UTF8.self), radix: 16)
      else { return nil }
      if !toml && (0xd800...0xdbff).contains(first) {
        guard firstEnd + 6 <= end, bytes[firstEnd] == 92, bytes[firstEnd + 1] == 117,
          let second = UInt32(
            String(decoding: bytes[firstEnd + 2..<firstEnd + 6], as: UTF8.self), radix: 16),
          (0xdc00...0xdfff).contains(second)
        else { return nil }
        return (0x10000 + (first - 0xd800) * 0x400 + second - 0xdc00, firstEnd + 6)
      }
      return (first, firstEnd)
    default: return nil
    }
  }
}
