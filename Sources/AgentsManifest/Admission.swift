import AgentsDescription
import Foundation

private let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

enum ProjectionKind: String, Sendable {
  case string, integer, negative, boolean, array, dictionary, sequence, call, group
  case member, reference, label, type, arrayType, dictionaryType
  case importDeclaration = "import"
  case letDeclaration = "let"
  case nilLiteral = "nil"
}

struct ProjectionEvent: Sendable, Equatable, Comparable {
  let start: Int
  let end: Int
  let kind: ProjectionKind
  let detail: String
  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    if lhs.end != rhs.end { return lhs.end < rhs.end }
    if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
    return lhs.detail < rhs.detail
  }
}

enum LexemeKind: String, Sendable {
  case identifier, string, integer
  case rangeOperator = "..<"
  case leftParenthesis = "("
  case rightParenthesis = ")"
  case leftSquare = "["
  case rightSquare = "]"
  case comma = ","
  case colon = ":"
  case period = "."
  case assignment = "="
  case plus = "+"
  case minus = "-"
  case endOfFile = "eof"
}

enum GrammarNodeKind: Sendable {
  case string, integer, negative, boolean, array, dictionary, sequence, range, name, call, group
  case nilLiteral
}

extension GrammarNodeKind {
  var projection: ProjectionKind? {
    switch self {
    case .string: .string
    case .integer: .integer
    case .negative: .negative
    case .boolean: .boolean
    case .array: .array
    case .dictionary: .dictionary
    case .sequence: .sequence
    case .name, .range: nil
    case .call: .call
    case .group: .group
    case .nilLiteral: .nilLiteral
    }
  }
}

struct Lexeme: Sendable {
  let text: String
  let range: Range<Int>
  let kind: LexemeKind
  let decoded: String?
}

struct GrammarArgument: Sendable {
  let label: String
  let labelRange: Range<Int>?
  let value: Int
}

struct GrammarNode: Sendable {
  let kind: GrammarNodeKind
  let range: Range<Int>
  var text: String = ""
  var children: [Int] = []
  var arguments: [GrammarArgument] = []
  var keys: [Lexeme] = []
}

struct GrammarDeclaration: Sendable {
  let name: String
  let nameRange: Range<Int>
  let type: ConstructionType?
  let expression: Int
  let range: Range<Int>
}

struct Admission: Sendable {
  let nodes: [GrammarNode]
  let declarations: [GrammarDeclaration]
  let tokens: [Lexeme]
  let comments: [Range<Int>]
  let projection: [ProjectionEvent]
  let reservation: Int
}

final class Recognizer {
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

  init(source: SourceText) {
    self.source = source
    bytes = source.bytes
  }

  private func fail(_ message: String, at offset: Int, code: String = "manifest.syntax")
    -> ManifestFailure
  {
    var metrics = FrontEndMetrics()
    metrics.tokens = tokens.count
    metrics.syntaxReservation =
      ManifestLimits.Admission.reservationBase + ManifestLimits.Admission.reservationPerUnit
      * (tokens.count + literalUnits)
    return ManifestFailure(
      ManifestDiagnostic(code: code, message: message, span: source.span(offset..<offset)),
      metrics: metrics)
  }

