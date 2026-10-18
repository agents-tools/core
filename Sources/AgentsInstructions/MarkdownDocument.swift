import Foundation
import Markdown

struct MarkdownLine: Sendable, Equatable {
  let text: String
  let ending: String
  var raw: String { text + ending }
  var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

  static func parse(_ text: String) -> [Self] {
    let bytes = Array(text.utf8)
    var lines: [Self] = []
    var start = 0
    var cursor = 0
    while cursor < bytes.count {
      if bytes[cursor] == 10 || bytes[cursor] == 13 {
        let end = cursor
        cursor += 1
        if bytes[end] == 13, cursor < bytes.count, bytes[cursor] == 10 { cursor += 1 }
        lines.append(
          Self(
            text: String(decoding: bytes[start..<end], as: UTF8.self),
            ending: String(decoding: bytes[end..<cursor], as: UTF8.self)))
        start = cursor
      } else {
        cursor += 1
      }
    }
    if start < bytes.count {
      lines.append(Self(text: String(decoding: bytes[start...], as: UTF8.self), ending: ""))
    }
    return lines
  }
}

struct MarkdownHeading: Sendable, Equatable {
  let level: Int
  let text: String
  let lines: Range<Int>
  /// UTF-8 offset of the ATX opening run, including container prefixes; nil for Setext.
  let openingOffset: Int?
  var isATX: Bool { openingOffset != nil }
  var key: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

struct HeadingIdentity: Hashable, Sendable {
  let level: Int
  let text: String
}

struct MarkdownDocument: Sendable, Equatable {
  static let begin =
    "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->"
  static let end = "<!-- END managed by agents -->"

  let lines: [MarkdownLine]
  var headings: [MarkdownHeading] = []
  var topLevelHeadings: [MarkdownHeading] = []
  var markers: [Int] = []
  var sections: [HeadingIdentity: [Range<Int>]] = [:]
  var codeByteRanges: [Range<Int>] = []
  var endsInCode = false
  var endsInHTML = false

  init(bytes: Data) throws {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw InstructionError.invalidUTF8
    }
    self.init(text)
  }

  init(_ text: String) {
    lines = MarkdownLine.parse(text)
    let normalized = normalized(0..<lines.count)
    let parsed = Document(parsing: normalized, options: [.disableSmartOpts])
    var starts = [0]
    for line in lines { starts.append(starts.last! + line.raw.utf8.count) }
    var pending: [(Markup, Bool, Int)] = [(parsed, false, lines.count)]
    while let (node, topLevel, containerEnd) = pending.popLast() {
      if let range = node.range {
        let first = range.lowerBound.line - 1
        // cmark can include the first line after a terminated container in a code block's range.
        let end = min(range.upperBound.line, containerEnd, lines.count)
        if let heading = node as? Heading {
          let offset = range.lowerBound.column - 1
          let bytes = Array(lines[first].text.utf8)
          let isATX = offset < bytes.count && bytes[offset] == 35
          let inlineRanges = heading.children.compactMap(\.range)
          let title: String
          let headingEnd: Int
          if let lower = inlineRanges.first?.lowerBound, let upper = inlineRanges.last?.upperBound {
            title = sourceText(lower..<upper)
            // cmark may extend a Setext heading through the following block. Inline ranges
            // identify its content; the underline is the immediately following source line.
            headingEnd = isATX ? first + 1 : min(upper.line + 1, lines.count)
          } else {
            title = ""
            headingEnd = first + 1
          }
          let item = MarkdownHeading(
            level: heading.level, text: title, lines: first..<headingEnd,
            openingOffset: isATX ? offset : nil)
          headings.append(item)
          if topLevel { topLevelHeadings.append(item) }
        } else if let html = node as? HTMLBlock, topLevel {
          let literal = MarkdownLine.parse(html.rawHTML)
          if literal.count == 1, lines[first].text == Self.begin || lines[first].text == Self.end {
            markers.append(first)
          }
        } else if node is CodeBlock {
          codeByteRanges.append(starts[first]..<starts[end])
        } else if node is InlineCode {
          let last = min(range.upperBound.line - 1, lines.count - 1)
          let lower = starts[first] + range.lowerBound.column - 1
          let upper = starts[last] + min(range.upperBound.column - 1, lines[last].text.utf8.count)
          codeByteRanges.append(lower..<upper)
        }
      }
      let childEnd =
        node is ListItem || node is BlockQuote
        ? min(node.range?.upperBound.line ?? containerEnd, containerEnd) : containerEnd
      for child in node.children.reversed() {
        pending.append((child, node is Document, childEnd))
      }
    }
    indexSections()
    codeByteRanges.sort { $0.lowerBound < $1.lowerBound }
    inspectEnd(of: parsed, text: normalized)
  }

