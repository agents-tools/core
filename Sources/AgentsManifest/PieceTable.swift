package struct PieceTable {
  private enum Piece {
    case original(Range<Int>)
    case inserted([UInt8])
    var count: Int {
      switch self {
      case .original(let range): range.count
      case .inserted(let bytes): bytes.count
      }
    }
    func slice(_ range: Range<Int>) -> Piece {
      switch self {
      case .original(let original):
        return .original(
          (original.lowerBound + range.lowerBound)..<(original.lowerBound + range.upperBound))
      case .inserted(let bytes): return .inserted(Array(bytes[range]))
      }
    }
  }
  private let original: [UInt8]
  private var pieces: [Piece]
  package init(_ bytes: [UInt8]) {
    original = bytes
    pieces = [.original(0..<bytes.count)]
  }
  package var count: Int { pieces.reduce(0) { $0 + $1.count } }
  package var bytes: [UInt8] {
    pieces.flatMap { piece in
      switch piece {
      case .original(let range): return Array(original[range])
      case .inserted(let bytes): return bytes
      }
    }
  }
  package mutating func replace(_ range: Range<Int>, with replacement: [UInt8]) {
    var result: [Piece] = []
    var offset = 0
    var inserted = false
    for piece in pieces {
      let end = offset + piece.count
      if offset < range.lowerBound {
        let kept = min(end, range.lowerBound) - offset
        if kept > 0 { result.append(piece.slice(0..<kept)) }
      }
      if !inserted && end >= range.lowerBound {
        if !replacement.isEmpty { result.append(.inserted(replacement)) }
        inserted = true
      }
      if end > range.upperBound {
        let first = max(offset, range.upperBound) - offset
        if first < piece.count { result.append(piece.slice(first..<piece.count)) }
      }
      offset = end
    }
    if !inserted && !replacement.isEmpty { result.append(.inserted(replacement)) }
    pieces = result
  }
  package func patches() -> [SourcePatch] {
    var result: [SourcePatch] = []
    var consumed = 0
    var replacement: [UInt8] = []
    for piece in pieces {
      switch piece {
      case .inserted(let bytes): replacement.append(contentsOf: bytes)
      case .original(let range):
        if range.lowerBound > consumed || !replacement.isEmpty {
          result.append(SourcePatch(range: consumed..<range.lowerBound, replacement: replacement))
          replacement = []
        }
        consumed = range.upperBound
      }
    }
    if consumed < original.count || !replacement.isEmpty {
      result.append(SourcePatch(range: consumed..<original.count, replacement: replacement))
    }
    return result
  }
}
