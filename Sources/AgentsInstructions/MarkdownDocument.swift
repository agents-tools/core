import Foundation

struct MarkdownLine: Sendable, Equatable {
  let text: String
  let ending: String
  var raw: String { text + ending }
  var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

  var indentation: Int {
    var columns = 0
    for character in text {
      if character == " " {
        columns += 1
      } else if character == "\t" {
        columns += 4 - columns % 4
      } else {
        break
      }
    }
    return columns
  }

  var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
}

struct MarkdownHeading: Sendable, Equatable {
  let level: Int
  let text: String
  let lines: Range<Int>
  let isATX: Bool
  var key: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

struct MarkdownDocument: Sendable, Equatable {
  static let begin =
    "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->"
  static let end = "<!-- END managed by agents -->"

  let lines: [MarkdownLine]
  var headings: [MarkdownHeading] = []
  var markers: [Int] = []
  var structuralLines: Set<Int> = []
  var endsInCode = false

  init(bytes: Data) throws {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw InstructionError.invalidUTF8
    }
    self.init(text)
  }

  init(_ text: String) {
    // Splitting UTF-8 avoids treating CRLF as one Swift Character and retains custom bytes.
    let bytes = Array(text.utf8)
    var parsed: [MarkdownLine] = []
    var start = 0
    var cursor = 0
    while cursor < bytes.count {
      if bytes[cursor] == 10 || bytes[cursor] == 13 {
        let end = cursor
        cursor += 1
        if bytes[end] == 13, cursor < bytes.count, bytes[cursor] == 10 { cursor += 1 }
        parsed.append(
          MarkdownLine(
            text: String(decoding: bytes[start..<end], as: UTF8.self),
            ending: String(decoding: bytes[end..<cursor], as: UTF8.self)))
        start = cursor
      } else {
        cursor += 1
      }
    }
    if start < bytes.count {
      parsed.append(
        MarkdownLine(text: String(decoding: bytes[start...], as: UTF8.self), ending: ""))
    }
    lines = parsed
    scan()
  }

  func managedBlock() throws -> Range<Int>? {
    var open: Int?
    var block: Range<Int>?
    for index in markers {
      if lines[index].trimmed == Self.begin {
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

  func sectionRange(_ heading: MarkdownHeading) -> Range<Int> {
    let nextHeading =
      headings.first {
        $0.lines.lowerBound > heading.lines.lowerBound && $0.level <= heading.level
      }?.lines.lowerBound ?? lines.count
    let nextMarker = markers.first { $0 > heading.lines.lowerBound } ?? lines.count
    return heading.lines.lowerBound..<min(nextHeading, nextMarker)
  }

  func normalized(_ range: Range<Int>) -> String {
    lines[range].map { $0.text + ($0.ending.isEmpty ? "" : "\n") }.joined()
  }

  static func content(_ lines: ArraySlice<MarkdownLine>) -> String {
    var trimmed = lines
    while trimmed.last?.isBlank == true { trimmed = trimmed.dropLast() }
    return trimmed.map(\.text).joined(separator: "\n")
  }

  private mutating func scan() {
    var fence: (character: Character, count: Int, containerIndent: Int)?
    var htmlEnd: String?
    var htmlUntilBlank = false
    var indented = false
    var paragraph: Int?
    for (index, line) in lines.enumerated() {
      let text = line.trimmed
      if let active = fence {
        if !line.isBlank && line.indentation < active.containerIndent {
          fence = nil
        } else {
          if line.indentation < active.containerIndent + 4, text.first == active.character {
            let run = text.prefix { $0 == active.character }.count
            if run >= active.count, text.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
              fence = nil
            }
          }
          continue
        }
      }
      if let end = htmlEnd {
        if text.lowercased().contains(end) { htmlEnd = nil }
        continue
      }
      if htmlUntilBlank {
        if line.isBlank { htmlUntilBlank = false }
        continue
      }
      if line.isBlank {
        paragraph = nil
        continue
      }
      if line.indentation >= 4 {
        if paragraph == nil { indented = true }
        continue
      }
      indented = false
      var fenceText = text
      var containerIndent = 0
      if let range = text.range(
        of: #"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#, options: .regularExpression)
      {
        containerIndent = line.indentation + text[range].count
        fenceText = String(text[range.upperBound...])
      }
      if let character = fenceText.first, character == "`" || character == "~" {
        let run = fenceText.prefix { $0 == character }.count
        if run >= 3, character != "`" || !fenceText.dropFirst(run).contains("`") {
          fence = (character, run, containerIndent)
          paragraph = nil
          continue
        }
      }
      structuralLines.insert(index)
      if text == Self.begin || text == Self.end {
        markers.append(index)
        paragraph = nil
        continue
      }
      if let end = Self.htmlTerminator(text) {
        if !text.lowercased().contains(end) { htmlEnd = end }
        structuralLines.remove(index)
        paragraph = nil
        continue
      }
      if text.range(
        of:
          #"^</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \t/>]|$)"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        htmlUntilBlank = true
        structuralLines.remove(index)
        paragraph = nil
        continue
      }
      if text.first == "#" {
        let level = text.prefix { $0 == "#" }.count
        let rest = text.dropFirst(level)
        if level <= 6, rest.isEmpty || rest.first == " " || rest.first == "\t" {
          var heading = rest.trimmingCharacters(in: .whitespaces)
          let closing = heading.reversed().prefix { $0 == "#" }.count
          if closing > 0 {
            let prefix = heading.dropLast(closing)
            if prefix.isEmpty || prefix.last == " " || prefix.last == "\t" {
              heading = prefix.trimmingCharacters(in: .whitespaces)
            }
          }
          headings.append(
            MarkdownHeading(level: level, text: heading, lines: index..<(index + 1), isATX: true))
          paragraph = nil
          continue
        }
      }
      if let first = paragraph, let character = text.first,
        character == "=" || character == "-", text.allSatisfy({ $0 == character })
      {
        headings.append(
          MarkdownHeading(
            level: character == "=" ? 1 : 2,
            text: lines[first..<index].map(\.trimmed).joined(separator: " "),
            lines: first..<(index + 1), isATX: false))
        paragraph = nil
        continue
      }
      let compact = text.filter { $0 != " " && $0 != "\t" }
      if let character = compact.first, "*-_".contains(character), compact.count >= 3,
        compact.allSatisfy({ $0 == character })
      {
        paragraph = nil
      } else if text.hasPrefix(">") {
        paragraph = nil
      } else if paragraph == nil {
        paragraph = index
      }
    }
    endsInCode = fence != nil || indented
  }

  private static func htmlTerminator(_ text: String) -> String? {
    if text.hasPrefix("<!--") { return "-->" }
    if text.hasPrefix("<?") { return "?>" }
    if text.hasPrefix("<![CDATA[") { return "]]>" }
    if text.range(of: #"^<![A-Z]"#, options: .regularExpression) != nil { return ">" }
    for tag in ["pre", "script", "style", "textarea"] {
      if text.range(of: "^<\(tag)(?:[ \\t>]|$)", options: [.regularExpression, .caseInsensitive])
        != nil
      {
        return "</\(tag)>"
      }
    }
    return nil
  }
}
