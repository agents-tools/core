struct Parser: ~Copyable {
  let budget: SemanticBudget
  var depth = 0
  var token = Token.empty
  var cursor = 0
  var currentLineNumber = 1
  var currentTable = 0
  var currentTableIsKeyed = false
  var tablePath: [(key: String, keyHash: Int)] = []
  var tables: [InternalTOMLTable] = []
  var arrays: [InternalTOMLArray] = []
  var keyTables: [KeyTablePair] = []
  var keyArrays: [KeyArrayPair] = []
  var keyValues: [KeyValuePair] = []

  mutating func parse(bytes: UnsafeBufferPointer<UInt8>) throws {
    try budget.node(depth: 0)
    tables.append(InternalTOMLTable())
    let estimatedKeyValues = max(32, bytes.count / 48)
    let estimatedNodes = max(8, estimatedKeyValues / 8)
    try budget.allocate(max(8, estimatedNodes), stage: "semantic storage")
    tables.reserveCapacity(max(8, estimatedNodes))
    try budget.allocate(estimatedNodes, stage: "semantic storage")
    arrays.reserveCapacity(estimatedNodes)
    try budget.allocate(estimatedNodes, stage: "semantic storage")
    keyTables.reserveCapacity(estimatedNodes)
    try budget.allocate(estimatedNodes, stage: "semantic storage")
    keyArrays.reserveCapacity(estimatedNodes)
    try budget.allocate(estimatedKeyValues, stage: "semantic storage")
    keyValues.reserveCapacity(estimatedKeyValues)
    try budget.allocate(8, stage: "semantic storage")
    tablePath.reserveCapacity(8)

    while token.kind != .eof {
      try budget.step()
      switch token.kind {
      case .newline:
        try nextToken(bytes: bytes, isDotSpecial: true)
      case .string, .bareKey:
        try parseKeyValue(bytes: bytes, tableIndex: currentTable, isKeyed: currentTableIsKeyed)
        if token.kind != .newline, token.kind != .eof {
          throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "extra chars after value"))
        }
        if token.kind == .newline {
          try eatToken(bytes: bytes, kind: .newline, isDotSpecial: true)
        }
      case .lbracket:
        try parseSelect(bytes: bytes)
      default:
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "syntax error"))
      }
    }
  }

  mutating func nextToken(bytes: UnsafeBufferPointer<UInt8>, isDotSpecial: Bool) throws {
    let lineNumber = currentLineNumber
    var position = cursor

    @inline(__always)
    func emitToken(kind: Token.Kind, start: Int, end: Int, newlines: Int = 0) throws {
      try budget.node(depth: depth)
      token = Token(budget: budget, kind: kind, lineNumber: lineNumber, text: start..<end)
      cursor = end
      currentLineNumber = lineNumber + newlines
    }

    let count = bytes.count
    while position < count {
      try budget.step()
      let ch = bytes[position]
      switch ch {
      case CodeUnits.pound:
        // skip comment, stop just before the \n.
        position += 1
        while position < count, bytes[position] != CodeUnits.lf {
          try budget.step()
          let commentChar = bytes[position]
          // Validate comment characters - control characters are not allowed except CR when followed by LF (CRLF)
          if (commentChar >= CodeUnits.null && commentChar <= CodeUnits.backspace)
            || (commentChar >= CodeUnits.lf && commentChar <= CodeUnits.unitSeparator)
            || commentChar == CodeUnits.delete
          {
            if commentChar == CodeUnits.cr {
              let nextPosition = position + 1
              if nextPosition < count, bytes[nextPosition] == CodeUnits.lf {
                // Allow CRLF sequence
              } else {
                throw TOMLError(
                  .syntax(
                    lineNumber: lineNumber,
                    message: "control characters are not allowed in comments"
                  )
                )
              }
            } else {
              throw TOMLError(
                .syntax(
                  lineNumber: lineNumber,
                  message: "control characters are not allowed in comments"
                )
              )
            }
          }
          position += 1
        }
        continue
      case CodeUnits.space, CodeUnits.tab:
        // ignore white spaces
        position += 1
        while position < count {
          try budget.step()
          let ws = bytes[position]
          if ws != CodeUnits.space, ws != CodeUnits.tab {
            break
          }
          position += 1
        }
        continue
      case CodeUnits.dot where isDotSpecial:
        try emitToken(kind: .dot, start: position, end: position + 1)
        return
      case CodeUnits.comma:
        try emitToken(kind: .comma, start: position, end: position + 1)
        return
      case CodeUnits.equal:
        try emitToken(kind: .equal, start: position, end: position + 1)
        return
      case CodeUnits.lbrace:
        try emitToken(kind: .lbrace, start: position, end: position + 1)
        return
      case CodeUnits.rbrace:
        try emitToken(kind: .rbrace, start: position, end: position + 1)
        return
      case CodeUnits.lbracket:
        try emitToken(kind: .lbracket, start: position, end: position + 1)
        return
      case CodeUnits.rbracket:
        try emitToken(kind: .rbracket, start: position, end: position + 1)
        return
      case CodeUnits.lf:
        try emitToken(kind: .newline, start: position, end: position + 1, newlines: 1)
        return
      case CodeUnits.cr:
        // Check if this is part of a CRLF sequence
        let nextPosition = position + 1
        if nextPosition < count, bytes[nextPosition] == CodeUnits.lf {
          // This is CRLF, treat as newline
          try emitToken(kind: .newline, start: position, end: nextPosition + 1, newlines: 1)
          return
        }
        // Bare CR is invalid
        throw TOMLError(
          .syntax(
            lineNumber: lineNumber,
            message: "bare carriage return is not allowed"
          )
        )
      default:
        break
      }

      func scanString(range: Range<Int>, lineNumber: Int) throws {
        let start = range.lowerBound
        let end = range.upperBound
        let head = bytes[start]
        if (head >= CodeUnits.lowerA && head <= CodeUnits.lowerZ)
          || (head >= CodeUnits.upperA && head <= CodeUnits.upperZ) || head == CodeUnits.underscore
        {
          let isBareKeyChar = CodeUnits.isBareKeyChar
          var index = start + 1
          while index < end {
            try budget.step()
            let ch = bytes[index]
            if isBareKeyChar[Int(ch)] {
              index += 1
              continue
            }
            break
          }
          try emitToken(kind: .bareKey, start: start, end: index)
          return
        }

        if head == CodeUnits.singleQuote {
          if start + 3 <= end,
            bytes[start + 1] == CodeUnits.singleQuote,
            bytes[start + 2] == CodeUnits.singleQuote
          {
            var i = start + 3
            var newlinesInToken = 0

            while i < end {
              try budget.step()
              if bytes[i] == CodeUnits.lf {
                newlinesInToken += 1
              }
              if i + 3 <= end,
                bytes[i] == CodeUnits.singleQuote,
                bytes[i + 1] == CodeUnits.singleQuote,
                bytes[i + 2] == CodeUnits.singleQuote
              {
                if i + 3 >= end || bytes[i + 3] != CodeUnits.singleQuote {
                  break
                }
              }
              i += 1
            }

            guard i < end else {
              throw TOMLError(
                .syntax(lineNumber: lineNumber, message: "unterminated triple-s-quote")
              )
            }

            try emitToken(kind: .string, start: start, end: i + 3, newlines: newlinesInToken)
            return
          }

          var i = start + 1
          while i < end {
            try budget.step()
            let ch = bytes[i]
            if ch == CodeUnits.singleQuote || ch == CodeUnits.lf {
              break
            }
            i += 1
          }

          if i >= end || bytes[i] != CodeUnits.singleQuote {
            throw TOMLError(
              .syntax(lineNumber: lineNumber, message: "unterminated s-quote")
            )
          }

          try emitToken(kind: .string, start: start, end: i + 1)
          return
        }

        if head == CodeUnits.doubleQuote {
          if start + 3 < end,
            bytes[start + 1] == CodeUnits.doubleQuote,
            bytes[start + 2] == CodeUnits.doubleQuote
          {
            var i = start + 3
            var newlinesInToken = 0

            while i < end {
              try budget.step()
              if bytes[i] == CodeUnits.lf {
                newlinesInToken += 1
              }
              if i + 3 <= end,
                bytes[i] == CodeUnits.doubleQuote,
                bytes[i + 1] == CodeUnits.doubleQuote,
                bytes[i + 2] == CodeUnits.doubleQuote
              {
                if i + 3 >= end || bytes[i + 3] != CodeUnits.doubleQuote {
                  if bytes[i - 1] == CodeUnits.backslash {
                    i += 1
                    continue
                  }
                  break
                }
              }
              i += 1
            }

            guard i < end else {
              throw TOMLError(
                .syntax(lineNumber: lineNumber, message: "unterminated triple-d-quote")
              )
            }

            try emitToken(kind: .string, start: start, end: i + 3, newlines: newlinesInToken)
            return
          }

          var i = start + 1
          let isBasicStringBodyChar = CodeUnits.isBasicStringBodyChar
          let baseAddress = bytes.baseAddress!
          while i + 8 <= end {
            try budget.step()
            let chunk = UnsafeRawPointer(baseAddress.advanced(by: i)).loadUnaligned(
              as: UInt64.self
            )
            if chunkContainsDoubleQuotedStopByte(chunk) {
              break
            }
            i += 8
          }

          while i < end {
            try budget.step()
            let ch = bytes[i]
            if isBasicStringBodyChar[Int(ch)] {
              i += 1
              continue
            }
            if ch == CodeUnits.backslash {
              i += 1
              if i < end {
                i += 1
                continue
              }
              break
            }

            break
          }

          if i >= end || bytes[i] != CodeUnits.doubleQuote {
            throw TOMLError(
              .syntax(lineNumber: lineNumber, message: "unterminated quote")
            )
          }

          try emitToken(kind: .string, start: start, end: i + 1)
          return
        }

        if !isDotSpecial {
          var index = start
          var dateEnder: Int?
          // Fast path: Dates must produce YYYY-MM-DD, so checks for the dash
          if start + 4 < end && bytes[start + 4] == CodeUnits.minus {
            dateEnder = scanDate(bytes: bytes, range: range)?.3
          }

          if let dateEnder, dateEnder < end,
            bytes[dateEnder] == CodeUnits.upperT || bytes[dateEnder] == CodeUnits.lowerT
              || bytes[dateEnder] == CodeUnits.space
          {
            let timeStarter = dateEnder + 1
            if let timeEnder = scanTime(
              bytes: bytes, range: timeStarter..<end
            )?.3 {
              index = timeEnder
            }
          } else if let dateEnder {
            index = dateEnder
          } else if start + 2 < end, bytes[start + 2] == CodeUnits.colon,
            let timeEnder = scanTime(
              bytes: bytes, range: start..<end
            )?.3
          {
            index = timeEnder
          }
          if index > start {
            if index < end {
              if bytes[index] == CodeUnits.dot {
                index += 1
                while index < end, bytes[index] >= CodeUnits.number0,
                  bytes[index] <= CodeUnits.number9
                {
                  try budget.step()
                  index += 1
                }
              }
              if index < end, bytes[index] == CodeUnits.upperZ || bytes[index] == CodeUnits.lowerZ {
                index += 1
              } else if let timzoneEnder = scanTimezoneOffset(
                bytes: bytes, range: index..<end
              ) {
                index = timzoneEnder
              }
            }
            // squeeze out any spaces at end of string
            while index > start, bytes[index - 1] == CodeUnits.space {
              try budget.step()
              index -= 1
            }
            // tokenize
            try emitToken(kind: .string, start: start, end: index)
            return
          }
        }

        if isDotSpecial {
          let isBareKeyChar = CodeUnits.isBareKeyChar
          var index = start
          while index < end, isBareKeyChar[Int(bytes[index])] {
            try budget.step()
            index += 1
          }
          if index >= end || bytes[index] != CodeUnits.plus {
            try emitToken(kind: .bareKey, start: start, end: index)
            return
          }

          index += 1
          while index < end {
            try budget.step()
            let ch = bytes[index]
            if isBareKeyChar[Int(ch)] || ch == CodeUnits.plus {
              index += 1
              continue
            }
            break
          }
          try emitToken(kind: .string, start: start, end: index)
        } else {
          let isValueChar = CodeUnits.isValueChar
          var index = start
          while index < end {
            try budget.step()
            let ch = bytes[index]
            if isValueChar[Int(ch)] {
              index += 1
              continue
            }
            break
          }
          try emitToken(kind: .string, start: start, end: index)
        }
      }

      try scanString(range: position..<count, lineNumber: lineNumber)
      return
    }

    try emitToken(kind: .eof, start: position, end: count)
  }

  mutating func eatToken(bytes: UnsafeBufferPointer<UInt8>, kind: Token.Kind, isDotSpecial: Bool)
    throws
  {
    if token.kind != kind {
      throw TOMLError(.internalError(lineNumber: token.lineNumber))
    }
    try nextToken(bytes: bytes, isDotSpecial: isDotSpecial)
  }

  mutating func createKeyValue(
    bytes: UnsafeBufferPointer<UInt8>,
    token: Token,
    value: Token,
    inTable tableIndex: Int,
    isKeyed: Bool
  ) throws {
    let (key, keyHash) = try normalizeKeyAndHash(bytes: bytes, token: token)
    if try tableValue(tableIndex: tableIndex, keyed: isKeyed, key: key, keyHash: keyHash) != nil {
      throw TOMLError(.badKey(lineNumber: token.lineNumber))
    }
    let index = keyValues.count
    try budget.node(depth: depth)
    keyValues.append(
      KeyValuePair(key: key, keyHash: keyHash, sourcePosition: token.text.lowerBound, value: value))

    if isKeyed {
      if keyTables[tableIndex].table.keyValues.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        keyTables[tableIndex].table.keyValues.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      keyTables[tableIndex].table.keyValues.append(index)
      keyTables[tableIndex].table.recordKeyHash(keyHash)
    } else {
      if tables[tableIndex].keyValues.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        tables[tableIndex].keyValues.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      tables[tableIndex].keyValues.append(index)
      tables[tableIndex].recordKeyHash(keyHash)
    }
  }

  mutating func createKeyTable(
    bytes: UnsafeBufferPointer<UInt8>, token: Token, inTable tableIndex: Int, isKeyed: Bool,
    implicit: Bool = false
  ) throws -> Int {
    let (key, keyHash) = try normalizeKeyAndHash(bytes: bytes, token: token)
    return try createKeyTable(
      normalizedKey: key,
      keyHash: keyHash,
      lineNumber: token.lineNumber,
      inTable: tableIndex,
      isKeyed: isKeyed,
      implicit: implicit
    )
  }

  mutating func createKeyTable(
    normalizedKey key: String, keyHash: Int, lineNumber: Int, inTable tableIndex: Int,
    isKeyed: Bool, implicit: Bool = false
  ) throws -> Int {
    // Check if parent table is readOnly (inline table)
    if isKeyed ? keyTables[tableIndex].table.readOnly : tables[tableIndex].readOnly {
      throw TOMLError(.syntax(lineNumber: lineNumber, message: "cannot add to inline table"))
    }

    switch try tableValue(tableIndex: tableIndex, keyed: isKeyed, key: key, keyHash: keyHash) {
    case .table(let existingTableIndex):
      if keyTables[existingTableIndex].table.implicit {
        if keyTables[existingTableIndex].table.definedByDottedKey {
          throw TOMLError(.keyExists(lineNumber: lineNumber))
        }
        keyTables[existingTableIndex].table.implicit = false
        return existingTableIndex
      }
      throw TOMLError(.keyExists(lineNumber: lineNumber))
    case .keyValue, .array:
      throw TOMLError(.keyExists(lineNumber: lineNumber))
    case nil:
      break
    }
    let index = keyTables.count
    var newTable = InternalTOMLTable()
    newTable.implicit = implicit
    newTable.definedByDottedKey = implicit
    try budget.node(depth: depth)
    keyTables.append(
      KeyTablePair(
        key: key, keyHash: keyHash, sourcePosition: token.text.lowerBound, table: newTable))

    if isKeyed {
      if keyTables[tableIndex].table.tables.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        keyTables[tableIndex].table.tables.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      keyTables[tableIndex].table.tables.append(index)
      keyTables[tableIndex].table.recordKeyHash(keyHash)
    } else {
      if tables[tableIndex].tables.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        tables[tableIndex].tables.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      tables[tableIndex].tables.append(index)
      tables[tableIndex].recordKeyHash(keyHash)
    }
    return index
  }

  mutating func createKeyArray(
    bytes: UnsafeBufferPointer<UInt8>, token: Token, inTable tableIndex: Int, isKeyed: Bool,
    kind: InternalTOMLArray.Kind? = nil
  ) throws -> Int {
    let (key, keyHash) = try normalizeKeyAndHash(bytes: bytes, token: token)
    return try createKeyArray(
      normalizedKey: key,
      keyHash: keyHash,
      lineNumber: token.lineNumber,
      inTable: tableIndex,
      isKeyed: isKeyed,
      kind: kind
    )
  }

  mutating func createKeyArray(
    normalizedKey key: String, keyHash: Int, lineNumber: Int, inTable tableIndex: Int,
    isKeyed: Bool, kind: InternalTOMLArray.Kind? = nil
  ) throws -> Int {
    if try tableValue(tableIndex: tableIndex, keyed: isKeyed, key: key, keyHash: keyHash) != nil {
      throw TOMLError(.keyExists(lineNumber: lineNumber))
    }

    let index = keyArrays.count
    var array = InternalTOMLArray(kind: kind)
    if kind == .table {
      try budget.allocate(8, stage: "semantic storage")
      array.elements.reserveCapacity(8)
    }
    try budget.node(depth: depth)
    keyArrays.append(
      KeyArrayPair(key: key, keyHash: keyHash, sourcePosition: token.text.lowerBound, array: array))
    if isKeyed {
      if keyTables[tableIndex].table.arrays.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        keyTables[tableIndex].table.arrays.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      keyTables[tableIndex].table.arrays.append(index)
      keyTables[tableIndex].table.recordKeyHash(keyHash)
    } else {
      if tables[tableIndex].arrays.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        tables[tableIndex].arrays.reserveCapacity(8)
      }
      try budget.node(depth: depth)
      tables[tableIndex].arrays.append(index)
      tables[tableIndex].recordKeyHash(keyHash)
    }
    return index
  }

  @inline(__always)
  mutating func skipNewlines(bytes: UnsafeBufferPointer<UInt8>, isDotSpecial: Bool) throws {
    if token.kind != .newline {
      return
    }

    let count = bytes.count
    var position = cursor
    var lineNumber = currentLineNumber

    while position < count {
      try budget.step()
      let ch = bytes[position]
      if ch == CodeUnits.space || ch == CodeUnits.tab {
        // 8x unrolling for space/tab skipping
        while position + 8 <= count {
          try budget.step()
          let c0 = bytes[position]
          let c1 = bytes[position + 1]
          let c2 = bytes[position + 2]
          let c3 = bytes[position + 3]
          let c4 = bytes[position + 4]
          let c5 = bytes[position + 5]
          let c6 = bytes[position + 6]
          let c7 = bytes[position + 7]

          if c0 == CodeUnits.space || c0 == CodeUnits.tab,
            c1 == CodeUnits.space || c1 == CodeUnits.tab,
            c2 == CodeUnits.space || c2 == CodeUnits.tab,
            c3 == CodeUnits.space || c3 == CodeUnits.tab,
            c4 == CodeUnits.space || c4 == CodeUnits.tab,
            c5 == CodeUnits.space || c5 == CodeUnits.tab,
            c6 == CodeUnits.space || c6 == CodeUnits.tab,
            c7 == CodeUnits.space || c7 == CodeUnits.tab
          {
            position += 8
          } else {
            break
          }
        }

        while position < count {
          try budget.step()
          let ws = bytes[position]
          if ws != CodeUnits.space, ws != CodeUnits.tab {
            break
          }
          position += 1
        }
        continue
      }
      switch ch {
      case CodeUnits.lf:
        lineNumber += 1
        position += 1
      case CodeUnits.cr:
        if position + 1 < count, bytes[position + 1] == CodeUnits.lf {
          lineNumber += 1
          position += 2
        } else {
          // Bare CR, let nextToken handle error
          cursor = position
          currentLineNumber = lineNumber
          try nextToken(bytes: bytes, isDotSpecial: isDotSpecial)
          return
        }
      case CodeUnits.pound:
        // Comment
        position += 1
        while position < count {
          try budget.step()
          let c = bytes[position]
          if c == CodeUnits.lf {
            break  // Leave LF for next iteration to handle line number
          }
          if (c >= CodeUnits.null && c <= CodeUnits.backspace)
            || (c >= CodeUnits.lf && c <= CodeUnits.unitSeparator) || c == CodeUnits.delete
          {
            if c == CodeUnits.cr {
              if position + 1 < count, bytes[position + 1] == CodeUnits.lf {
                // CRLF ends comment
                break
              }
            }
            // Let nextToken throw the error
            cursor = position
            currentLineNumber = lineNumber
            try nextToken(bytes: bytes, isDotSpecial: isDotSpecial)
            return
          }
          position += 1
        }
      default:
        // Found something else, stop skipping
        cursor = position
        currentLineNumber = lineNumber
        try nextToken(bytes: bytes, isDotSpecial: isDotSpecial)
        return
      }
    }

    // If we hit EOF or loop finishes
    cursor = position
    currentLineNumber = lineNumber
    try nextToken(bytes: bytes, isDotSpecial: isDotSpecial)
  }

  mutating func parseKeyedInlineTable(bytes: UnsafeBufferPointer<UInt8>, tableIndex: Int) throws {
    try budget.enter(depth + 1)
    depth += 1
    defer { depth -= 1 }
    try eatToken(bytes: bytes, kind: .lbrace, isDotSpecial: true)

    while true {
      try budget.step()
      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .rbrace {
        break
      }

      if token.kind != .string, token.kind != .bareKey {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "expect a string"))
      }

      try parseKeyValue(bytes: bytes, tableIndex: tableIndex, isKeyed: true)

      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .comma {
        try eatToken(bytes: bytes, kind: .comma, isDotSpecial: true)
        continue
      }
      break
    }

    try eatToken(bytes: bytes, kind: .rbrace, isDotSpecial: true)

    keyTables[tableIndex].table.readOnly = true
  }

  mutating func parseInlineTable(bytes: UnsafeBufferPointer<UInt8>, tableIndex: Int) throws {
    try budget.enter(depth + 1)
    depth += 1
    defer { depth -= 1 }
    try eatToken(bytes: bytes, kind: .lbrace, isDotSpecial: true)

    while true {
      try budget.step()
      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .rbrace {
        break
      }

      if token.kind != .string, token.kind != .bareKey {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "expect a string"))
      }

      try parseKeyValue(bytes: bytes, tableIndex: tableIndex, isKeyed: false)

      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .comma {
        try eatToken(bytes: bytes, kind: .comma, isDotSpecial: true)
        continue
      }
      break
    }

    try eatToken(bytes: bytes, kind: .rbrace, isDotSpecial: true)

    tables[tableIndex].readOnly = true
  }

  mutating func parseKeyedArray(bytes: UnsafeBufferPointer<UInt8>, arrayIndex: Int) throws {
    try budget.enter(depth + 1)
    depth += 1
    defer { depth -= 1 }
    try eatToken(bytes: bytes, kind: .lbracket, isDotSpecial: false)

    while true {
      try budget.step()
      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .rbracket {
        break
      }
      if keyArrays[arrayIndex].array.elements.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        keyArrays[arrayIndex].array.elements.reserveCapacity(8)
      }

      switch token.kind {
      case .string, .bareKey:
        if keyArrays[arrayIndex].array.kind == nil {
          keyArrays[arrayIndex].array.kind = .value
        } else if keyArrays[arrayIndex].array.kind != .value {
          keyArrays[arrayIndex].array.kind = .mixed
        }

        try budget.node(depth: depth)
        keyArrays[arrayIndex].array.elements.append(.leaf(token))

        try nextToken(bytes: bytes, isDotSpecial: true)

      case .lbracket:  // Nested array
        if keyArrays[arrayIndex].array.kind == nil {
          keyArrays[arrayIndex].array.kind = .array
        } else if keyArrays[arrayIndex].array.kind != .array {
          keyArrays[arrayIndex].array.kind = .mixed
        }

        let newArrayIndex = arrays.count
        try budget.node(depth: depth)
        arrays.append(InternalTOMLArray())
        try budget.node(depth: depth)
        keyArrays[arrayIndex].array.elements.append(
          .array(lineNumber: token.lineNumber, newArrayIndex))

        try parseArray(bytes: bytes, arrayIndex: newArrayIndex)

      case .lbrace:  // Nested table
        if keyArrays[arrayIndex].array.kind == nil {
          keyArrays[arrayIndex].array.kind = .table
        } else if keyArrays[arrayIndex].array.kind != .table {
          keyArrays[arrayIndex].array.kind = .mixed
        }

        let newTableIndex = tables.count
        try budget.node(depth: depth)
        tables.append(InternalTOMLTable())
        try budget.node(depth: depth)
        keyArrays[arrayIndex].array.elements.append(
          .table(lineNumber: token.lineNumber, newTableIndex))

        try parseInlineTable(bytes: bytes, tableIndex: newTableIndex)

      default:
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "syntax error"))
      }

      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .comma {
        try eatToken(bytes: bytes, kind: .comma, isDotSpecial: false)
        continue
      }
      break
    }

    try eatToken(bytes: bytes, kind: .rbracket, isDotSpecial: true)
  }

  mutating func parseArray(bytes: UnsafeBufferPointer<UInt8>, arrayIndex: Int) throws {
    try budget.enter(depth + 1)
    depth += 1
    defer { depth -= 1 }
    try eatToken(bytes: bytes, kind: .lbracket, isDotSpecial: false)

    while true {
      try budget.step()
      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .rbracket {
        break
      }
      if arrays[arrayIndex].elements.isEmpty {
        try budget.allocate(8, stage: "semantic storage")
        arrays[arrayIndex].elements.reserveCapacity(8)
      }

      switch token.kind {
      case .string, .bareKey:
        if arrays[arrayIndex].kind == nil {
          arrays[arrayIndex].kind = .value
        } else if arrays[arrayIndex].kind != .value {
          arrays[arrayIndex].kind = .mixed
        }

        try budget.node(depth: depth)
        arrays[arrayIndex].elements.append(.leaf(token))

        try nextToken(bytes: bytes, isDotSpecial: true)

      case .lbracket:  // Nested array
        if arrays[arrayIndex].kind == nil {
          arrays[arrayIndex].kind = .array
        } else if arrays[arrayIndex].kind != .array {
          arrays[arrayIndex].kind = .mixed
        }

        let newArrayIndex = arrays.count
        try budget.node(depth: depth)
        arrays.append(InternalTOMLArray())
        try budget.node(depth: depth)
        arrays[arrayIndex].elements.append(.array(lineNumber: token.lineNumber, newArrayIndex))

        try parseArray(bytes: bytes, arrayIndex: newArrayIndex)

      case .lbrace:  // Nested table
        if arrays[arrayIndex].kind == nil {
          arrays[arrayIndex].kind = .table
        } else if arrays[arrayIndex].kind != .table {
          arrays[arrayIndex].kind = .mixed
        }

        let newTableIndex = tables.count
        try budget.node(depth: depth)
        tables.append(InternalTOMLTable())
        try budget.node(depth: depth)
        arrays[arrayIndex].elements.append(.table(lineNumber: token.lineNumber, newTableIndex))

        try parseInlineTable(bytes: bytes, tableIndex: newTableIndex)

      default:
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "syntax error"))
      }

      try skipNewlines(bytes: bytes, isDotSpecial: false)

      if token.kind == .comma {
        try eatToken(bytes: bytes, kind: .comma, isDotSpecial: false)
        continue
      }
      break
    }

    try eatToken(bytes: bytes, kind: .rbracket, isDotSpecial: true)
  }

  mutating func parseKeyValue(bytes: UnsafeBufferPointer<UInt8>, tableIndex: Int, isKeyed: Bool)
    throws
  {
    if isKeyed ? keyTables[tableIndex].table.readOnly : tables[tableIndex].readOnly {
      throw TOMLError(
        .syntax(
          lineNumber: token.lineNumber, message: "cannot insert new entry into existing table"))
    }

    let key = token
    try nextToken(bytes: bytes, isDotSpecial: true)

    if token.kind == .dot {
      let (subTableKey, subTableHash) = try normalizeKeyAndHash(
        bytes: bytes,
        token: key
      )
      let subTableIndex: Int

      if let existingTableIndex = try lookupTable(
        in: tableIndex, keyed: isKeyed, key: subTableKey, keyHash: subTableHash)
      {
        // Check if the existing table is explicitly defined (not implicit)
        if !keyTables[existingTableIndex].table.implicit {
          throw TOMLError(
            .syntax(
              lineNumber: token.lineNumber,
              message: "cannot add to explicitly defined table using dotted keys"))
        }
        subTableIndex = existingTableIndex
      } else {
        subTableIndex = try createKeyTable(
          normalizedKey: subTableKey,
          keyHash: subTableHash,
          lineNumber: key.lineNumber,
          inTable: tableIndex,
          isKeyed: isKeyed,
          implicit: true
        )
      }

      try nextToken(bytes: bytes, isDotSpecial: true)
      try parseKeyValue(bytes: bytes, tableIndex: subTableIndex, isKeyed: true)
      return
    }

    if token.kind != .equal {
      throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "missing ="))
    }

    try nextToken(bytes: bytes, isDotSpecial: false)

    if token.kind == .string || token.kind == .bareKey {
      try createKeyValue(
        bytes: bytes, token: key, value: token, inTable: tableIndex, isKeyed: isKeyed)
      try nextToken(bytes: bytes, isDotSpecial: false)
      return
    }

    if token.kind == .lbracket {
      let index = try createKeyArray(
        bytes: bytes, token: key, inTable: tableIndex, isKeyed: isKeyed)
      try parseKeyedArray(bytes: bytes, arrayIndex: index)
      return
    }

    if token.kind == .lbrace {
      let index = try createKeyTable(
        bytes: bytes, token: key, inTable: tableIndex, isKeyed: isKeyed)
      try parseKeyedInlineTable(bytes: bytes, tableIndex: index)
      return
    }

    throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "syntax error"))
  }

  mutating func fillTablePath(bytes: UnsafeBufferPointer<UInt8>, clearPath: Bool = true) throws -> (
    key: String,
    keyHash: Int,
    token: Token
  ) {
    let lineNumber = token.lineNumber
    if clearPath {
      tablePath.removeAll(keepingCapacity: true)
    }

    while true {
      try budget.step()
      if token.kind != .string, token.kind != .bareKey {
        throw TOMLError(.syntax(lineNumber: lineNumber, message: "invalid or missing key"))
      }

      let currentToken = token
      let (key, keyHash) = try normalizeKeyAndHash(bytes: bytes, token: token)
      try nextToken(bytes: bytes, isDotSpecial: true)

      if token.kind == .rbracket {
        return (key: key, keyHash: keyHash, token: currentToken)
      }

      try budget.node(depth: depth)
      tablePath.append((key: key, keyHash: keyHash))

      if token.kind != .dot {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "invalid key"))
      }

      try nextToken(bytes: bytes, isDotSpecial: true)
    }
  }

  mutating func parseSelect(bytes: UnsafeBufferPointer<UInt8>) throws {
    assert(token.kind == .lbracket)
    let nextIndex = token.text.lowerBound + 1
    let llb = nextIndex < bytes.count && bytes[nextIndex] == CodeUnits.lbracket
    if llb {
      cursor = nextIndex + 1
      try nextToken(bytes: bytes, isDotSpecial: true)
    } else {
      try eatToken(bytes: bytes, kind: .lbracket, isDotSpecial: true)
    }

    if token.kind != .string, token.kind != .bareKey {
      throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "invalid or missing key"))
    }

    let firstToken = token
    let firstIsBare = firstToken.kind == .bareKey
    let firstKey: String?
    let firstKeyHash: Int
    if firstIsBare {
      firstKey = nil
      firstKeyHash = fastKeyHash(bytes: bytes, range: firstToken.text)
    } else {
      let normalized = try normalizeKeyAndHash(
        bytes: bytes,
        token: firstToken
      )
      firstKey = normalized.key
      firstKeyHash = normalized.keyHash
    }
    try nextToken(bytes: bytes, isDotSpecial: true)

    if token.kind == .rbracket {
      currentTable = 0
      currentTableIsKeyed = false
      if !llb {
        let key = try firstKey ?? makeString(budget: budget, bytes: bytes, range: firstToken.text)
        currentTable = try createKeyTable(
          normalizedKey: key,
          keyHash: firstKeyHash,
          lineNumber: firstToken.lineNumber,
          inTable: currentTable,
          isKeyed: currentTableIsKeyed
        )
        currentTableIsKeyed = true
      } else {
        let arrayIndex: Int
        if firstIsBare {
          if let existingArrayIndex = try lookupArray(
            in: currentTable,
            keyed: currentTableIsKeyed,
            bytes: bytes,
            token: firstToken,
            keyHash: firstKeyHash
          ) {
            arrayIndex = existingArrayIndex
          } else {
            let key = try makeString(budget: budget, bytes: bytes, range: firstToken.text)
            arrayIndex = try createKeyArray(
              normalizedKey: key,
              keyHash: firstKeyHash,
              lineNumber: firstToken.lineNumber,
              inTable: currentTable,
              isKeyed: currentTableIsKeyed,
              kind: .table
            )
          }
        } else {
          let key = firstKey!
          if let existingArrayIndex = try lookupArray(
            in: currentTable,
            keyed: currentTableIsKeyed,
            key: key,
            keyHash: firstKeyHash
          ) {
            arrayIndex = existingArrayIndex
          } else {
            arrayIndex = try createKeyArray(
              normalizedKey: key,
              keyHash: firstKeyHash,
              lineNumber: firstToken.lineNumber,
              inTable: currentTable,
              isKeyed: currentTableIsKeyed,
              kind: .table
            )
          }
        }
        if keyArrays[arrayIndex].array.kind != .table {
          throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "array mismatch"))
        }

        let newTableIndex = tables.count
        try budget.node(depth: depth)
        tables.append(InternalTOMLTable())
        try budget.node(depth: depth)
        keyArrays[arrayIndex].array.elements.append(
          .table(lineNumber: token.lineNumber, newTableIndex))
        currentTable = newTableIndex
        currentTableIsKeyed = false
      }
    } else {
      if token.kind != .dot {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "invalid key"))
      }

      let firstPathKey =
        try firstKey ?? makeString(budget: budget, bytes: bytes, range: firstToken.text)
      var pathTableIndex = 0
      var pathTableIsKeyed = false
      try advanceTablePathSegment(
        tableIndex: &pathTableIndex,
        isKeyed: &pathTableIsKeyed,
        key: firstPathKey,
        keyHash: firstKeyHash
      )

      try nextToken(bytes: bytes, isDotSpecial: true)
      if token.kind != .string, token.kind != .bareKey {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "invalid or missing key"))
      }

      let secondToken = token
      let (secondKey, secondKeyHash) = try normalizeKeyAndHash(
        bytes: bytes,
        token: secondToken
      )
      try nextToken(bytes: bytes, isDotSpecial: true)

      let key: String
      let keyHash: Int
      let keyToken: Token

      if token.kind == .rbracket {
        currentTable = pathTableIndex
        currentTableIsKeyed = pathTableIsKeyed
        key = secondKey
        keyHash = secondKeyHash
        keyToken = secondToken
      } else {
        tablePath.removeAll(keepingCapacity: true)
        try budget.node(depth: depth)
        tablePath.append((key: secondKey, keyHash: secondKeyHash))
        if token.kind != .dot {
          throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "invalid key"))
        }
        try nextToken(bytes: bytes, isDotSpecial: true)

        let terminal = try fillTablePath(bytes: bytes, clearPath: false)
        key = terminal.key
        keyHash = terminal.keyHash
        keyToken = terminal.token
        try walkTablePath(startTable: pathTableIndex, startKeyed: pathTableIsKeyed)
      }

      if !llb {
        currentTable = try createKeyTable(
          normalizedKey: key,
          keyHash: keyHash,
          lineNumber: keyToken.lineNumber,
          inTable: currentTable,
          isKeyed: currentTableIsKeyed
        )
        currentTableIsKeyed = true
      } else {
        let arrayIndex: Int =
          if let existingArrayIndex = try lookupArray(
            in: currentTable,
            keyed: currentTableIsKeyed,
            key: key,
            keyHash: keyHash
          ) {
            existingArrayIndex
          } else {
            try createKeyArray(
              normalizedKey: key,
              keyHash: keyHash,
              lineNumber: keyToken.lineNumber,
              inTable: currentTable,
              isKeyed: currentTableIsKeyed,
              kind: .table
            )
          }
        if keyArrays[arrayIndex].array.kind != .table {
          throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "array mismatch"))
        }

        let newTableIndex = tables.count
        try budget.node(depth: depth)
        tables.append(InternalTOMLTable())
        try budget.node(depth: depth)
        keyArrays[arrayIndex].array.elements.append(
          .table(lineNumber: token.lineNumber, newTableIndex))
        currentTable = newTableIndex
        currentTableIsKeyed = false
      }
    }

    if token.kind != .rbracket {
      throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "expects ]"))
    }

    if llb {
      guard cursor < bytes.count, bytes[cursor] == CodeUnits.rbracket else {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "expects ]]"))
      }
      cursor += 1
      try nextToken(bytes: bytes, isDotSpecial: true)
    } else {
      try eatToken(bytes: bytes, kind: .rbracket, isDotSpecial: true)
    }

    if token.kind != .newline, token.kind != .eof {
      throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "extra chars after ] or ]]"))
    }
  }
}

