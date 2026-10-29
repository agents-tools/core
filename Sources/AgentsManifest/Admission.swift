import AgentsDescription
import Foundation

package struct ProjectionEvent: Sendable, Equatable, Comparable, Codable {
  package let start: Int
  package let end: Int
  package let kind: String
  package let detail: String
  package static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    if lhs.end != rhs.end { return lhs.end < rhs.end }
    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
    return lhs.detail < rhs.detail
  }
}

package struct Lexeme: Sendable {
  package let text: String
  package let range: Range<Int>
  package let kind: String
  package let decoded: String?
}

package struct GrammarArgument: Sendable {
  package let label: String
  package let labelRange: Range<Int>?
  package let value: Int
}

package struct GrammarNode: Sendable {
  package let kind: String
  package let range: Range<Int>
  package var text: String = ""
  package var children: [Int] = []
  package var arguments: [GrammarArgument] = []
  package var keys: [Lexeme] = []
}

package struct GrammarDeclaration: Sendable {
  package let name: String
  package let nameRange: Range<Int>
  package let type: ConstructionType?
  package let expression: Int
  package let range: Range<Int>
}

package struct Admission: Sendable {
  package let nodes: [GrammarNode]
  package let declarations: [GrammarDeclaration]
  package let tokens: [Lexeme]
  package let comments: [Range<Int>]
  package let projection: [ProjectionEvent]
  package let reservation: Int
}