  func managedBlock() throws -> Range<Int>? {
    var open: Int?
    var block: Range<Int>?
    for index in markers {
      if lines[index].text == Self.begin {
        if open != nil { throw InstructionError.nestedMarker(line: index + 1) }
        if block != nil { throw InstructionError.multipleBlocks }
        open = index
      } else {
        guard let begin = open else { throw InstructionError.unpairedMarker(line: index + 1) }
        block = begin..<(index + 1)
        open = nil
      }
    }
    if let open { throw InstructionError.unpairedMarker(line: open + 1) }
    return block
  }

  func normalized(_ range: Range<Int>) -> String {
    lines[range].map { $0.text + ($0.ending.isEmpty ? "" : "\n") }.joined()
  }

  static func content(_ lines: ArraySlice<MarkdownLine>) -> String {
    var trimmed = lines
    while trimmed.last?.isBlank == true { trimmed = trimmed.dropLast() }
    return trimmed.map(\.text).joined(separator: "\n")
  }

  private func sourceText(_ range: SourceRange) -> String {
    let first = range.lowerBound.line - 1
    let last = range.upperBound.line - 1
    return (first...last).map { line in
      let bytes = Array(lines[line].text.utf8)
      let lower = line == first ? min(range.lowerBound.column - 1, bytes.count) : 0
      let upper = line == last ? min(range.upperBound.column - 1, bytes.count) : bytes.count
      return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }.joined(separator: "\n")
  }

  private mutating func indexSections() {
    var nextAtLevel = Array(repeating: lines.count, count: 7)
    var markerIndex = markers.count
    var nextMarker = lines.count
    var ranges: [Range<Int>] = []
    for heading in topLevelHeadings.reversed() {
      while markerIndex > 0, markers[markerIndex - 1] > heading.lines.lowerBound {
        markerIndex -= 1
        nextMarker = markers[markerIndex]
      }
      let end = min(nextAtLevel[1...heading.level].min()!, nextMarker)
      ranges.append(heading.lines.lowerBound..<end)
      nextAtLevel[heading.level] = heading.lines.lowerBound
    }
    for (heading, range) in zip(topLevelHeadings, ranges.reversed()) {
      sections[HeadingIdentity(level: heading.level, text: heading.key), default: []].append(range)
    }
  }

  private static func terminalBlock(_ document: Markup) -> Markup {
    var node = document
    while node is Document || node is BlockQuote || node is ListItem || node is ListItemContainer {
      guard node.childCount > 0, let child = node.child(at: node.childCount - 1) else { break }
      node = child
    }
    return node
  }

  private mutating func inspectEnd(of document: Document, text: String) {
    let tail = Self.terminalBlock(document)
    guard tail is CodeBlock || tail is HTMLBlock, let start = tail.range?.lowerBound else { return }
    // The AST does not expose closure state. Continue the same container and ask the parser
    // whether a sentinel becomes code/HTML. List markers become continuation indentation.
    let prefix = lines[start.line - 1].text.utf8.prefix(start.column - 1).map {
      $0 == 62 || $0 == 9 ? $0 : UInt8(32)
    }
    let sentinel = "agents-instructions-boundary-probe"
    let probe =
      text + (text.utf8.last == 10 ? "" : "\n")
      + String(decoding: prefix, as: UTF8.self) + sentinel + "\n"
    let last = Self.terminalBlock(Document(parsing: probe, options: [.disableSmartOpts]))
    endsInCode = (last as? CodeBlock)?.code.contains(sentinel) == true
    endsInHTML = (last as? HTMLBlock)?.rawHTML.contains(sentinel) == true
  }
}