extension Token {
  func unpackBool(bytes: UnsafeBufferPointer<UInt8>, context: TOMLKey) throws -> Bool {
    try budget.allocate(text.count, stage: "scalar decode")
    try budget.step(text.count)
    if text.count == 4,
      bytes[text.lowerBound] == CodeUnits.lowerT,
      bytes[text.lowerBound + 1] == CodeUnits.lowerR,
      bytes[text.lowerBound + 2] == CodeUnits.lowerU,
      bytes[text.lowerBound + 3] == CodeUnits.lowerE
    {
      return true
    } else if text.count == 5,
      bytes[text.lowerBound] == CodeUnits.lowerF,
      bytes[text.lowerBound + 1] == CodeUnits.lowerA,
      bytes[text.lowerBound + 2] == CodeUnits.lowerL,
      bytes[text.lowerBound + 3] == CodeUnits.lowerS,
      bytes[text.lowerBound + 4] == CodeUnits.lowerE
    {
      return false
    }

    throw TOMLError(.invalidBool(context: context, lineNumber: lineNumber))
  }

  func unpackFloat(bytes: UnsafeBufferPointer<UInt8>, context: TOMLKey) throws -> Double {
    try budget.allocate(text.count, stage: "scalar decode")
    try budget.step(text.count)
    var resultCodeUnits: [UTF8.CodeUnit] = []
    var index = text.lowerBound
    if bytes[index] == CodeUnits.plus || bytes[index] == CodeUnits.minus {
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(bytes[index])
      index += 1
    }
    guard index < text.upperBound else {
      throw TOMLError(
        .invalidFloat(
          context: context, lineNumber: lineNumber, reason: "expected digit, nan or inf after sign")
      )
    }

    if !bytes[index].isDecimalDigit {
      let nameEnd = index + 3
      guard nameEnd == text.upperBound,
        (bytes[index] == CodeUnits.lowerN && bytes[index + 1] == CodeUnits.lowerA
          && bytes[index + 2] == CodeUnits.lowerN)
          || (bytes[index] == CodeUnits.lowerI && bytes[index + 1] == CodeUnits.lowerN
            && bytes[index + 2] == CodeUnits.lowerF)
      else {
        throw TOMLError(
          .invalidFloat(
            context: context, lineNumber: lineNumber,
            reason: "Expected nan or inf, found \(bytes[index])"))
      }
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(bytes[index])
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(bytes[index + 1])
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(bytes[index + 2])
    } else {
      let nextIndex = index + 1
      if bytes[index] == CodeUnits.number0,
        nextIndex < text.upperBound,
        case let next = bytes[nextIndex],
        next != CodeUnits.dot, next != CodeUnits.lowerE, next != CodeUnits.upperE
      {
        throw TOMLError(
          .invalidFloat(
            context: context, lineNumber: lineNumber,
            reason: "Float begins with 0 must be followed by a '.', 'e' or 'E'"))
      }

      while index < text.upperBound {
        try budget.step()
        let ch = bytes[index]
        index += 1

        if ch == CodeUnits.underscore {
          guard
            let last = resultCodeUnits.last,
            last.isDecimalDigit
          else {
            throw TOMLError(
              .invalidFloat(
                context: context, lineNumber: lineNumber, reason: "'_' must be preceded by a digit")
            )
          }

          guard
            index < text.upperBound,
            case let next = bytes[index],
            next.isDecimalDigit
          else {
            throw TOMLError(
              .invalidFloat(
                context: context, lineNumber: lineNumber, reason: "'_' must be follewed by a digit")
            )
          }

          continue
        } else if ch == CodeUnits.dot {
          if resultCodeUnits.isEmpty {
            throw TOMLError(
              .invalidFloat(
                context: context, lineNumber: lineNumber,
                reason: "First digit of floats cannot be '.'"))
          }

          if !resultCodeUnits.last!.isDecimalDigit {
            throw TOMLError(
              .invalidFloat(
                context: context, lineNumber: lineNumber,
                reason: "'.' must be preceded by a decimal digit"))
          }

          guard index < text.upperBound, bytes[index].isDecimalDigit else {
            throw TOMLError(
              .invalidFloat(
                context: context, lineNumber: lineNumber, reason: "A digit must follow '.'"))
          }

        } else if ch == CodeUnits.upperE || ch == CodeUnits.lowerE {
        } else if !ch.isDecimalDigit, ch != CodeUnits.plus, ch != CodeUnits.minus {
          throw TOMLError(
            .invalidFloat(
              context: context, lineNumber: lineNumber, reason: "invalid character for float"))
        }

        try budget.allocate(1, stage: "decoded scalar storage")
        resultCodeUnits.append(ch)
      }
    }

    guard let double = Double(String(decoding: resultCodeUnits, as: UTF8.self)) else {
      throw TOMLError(
        .invalidFloat(context: context, lineNumber: lineNumber, reason: "not a float"))
    }

    return double
  }

