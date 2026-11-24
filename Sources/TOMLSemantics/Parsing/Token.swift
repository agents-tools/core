struct Token: Equatable {
  enum Kind: UInt8 {
    case dot
    case comma
    case equal
    case lbrace
    case rbrace
    case newline
    case lbracket
    case rbracket
    case string
    case bareKey
    case eof
  }

  var budget: SemanticBudget! = nil

  let kind: Kind
  let lineNumber: Int
  let text: Range<Int>

  static func == (lhs: Token, rhs: Token) -> Bool {
    lhs.kind == rhs.kind && lhs.lineNumber == rhs.lineNumber && lhs.text == rhs.text
  }

  static var empty: Token { Token(kind: .newline, lineNumber: 1, text: 0..<0) }
}
