import Foundation

struct JSONParser {
  let bytes: [UInt8]
  let format: NativeDocumentFormat
  let budget: NativeDocumentBudget
  var i: Int = 0
  var comments: [Range<Int>] = []
  var allowsComments: Bool { if case .jsonc = format { true } else { false } }
  var trailing: Bool { if case .jsonc(let allowed) = format { allowed } else { false } }

  mutating func parse() throws -> Node {
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) { i = 3 }
    try trivia()
    let node = try value(depth: 0)
    try trivia()
    guard i == bytes.count else { throw invalid() }
    return node
  }
  func invalid() -> NativeDocumentError {
    .invalidDocument(code: "jsonSyntax", range: i..<min(i + 1, bytes.count))
  }
  mutating func trivia() throws {
    while i < bytes.count {
      try budget.step()
      if [9, 10, 13, 32].contains(bytes[i]) {
        i += 1
        continue
      }
      guard bytes[i] == 47, allowsComments, i + 1 < bytes.count else { return }
      let start = i
      if bytes[i + 1] == 47 {
        i += 2
        while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 {
          try budget.step()
          i += 1
        }
      } else if bytes[i + 1] == 42 {
        i += 2
        while i + 1 < bytes.count && !(bytes[i] == 42 && bytes[i + 1] == 47) {
          try budget.step()
          i += 1
        }
        guard i + 1 < bytes.count else { throw invalid() }
        i += 2
      } else {
        throw invalid()
      }
      try budget.allocate(1, stage: "comment")
      comments.append(start..<i)
    }
  }
  mutating func string() throws -> (String, Range<Int>) {
    let start = i
    guard i < bytes.count, bytes[i] == 34 else { throw invalid() }
    i += 1
    while i < bytes.count {
      try budget.step()
      let ch = bytes[i]
      i += 1
      if ch == 34 {
        try budget.allocate(i - start, stage: "decoded string")
        let data = Data(bytes[start..<i])
        guard let text = try? JSONDecoder().decode(String.self, from: data) else {
          throw NativeDocumentError.invalidDocument(code: "jsonString", range: start..<i)
        }
        return (text, start..<i)
      }
      if ch < 32 { throw invalid() }
      if ch == 92 {
        guard i < bytes.count else { throw invalid() }
        i += 1
      }
    }
    throw invalid()
  }
  mutating func value(depth: Int) throws -> Node {
    try budget.node(depth: depth)
    try trivia()
    guard i < bytes.count else { throw invalid() }
    let start = i
    switch bytes[i] {
    case 123, 91:
      let object = bytes[i] == 123
      let close: UInt8 = object ? 125 : 93
      let node = Node(object ? .object : .array)
      node.inline = true
      i += 1
      try trivia()
      if i < bytes.count && bytes[i] == close {
        i += 1
        node.range = start..<i
        node.insertion = i - 1
        return node
      }
      while true {
        try budget.step()
        let entryStart = i
        var key = ""
        var keyRange: Range<Int>?
        if object {
          let parsedKey = try string()
          key = parsedKey.0
          keyRange = parsedKey.1
          guard try node.member(key, budget: budget) == nil else {
            throw NativeDocumentError.invalidDocument(code: "duplicateKey", range: entryStart..<i)
          }
          try trivia()
          guard i < bytes.count, bytes[i] == 58 else { throw invalid() }
          i += 1
        }
        let child = try value(depth: depth + 1)
        let end = i
        try trivia()
        var comma: Range<Int>?
        if i < bytes.count && bytes[i] == 44 {
          comma = i..<i + 1
          i += 1
        }
        try budget.allocate(1, stage: "member")
        if object {
          child.entry = entryStart..<end
          node.members.append(
            Member(key: key, node: child, entry: entryStart..<end, comma: comma, keyRange: keyRange)
          )
        } else {
          node.elements.append(child)
          if let comma { node.commas.append(comma) }
        }
        try trivia()
        guard i < bytes.count else { throw invalid() }
        if bytes[i] == close {
          if comma != nil && !trailing { throw invalid() }
          node.insertion = i
          i += 1
          node.range = start..<i
          return node
        }
        guard comma != nil else { throw invalid() }
      }
    case 34:
      let (text, range) = try string()
      return Node(.string, text: text, range: range)
    case 116, 102, 110:
      let expected = bytes[i] == 116 ? "true" : (bytes[i] == 102 ? "false" : "null")
      for ch in expected.utf8 {
        try budget.step()
        guard i < bytes.count, bytes[i] == ch else { throw invalid() }
        i += 1
      }
      return Node(
        expected == "null" ? .null : .boolean, text: expected, raw: expected, range: start..<i)
    default:
      if bytes[i] == 45 { i += 1 }
      guard i < bytes.count else { throw invalid() }
      if bytes[i] == 48 {
        i += 1
      } else {
        guard bytes[i] >= 49 && bytes[i] <= 57 else { throw invalid() }
        try digits()
      }
      var decimal = false
      if i < bytes.count && bytes[i] == 46 {
        decimal = true
        i += 1
        try requiredDigits()
      }
      if i < bytes.count && [69, 101].contains(bytes[i]) {
        decimal = true
        i += 1
        if i < bytes.count && [43, 45].contains(bytes[i]) { i += 1 }
        try requiredDigits()
      }
      try budget.allocate(i - start, stage: "numeric lexeme")
      let raw = String(decoding: bytes[start..<i], as: UTF8.self)
      return Node(decimal ? .decimal : .integer, text: raw, raw: raw, range: start..<i)
    }
  }
  mutating func digits() throws {
    while i < bytes.count && bytes[i] >= 48 && bytes[i] <= 57 {
      try budget.step()
      i += 1
    }
  }
  mutating func requiredDigits() throws {
    let start = i
    try digits()
    guard i > start else { throw invalid() }
  }
}
