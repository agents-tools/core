import Foundation

struct TOMLDocument {
  let tables: [InternalTOMLTable]
  let arrays: [InternalTOMLArray]
  let keyTables: [KeyTablePair]
  let keyArrays: [KeyArrayPair]
  let keyValues: [KeyValuePair]

  let source: String

  init(
    source: String,
    tables: [InternalTOMLTable],
    arrays: [InternalTOMLArray],
    keyTables: [KeyTablePair],
    keyArrays: [KeyArrayPair],
    keyValues: [KeyValuePair]
  ) {
    self.source = source
    self.tables = tables
    self.arrays = arrays
    self.keyTables = keyTables
    self.keyArrays = keyArrays
    self.keyValues = keyValues
  }

}

struct InternalTOMLArray: Equatable {
  var kind: Kind?
  var elements: [Element]

  init(kind: Kind? = nil, elements: [Element] = []) {
    self.kind = kind
    self.elements = elements
  }

  enum Element: Equatable {
    case leaf(Token)
    case array(lineNumber: Int, Int)
    case table(lineNumber: Int, Int)

    var lineNumber: Int {
      switch self {
      case .leaf(let token):
        token.lineNumber
      case .array(let lineNumber, _):
        lineNumber
      case .table(let lineNumber, _):
        lineNumber
      }
    }

    static func == (lhs: Element, rhs: Element) -> Bool {
      switch (lhs, rhs) {
      case (.leaf(let lhsToken), .leaf(let rhsToken)):
        lhsToken == rhsToken
      case (.array(let lhsLineNumber, let lhsIndex), .array(let rhsLineNumber, let rhsIndex)):
        lhsLineNumber == rhsLineNumber && lhsIndex == rhsIndex
      case (.table(let lhsLineNumber, let lhsIndex), .table(let rhsLineNumber, let rhsIndex)):
        lhsLineNumber == rhsLineNumber && lhsIndex == rhsIndex
      default:
        false
      }
    }
  }

  enum Kind: UInt8 {
    case value
    case array
    case table
    case mixed
  }
}

struct KeyTablePair {
  let key: String
  let keyHash: Int
  let sourcePosition: Int
  var table: InternalTOMLTable
}

struct KeyArrayPair {
  let key: String
  let keyHash: Int
  let sourcePosition: Int
  var array: InternalTOMLArray
}

struct KeyValuePair {
  let key: String
  let keyHash: Int
  let sourcePosition: Int
  var value: Token
}

struct InternalTOMLTable: Equatable {
  var implicit: Bool = false
  var readOnly: Bool = false
  var definedByDottedKey: Bool = false
  var keyHashBloom: UInt64 = 0
  var keyValues: [Int] = []
  var arrays: [Int] = []
  var tables: [Int] = []

  @inline(__always)
  mutating func recordKeyHash(_ keyHash: Int) {
    keyHashBloom |= keyHashBloomMask(keyHash)
  }

  @inline(__always)
  func mightContainKeyHash(_ keyHash: Int) -> Bool {
    let mask = keyHashBloomMask(keyHash)
    return (keyHashBloom & mask) == mask
  }

  enum Value {
    case keyValue(Int)
    case array(Int)
    case table(Int)
  }
}

@inline(__always)
private func keyHashBloomMask(_ keyHash: Int) -> UInt64 {
  let raw = UInt(bitPattern: keyHash)
  let bit0 = UInt64(1) << UInt64(raw & 63)
  let bit1 = UInt64(1) << UInt64((raw >> 6) & 63)
  return bit0 | bit1
}

struct DateTimeComponents: Equatable {
  let date: LocalDate?
  let time: LocalTime?
  let offset: Int16?
  let features: OffsetDateTime.Features

  @inline(__always)
  func localDate(exactMatch: Bool = true) -> LocalDate? {
    switch (date, time, offset) {
    case (.some(let date), .none, .none):
      date
    case (.some(let date), _, _) where !exactMatch:
      date
    default:
      nil
    }
  }

  @inline(__always)
  func localTime(exactMatch: Bool = true) -> LocalTime? {
    switch (date, time, offset) {
    case (.none, .some(let time), .none):
      time
    case (_, .some(let time), _) where !exactMatch:
      time
    default:
      nil
    }
  }

  @inline(__always)
  func localDateTime(exactMatch: Bool = true) -> LocalDateTime? {
    switch (date, time, offset) {
    case (.some(let date), .some(let time), .none):
      LocalDateTime(date: date, time: time)
    case (.some(let date), .some(let time), .some) where !exactMatch:
      LocalDateTime(date: date, time: time)
    default:
      nil
    }
  }
}

extension TOMLDocument {
  @inline(__always)
  func table(at index: Int, keyed: Bool) -> InternalTOMLTable {
    keyed ? keyTables[index].table : tables[index]
  }

  @inline(__always)
  func array(at index: Int, keyed: Bool) -> InternalTOMLArray {
    keyed ? keyArrays[index].array : arrays[index]
  }
}
