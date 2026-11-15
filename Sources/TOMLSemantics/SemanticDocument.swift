import Foundation

package enum SemanticScalarKind: String { case string, boolean, integer, float, dateTime }

package struct SemanticEntry {
  package let key: String
  package let value: SemanticValue
  package init(key: String, value: SemanticValue) {
    self.key = key
    self.value = value
  }
}

package indirect enum SemanticValue {
  case object([SemanticEntry])
  case array([SemanticValue])
  case scalar(kind: SemanticScalarKind, decoded: String, raw: String, range: Range<Int>)
}

package struct SemanticDocument {
  package let root: SemanticValue

  package init(source: String, budget: SemanticBudget) throws {
    try budget.allocate(source.utf8.count, stage: "semantic input")
    var parser = Parser(budget: budget)
    try source.utf8.withContiguousStorageIfAvailable { try parser.parse(bytes: $0) }
      .unwrapStorage()
    let document = parser.finish(source: source)
    root = try Self.table(document.tables[0], document: document, budget: budget, depth: 0)
  }

  private static func table(
    _ table: InternalTOMLTable, document: TOMLDocument, budget: SemanticBudget, depth: Int
  ) throws -> SemanticValue {
    try budget.node(depth: depth)
    var entries: [(Int, SemanticEntry)] = []
    for i in table.keyValues {
      try budget.step()
      let pair = document.keyValues[i]
      try budget.allocate(1, stage: "ordered entry")
      entries.append(
        (
          pair.sourcePosition,
          SemanticEntry(
            key: pair.key, value: try scalar(pair.value, source: document.source, budget: budget))
        ))
    }
    for i in table.arrays {
      try budget.step()
      let pair = document.keyArrays[i]
      try budget.allocate(1, stage: "ordered entry")
      entries.append(
        (
          pair.sourcePosition,
          SemanticEntry(
            key: pair.key,
            value: try array(pair.array, document: document, budget: budget, depth: depth + 1))
        ))
    }
    for i in table.tables {
      try budget.step()
      let pair = document.keyTables[i]
      try budget.allocate(1, stage: "ordered entry")
      entries.append(
        (
          pair.sourcePosition,
          SemanticEntry(
            key: pair.key,
            value: try Self.table(pair.table, document: document, budget: budget, depth: depth + 1))
        ))
    }
    try budget.allocate(entries.count, stage: "ordered entries")
    let ordered = try entries.sorted {
      try budget.step()
      return $0.0 < $1.0
    }
    return .object(ordered.map(\.1))
  }

  private static func array(
    _ array: InternalTOMLArray, document: TOMLDocument, budget: SemanticBudget, depth: Int
  ) throws -> SemanticValue {
    try budget.node(depth: depth)
    var values: [SemanticValue] = []
    for element in array.elements {
      try budget.step()
      try budget.allocate(1, stage: "ordered element")
      switch element {
      case .leaf(let token):
        values.append(try scalar(token, source: document.source, budget: budget))
      case .array(_, let i):
        values.append(
          try Self.array(document.arrays[i], document: document, budget: budget, depth: depth + 1))
      case .table(_, let i):
        values.append(
          try table(document.tables[i], document: document, budget: budget, depth: depth + 1))
      }
    }
    return .array(values)
  }

  private static func scalar(_ token: Token, source: String, budget: SemanticBudget) throws
    -> SemanticValue
  {
    try budget.node(depth: 0)
    try budget.allocate(token.text.count, stage: "scalar lexeme")
    return try source.utf8.withContiguousStorageIfAvailable { bytes in
      try budget.step(token.text.count)
      let raw = String(decoding: bytes[token.text], as: UTF8.self)
      let kind: SemanticScalarKind
      let decoded: String
      let first = bytes[token.text.lowerBound]
      var dot = false
      var exponent = false
      var colon = false
      for byte in bytes[token.text] {
        try budget.step()
        dot = dot || byte == 46
        exponent = exponent || byte == 101 || byte == 69
        colon = colon || byte == 58
      }
      if first == 34 || first == 39 {
        kind = .string
        decoded = try token.unpackString(bytes: bytes, context: .super)
      } else if first == 116 || first == 102 {
        kind = .boolean
        decoded = try token.unpackBool(bytes: bytes, context: .super) ? "true" : "false"
      } else if colon || (token.text.count > 4 && bytes[token.text.lowerBound + 4] == 45) {
        kind = .dateTime
        _ = try token.unpackDateTime(bytes: bytes, context: .super)
        decoded = raw
      } else {
        // Base-prefixed integers can contain e/E hex digits. Classification precedes validation.
        let numeric = (first == 43 || first == 45) ? String(raw.dropFirst()) : raw
        if !numeric.hasPrefix("0x") && !numeric.hasPrefix("0o") && !numeric.hasPrefix("0b")
          && (dot || exponent || numeric == "inf" || numeric == "nan")
        {
          kind = .float
          _ = try token.unpackFloat(bytes: bytes, context: .super)
          try budget.allocate(token.text.count, stage: "decimal projection")
          var projection: [UInt8] = []
          for (i, byte) in bytes[token.text].enumerated() {
            try budget.step()
            if byte != 95 && !(i == 0 && byte == 43) { projection.append(byte) }
          }
          decoded = String(decoding: projection, as: UTF8.self)
        } else {
          kind = .integer
          decoded = String(try token.unpackInteger(bytes: bytes, context: .super))
        }
      }
      return .scalar(kind: kind, decoded: decoded, raw: raw, range: token.text)
    }.unwrapStorage()
  }

  package static func decodeKey(_ bytes: [UInt8], budget: SemanticBudget) throws -> String {
    try budget.allocate(bytes.count, stage: "key input")
    if bytes.first == 34 || bytes.first == 39 {
      return try bytes.withUnsafeBufferPointer {
        let token = Token(budget: budget, kind: .string, lineNumber: 1, text: 0..<bytes.count)
        return try token.unpackString(bytes: $0, context: .super)
      }
    }
    try budget.step(bytes.count)
    return String(decoding: bytes, as: UTF8.self)
  }
}

extension Optional {
  fileprivate func unwrapStorage() throws -> Wrapped {
    guard let self else { throw TOMLError(.invalidUTF8) }
    return self
  }
}