  func unpackString(bytes: UnsafeBufferPointer<UInt8>, context: TOMLKey) throws -> String {
    try budget.allocate(text.count, stage: "scalar decode")
    try budget.step(text.count)
    var multiline = false

    if bytes.count == 0 {
      throw TOMLError(
        .invalidString(context: context, lineNumber: lineNumber, reason: "missing closing quote"))
    }

    let quoteChar = bytes[text.lowerBound]
    if quoteChar != CodeUnits.doubleQuote, quoteChar != CodeUnits.singleQuote {
      throw TOMLError(.typeMismatch(context: context, lineNumber: lineNumber, expected: "string"))
    }
    var index = text.lowerBound
    var endIndex = text.upperBound

    if endIndex - index >= 3 && bytes[index] == CodeUnits.doubleQuote
      && bytes[index + 1] == CodeUnits.doubleQuote && bytes[index + 2] == CodeUnits.doubleQuote
      || endIndex - index >= 3 && bytes[index] == CodeUnits.singleQuote
        && bytes[index + 1] == CodeUnits.singleQuote && bytes[index + 2] == CodeUnits.singleQuote
    {
      multiline = true
      index += 3
      endIndex -= 3

      if index < endIndex, bytes[index] == CodeUnits.lf {
        index += 1
      } else if endIndex - index >= 2, bytes[index] == CodeUnits.cr,
        bytes[index + 1] == CodeUnits.lf
      {
        index += 2
      }
    } else {
      index = index + 1
      endIndex = endIndex - 1
      guard endIndex >= 0, bytes[endIndex] == quoteChar else {
        throw TOMLError(
          .invalidString(context: context, lineNumber: lineNumber, reason: "missing closing quote"))
      }
    }

    if quoteChar == CodeUnits.singleQuote {
      return try literalString(
        budget: budget, bytes: bytes, range: index..<endIndex, multiline: multiline)
    } else {
      return try basicString(
        budget: budget, bytes: bytes, range: index..<endIndex, multiline: multiline)
    }
  }