  func recognize() throws -> Admission {
    if bytes.count > ManifestLimits.Input.bytes {
      throw fail("input byte limit", at: ManifestLimits.Input.bytes, code: "manifest.limit")
    }
    try validateUTF8()
    let header = bytes.starts(with: utf8ByteOrderMark) ? utf8ByteOrderMark.count : 0
    try version(at: header)
    try lex(from: header)
    let start = try take("import").range.lowerBound
    let module = try take("AgentsDescription")
    emit(.importDeclaration, start..<module.range.upperBound, "AgentsDescription")
    var previous = module.range.upperBound
    var declarations: [GrammarDeclaration] = []
    while peek().kind != .endOfFile {
      let gap = bytes[previous..<peek().range.lowerBound]
      guard gap.contains(UInt8(ascii: "\n")) || gap.contains(UInt8(ascii: "\r")) else {
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
      emit(.letDeclaration, range, name.text)
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
      reservation: ManifestLimits.Admission.reservationBase + ManifestLimits.Admission
        .reservationPerUnit * (tokens.count - 1 + literalUnits))
  }

  private func version(at start: Int) throws {
    var end = start
    while end < bytes.count && bytes[end] != UInt8(ascii: "\n") && bytes[end] != UInt8(ascii: "\r")
    { end += 1 }
    if end < bytes.count && bytes[end] == UInt8(ascii: "\r")
      && (end + 1 == bytes.count || bytes[end + 1] != UInt8(ascii: "\n"))
    {
      throw fail(
        "version directive requires LF, CRLF or EOF", at: end,
        code: "manifest.version.invalid")
    }
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
        !part.isEmpty
          && part.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
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
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
      || byte == UInt8(ascii: "\r")
  }
  private func isHead(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: "_") || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
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
      if starts([UInt8(ascii: "/"), UInt8(ascii: "/")], at: i) {
        let first = i
        i += 2
        while i < bytes.count && bytes[i] != UInt8(ascii: "\n") && bytes[i] != UInt8(ascii: "\r") {
          i += 1
        }
        let range = first..<i
        if first != start && source.spelling(range).hasPrefix("// agents-tools-version:") {
          throw fail(
            "duplicate language version directive", at: first, code: "manifest.version.duplicate")
        }
        comments.append(range)
        continue
      }
      if starts([UInt8(ascii: "/"), UInt8(ascii: "*")], at: i) {
        let first = i
        i += 2
        var level = 1
        while i < bytes.count && level > 0 {
          if starts([UInt8(ascii: "/"), UInt8(ascii: "*")], at: i) {
            level += 1
            if level > ManifestLimits.Admission.commentDepth {
              throw fail("block comment depth", at: i, code: "manifest.limit")
            }
            i += 2
          } else if starts([UInt8(ascii: "*"), UInt8(ascii: "/")], at: i) {
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
      let kind: LexemeKind
      var decoded: String?
      if bytes[i] == UInt8(ascii: "\"") {
        (i, decoded) = try string(at: i)
        kind = .string
      } else if isHead(bytes[i]) {
        i += 1
        while i < bytes.count
          && (isHead(bytes[i]) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]))
        { i += 1 }
        kind = .identifier
      } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) {
        i += 1
        while i < bytes.count
          && ((UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i])
            || bytes[i] == UInt8(ascii: "_"))
        { i += 1 }
        kind = .integer
      } else if starts([UInt8(ascii: "."), UInt8(ascii: "."), UInt8(ascii: "<")], at: i) {
        i += 3
        kind = .rangeOperator
        if (first > 0 && isSpace(bytes[first - 1])) != (i < bytes.count && isSpace(bytes[i])) {
          throw fail(
            "range requires balanced whitespace; canonical spelling: \(canonical(kind.rawValue))",
            at: first)
        }
      } else if [
        UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"),
        UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "="),
        UInt8(ascii: "+"), UInt8(ascii: "-"),
      ].contains(bytes[i]) {
        let byte = bytes[i]
        i += 1
        kind = LexemeKind(rawValue: String(UnicodeScalar(byte)))!
        if byte == UInt8(ascii: "=") || byte == UInt8(ascii: "+") {
          if first == 0 || i == bytes.count || !isSpace(bytes[first - 1]) || !isSpace(bytes[i]) {
            throw fail(
              "operator requires whitespace on both sides; canonical spelling: \(canonical(kind.rawValue))",
              at: first)
          }
        }
        if byte == UInt8(ascii: "-") {
          if i == bytes.count || !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i])
            || first == 0
            || !(isSpace(bytes[first - 1])
              || [UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: ","), UInt8(ascii: ":")]
                .contains(bytes[first - 1]))
          {
            throw fail(
              "negative integer requires an adjacent sign and separated boundary; canonical spelling: let value = -1",
              at: first)
          }
        }
      } else {
        throw fail("token outside the lexical grammar", at: i)
      }
      if tokens.count == ManifestLimits.Admission.tokens {
        throw fail("token count", at: first, code: "manifest.limit")
      }
      // Reserve container/wrapper storage before SwiftParser: the fixed base plus
      // four nodes for every token, literal escape and physical literal line break.
      // The independent all-node guard verifies this conservative reservation.
      if ManifestLimits.Admission.reservationBase + ManifestLimits.Admission.reservationPerUnit
        * (tokens.count + 1 + literalUnits) > ManifestLimits.Admission.syntaxReservation
      {
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
    tokens.append(
      Lexeme(text: "", range: bytes.count..<bytes.count, kind: .endOfFile, decoded: nil))
  }

  private func string(at start: Int) throws -> (Int, String?) {
    let multiline = starts([UInt8(ascii: "\""), UInt8(ascii: "\""), UInt8(ascii: "\"")], at: start)
    let width = multiline ? 3 : 1
    var i = start + width
    var body = i
    if multiline {
      guard i < bytes.count && (bytes[i] == UInt8(ascii: "\n") || bytes[i] == UInt8(ascii: "\r"))
      else {
        throw fail("multiline opener requires a newline", at: i)
      }
      if starts([UInt8(ascii: "\r"), UInt8(ascii: "\n")], at: i) { i += 2 } else { i += 1 }
      body = i
    }
    while i < bytes.count {
      let byte = bytes[i]
      if byte < UInt8(ascii: " ") && byte != UInt8(ascii: "\t") && byte != UInt8(ascii: "\n")
        && byte != UInt8(ascii: "\r")
      {
        throw fail("control scalar in string", at: i)
      }
      if !multiline && (byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")) {
        throw fail("newline in single-line string", at: i)
      }
      if byte == UInt8(ascii: "\\") {
        let escape = i
        i += 1
        if i < bytes.count
          && [
            UInt8(ascii: "0"), UInt8(ascii: "\\"), UInt8(ascii: "t"), UInt8(ascii: "n"),
            UInt8(ascii: "r"), UInt8(ascii: "\""), UInt8(ascii: "'"),
          ].contains(bytes[i])
        {
          i += 1
          continue
        }
        guard starts([UInt8(ascii: "u"), UInt8(ascii: "{")], at: i) else {
          throw fail("unsupported escape or interpolation", at: escape)
        }
        i += 2
        let digits = i
        var scalar: UInt32 = 0
        while i < bytes.count, let hex = hex(bytes[i]), i - digits < 9 {
          scalar = scalar &* 16 &+ hex
          i += 1
        }
        guard (1...8).contains(i - digits), i < bytes.count, bytes[i] == UInt8(ascii: "}"),
          scalar <= 0x10ffff, !(0xd800...0xdfff).contains(scalar)
        else { throw fail("invalid Unicode escape", at: escape) }
        i += 1
        continue
      }
      if byte == UInt8(ascii: "\"")
        && (!multiline
          || starts([UInt8(ascii: "\""), UInt8(ascii: "\""), UInt8(ascii: "\"")], at: i))
      {
        let closing = i
        let end = i + width
        let content: [UInt8]
        if multiline {
          var lineStart = i
          while lineStart > body && bytes[lineStart - 1] != UInt8(ascii: "\n")
            && bytes[lineStart - 1] != UInt8(ascii: "\r")
          {
            lineStart -= 1
          }
          let indent = i - lineStart
          guard bytes[lineStart..<i].allSatisfy({ $0 == UInt8(ascii: " ") }) else {
            throw fail("multiline closing indentation uses spaces only", at: lineStart)
          }
          var decodedBody: [UInt8] = []
          var cursor = body
          while cursor < lineStart {
            let first = cursor
            while cursor < lineStart && bytes[cursor] != UInt8(ascii: "\n")
              && bytes[cursor] != UInt8(ascii: "\r")
            { cursor += 1 }
            let lineEnd = cursor
            var leading = first
            while leading < lineEnd
              && (bytes[leading] == UInt8(ascii: " ") || bytes[leading] == UInt8(ascii: "\t"))
            {
              if bytes[leading] == UInt8(ascii: "\t") {
                throw fail("multiline leading indentation uses spaces only", at: leading)
              }
              leading += 1
            }
            if lineEnd > first
              && (lineEnd - first < indent
                || !bytes[first..<(first + indent)].allSatisfy({ $0 == UInt8(ascii: " ") }))
            {
              throw fail("nonempty multiline line requires full indentation", at: first)
            }
            let contentStart = lineEnd == first ? first : first + indent
            decodedBody.append(contentsOf: bytes[contentStart..<lineEnd])
            if starts([UInt8(ascii: "\r"), UInt8(ascii: "\n")], at: cursor) {
              cursor += 2
            } else {
              cursor += 1
            }
            if cursor < lineStart { decodedBody.append(UInt8(ascii: "\n")) }
          }
          content = decodedBody
        } else {
          content = Array(bytes[body..<closing])
        }
        for byte in bytes[start..<end]
        where byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        {
          literalUnits += 1
        }
        return (end, decode(content))
      }
      i += 1
    }
    throw fail("unterminated string", at: start)
  }

  private func hex(_ b: UInt8) -> UInt32? {
    if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { return UInt32(b - UInt8(ascii: "0")) }
    if (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(b) {
      return UInt32(b - UInt8(ascii: "A")) + 10
    }
    if (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b) {
      return UInt32(b - UInt8(ascii: "a")) + 10
    }
    return nil
  }

  private func decode(_ raw: [UInt8]) -> String {
    if !raw.contains(UInt8(ascii: "\\")) { return String(decoding: raw, as: UTF8.self) }
    var result: [UInt8] = []
    var i = 0
    while i < raw.count {
      if raw[i] != UInt8(ascii: "\\") {
        result.append(raw[i])
        i += 1
        continue
      }
      i += 1
      switch raw[i] {
      case UInt8(ascii: "0"): result.append(UInt8(ascii: "\0"))
      case UInt8(ascii: "t"): result.append(UInt8(ascii: "\t"))
      case UInt8(ascii: "n"): result.append(UInt8(ascii: "\n"))
      case UInt8(ascii: "r"): result.append(UInt8(ascii: "\r"))
      case UInt8(ascii: "u"):
        i += 2
        var scalar: UInt32 = 0
        while raw[i] != UInt8(ascii: "}") {
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
    if token.kind != .endOfFile { index += 1 }
    return token
  }
  private func identifier(bare: Bool = false) throws -> Lexeme {
    let token = peek()
    guard token.kind == .identifier, !reserved.contains(token.text),
      !(bare && prefixes.contains(token.text))
    else { throw fail("expected an identifier", at: token.range.lowerBound) }
    return try take()
  }
  private func open(_ text: String) throws -> Int {
    let token = try take(text)
    depth += 1
    if text == "[" { square += 1 }
    if depth > ManifestLimits.Admission.delimiterDepth
      || square > ManifestLimits.Admission.squareDepth
    {
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
  private func emit(_ kind: ProjectionKind, _ range: Range<Int>, _ detail: String = "") {
    events.append(
      ProjectionEvent(start: range.lowerBound, end: range.upperBound, kind: kind, detail: detail))
  }
  private func node(_ value: GrammarNode) -> Int {
    let id = nodes.count
    nodes.append(value)
    if let kind = value.kind.projection {
      let detail: String
      switch kind {
      case .string, .integer, .boolean, .nilLiteral: detail = source.spelling(value.range)
      default: detail = ""
      }
      emit(kind, value.range, detail)
    }
    return id
  }

  private func type() throws -> ConstructionType {
    if peek("[") {
      let start = try open("[")
      let first = try type()
      let result: ConstructionType
      let kind: ProjectionKind
      if peek(":") {
        guard first == .named("String") else {
          throw fail("dictionary key type must be String", at: start)
        }
        _ = try take(":")
        result = .dictionary(try type())
        kind = .dictionaryType
      } else {
        result = .array(first)
        kind = .arrayType
      }
      emit(kind, start..<(try close("]")))
      return result
    }
    let token = try identifier(bare: true)
    guard Vocabulary.typeNames.contains(token.text) else {
      throw fail("type outside construction vocabulary", at: token.range.lowerBound)
    }
    emit(.type, token.range, token.text)
    return Vocabulary.aliasTypes[token.text] ?? .named(token.text)
  }

  private func expression() throws -> Int {
    let first = try primary()
    var terms = [first]
    while peek("+") {
      let op = try take("+")
      if terms.count == ManifestLimits.Admission.additiveTerms {
        throw fail(
          "additive chain exceeds 32 terms", at: op.range.lowerBound, code: "manifest.limit")
      }
      terms.append(try primary())
    }
    if terms.count == 1 { return first }
    return node(
      GrammarNode(
        kind: .sequence,
        range: nodes[first].range.lowerBound..<nodes[terms.last!].range.upperBound, children: terms)
    )
  }

  private func primary(rangeFactory: Bool = false) throws -> Int {
    let token = peek()
    let start = token.range.lowerBound
    if token.kind == .string || token.kind == .integer
      || ["true", "false", "nil"].contains(token.text)
    {
      _ = try take()
      let kind: GrammarNodeKind =
        token.kind == .identifier
        ? (token.text == "nil" ? .nilLiteral : .boolean)
        : (token.kind == .string ? .string : .integer)
      return node(
        GrammarNode(kind: kind, range: token.range, text: token.decoded ?? token.text))
    }
    if peek("-") {
      _ = try take("-")
      let integer = try take()
      guard integer.kind == .integer, integer.range.lowerBound == token.range.upperBound else {
        throw fail("minus requires adjacent decimal digits", at: integer.range.lowerBound)
      }
      emit(.integer, integer.range, integer.text)
      return node(
        GrammarNode(kind: .negative, range: start..<integer.range.upperBound, text: integer.text))
    }
    if peek("(") {
      _ = try open("(")
      let child = try expression()
      return node(GrammarNode(kind: .group, range: start..<(try close(")")), children: [child]))
    }
    if peek("[") {
      _ = try open("[")
      var kind = GrammarNodeKind.array
      var children: [Int] = []
      var keys: [Lexeme] = []
      if peek(":") {
        _ = try take(":")
        kind = .dictionary
      } else if !peek("]") {
        let dictionary = peek().kind == .string && tokens[index + 1].text == ":"
        kind = dictionary ? .dictionary : .array
        while true {
          if dictionary {
            guard peek().kind == .string else {
              throw fail("dictionary key must be a string literal", at: peek().range.lowerBound)
            }
            let key = try take()
            keys.append(key)
            emit(.string, key.range, key.text)
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
      emit(.member, start..<last, member.text)
    } else {
      let base = try identifier(bare: true)
      callee = base.text
      last = base.range.upperBound
      emit(.reference, base.range, base.text)
      if peek(".") {
        let dot = try take(".")
        let member = try identifier()
        guard dot.range.lowerBound == last, member.range.lowerBound == dot.range.upperBound else {
          throw fail("member must be contiguous", at: dot.range.lowerBound)
        }
        callee += "." + member.text
        last = member.range.upperBound
        emit(.member, start..<last, member.text)
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
      return node(GrammarNode(kind: .name, range: start..<last, text: callee))
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
        if peek().kind == .identifier && tokens[index + 1].text == ":" {
          let name = try identifier()
          label = name.text
          labelRange = name.range
          emit(.label, name.range, name.text)
          _ = try take(":")
        }
        arguments.append(
          GrammarArgument(label: label, labelRange: labelRange, value: try expression()))
        if !peek(",") { break }
        _ = try take(",")
        if peek(")") { throw fail("calls have no trailing comma", at: peek().range.lowerBound) }
      }
    }
    let end = try close(")")
    return node(
      GrammarNode(kind: .call, range: start..<end, text: callee, arguments: arguments))
  }

  private func argument(label: String) throws -> GrammarArgument {
    let token = try take(label)
    emit(.label, token.range, token.text)
    _ = try take(":")
    return GrammarArgument(label: label, labelRange: token.range, value: try expression())
  }

  private func sourceArguments() throws -> [GrammarArgument] {
    var args = [try argument(label: "name")]
    _ = try take(",")
    let location = peek().text
    guard SourceRequirements.locations.contains(location) else {
      throw fail(
        "source requires a location label: "
          + SourceRequirements.locations.sorted().joined(separator: ", "),
        at: peek().range.lowerBound)
    }
    args.append(try argument(label: location))
    if !peek(",") { return args }
    _ = try take(",")
    if peek("subpath") {
      args.append(try argument(label: "subpath"))
      return args
    }
    if !SourceRequirements.locationsWithRequirements.contains(location) {
      throw fail("source location has no registered requirement", at: peek().range.lowerBound)
    }
    if SourceRequirements.labels.contains(peek().text) {
      args.append(try argument(label: peek().text))
    } else if peek().kind == .string {
      let first = try primary()
      let op = try take("..<")
      emit(.reference, op.range, "..<")
      guard peek().kind == .string else {
        throw fail("range endpoint must be a string literal", at: peek().range.lowerBound)
      }
      let second = try primary()
      let range = nodes[first].range.lowerBound..<nodes[second].range.upperBound
      emit(.sequence, range)
      let id = node(
        GrammarNode(kind: .range, range: range, children: [first, second]))
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
