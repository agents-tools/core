enum TOMLKey: CodingKey {
  case string(String)
  case int(Int)
  case `super`

  init(stringValue: String) {
    self = .string(stringValue)
  }

  init(intValue: Int) {
    self = .int(intValue)
  }

  var stringValue: String {
    switch self {
    case .string(let string):
      string
    case .int(let int):
      "Index \(int)"
    case .super:
      "super"
    }
  }

  var intValue: Int? {
    switch self {
    case .int(let int):
      int
    default:
      nil
    }
  }
}