  func unpackInteger(bytes: UnsafeBufferPointer<UInt8>, context: TOMLKey) throws -> Int64 {
    try budget.allocate(text.count, stage: "scalar decode")
    try budget.step(text.count)
    @_transparent
    func isValidDigit(_ codeUnit: UTF8.CodeUnit, base: Int) -> Bool {
      switch base {
      case 10:
        codeUnit.isDecimalDigit
      case 16:
        codeUnit.isHexDigit
      case 2:
        codeUnit == CodeUnits.number0 || codeUnit == CodeUnits.number1
      case 8:
        CodeUnits.number0 <= codeUnit && codeUnit <= CodeUnits.number7
      default:
        false
      }
    }

    var resultCodeUnits: [UTF8.CodeUnit] = []
    var index = text.lowerBound
    var base = 10
    var hasSign = false
    if bytes[index] == CodeUnits.plus || bytes[index] == CodeUnits.minus {
      hasSign = true
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(bytes[index])
      index = text.index(after: index)
    }
    guard index < text.upperBound else {
      throw TOMLError(
        .invalidInteger(
          context: context, lineNumber: lineNumber, reason: "expected digit after sign"))
    }

    if bytes[index] == CodeUnits.underscore {
      throw TOMLError(
        .invalidInteger(context: context, lineNumber: lineNumber, reason: "cannot start with a '_'")
      )
    }

    if bytes[index] == CodeUnits.number0 {
      let nextIndex = index + 1
      if nextIndex < text.upperBound {
        if bytes[nextIndex] == CodeUnits.lowerX {
          if hasSign {
            throw TOMLError(
              .invalidInteger(
                context: context, lineNumber: lineNumber,
                reason: "hexadecimal integers cannot have explicit signs"))
          }
          base = 16
          index += 2
        } else if bytes[nextIndex] == CodeUnits.lowerO {
          if hasSign {
            throw TOMLError(
              .invalidInteger(
                context: context, lineNumber: lineNumber,
                reason: "octal integers cannot have explicit signs"))
          }
          base = 8
          index += 2
        } else if bytes[nextIndex] == CodeUnits.lowerB {
          if hasSign {
            throw TOMLError(
              .invalidInteger(
                context: context, lineNumber: lineNumber,
                reason: "binary integers cannot have explicit signs"))
          }
          base = 2
          index += 2
        } else if bytes[nextIndex].isDecimalDigit || bytes[nextIndex] == CodeUnits.underscore {
          throw TOMLError(
            .invalidInteger(
              context: context, lineNumber: lineNumber,
              reason: "decimal integers cannot have leading zeros"))
        }
      }
      // Single zero is allowed to continue to the main loop
    }
    guard index < text.upperBound else {
      throw TOMLError(
        .invalidInteger(
          context: context, lineNumber: lineNumber, reason: "expected digit after base prefix"))
    }

    while index < text.upperBound {
      try budget.step()
      let ch = bytes[index]
      index += 1

      if ch == CodeUnits.underscore {
        guard
          let last = resultCodeUnits.last,
          isValidDigit(last, base: base)
        else {
          throw TOMLError(
            .invalidInteger(
              context: context, lineNumber: lineNumber,
              reason: "cannot use '_' adjacent to a non-digit"))
        }

        if index >= text.endIndex {
          throw TOMLError(
            .invalidInteger(
              context: context, lineNumber: lineNumber, reason: "cannot end with a '_'"))
        }

        let next = bytes[index]
        if next == CodeUnits.underscore {
          throw TOMLError(
            .invalidInteger(
              context: context, lineNumber: lineNumber, reason: "cannot contain consecutive '_'"))
        }
        guard isValidDigit(next, base: base) else {
          throw TOMLError(
            .invalidInteger(
              context: context, lineNumber: lineNumber,
              reason: "cannot use '_' adjacent to a non-digit"))
        }
        continue
      }

      guard isValidDigit(ch, base: base) else {
        throw TOMLError(
          .invalidInteger(
            context: context, lineNumber: lineNumber, reason: "invalid digit for base \(base)"))
      }

      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(ch)
    }

    let s = String(decoding: resultCodeUnits, as: UTF8.self)
    guard let i = Int64(s, radix: base) else {
      throw TOMLError(
        .invalidInteger(
          context: context, lineNumber: lineNumber,
          reason: "\(s) is a invalid integer of base \(base)"))
    }
    return i
  }

