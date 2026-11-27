import AgentsCore

struct SourceText: Sendable {
  let bytes: [UInt8]
  let identity: DocumentIdentity
  private let lines: [Int]

  init(_ bytes: [UInt8], identity: DocumentIdentity) {
    self.bytes = bytes
    self.identity = identity
    var starts = [0]
    var i = 0
    while i < min(bytes.count, ManifestLimits.Input.bytes + 1) {
      if bytes[i] == UInt8(ascii: "\r") {
        if i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "\n") { i += 1 }
        starts.append(i + 1)
      } else if bytes[i] == UInt8(ascii: "\n") {
        starts.append(i + 1)
      }
      i += 1
    }
    lines = starts
  }

  func span(_ range: Range<Int>) -> SourceSpan {
    let start = min(max(0, range.lowerBound), bytes.count)
    var lo = 0
    var hi = lines.count
    while lo + 1 < hi {
      let mid = (lo + hi) / 2
      if lines[mid] <= start { lo = mid } else { hi = mid }
    }
    return SourceSpan(
      document: identity, start: start, end: min(max(start, range.upperBound), bytes.count),
      line: lo + 1, column: start - lines[lo] + 1)
  }

  func failure(_ code: String, _ message: String, _ offset: Int, end: Int? = nil)
    -> ManifestFailure
  {
    ManifestFailure(
      ManifestDiagnostic(code: code, message: message, span: span(offset..<(end ?? offset))))
  }

  /// Decoder columns count Unicode scalars, excluding a stream-initial UTF-8 BOM.
  /// Source spans retain the original bytes and count CRLF as one line break.
  func decoderOffset(line: Int, scalarColumn: Int) -> Int {
    guard line > 0, scalarColumn > 0 else { return 0 }
    guard line <= lines.count else { return bytes.count }
    var offset = lines[line - 1]
    if line == 1, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
    var column = 1
    while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13,
      column < scalarColumn
    {
      offset += 1
      while offset < bytes.count, bytes[offset] & 0xC0 == 0x80 { offset += 1 }
      column += 1
    }
    return offset
  }

  func spelling(_ range: Range<Int>) -> String {
    String(decoding: bytes[range], as: UTF8.self)
  }
}

func utf8Less(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
