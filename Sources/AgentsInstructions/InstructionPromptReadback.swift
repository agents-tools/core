import Foundation

extension InstructionTargets {
  /// Normalized bytes are used by the ledger. The byte range belongs to the original document.
  package static func auditImportBlock(_ bytes: Data) throws
    -> (normalized: Data, byteRange: Range<Int>)?
  {
    let document = try MarkdownDocument(bytes: bytes)
    guard let block = try document.managedBlock() else { return nil }
    let start = document.lines[..<block.lowerBound].reduce(document.byteOrderMark.count) {
      $0 + $1.text.utf8.count + $1.ending.utf8.count
    }
    let end = document.lines[block].reduce(start) {
      $0 + $1.text.utf8.count + $1.ending.utf8.count
    }
    return (Data(document.normalized(block).utf8), start..<end)
  }
}