  func unpackDateTime(bytes: UnsafeBufferPointer<UInt8>, context: TOMLKey) throws
    -> DateTimeComponents
  {
    try budget.allocate(text.count, stage: "scalar decode")
    try budget.step(text.count)
    var mustParseTime = false
    var date: (year: Int, month: Int, day: Int)?
    var time: (hour: Int, minute: Int, second: Int)?

    var index = text.lowerBound
    if let (year, month, day, _) = scanDate(bytes: bytes, range: text) {
      // Validate date components
      if month < 1 || month > 12 {
        throw TOMLError(
          .invalidDateTime3(
            context: context, lineNumber: lineNumber, reason: "month must be between 01 and 12"))
      }
      if day < 1 {
        throw TOMLError(
          .invalidDateTime3(
            context: context, lineNumber: lineNumber, reason: "day must be between 01 and 31"))
      }

      // Validate days per month and leap years
      let isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
      let maxDaysInMonth: Int =
        switch month {
        case 2:
          isLeapYear ? 29 : 28
        case 4, 6, 9, 11:
          30
        default:
          31
        }

      if day > maxDaysInMonth {
        if month == 2, !isLeapYear {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber,
              reason: "February only has 28 days in non-leap years"))
        } else if month == 2, isLeapYear {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber,
              reason: "February only has 29 days in leap years"))
        } else {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber,
              reason: "day \(day) is invalid for month \(month)"))
        }
      }

      date = (year, month, day)
      index += 10
    }

    var features: OffsetDateTime.Features = []
    var nanoseconds: UInt32?
    if index < text.upperBound {
      if date != nil {
        let isSeparatorLowerT = bytes[index] == CodeUnits.lowerT
        let isSeparatorUpperT = bytes[index] == CodeUnits.upperT
        guard isSeparatorLowerT || isSeparatorUpperT || bytes[index] == CodeUnits.space else {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber,
              reason: "expected 'T' or 't' or space to separate date and time"))
        }
        if isSeparatorLowerT {
          features.insert(.lowercaseT)
        } else if isSeparatorUpperT {
          features.insert(.uppercaseT)
        }
        mustParseTime = true
        index += 1
      } else {
        // For standalone time values, don't advance index
        mustParseTime = true
      }
      if let (hour, minute, second, newIndex) = scanTime(
        bytes: bytes, range: index..<text.upperBound)
      {
        // Validate time components
        if hour > 23 {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber, reason: "hour must be between 00 and 23"))
        }
        if minute > 59 {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber, reason: "minute must be between 00 and 59"))
        }
        if second > 59 {
          throw TOMLError(
            .invalidDateTime3(
              context: context, lineNumber: lineNumber, reason: "second must be between 00 and 59"))
        }

        time = (hour, minute, second)

        index = newIndex
        if index < text.upperBound, bytes[index] == CodeUnits.dot {
          index += 1
          let beforeNanoIndex = index
          nanoseconds = try parseNanoSeconds(
            budget: budget, bytes: bytes, range: index..<text.upperBound, updatedIndex: &index)
          // Must have at least one digit after decimal point
          if index == beforeNanoIndex {
            throw TOMLError(
              .invalidDateTime3(
                context: context, lineNumber: lineNumber,
                reason: "decimal point must be followed by digits"))
          }
        }
      }
    }

    if mustParseTime, time == nil {
      throw TOMLError(
        .invalidDateTime3(context: context, lineNumber: lineNumber, reason: "expected valid time"))
    }

    var timeOffset: Int16?
    if index < text.upperBound {
      if bytes[index] == CodeUnits.lowerZ {
        features.insert(.lowercaseZ)
        index += 1
        timeOffset = 0
      } else if bytes[index] == CodeUnits.upperZ {
        features.insert(.uppercaseZ)
        index += 1
        timeOffset = 0
      } else if bytes[index] == CodeUnits.plus || bytes[index] == CodeUnits.minus {
        let offsetIsNegative = bytes[index] == CodeUnits.minus
        index += 1

        // Scan ahead to find the end of the timezone offset
        var endIndex = index
        while endIndex < text.upperBound {
          try budget.step()
          let ch = bytes[endIndex]
          if ch.isDecimalDigit || ch == CodeUnits.colon {
            endIndex += 1
          } else {
            break
          }
        }

        do {
          let (offsetHour, offsetMinute, consumedLength) = try parseTimezoneOffset(
            bytes: bytes, range: index..<endIndex, lineNumber: lineNumber)

          // Validate timezone offset ranges
          if offsetHour > 24 {
            throw TOMLError(
              .invalidDateTime3(
                context: context, lineNumber: lineNumber,
                reason: "timezone offset hour must be between 00 and 24"))
          }
          if offsetMinute > 59 {
            throw TOMLError(
              .invalidDateTime3(
                context: context, lineNumber: lineNumber,
                reason: "timezone offset minute must be between 00 and 59"))
          }

          let offsetInMinutes = offsetHour * 60 + offsetMinute
          timeOffset = Int16(offsetIsNegative ? -offsetInMinutes : offsetInMinutes)
          index += consumedLength
        } catch let parseError {
          if let tomlError = parseError as? TOMLError {
            switch tomlError.reason {
            case .invalidDateTime(_, let reason):
              throw TOMLError(
                .invalidDateTime3(context: context, lineNumber: lineNumber, reason: reason))
            default:
              throw tomlError
            }
          } else {
            throw TOMLError(
              .invalidDateTime3(
                context: context, lineNumber: lineNumber, reason: "timezone parsing error"))
          }
        }
      }
    }

    if index < text.upperBound {
      throw TOMLError(
        .invalidDateTime3(
          context: context, lineNumber: lineNumber, reason: "extra character after date time"))
    }

    return DateTimeComponents(
      date: date.map {
        LocalDate(year: .init($0.year), month: .init($0.month), day: .init($0.day))
      },
      time: time.map {
        LocalTime(
          hour: .init($0.hour), minute: .init($0.minute), second: .init($0.second),
          nanosecond: nanoseconds ?? 0)
      },
      offset: timeOffset,
      features: features
    )
  }

}