package final class Recognizer {
  private let source: SourceText
  private let bytes: [UInt8]
  private var tokens: [Lexeme] = []
  private var comments: [Range<Int>] = []
  private var index = 0
  private var nodes: [GrammarNode] = []
  private var events: [ProjectionEvent] = []
  private var depth = 0
  private var square = 0
  private var literalUnits = 0
  private let reserved: Set<String> = Set(
    "_ Any Self as associatedtype break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate for func guard if import in init inout internal is let nil open operator precedencegroup private protocol public repeat rethrows return self static struct subscript super switch throw throws true try typealias var where while"
      .split(separator: " ").map(String.init))
  private let prefixes: Set<String> = ["await", "copy", "consume", "each", "unsafe"]

  package init(source: SourceText) {
    self.source = source
    bytes = source.bytes
  }

  private func fail(_ message: String, at offset: Int, code: String = "manifest.syntax")
    -> ManifestFailure
  {
    var metrics = FrontEndMetrics()
    metrics.tokens = tokens.count
    metrics.syntaxReservation = 16 + 4 * (tokens.count + literalUnits)
    return ManifestFailure(
      ManifestDiagnostic(code: code, message: message, span: source.span(offset..<offset)),
      metrics: metrics)
  }

  package func recognize() throws -> Admission {
    if bytes.count > 2_097_152 {
      throw fail("input byte limit", at: 2_097_152, code: "manifest.limit")
    }
    try validateUTF8()
    let header = bytes.starts(with: [239, 187, 191]) ? 3 : 0
    try version(at: header)
    try lex(from: header)
    let start = try take("import").range.lowerBound
    let module = try take("AgentsDescription")
    emit("import", start..<module.range.upperBound, "AgentsDescription")
    var previous = module.range.upperBound
    var declarations: [GrammarDeclaration] = []
    while peek().kind != "eof" {
      let gap = bytes[previous..<peek().range.lowerBound]
      guard gap.contains(10) || gap.contains(13) else {
        throw fail("declarations require a newline", at: peek().range.lowerBound)
      }
      let first = try take("let")
      let name = try identifier(bare: true)
      var annotation: ConstructionType?
      if peek(":") {
        _ = try take(":")
        annotation = try type()
      }
      _ = try take("=")
      let expression = try expression()
      previous = nodes[expression].range.upperBound
      let range = first.range.lowerBound..<previous
      emit("let", range, name.text)
      declarations.append(
        GrammarDeclaration(
          name: name.text, nameRange: name.range, type: annotation, expression: expression,
          range: range))
    }
    if declarations.isEmpty {
      throw fail("expected a let declaration", at: peek().range.lowerBound)
    }
    return Admission(
      nodes: nodes, declarations: declarations, tokens: Array(tokens.dropLast()),
      comments: comments, projection: events.sorted(),
      reservation: 16 + 4 * (tokens.count - 1 + literalUnits))
  }

  private func version(at start: Int) throws {
    var end = start
    while end < bytes.count && bytes[end] != 10 && bytes[end] != 13 { end += 1 }
    let line = source.spelling(start..<end)
    let prefix = "// agents-tools-version: "
    guard line.hasPrefix(prefix) else {
      throw fail(
        "first line must be // agents-tools-version: 1.0", at: start,
        code: line.contains("agents-tools-version")
          ? "manifest.version.invalid" : "manifest.version.missing")
    }
    let raw = String(line.dropFirst(prefix.count))
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts.allSatisfy({ part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
          && (part.count == 1 || !part.hasPrefix("0"))
      })
    else {
      throw fail("invalid language version directive", at: start, code: "manifest.version.invalid")
    }
    guard raw == "1.0" else {
      let newer = parts[0].count > 1 || parts[0] > "1" || parts[0] == "1" && parts[1] != "0"
      throw fail(
        newer
          ? "unsupported language version; upgrade the reader"
          : "unsupported language version; use a supported converter", at: start,
        code: "manifest.version.unsupported")
    }
  }

  private func validateUTF8() throws {
    var i = 0
    while i < bytes.count {
      let b = bytes[i]
      if b < 128 {
        i += 1
        continue
      }
      let length: Int
      if b >= 194 && b <= 223 {
        length = 2
      } else if b >= 224 && b <= 239 {
        length = 3
      } else if b >= 240 && b <= 244 {
        length = 4
      } else {
        throw fail("invalid UTF-8", at: i)
      }
      guard i + length <= bytes.count else { throw fail("invalid UTF-8", at: i) }
      for j in 1..<length where bytes[i + j] < 128 || bytes[i + j] > 191 {
        throw fail("invalid UTF-8", at: i + j)
      }
      let next = bytes[i + 1]
      if b == 224 && next < 160 || b == 237 && next >= 160 || b == 240 && next < 144
        || b == 244 && next >= 144
      {
        throw fail("invalid UTF-8 scalar", at: i)
      }
      i += length
    }
  }

  private func isSpace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }
  private func isHead(_ byte: UInt8) -> Bool {
    byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
  }
  private func starts(_ spelling: [UInt8], at offset: Int) -> Bool {
    offset + spelling.count <= bytes.count
      && bytes[offset..<(offset + spelling.count)].elementsEqual(spelling)
  }
  private func canonical(_ op: String) -> String {
    op == "=" ? "let value = -1" : op == "+" ? "left + right" : "\"1.2.0\"..<\"1.8.0\""
  }

  private func lex(from start: Int) throws {
    var i = start
    while i < bytes.count {
      if isSpace(bytes[i]) {
        i += 1
        continue
      }
      if starts([47, 47], at: i) {
        let first = i
        i += 2
        while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
        let range = first..<i
        if first != start && source.spelling(range).hasPrefix("// agents-tools-version:") {
          throw fail(
            "duplicate language version directive", at: first, code: "manifest.version.duplicate")
        }
        comments.append(range)
        continue
      }
      if starts([47, 42], at: i) {
        let first = i
        i += 2
        var level = 1
        while i < bytes.count && level > 0 {
          if starts([47, 42], at: i) {
            level += 1
            if level > 20 { throw fail("block comment depth", at: i, code: "manifest.limit") }
            i += 2
          } else if starts([42, 47], at: i) {
            level -= 1
            i += 2
          } else {
            i += 1
          }
        }
        if level != 0 { throw fail("unterminated comment", at: first) }
        comments.append(first..<i)
        continue
      }
      let first = i
      let kind: String
      var decoded: String?
      if bytes[i] == 34 {
        (i, decoded) = try string(at: i)
        kind = "string"
      } else if isHead(bytes[i]) {
        i += 1
        while i < bytes.count && (isHead(bytes[i]) || (48...57).contains(bytes[i])) { i += 1 }
        kind = "identifier"
      } else if (48...57).contains(bytes[i]) {
        i += 1
        while i < bytes.count && ((48...57).contains(bytes[i]) || bytes[i] == 95) { i += 1 }
        kind = "integer"
      } else if starts([46, 46, 60], at: i) {
        i += 3
        kind = "..<"
        if (first > 0 && isSpace(bytes[first - 1])) != (i < bytes.count && isSpace(bytes[i])) {
          throw fail(
            "range requires balanced whitespace; canonical spelling: \(canonical(kind))", at: first)
        }
      } else if [40, 41, 91, 93, 44, 58, 46, 61, 43, 45].contains(bytes[i]) {
        let byte = bytes[i]
        i += 1
        kind = String(UnicodeScalar(byte))
        if byte == 61 || byte == 43 {
          if first == 0 || i == bytes.count || !isSpace(bytes[first - 1]) || !isSpace(bytes[i]) {
            throw fail(
              "operator requires whitespace on both sides; canonical spelling: \(canonical(kind))",
              at: first)
          }
        }
        if byte == 45 {
          if i == bytes.count || !(48...57).contains(bytes[i]) || first == 0
            || !(isSpace(bytes[first - 1]) || [40, 91, 44, 58].contains(bytes[first - 1]))
          {
            throw fail(
              "negative integer requires an adjacent sign and separated boundary; canonical spelling: let value = -1",
              at: first)
          }
        }
      } else {
        throw fail("token outside the lexical grammar", at: i)
      }
      if tokens.count == 100_000 { throw fail("token count", at: first, code: "manifest.limit") }
      if 16 + 4 * (tokens.count + 1 + literalUnits) > 100_000 {
        throw fail("syntax storage reservation", at: first, code: "manifest.limit")
      }
      tokens.append(
        Lexeme(text: source.spelling(first..<i), range: first..<i, kind: kind, decoded: decoded))
    }
    var ci = 0
    for pair in zip(tokens, tokens.dropFirst()) {
      let left = pair.0
      let right = pair.1
      while ci < comments.count && comments[ci].lowerBound < right.range.lowerBound {
        let comment = comments[ci]
        if comment.lowerBound >= left.range.upperBound {
          let op = ["=", "+", "..<"].contains(left.text) ? left : right
          if ["=", "+", "..<"].contains(op.text) {
            if comment.lowerBound == 0 || comment.upperBound == bytes.count
              || !isSpace(bytes[comment.lowerBound - 1]) || !isSpace(bytes[comment.upperBound])
            {
              throw fail(
                "operator-adjacent comments require whitespace; canonical spelling: \(canonical(op.text))",
                at: op.range.lowerBound)
            }
          }
        }
        ci += 1
      }
    }
    tokens.append(Lexeme(text: "", range: bytes.count..<bytes.count, kind: "eof", decoded: nil))
  }

  private func string(at start: Int) throws -> (Int, String?) {
    let multiline = starts([34, 34, 34], at: start)
    let width = multiline ? 3 : 1
    var i = start + width
    var body = i
    if multiline {
      guard i < bytes.count && (bytes[i] == 10 || bytes[i] == 13) else {
        throw fail("multiline opener requires a newline", at: i)
      }
      if starts([13, 10], at: i) { i += 2 } else { i += 1 }
      body = i
    }
    while i < bytes.count {
      let byte = bytes[i]
      if byte < 32 && byte != 9 && byte != 10 && byte != 13 {
        throw fail("control scalar in string", at: i)
      }
      if !multiline && (byte == 10 || byte == 13) {
        throw fail("newline in single-line string", at: i)
      }
      if byte == 92 {
        let escape = i
        i += 1
        if i < bytes.count && [48, 92, 116, 110, 114, 34, 39].contains(bytes[i]) {
          i += 1
          continue
        }
        guard starts([117, 123], at: i) else {
          throw fail("unsupported escape or interpolation", at: escape)
        }
        i += 2
        let digits = i
        var scalar: UInt32 = 0
        while i < bytes.count, let hex = hex(bytes[i]), i - digits < 9 {
          scalar = scalar &* 16 &+ hex
          i += 1
        }
        guard (1...8).contains(i - digits), i < bytes.count, bytes[i] == 125,
          scalar <= 0x10ffff, !(0xd800...0xdfff).contains(scalar)
        else { throw fail("invalid Unicode escape", at: escape) }
        i += 1
        continue
      }
      if byte == 34 && (!multiline || starts([34, 34, 34], at: i)) {
        let closing = i
        let end = i + width
        let content: [UInt8]
        if multiline {
          var lineStart = i
          while lineStart > body && bytes[lineStart - 1] != 10 && bytes[lineStart - 1] != 13 {
            lineStart -= 1
          }
          let indent = i - lineStart
          guard bytes[lineStart..<i].allSatisfy({ $0 == 32 }) else {
            throw fail("multiline closing indentation uses spaces only", at: lineStart)
          }
          var decodedBody: [UInt8] = []
          var cursor = body
          while cursor < lineStart {
            let first = cursor
            while cursor < lineStart && bytes[cursor] != 10 && bytes[cursor] != 13 { cursor += 1 }
            let lineEnd = cursor
            var leading = first
            while leading < lineEnd && (bytes[leading] == 32 || bytes[leading] == 9) {
              if bytes[leading] == 9 {
                throw fail("multiline leading indentation uses spaces only", at: leading)
              }
              leading += 1
            }
            if lineEnd > first
              && (lineEnd - first < indent
                || !bytes[first..<(first + indent)].allSatisfy({ $0 == 32 }))
            {
              throw fail("nonempty multiline line requires full indentation", at: first)
            }
            let contentStart = lineEnd == first ? first : first + indent
            decodedBody.append(contentsOf: bytes[contentStart..<lineEnd])
            if starts([13, 10], at: cursor) { cursor += 2 } else { cursor += 1 }
            if cursor < lineStart { decodedBody.append(10) }
          }
          content = decodedBody
        } else {
          content = Array(bytes[body..<closing])
        }
        for byte in bytes[start..<end] where byte == 92 || byte == 10 || byte == 13 {
          literalUnits += 1
        }
        return (end, decode(content))
      }
      i += 1
    }
    throw fail("unterminated string", at: start)
  }

  private func hex(_ b: UInt8) -> UInt32? {
    if (48...57).contains(b) { return UInt32(b - 48) }
    if (65...70).contains(b) { return UInt32(b - 55) }
    if (97...102).contains(b) { return UInt32(b - 87) }
    return nil
  }

  private func decode(_ raw: [UInt8]) -> String {
    if !raw.contains(92) { return String(decoding: raw, as: UTF8.self) }
    var result: [UInt8] = []
    var i = 0
    while i < raw.count {
      if raw[i] != 92 {
        result.append(raw[i])
        i += 1
        continue
      }
      i += 1
      switch raw[i] {
      case 48: result.append(0)
      case 116: result.append(9)
      case 110: result.append(10)
      case 114: result.append(13)
      case 117:
        i += 2
        var scalar: UInt32 = 0
        while raw[i] != 125 {
          scalar = scalar * 16 + hex(raw[i])!
          i += 1
        }
        result.append(contentsOf: String(UnicodeScalar(scalar)!).utf8)
      default: result.append(raw[i])
      }
      i += 1
    }
    return String(decoding: result, as: UTF8.self)
  }

  private func peek() -> Lexeme { tokens[index] }
  private func peek(_ text: String) -> Bool { peek().text == text }
  @discardableResult private func take(_ text: String? = nil) throws -> Lexeme {
    let token = peek()
    if let text, token.text != text { throw fail("expected \(text)", at: token.range.lowerBound) }
    if token.kind != "eof" { index += 1 }
    return token
  }
  private func identifier(bare: Bool = false) throws -> Lexeme {
    let token = peek()
    guard token.kind == "identifier", !reserved.contains(token.text),
      !(bare && prefixes.contains(token.text))
    else { throw fail("expected an identifier", at: token.range.lowerBound) }
    return try take()
  }
  private func open(_ text: String) throws -> Int {
    let token = try take(text)
    depth += 1
    if text == "[" { square += 1 }
    if depth > 20 || square > 8 {
      throw fail("grammar delimiter depth", at: token.range.lowerBound, code: "manifest.limit")
    }
    return token.range.lowerBound
  }
  private func close(_ text: String) throws -> Int {
    let token = try take(text)
    depth -= 1
    if text == "]" { square -= 1 }
    return token.range.upperBound
  }
  private func emit(_ kind: String, _ range: Range<Int>, _ detail: String = "") {
    events.append(
      ProjectionEvent(start: range.lowerBound, end: range.upperBound, kind: kind, detail: detail))
  }
  private func node(_ value: GrammarNode, projection: Bool = true) -> Int {
    let id = nodes.count
    nodes.append(value)
    if projection { emit(value.kind, value.range, value.text) }
    return id
  }

  private func type() throws -> ConstructionType {
    if peek("[") {
      let start = try open("[")
      let first = try type()
      let result: ConstructionType
      let kind: String
      if peek(":") {
        guard first == .named("String") else {
          throw fail("dictionary key type must be String", at: start)
        }
        _ = try take(":")
        result = .dictionary(try type())
        kind = "dictionaryType"
      } else {
        result = .array(first)
        kind = "arrayType"
      }
      emit(kind, start..<(try close("]")))
      return result
    }
    let token = try identifier(bare: true)
    guard Vocabulary.typeNames.contains(token.text) else {
      throw fail("type outside construction vocabulary", at: token.range.lowerBound)
    }
    emit("type", token.range, token.text)
    return token.text == "NativeConfiguration"
      ? .dictionary(.dictionary(.named("ConfigurationValue"))) : .named(token.text)
  }

  private func expression() throws -> Int {
    let first = try primary()
    var terms = [first]
    while peek("+") {
      let op = try take("+")
      if terms.count == 32 {
        throw fail(
          "additive chain exceeds 32 terms", at: op.range.lowerBound, code: "manifest.limit")
      }
      terms.append(try primary())
    }
    if terms.count == 1 { return first }
    return node(
      GrammarNode(
        kind: "sequence",
        range: nodes[first].range.lowerBound..<nodes[terms.last!].range.upperBound, children: terms)
    )
  }

  private func primary(rangeFactory: Bool = false) throws -> Int {
    let token = peek()
    let start = token.range.lowerBound
    if token.kind == "string" || token.kind == "integer"
      || ["true", "false", "nil"].contains(token.text)
    {
      _ = try take()
      let kind = token.kind == "identifier" ? (token.text == "nil" ? "nil" : "boolean") : token.kind
      emit(kind, token.range, token.text)
      return node(
        GrammarNode(kind: kind, range: token.range, text: token.decoded ?? token.text),
        projection: false)
    }
    if peek("-") {
      _ = try take("-")
      let integer = try take()
      guard integer.kind == "integer", integer.range.lowerBound == token.range.upperBound else {
        throw fail("minus requires adjacent decimal digits", at: integer.range.lowerBound)
      }
      emit("integer", integer.range, integer.text)
      return node(
        GrammarNode(kind: "negative", range: start..<integer.range.upperBound, text: integer.text),
        projection: falseWithEvent("negative", start..<integer.range.upperBound))
    }
    if peek("(") {
      _ = try open("(")
      let child = try expression()
      return node(GrammarNode(kind: "group", range: start..<(try close(")")), children: [child]))
    }
    if peek("[") {
      _ = try open("[")
      var kind = "array"
      var children: [Int] = []
      var keys: [Lexeme] = []
      if peek(":") {
        _ = try take(":")
        kind = "dictionary"
      } else if !peek("]") {
        let dictionary = peek().kind == "string" && tokens[index + 1].text == ":"
        kind = dictionary ? "dictionary" : "array"
        while true {
          if dictionary {
            guard peek().kind == "string" else {
              throw fail("dictionary key must be a string literal", at: peek().range.lowerBound)
            }
            let key = try take()
            keys.append(key)
            emit("string", key.range, key.text)
            _ = try take(":")
          }
          children.append(try expression())
          if !peek(",") { break }
          _ = try take(",")
          if peek("]") { break }
        }
      }
      return node(
        GrammarNode(kind: kind, range: start..<(try close("]")), children: children, keys: keys))
    }
    var callee: String
    var last: Int
    if peek(".") {
      let dot = try take(".")
      let member = try identifier()
      guard member.range.lowerBound == dot.range.upperBound else {
        throw fail("member must be contiguous", at: member.range.lowerBound)
      }
      callee = "." + member.text
      last = member.range.upperBound
      emit("member", start..<last, member.text)
    } else {
      let base = try identifier(bare: true)
      callee = base.text
      last = base.range.upperBound
      emit("reference", base.range, base.text)
      if peek(".") {
        let dot = try take(".")
        let member = try identifier()
        guard dot.range.lowerBound == last, member.range.lowerBound == dot.range.upperBound else {
          throw fail("member must be contiguous", at: dot.range.lowerBound)
        }
        callee += "." + member.text
        last = member.range.upperBound
        emit("member", start..<last, member.text)
      }
    }
    let sourceCall = callee == ".source" || callee == "Source.source"
    if (callee == ".upToNextMajor" || callee == ".upToNextMinor") && !rangeFactory {
      throw fail("range factory requires the unlabeled source requirement slot", at: start)
    }
    if (sourceCall || rangeFactory) && !peek("(") {
      throw fail("factory requires an argument list", at: last)
    }
    if !peek("(") {
      return node(GrammarNode(kind: "name", range: start..<last, text: callee), projection: false)
    }
    guard peek().range.lowerBound == last else {
      throw fail("call opener must immediately follow callee", at: peek().range.lowerBound)
    }
    _ = try open("(")
    var arguments: [GrammarArgument] = []
    if sourceCall {
      arguments = try sourceArguments()
    } else if rangeFactory {
      arguments = [try argument(label: "from")]
    } else if !peek(")") {
      while true {
        var label = "_"
        var labelRange: Range<Int>?
        if peek().kind == "identifier" && tokens[index + 1].text == ":" {
          let name = try identifier()
          label = name.text
          labelRange = name.range
          emit("label", name.range, name.text)
          _ = try take(":")
        }
        arguments.append(
          GrammarArgument(label: label, labelRange: labelRange, value: try expression()))
        if !peek(",") { break }
        _ = try take(",")
        if peek(")") { throw fail("calls have no trailing comma", at: peek().range.lowerBound) }
      }
    }
    return node(
      GrammarNode(
        kind: "call", range: start..<(try close(")")), text: callee, arguments: arguments),
      projection: falseWithEvent("call", start..<tokens[index - 1].range.upperBound))
  }

  private func falseWithEvent(_ kind: String, _ range: Range<Int>) -> Bool {
    emit(kind, range)
    return false
  }

  private func argument(label: String) throws -> GrammarArgument {
    let token = try take(label)
    emit("label", token.range, token.text)
    _ = try take(":")
    return GrammarArgument(label: label, labelRange: token.range, value: try expression())
  }

  private func sourceArguments() throws -> [GrammarArgument] {
    var args = [try argument(label: "name")]
    _ = try take(",")
    let location = peek().text
    guard ["url", "path", "index"].contains(location) else {
      throw fail("source requires url:, path: or index:", at: peek().range.lowerBound)
    }
    args.append(try argument(label: location))
    if !peek(",") { return args }
    _ = try take(",")
    if peek("subpath") {
      args.append(try argument(label: "subpath"))
      return args
    }
    if location == "index" {
      throw fail("index source has no requirement", at: peek().range.lowerBound)
    }
    if ["from", "exact", "branch", "revision"].contains(peek().text) {
      args.append(try argument(label: peek().text))
    } else if peek().kind == "string" {
      let first = try primary()
      let op = try take("..<")
      emit("reference", op.range, "..<")
      guard peek().kind == "string" else {
        throw fail("range endpoint must be a string literal", at: peek().range.lowerBound)
      }
      let second = try primary()
      let range = nodes[first].range.lowerBound..<nodes[second].range.upperBound
      let id = node(
        GrammarNode(kind: "range", range: range, children: [first, second]),
        projection: falseWithEvent("sequence", range))
      args.append(GrammarArgument(label: "_", labelRange: nil, value: id))
    } else if peek(".") && ["upToNextMajor", "upToNextMinor"].contains(tokens[index + 1].text) {
      args.append(
        GrammarArgument(label: "_", labelRange: nil, value: try primary(rangeFactory: true)))
    } else {
      throw fail("expected a literal version range or range factory", at: peek().range.lowerBound)
    }
    if peek(",") {
      _ = try take(",")
      args.append(try argument(label: "subpath"))
    }
    return args
  }
}
