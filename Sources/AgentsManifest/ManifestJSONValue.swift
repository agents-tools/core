import AgentsCore
import Foundation

/// JSON data for the evaluated manifest schema. Decimal configuration payloads remain strings.
public indirect enum ManifestJSONValue: Sendable, Equatable {
  case string(String)
  case integer(Int)
  case boolean(Bool)
  case null
  case array([ManifestJSONValue])
  case object([String: ManifestJSONValue])

  static func json(_ input: Any) throws -> Self {
    switch input {
    case let string as String: return .string(string)
    case is NSNull: return .null
    case let array as [Any]: return .array(try array.map(json))
    case let fields as [String: Any]: return .object(try fields.mapValues(json))
    default: throw CoreError.invalidState("unexpected migration diagnostic value")
    }
  }

  func encodedCount(limit: Int, budget: String = "encoded JSON output bytes") throws -> Int {
    var count = 0
    try write(indentation: "") { text in
      guard text.utf8.count <= limit - count else {
        throw ManifestFailure(
          ManifestDiagnostic(
            code: "manifest.limit", message: budget,
            span: SourceSpan(
              document: DocumentIdentity("manifest"), start: 0, end: 0, line: 1, column: 1)))
      }
      count += text.utf8.count
    }
    return count
  }

  func encodedJSON(limit: Int = ManifestLimits.Output.encodedBytes) throws -> [UInt8] {
    let count = try encodedCount(limit: limit - 1)
    var result = ""
    result.reserveCapacity(count + 1)
    try write(indentation: "") { result += $0 }
    result += "\n"
    return Array(result.utf8)
  }

  private func write(indentation: String, emit: (String) throws -> Void) throws {
    func string(_ text: String) throws {
      try emit("\"")
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": try emit("\\\"")
        case "\\": try emit("\\\\")
        case "\n": try emit("\\n")
        case "\r": try emit("\\r")
        case "\t": try emit("\\t")
        case "\u{8}": try emit("\\b")
        case "\u{C}": try emit("\\f")
        case "\0"..<" ":
          let hex = String(scalar.value, radix: 16)
          try emit("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
        default: try emit(String(scalar))
        }
      }
      try emit("\"")
    }
    switch self {
    case .null: try emit("null")
    case .integer(let value): try emit(String(value))
    case .boolean(let value): try emit(value ? "true" : "false")
    case .string(let value): try string(value)
    case .array(let values):
      if values.isEmpty {
        try emit("[]")
        return
      }
      try emit("[\n")
      for (index, value) in values.enumerated() {
        try emit(indentation + "  ")
        try value.write(indentation: indentation + "  ", emit: emit)
        try emit((index < values.count - 1 ? "," : "") + "\n")
      }
      try emit(indentation + "]")
    case .object(let fields):
      if fields.isEmpty {
        try emit("{}")
        return
      }
      try emit("{\n")
      let keys = fields.keys.sorted(by: utf8Less)
      for (index, key) in keys.enumerated() {
        try emit(indentation + "  ")
        try string(key)
        try emit(": ")
        try fields[key]!.write(indentation: indentation + "  ", emit: emit)
        try emit((index < keys.count - 1 ? "," : "") + "\n")
      }
      try emit(indentation + "}")
    }
  }
}
