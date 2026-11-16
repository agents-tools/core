/// An error originated from parsing the TOML document.
///
/// This error provides details for invalid values,
/// or formatting issues in the TOML document.
/// It comes from the parsing phase.
/// Read <doc:DeserializingTOML#The-Deserialization-Process> to learn more.
public struct TOMLError: Error {
  let reason: Reason

  init(_ reason: Reason) {
    self.reason = reason
  }

  enum Reason {
    case arrayOutOfBound(index: Int, bound: Int)
    case badKey(lineNumber: Int)
    case expectedHexCharacters(UTF8.CodeUnit, Int)
    case illegalEscapeCharacter(UTF8.CodeUnit)
    case illegalUCSCode(UInt32)
    case internalError(lineNumber: Int)
    case invalidBool(context: TOMLKey, lineNumber: Int)
    case invalidCharacter(UTF8.CodeUnit)
    case invalidDateTime(lineNumber: Int?, reason: String)
    case invalidDateTime3(context: TOMLKey, lineNumber: Int, reason: String)
    case invalidDateTimeComponents(String)
    case invalidFloat(context: TOMLKey, lineNumber: Int, reason: String)
    case invalidHexCharacters(UTF8.CodeUnit)
    case invalidInteger(context: TOMLKey, lineNumber: Int, reason: String)
    case invalidNumber(reason: String)
    case invalidString(context: TOMLKey, lineNumber: Int, reason: String)
    case invalidUTF8
    case invalidValueInTable(context: TOMLKey, lineNumber: Int)
    case keyExists(lineNumber: Int)
    case keyNotFoundInTable(key: String, expected: String)
    case notReallyCodable
    case syntax(lineNumber: Int, message: String)
    case typeMismatch(context: TOMLKey, lineNumber: Int, expected: String)
    case typeMismatchInArray(lineNumber: Int, index: Int, expected: String)
    case typeMismatchInTable(key: String, expected: String)
  }
}

extension TOMLError: CustomStringConvertible {
  public var description: String {
    switch reason {
    case .arrayOutOfBound(let index, let bound):
      "Array index \(index) is out of bounds (0..<\(bound))."
    case .badKey(let lineNumber):
      "(Line \(lineNumber)) Ill-formed key."
    case .expectedHexCharacters(let codeUnit, let hexCount):
      "Expected \(hexCount) hexadecimal characters after '\(String(UnicodeScalar(codeUnit))).'."
    case .illegalEscapeCharacter(let codeUnit):
      "Illegal escape character '\(String(UnicodeScalar(codeUnit)))'."
    case .illegalUCSCode(let ucs):
      "Illegal UCS code '\(ucs)'."
    case .internalError(let lineNumber):
      "(Line \(lineNumber)) Internal error."
    case .invalidBool(let context, let lineNumber):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid boolean value for key '\(key)'."
      case .int(let index):
        "(Line \(lineNumber)) Invalid boolean value for index \(index)."
      case .super:
        "(Line \(lineNumber)) Invalid boolean value for 'super'."
      }
    case .invalidCharacter(let codeUnit):
      "Invalid character '\(String(UnicodeScalar(codeUnit)))'."
    case .invalidDateTime(let lineNumber, let reason):
      "\(lineNumber.map { "(Line \($0)) " } ?? "")Invalid date-time: \(reason)."
    case .invalidDateTime3(let context, let lineNumber, let reason):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid date-time value for key '\(key)': \(reason)."
      case .int(let index):
        "(Line \(lineNumber)) Invalid date-time value for index \(index)': \(reason)."
      case .super:
        "(Line \(lineNumber)) Invalid date-time value for 'super': \(reason)."
      }
    case .invalidDateTimeComponents(let components):
      "Invalid date-time components: \(components)."
    case .invalidFloat(let context, let lineNumber, let reason):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid float value for key '\(key)': \(reason)."
      case .int(let index):
        "(Line \(lineNumber)) Invalid float value for index \(index)': \(reason)."
      case .super:
        "(Line \(lineNumber)) Invalid float value for 'super': \(reason)."
      }
    case .invalidHexCharacters(let codeUnit):
      "Invalid hexadecimal characters '\(String(UnicodeScalar(codeUnit)))'."
    case .invalidInteger(let context, let lineNumber, let reason):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid integer value for key '\(key)': \(reason)."
      case .int(let index):
        "(Line \(lineNumber)) Invalid integer value for index \(index)': \(reason)."
      case .super:
        "(Line \(lineNumber)) Invalid integer value for 'super': \(reason)."
      }
    case .invalidNumber(let reason):
      "Invalid number: \(reason)."
    case .invalidString(let context, let lineNumber, let reason):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid string value for key '\(key)': \(reason)."
      case .int(let index):
        "(Line \(lineNumber)) Invalid string value for index \(index)': \(reason)."
      case .super:
        "(Line \(lineNumber)) Invalid string value for 'super': \(reason)."
      }
    case .invalidUTF8:
      "The given data was not valid UTF8."
    case .invalidValueInTable(let context, let lineNumber):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Invalid value in table for key '\(key)'."
      case .int(let index):
        "(Line \(lineNumber)) Invalid value in table for index \(index)."
      case .super:
        "(Line \(lineNumber)) Invalid value in table for 'super'."
      }
    case .keyExists(let lineNumber):
      "(Line \(lineNumber)) Key already exists."
    case .keyNotFoundInTable(let key, let expected):
      "Key '\(key)' not found in table while looking for \(expected)."
    case .notReallyCodable:
      "This type is not generally codable. Use TOMLDecoder to decode it as part of a larger Codable."
    case .syntax(let lineNumber, let message):
      "(Line \(lineNumber)) Syntax error: \(message)."
    case .typeMismatch(let context, let lineNumber, let expected):
      switch context {
      case .string(let key):
        "(Line \(lineNumber)) Type mismatch at table key '\(key)': expected \(expected)."
      case .int(let index):
        "(Line \(lineNumber)) Type mismatch at array index \(index): expected \(expected)."
      case .super:
        "(Line \(lineNumber)) Type mismatch at 'super': expected \(expected)."
      }
    case .typeMismatchInArray(let lineNumber, let index, let expected):
      "(Line \(lineNumber)) Type mismatch at array index \(index): expected \(expected)."
    case .typeMismatchInTable(let key, let expected):
      "Type mismatch at table key '\(key)': expected \(expected)."
    }
  }
}
