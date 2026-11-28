import AgentsCore
import Foundation

/// YAML 1.2 Core resolution. Number conversion never passes through floating-point formatting.
package enum YAMLScalar: Equatable, Sendable {
  case string, integer, decimal, boolean, null

  package static func classify(_ text: String) -> Self {
    if ["", "~", "null", "Null", "NULL"].contains(text) { return .null }
    if ["true", "True", "TRUE", "false", "False", "FALSE"].contains(text) { return .boolean }
    if matches(text, #"^[-+]?(0o[0-7]+|0x[0-9a-fA-F]+|[0-9]+)$"#) { return .integer }
    if matches(text, #"^[-+]?(([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?|\.(inf|Inf|INF))$"#)
      || [".nan", ".NaN", ".NAN"].contains(text)
    {
      return .decimal
    }
    return .string
  }

  package static func integer(_ text: String) -> Int? {
    var digits = text
    let negative = digits.hasPrefix("-")
    if digits.hasPrefix("-") || digits.hasPrefix("+") { digits.removeFirst() }
    let radix: Int
    if digits.hasPrefix("0o") {
      radix = 8
      digits.removeFirst(2)
    } else if digits.hasPrefix("0x") {
      radix = 16
      digits.removeFirst(2)
    } else {
      radix = 10
    }
    return Int((negative ? "-" : "") + digits, radix: radix)
  }

  static func decimal(_ text: String, explicit: Bool) -> String? {
    if explicit { return validDecimal(text) ? text : nil }
    var result = text
    if result.hasPrefix("+") { result.removeFirst() }
    let negative = result.hasPrefix("-")
    if negative { result.removeFirst() }
    let exponent = result.firstIndex { $0 == "e" || $0 == "E" }
    let suffix = exponent.map { String(result[$0...]) } ?? ""
    var mantissa = exponent.map { String(result[..<$0]) } ?? result
    if mantissa.hasPrefix(".") { mantissa = "0" + mantissa }
    if mantissa.hasSuffix(".") { mantissa += "0" }
    if let dot = mantissa.firstIndex(of: ".") {
      var whole = String(mantissa[..<dot])
      while whole.count > 1 && whole.hasPrefix("0") { whole.removeFirst() }
      mantissa = whole + mantissa[dot...]
    } else {
      while mantissa.count > 1 && mantissa.hasPrefix("0") { mantissa.removeFirst() }
    }
    result = (negative ? "-" : "") + mantissa + suffix
    return validDecimal(result) ? result : nil
  }

  static func validDecimal(_ text: String) -> Bool {
    matches(text, #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)
      && Double(text)?.isFinite == true
  }

  private static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