func parseTimezoneOffset(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, lineNumber: Int)
  throws -> (hour: Int, minute: Int, consumedLength: Int)
{
  guard range.count >= 2 else {
    throw TOMLError(
      .invalidDateTime(
        lineNumber: lineNumber, reason: "timezone offset must have at least 2 digits for hour"))
  }

  var index = range.lowerBound

  // Parse hour digits (exactly 2 required)
  guard
    index < range.upperBound,
    bytes[index].isDecimalDigit,
    case let firstHourDigit = bytes[index],
    case let nextIndex = index + 1,
    nextIndex < range.upperBound,
    bytes[nextIndex].isDecimalDigit,
    case let secondHourDigit = bytes[nextIndex]
  else {
    throw TOMLError(
      .invalidDateTime(
        lineNumber: lineNumber, reason: "timezone offset hour must be exactly 2 digits"))
  }

  let offsetHour =
    Int(firstHourDigit - CodeUnits.number0) * 10 + Int(secondHourDigit - CodeUnits.number0)
  index += 2
  var consumedLength = 2

  // Parse required minute digits (timezone offset must include minutes)
  guard index < range.upperBound, bytes[index] == CodeUnits.colon else {
    throw TOMLError(
      .invalidDateTime(
        lineNumber: lineNumber, reason: "timezone offset must include minutes (format: ±HH:MM)"))
  }

  index += 1
  consumedLength += 1

  guard
    index < range.upperBound,
    bytes[index].isDecimalDigit,
    case let firstMinuteDigit = bytes[index],
    case let nextMinuteIndex = index + 1,
    nextMinuteIndex < range.upperBound,
    bytes[nextMinuteIndex].isDecimalDigit,
    case let secondMinuteDigit = bytes[nextMinuteIndex]
  else {
    throw TOMLError(
      .invalidDateTime(
        lineNumber: lineNumber, reason: "timezone offset minute must be exactly 2 digits"))
  }

  let offsetMinute =
    Int(firstMinuteDigit - CodeUnits.number0) * 10 + Int(secondMinuteDigit - CodeUnits.number0)
  consumedLength += 2

  return (offsetHour, offsetMinute, consumedLength)
}

func literalString(
  budget: SemanticBudget, bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, multiline: Bool
) throws -> String {
  var resultCodeUnits: [UTF8.CodeUnit] = []
  var consecutiveQuotes = 0

  for index in range {
    try budget.step()
    let codeUnit = bytes[index]
    if codeUnit >= CodeUnits.null && codeUnit <= CodeUnits.backspace
      || codeUnit >= CodeUnits.lf && codeUnit <= CodeUnits.unitSeparator
      || codeUnit == CodeUnits.delete
    {
      if multiline, codeUnit == CodeUnits.lf {
        // Allow LF in multiline literal strings
      } else if multiline, codeUnit == CodeUnits.cr {
        // Only allow CR if followed by LF (CRLF sequence)
        let nextIndex = index + 1
        if nextIndex < range.upperBound, bytes[nextIndex] == CodeUnits.lf {
          // Allow CRLF sequence - will be processed as separate characters
        } else {
          throw TOMLError(.invalidCharacter(codeUnit))
        }
      } else {
        throw TOMLError(.invalidCharacter(codeUnit))
      }
    }

    if multiline, codeUnit == CodeUnits.singleQuote {
      consecutiveQuotes += 1
      if consecutiveQuotes > 2 {
        throw TOMLError(
          .syntax(
            lineNumber: 0,
            message:
              "literal multiline strings cannot contain more than 2 consecutive single quotes"))
      }
    } else {
      consecutiveQuotes = 0
    }

    try budget.allocate(1, stage: "decoded scalar storage")
    resultCodeUnits.append(codeUnit)
  }
  return String(decoding: resultCodeUnits, as: UTF8.self)
}

func basicString(
  budget: SemanticBudget, bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, multiline: Bool
) throws -> String {
  let startIndex = range.lowerBound
  let endIndex = range.upperBound
  var resultCodeUnits: [UTF8.CodeUnit] = []
  try budget.allocate(range.count, stage: "decoded string capacity")
  resultCodeUnits.reserveCapacity(range.count)
  var consecutiveQuotes = 0
  var index = startIndex
  while true {
    try budget.step()
    if index >= endIndex {
      break
    }

    var ch = bytes[index]
    index += 1
    if ch != CodeUnits.backslash {
      if ch >= CodeUnits.null && ch <= CodeUnits.backspace
        || ch >= CodeUnits.lf && ch <= CodeUnits.unitSeparator || ch == CodeUnits.delete
      {
        if multiline, ch == CodeUnits.lf {
          // Allow LF in multiline basic strings
        } else if multiline, ch == CodeUnits.cr {
          // Only allow CR if followed by LF (CRLF sequence)
          if index < endIndex, bytes[index] == CodeUnits.lf {
            // Allow CRLF sequence - will be processed as separate characters
          } else {
            throw TOMLError(.invalidCharacter(ch))
          }
        } else {
          throw TOMLError(.invalidCharacter(ch))
        }
      }

      if multiline, ch == CodeUnits.doubleQuote {
        consecutiveQuotes += 1
        if consecutiveQuotes > 2 {
          throw TOMLError(
            .syntax(
              lineNumber: 0,
              message:
                "basic multiline strings cannot contain more than 2 consecutive double quotes"
            )
          )
        }
      } else {
        consecutiveQuotes = 0
      }

      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(ch)
      continue
    }

    if index >= endIndex {
      throw TOMLError(.invalidCharacter(CodeUnits.backslash))
    }

    func indexAfterSkippingCharacters(start: Int, endIndex: Int, characters: [UTF8.CodeUnit])
      throws -> Int
    {
      var index = start
      while index < endIndex {
        try budget.step()
        if characters.contains(bytes[index]) {
          index += 1
        } else {
          break
        }
      }
      return index
    }

    if multiline {
      let afterWhitespace = try indexAfterSkippingCharacters(
        start: index, endIndex: endIndex,
        characters: [CodeUnits.space, CodeUnits.tab, CodeUnits.cr]
      )
      if afterWhitespace < endIndex, bytes[afterWhitespace] == CodeUnits.lf {
        index = try indexAfterSkippingCharacters(
          start: index, endIndex: endIndex,
          characters: [CodeUnits.space, CodeUnits.tab, CodeUnits.cr, CodeUnits.lf]
        )
        continue
      }
    }

    ch = bytes[index]
    index += 1

    if ch == CodeUnits.lowerU || ch == CodeUnits.upperU || ch == CodeUnits.lowerX {
      let hexCount =
        switch ch {
        case CodeUnits.lowerU: 4
        case CodeUnits.upperU: 8
        case CodeUnits.lowerX: 2
        default: fatalError("Unsupported CodeUnit: \(ch)")
        }
      var ucs: UInt32 = 0
      for _ in 0..<hexCount {
        try budget.step()
        if index >= endIndex {
          throw TOMLError(.expectedHexCharacters(ch, hexCount))
        }
        ch = bytes[index]
        index += 1
        let v: Int32 =
          ch.isDecimalDigit
          ? Int32(ch - CodeUnits.number0)
          : (ch >= CodeUnits.upperA && ch <= CodeUnits.upperF)
            ? Int32(ch - CodeUnits.upperA + 10)
            : (ch >= CodeUnits.lowerA && ch <= CodeUnits.lowerF)
              ? Int32(ch - CodeUnits.lowerA + 10)
              : -1
        if v == -1 {
          throw TOMLError(.invalidHexCharacters(ch))
        }
        ucs = ucs * 16 + UInt32(v)
      }
      guard let scalar = Unicode.Scalar(ucs) else {
        throw TOMLError(.illegalUCSCode(ucs))
      }
      try budget.allocate(1, stage: "decoded scalar storage")
      resultCodeUnits.append(contentsOf: scalar.utf8)
      continue
    } else if ch == CodeUnits.lowerB {
      ch = CodeUnits.backspace
    } else if ch == CodeUnits.lowerT {
      ch = CodeUnits.tab
    } else if ch == CodeUnits.lowerF {
      ch = CodeUnits.formfeed
    } else if ch == CodeUnits.lowerR {
      ch = CodeUnits.cr
    } else if ch == CodeUnits.lowerN {
      ch = CodeUnits.lf
    } else if ch == CodeUnits.lowerE {
      ch = CodeUnits.escape
    } else if ch != CodeUnits.doubleQuote, ch != CodeUnits.backslash {
      throw TOMLError(.illegalEscapeCharacter(ch))
    }

    consecutiveQuotes = 0  // Reset count after escape sequence
    try budget.allocate(1, stage: "decoded scalar storage")
    resultCodeUnits.append(ch)
  }
  return String(decoding: resultCodeUnits, as: UTF8.self)
}

