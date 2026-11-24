import Foundation

/// One final public text projection: controls are removed before known private
/// values are masked, then the valid UTF8 result is bounded in bytes.
struct MCPConnectionRedaction {
  private let expression: NSRegularExpression?
  private let byteLimit: Int
  private let hasPrivateValues: Bool
  init(privateValues: [String], byteLimit: Int) {
    self.byteLimit = byteLimit
    let values = Set(privateValues.map(Self.withoutControls).filter { !$0.isEmpty }).sorted {
      $0.count > $1.count
    }
    hasPrivateValues = !values.isEmpty
    expression =
      values.isEmpty
      ? nil
      : try? NSRegularExpression(
        pattern: values.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))
  }
  func text(_ value: String) -> String {
    guard !hasPrivateValues || expression != nil else { return "[redacted]" }
    let filtered = Self.withoutControls(value)
    let text =
      expression?.stringByReplacingMatches(
        in: filtered, range: NSRange(filtered.startIndex..., in: filtered),
        withTemplate: "[redacted]") ?? filtered
    var bytes = Data(text.utf8.prefix(byteLimit))
    while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
  }
  private static func withoutControls(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
  }
}
