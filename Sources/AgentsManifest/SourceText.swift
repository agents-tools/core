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

  func spelling(_ range: Range<Int>) -> String {
    String(decoding: bytes[range], as: UTF8.self)
  }
}