func scanDate(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> (Int, Int, Int, Int)? {
  guard let year = scanDigits(bytes: bytes, range: range, n: 4) else {
    return nil
  }

  var index = range.lowerBound
  index += 4

  guard index < range.upperBound, bytes[index] == CodeUnits.minus else {
    return nil
  }

  index += 1
  guard let month = scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) else {
    return nil
  }

  index += 2
  guard index < range.upperBound, bytes[index] == CodeUnits.minus else {
    return nil
  }

  index += 1
  guard let day = scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) else {
    return nil
  }

  index += 2
  return (year, month, day, index)
}

func scanDigits(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, n: Int) -> Int? {
  var result = 0
  var n = n
  var index = range.lowerBound
  while n > 0, index < range.upperBound, bytes[index].isDecimalDigit {
    result = 10 * result + Int(bytes[index]) - Int(CodeUnits.number0)
    index += 1
    n -= 1
  }
  return n != 0 ? nil : result
}

func scanTime(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> (Int, Int, Int, Int)? {
  guard let hour = scanDigits(bytes: bytes, range: range, n: 2) else {
    return nil
  }

  var index = range.lowerBound

  index += 2
  guard index < range.upperBound, bytes[index] == CodeUnits.colon else {
    return nil
  }

  index += 1
  guard let minute = scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) else {
    return nil
  }

  index += 2
  guard index < range.upperBound, bytes[index] == CodeUnits.colon else {
    // TOML 1.1 permits omitted seconds, interpreted as :00.
    return (hour, minute, 0, index)
  }

  index += 1
  guard let second = scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) else {
    return nil
  }

  index += 2
  return (hour, minute, second, index)
}

func parseNanoSeconds(
  budget: SemanticBudget, bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>,
  updatedIndex: inout Int
) throws -> UInt32 {
  var unit: Double = 100_000_000
  var result: Double = 0
  var index = range.lowerBound
  while index < range.upperBound, bytes[index].isDecimalDigit {
    try budget.step()
    result += Double(bytes[index] - CodeUnits.number0) * unit
    index += 1
    unit /= 10
  }
  updatedIndex = index
  return UInt32(result)
}

func scanTimezoneOffset(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> Int? {
  var index = range.lowerBound
  guard index < range.upperBound, bytes[index] == CodeUnits.plus || bytes[index] == CodeUnits.minus
  else {
    return nil
  }

  index += 1
  guard scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) != nil else {
    return nil
  }

  index += 2
  guard index < range.upperBound, bytes[index] == CodeUnits.colon else {
    return nil
  }

  index += 1
  guard scanDigits(bytes: bytes, range: index..<range.upperBound, n: 2) != nil else {
    return nil
  }
  index += 2
  return index
}

@inline(__always)
private func chunkContainsDoubleQuotedStopByte(_ chunk: UInt64) -> Bool {
  let ones: UInt64 = 0x0101_0101_0101_0101
  let highBits: UInt64 = 0x8080_8080_8080_8080

  @inline(__always)
  func hasByte(_ bytePattern: UInt64) -> Bool {
    let xor = chunk ^ bytePattern
    return ((xor &- ones) & ~xor & highBits) != 0
  }

  return hasByte(0x2222_2222_2222_2222)
    || hasByte(0x5C5C_5C5C_5C5C_5C5C)
    || hasByte(0x0A0A_0A0A_0A0A_0A0A)
}

func normalizeKeyAndHash(bytes: UnsafeBufferPointer<UInt8>, token: Token) throws -> (
  key: String, keyHash: Int
) {
  let budget = token.budget!
  try budget.allocate(token.text.count, stage: "decoded key")
  var start = token.text.lowerBound
  var end = token.text.upperBound
  if token.kind == .bareKey {
    let str = try makeString(budget: budget, bytes: bytes, range: start..<end)
    return (str, fastKeyHash(bytes: bytes, range: start..<end))
  }

  let ch = bytes[start]
  var result = ""
  if ch == CodeUnits.doubleQuote || ch == CodeUnits.singleQuote {
    if start + 2 < end, bytes[start + 1] == ch, bytes[start + 2] == ch {
      // Keys cannot be multiline
      throw TOMLError(.badKey(lineNumber: token.lineNumber))
    } else {
      start = start + 1
      end = end - 1
    }

    if ch == CodeUnits.singleQuote {
      result = try literalString(budget: budget, bytes: bytes, range: start..<end, multiline: false)
      return (result, fastKeyHash(bytes: bytes, range: start..<end))
    } else {
      result = try basicString(budget: budget, bytes: bytes, range: start..<end, multiline: false)
      return (result, fastKeyHash(result))
    }
  }

  for i in start..<end {
    try budget.step()
    let byte = bytes[i]
    if byte >= CodeUnits.number0 && byte <= CodeUnits.number9  // 0-9
      || byte >= CodeUnits.upperA && byte <= CodeUnits.upperZ  // A-Z
      || byte >= CodeUnits.lowerA && byte <= CodeUnits.lowerZ  // a-z
      || byte == CodeUnits.underscore  // _
      || byte == CodeUnits.minus  // -
    {
      continue
    }
    throw TOMLError(.badKey(lineNumber: token.lineNumber))
  }

  let key = try makeString(budget: budget, bytes: bytes, range: start..<end)
  return (key, fastKeyHash(bytes: bytes, range: start..<end))
}

