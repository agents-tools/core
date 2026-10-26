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
  /// The line where CommonMark starts the heading.
  let line: Int
  /// UTF-8 offset of the ATX opening run, including container prefixes; nil for Setext.
  let openingOffset: Int?
  var isATX: Bool { openingOffset != nil }
  var key: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

struct MarkdownDocument: Sendable, Equatable {
  static let begin =
    "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->"
  static let end = "<!-- END managed by agents -->"

  let byteOrderMark: Data
  let lines: [MarkdownLine]
  var headings: [MarkdownHeading] = []
  var topLevelHeadings: [MarkdownHeading] = []
  var markers: [Int] = []
  var endsInCode = false
  var endsInHTML = false

  init(bytes: Data) throws {
    guard String(data: bytes, encoding: .utf8) != nil else {
      throw InstructionError.invalidUTF8
    }
    self.init(String(decoding: bytes, as: UTF8.self))
  }

  init(_ text: String) {
    let hasBOM = text.utf8.starts(with: [0xEF, 0xBB, 0xBF])
    byteOrderMark = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
    lines = MarkdownLine.parse(hasBOM ? String(text.dropFirst()) : text)
    let normalized = normalized(0..<lines.count)
    let parsed = Document(parsing: normalized, options: [.disableSmartOpts])
    var pending: [(Markup, Bool)] = [(parsed, false)]
    while let (node, topLevel) = pending.popLast() {
      if let range = node.range, let heading = node as? Heading {
        let first = range.lowerBound.line - 1
        let item = MarkdownHeading(
          level: heading.level, text: heading.plainText, line: first,
          openingOffset: Self.atxOpening(in: lines[first].text, inContainer: !topLevel))
        headings.append(item)
        if topLevel { topLevelHeadings.append(item) }
      } else if let html = node as? HTMLBlock, topLevel, let range = html.range {
        let first = range.lowerBound.line - 1
        let literal = MarkdownLine.parse(html.rawHTML)
        if literal.count == 1, lines[first].text == Self.begin || lines[first].text == Self.end {
          markers.append(first)
        }
      }
      if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML {
        continue
      }
      for child in node.children.reversed() {
        pending.append((child, node is Document))
      }
    }
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

  /// Physical prefix verification is used only for blocks already identified by CommonMark.
  private static func contentOffset(in bytes: [UInt8], inContainer: Bool) -> Int {
    var cursor = 0
    while cursor < bytes.count {
      if bytes[cursor] == 32 || bytes[cursor] == 9 {
        cursor += 1
      } else if inContainer, bytes[cursor] == 62 {
        cursor += 1
      } else if inContainer {
        var end = cursor
        if bytes[end] == 45 || bytes[end] == 43 || bytes[end] == 42 {
          end += 1
        } else {
          while end < bytes.count, (48...57).contains(bytes[end]), end - cursor < 9 { end += 1 }
          guard end > cursor, end < bytes.count, bytes[end] == 46 || bytes[end] == 41 else {
            break
          }
          end += 1
        }
        guard end < bytes.count, bytes[end] == 32 || bytes[end] == 9 else { break }
        cursor = end + 1
      } else {
        break
      }
    }
    return cursor
  }

  private static func atxOpening(in line: String, inContainer: Bool) -> Int? {
    let bytes = Array(line.utf8)
    let start = contentOffset(in: bytes, inContainer: inContainer)
    if !inContainer, start > 3 || bytes[..<start].contains(9) { return nil }
    var end = start
    while end < bytes.count, bytes[end] == 35 { end += 1 }
    guard (1...6).contains(end - start),
      end == bytes.count || bytes[end] == 32 || bytes[end] == 9
    else { return nil }
    return start
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
    let bytes = Array(lines[start.line - 1].text.utf8)
    let prefix = bytes.prefix(Self.contentOffset(in: bytes, inContainer: true)).map {
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
