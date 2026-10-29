import AgentsCore
import AgentsDescription
import Foundation

extension DocumentEditor {
  func internalComments(_ range: Range<Int>) -> Bool {
    current.admission.comments.contains {
      $0.lowerBound >= range.lowerBound && $0.upperBound <= range.upperBound
    }
  }

  func lineStart(_ offset: Int) -> Int {
    var result = offset
    while result > 0 && current.bytes[result - 1] != UInt8(ascii: "\n")
      && current.bytes[result - 1] != UInt8(ascii: "\r")
    {
      result -= 1
    }
    return result
  }

  func lineEnd(_ offset: Int) -> Int {
    var result = offset
    while result < current.bytes.count && current.bytes[result] != UInt8(ascii: "\n")
      && current.bytes[result] != UInt8(ascii: "\r")
    { result += 1 }
    return result
  }

  func blankLine(_ range: Range<Int>) -> Bool {
    let normalized = current.source.spelling(range).replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
      .dropLast().contains { $0.allSatisfy { $0 == " " || $0 == "\t" } }
  }

  /// Own contiguous leading comment lines and same-line trailing comments, stopping
  /// at blank lines and sibling boundaries. The separator and line ending travel together.
  func ownedRange(_ value: EvaluatedValue, container: GrammarNode, index: Int) throws
    -> Range<Int>
  {
    let expressionRange = current.admission.nodes[value.syntax].range
    let range =
      container.kind == .dictionary
      ? container.keys[index].range.lowerBound..<expressionRange.upperBound : expressionRange
    let siblings = container.children
    let previous =
      index == 0
      ? container.range.lowerBound + 1
      : current.admission.nodes[siblings[index - 1]].range.upperBound
    let next =
      index + 1 == siblings.count
      ? container.range.upperBound - 1
      : (container.kind == .dictionary
        ? container.keys[index + 1].range.lowerBound
        : current.admission.nodes[siblings[index + 1]].range.lowerBound)
    var start = range.lowerBound
    var end = range.upperBound
    let preceding = current.admission.comments.filter {
      $0.lowerBound >= previous && $0.upperBound <= start
    }
    for comment in preceding.reversed() {
      if blankLine(comment.upperBound..<start) { break }
      let line = lineStart(comment.lowerBound)
      guard line >= previous,
        current.bytes[line..<comment.lowerBound].allSatisfy({
          $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t")
        })
      else { break }
      start = line
    }
    let line = lineStart(start)
    if line >= previous
      && current.bytes[line..<start].allSatisfy({
        $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t")
      })
    {
      start = line
    }
    let comma = current.admission.tokens.first {
      $0.text == "," && $0.range.lowerBound >= end && $0.range.upperBound <= next
    }
    if let comma { end = comma.range.upperBound }
    for comment in current.admission.comments
    where comment.lowerBound >= range.upperBound && comment.upperBound <= next {
      if comment.lowerBound <= (comma?.range.lowerBound ?? range.upperBound)
        || lineStart(comment.lowerBound) == lineStart(end)
      {
        end = max(end, comment.upperBound)
      }
    }
    let ending = lineEnd(end)
    if start == lineStart(start), ending <= next,
      current.bytes[end..<ending].allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
      )
    {
      end = ending
      if end < current.bytes.count && current.bytes[end] == UInt8(ascii: "\r") { end += 1 }
      if end < current.bytes.count && current.bytes[end] == UInt8(ascii: "\n") { end += 1 }
    }
    return start..<end
  }
}

extension DocumentEditor {
  func hasNewline(_ range: Range<Int>) -> Bool {
    current.bytes[range].contains(UInt8(ascii: "\n"))
      || current.bytes[range].contains(UInt8(ascii: "\r"))
  }
}

/// Relative indentation is carried with the element; the destination supplies the
/// common prefix and line ending. Empty lines stay empty, including inside strings.
struct CarriedElement {
  let text: String
  let indentation: String

  var isMultiline: Bool { text.contains("\n") || text.contains("\r") }

  func render(indentation target: String, newline: String) -> String {
    let bytes = Array(text.utf8)
    var lines: [String] = []
    var start = 0
    while start < bytes.count {
      var end = start
      while end < bytes.count && bytes[end] != UInt8(ascii: "\n")
        && bytes[end] != UInt8(ascii: "\r")
      { end += 1 }
      let line = String(decoding: bytes[start..<end], as: UTF8.self)
      let relative = line.hasPrefix(indentation) ? String(line.dropFirst(indentation.count)) : line
      lines.append((lines.isEmpty || line.isEmpty ? "" : target) + relative)
      if end < bytes.count && bytes[end] == UInt8(ascii: "\r") { end += 1 }
      if end < bytes.count && bytes[end] == UInt8(ascii: "\n") { end += 1 }
      start = end
    }
    return lines.joined(separator: newline)
  }
}