@inline(__always)
func fastKeyHash(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> Int {
  let count = range.upperBound - range.lowerBound
  if count == 0 {
    return 0
  }
  let start = bytes.baseAddress!.advanced(by: range.lowerBound)
  if count <= 8 {
    return Int(truncatingIfNeeded: packedKeyHash(UnsafeBufferPointer(start: start, count: count)))
  }
  return Int(truncatingIfNeeded: sampledKeyHash(start: start, count: count))
}

@inline(__always)
func fastKeyHash(_ key: String) -> Int {
  if let hash = key.utf8.withContiguousStorageIfAvailable({ buffer -> UInt64 in
    if buffer.count <= 8 {
      return packedKeyHash(buffer)
    }
    if let start = buffer.baseAddress {
      return sampledKeyHash(start: start, count: buffer.count)
    }
    return 0
  }) {
    return Int(truncatingIfNeeded: hash)
  }

  let offsetBasis: UInt64 = 14_695_981_039_346_656_037
  let prime: UInt64 = 1_099_511_628_211
  var hash = offsetBasis
  var packed: UInt64 = 0
  var count = 0
  for byte in key.utf8 {
    if count < 8 {
      packed |= UInt64(byte) << (UInt64(count) * 8)
    }
    hash ^= UInt64(byte)
    hash &*= prime
    count += 1
  }
  return Int(truncatingIfNeeded: count <= 8 ? packed : hash)
}

@inline(__always)
private func sampledKeyHash(start: UnsafePointer<UInt8>, count: Int) -> UInt64 {
  let prefix = packedKeyHash(UnsafeBufferPointer(start: start, count: 8))
  let suffix = packedKeyHash(UnsafeBufferPointer(start: start.advanced(by: count - 8), count: 8))
  let rotatedSuffix = (suffix << 1) | (suffix >> 63)
  return prefix ^ rotatedSuffix ^ (UInt64(truncatingIfNeeded: count) &* 0x9E37_79B1_85EB_CA87)
}

@inline(__always)
private func packedKeyHash(_ buffer: UnsafeBufferPointer<UInt8>) -> UInt64 {
  var packed: UInt64 = 0
  switch buffer.count {
  case 8:
    packed |= UInt64(buffer[7]) << 56
    fallthrough
  case 7:
    packed |= UInt64(buffer[6]) << 48
    fallthrough
  case 6:
    packed |= UInt64(buffer[5]) << 40
    fallthrough
  case 5:
    packed |= UInt64(buffer[4]) << 32
    fallthrough
  case 4:
    packed |= UInt64(buffer[3]) << 24
    fallthrough
  case 3:
    packed |= UInt64(buffer[2]) << 16
    fallthrough
  case 2:
    packed |= UInt64(buffer[1]) << 8
    fallthrough
  case 1:
    packed |= UInt64(buffer[0])
  default:
    break
  }
  return packed
}

@inline(__always)
private func makeString(
  budget: SemanticBudget, bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>
) throws -> String {
  try budget.allocate(range.count, stage: "decoded key copy")
  try budget.step(range.count)
  let count = range.upperBound - range.lowerBound
  if count == 0 {
    return ""
  }
  let start = bytes.baseAddress!.advanced(by: range.lowerBound)
  return String(decoding: UnsafeBufferPointer(start: start, count: count), as: UTF8.self)
}

extension Parser {
  @inline(__always)
  func matchKeyValue(in indices: borrowing [Int], key: borrowing String, keyHash: Int) throws
    -> Int?
  {
    if indices.isEmpty {
      return nil
    }
    return try keyValues.withUnsafeBufferPointer { keyValueBuffer -> Int? in
      guard let keyValueBase = keyValueBuffer.baseAddress else {
        return nil
      }
      let indexCount = indices.count
      var i = 0
      while i < indexCount {
        try budget.step()
        let keyValueIndex = indices[i]
        let keyValuePair = keyValueBase.advanced(by: keyValueIndex).pointee
        if keyValuePair.keyHash == keyHash, try budget.equal(keyValuePair.key, key) {
          return keyValueIndex
        }
        i += 1
      }
      return nil
    }
  }

  @inline(__always)
  func matchKeyArray(in indices: borrowing [Int], key: borrowing String, keyHash: Int) throws
    -> Int?
  {
    if indices.isEmpty {
      return nil
    }
    return try keyArrays.withUnsafeBufferPointer { keyArrayBuffer -> Int? in
      guard let keyArrayBase = keyArrayBuffer.baseAddress else {
        return nil
      }
      let indexCount = indices.count
      var i = 0
      while i < indexCount {
        try budget.step()
        let keyArrayIndex = indices[i]
        let keyArrayPair = keyArrayBase.advanced(by: keyArrayIndex).pointee
        if keyArrayPair.keyHash == keyHash, try budget.equal(keyArrayPair.key, key) {
          return keyArrayIndex
        }
        i += 1
      }
      return nil
    }
  }

  @inline(__always)
  func keyMatchesToken(bytes: UnsafeBufferPointer<UInt8>, token: Token, key: borrowing String)
    throws -> Bool
  {
    let range = token.text
    let count = range.upperBound - range.lowerBound

    if let matches = try key.utf8.withContiguousStorageIfAvailable({ keyBuffer -> Bool in
      if keyBuffer.count != count {
        return false
      }

      var keyIndex = 0
      var byteIndex = range.lowerBound
      while keyIndex < count {
        try budget.step()
        if keyBuffer[keyIndex] != bytes[byteIndex] {
          return false
        }
        keyIndex += 1
        byteIndex += 1
      }
      return true
    }) {
      return matches
    }

    var index = range.lowerBound
    for byte in key.utf8 {
      try budget.step()
      if index >= range.upperBound || bytes[index] != byte {
        return false
      }
      index += 1
    }
    return index == range.upperBound
  }

  @inline(__always)
  func matchKeyArray(
    in indices: borrowing [Int],
    bytes: UnsafeBufferPointer<UInt8>,
    token: Token,
    keyHash: Int
  ) throws -> Int? {
    if indices.isEmpty {
      return nil
    }
    return try keyArrays.withUnsafeBufferPointer { keyArrayBuffer -> Int? in
      guard let keyArrayBase = keyArrayBuffer.baseAddress else {
        return nil
      }
      let indexCount = indices.count
      var i = 0
      while i < indexCount {
        try budget.step()
        let keyArrayIndex = indices[i]
        let keyArrayPair = keyArrayBase.advanced(by: keyArrayIndex).pointee
        if keyArrayPair.keyHash == keyHash,
          try keyMatchesToken(bytes: bytes, token: token, key: keyArrayPair.key)
        {
          return keyArrayIndex
        }
        i += 1
      }
      return nil
    }
  }

  @inline(__always)
  func matchKeyTable(in indices: borrowing [Int], key: borrowing String, keyHash: Int) throws
    -> Int?
  {
    if indices.isEmpty {
      return nil
    }
    return try keyTables.withUnsafeBufferPointer { keyTableBuffer -> Int? in
      guard let keyTableBase = keyTableBuffer.baseAddress else {
        return nil
      }
      let indexCount = indices.count
      var i = 0
      while i < indexCount {
        try budget.step()
        let keyTableIndex = indices[i]
        let keyTablePair = keyTableBase.advanced(by: keyTableIndex).pointee
        if keyTablePair.keyHash == keyHash, try budget.equal(keyTablePair.key, key) {
          return keyTableIndex
        }
        i += 1
      }
      return nil
    }
  }

  @inline(__always)
  func tableValue(
    tableIndex: Int,
    keyed: Bool,
    key: borrowing String,
    keyHash: Int
  ) throws -> InternalTOMLTable.Value? {
    if keyed {
      if !keyTables[tableIndex].table.mightContainKeyHash(keyHash) {
        return nil
      }
    } else if !tables[tableIndex].mightContainKeyHash(keyHash) {
      return nil
    }

    if keyed {
      if let keyValueIndex = try matchKeyValue(
        in: keyTables[tableIndex].table.keyValues, key: key, keyHash: keyHash)
      {
        return .keyValue(keyValueIndex)
      }

      if let keyArrayIndex = try matchKeyArray(
        in: keyTables[tableIndex].table.arrays, key: key, keyHash: keyHash)
      {
        return .array(keyArrayIndex)
      }

      if let keyTableIndex = try matchKeyTable(
        in: keyTables[tableIndex].table.tables, key: key, keyHash: keyHash)
      {
        return .table(keyTableIndex)
      }
      return nil
    }

    if let keyValueIndex = try matchKeyValue(
      in: tables[tableIndex].keyValues, key: key, keyHash: keyHash)
    {
      return .keyValue(keyValueIndex)
    }

    if let keyArrayIndex = try matchKeyArray(
      in: tables[tableIndex].arrays, key: key, keyHash: keyHash)
    {
      return .array(keyArrayIndex)
    }

    if let keyTableIndex = try matchKeyTable(
      in: tables[tableIndex].tables, key: key, keyHash: keyHash)
    {
      return .table(keyTableIndex)
    }

    return nil
  }

  @inline(__always)
  func lookupTable(in tableIndex: Int, keyed: Bool, key: borrowing String, keyHash: Int) throws
    -> Int?
  {
    if keyed {
      if !keyTables[tableIndex].table.mightContainKeyHash(keyHash) {
        return nil
      }
      return try matchKeyTable(in: keyTables[tableIndex].table.tables, key: key, keyHash: keyHash)
    }
    if !tables[tableIndex].mightContainKeyHash(keyHash) {
      return nil
    }
    return try matchKeyTable(in: tables[tableIndex].tables, key: key, keyHash: keyHash)
  }

  @inline(__always)
  func lookupArray(in tableIndex: Int, keyed: Bool, key: borrowing String, keyHash: Int) throws
    -> Int?
  {
    if keyed {
      if !keyTables[tableIndex].table.mightContainKeyHash(keyHash) {
        return nil
      }
      return try matchKeyArray(in: keyTables[tableIndex].table.arrays, key: key, keyHash: keyHash)
    }
    if !tables[tableIndex].mightContainKeyHash(keyHash) {
      return nil
    }
    return try matchKeyArray(in: tables[tableIndex].arrays, key: key, keyHash: keyHash)
  }

  @inline(__always)
  func lookupArray(
    in tableIndex: Int,
    keyed: Bool,
    bytes: UnsafeBufferPointer<UInt8>,
    token: Token,
    keyHash: Int
  ) throws -> Int? {
    if keyed {
      if !keyTables[tableIndex].table.mightContainKeyHash(keyHash) {
        return nil
      }
      return try matchKeyArray(
        in: keyTables[tableIndex].table.arrays,
        bytes: bytes,
        token: token,
        keyHash: keyHash
      )
    }
    if !tables[tableIndex].mightContainKeyHash(keyHash) {
      return nil
    }
    return try matchKeyArray(
      in: tables[tableIndex].arrays,
      bytes: bytes,
      token: token,
      keyHash: keyHash
    )
  }

  mutating func advanceTablePathSegment(
    tableIndex: inout Int,
    isKeyed: inout Bool,
    key: String,
    keyHash: Int
  ) throws {
    switch try tableValue(tableIndex: tableIndex, keyed: isKeyed, key: key, keyHash: keyHash) {
    case .table(let index):
      tableIndex = index
      isKeyed = true
    case .array(let arrayIndex):
      let array = keyArrays[arrayIndex].array
      guard case .table = array.kind else {
        throw TOMLError(
          .syntax(lineNumber: token.lineNumber, message: "array element is not a table"))
      }

      if array.elements.isEmpty {
        throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "empty array"))
      }

      guard case .table(_, let index) = array.elements.last else {
        throw TOMLError(
          .syntax(lineNumber: token.lineNumber, message: "array element is not a table"))
      }

      tableIndex = index
      isKeyed = false
    case .keyValue:
      throw TOMLError(.syntax(lineNumber: token.lineNumber, message: "key-value already exists"))
    default:
      let newTableAddress = keyTables.count
      var newTable = InternalTOMLTable()
      newTable.implicit = true
      newTable.definedByDottedKey = false
      try budget.node(depth: depth)
      keyTables.append(
        KeyTablePair(
          key: key, keyHash: keyHash, sourcePosition: token.text.lowerBound, table: newTable))

      if isKeyed {
        if keyTables[tableIndex].table.tables.isEmpty {
          try budget.allocate(8, stage: "semantic storage")
          keyTables[tableIndex].table.tables.reserveCapacity(8)
        }
        try budget.node(depth: depth)
        keyTables[tableIndex].table.tables.append(newTableAddress)
        keyTables[tableIndex].table.recordKeyHash(keyHash)
      } else {
        if tables[tableIndex].tables.isEmpty {
          try budget.allocate(8, stage: "semantic storage")
          tables[tableIndex].tables.reserveCapacity(8)
        }
        try budget.node(depth: depth)
        tables[tableIndex].tables.append(newTableAddress)
        tables[tableIndex].recordKeyHash(keyHash)
      }
      tableIndex = newTableAddress
      isKeyed = true
    }
  }

  mutating func walkTablePath(startTable: Int = 0, startKeyed: Bool = false) throws {
    var tableIndex = startTable
    var isKeyed = startKeyed
    for (key, keyHash) in tablePath {
      try budget.step()
      try advanceTablePathSegment(
        tableIndex: &tableIndex,
        isKeyed: &isKeyed,
        key: key,
        keyHash: keyHash
      )
    }
    currentTable = tableIndex
    currentTableIsKeyed = isKeyed
  }
}
