import Foundation

public enum LifecycleEvent: String, CaseIterable, Codable, Sendable {
  case preInstall = "pre-install"
  case postInstall = "post-install"
  case preUpdate = "pre-update"
  case postUpdate = "post-update"
  case preUninstall = "pre-uninstall"
  case postUninstall = "post-uninstall"
  case preCompile = "pre-compile"
}

package struct LifecycleDeclarationIssue: Equatable, Sendable {
  package let event: String?
  package let index: Int?
  package let field: String
  package let message: String
}

package struct DeclaredLifecycleAction: Sendable {
  package enum CommandField: String, CaseIterable, Sendable {
    case bash, command, run
  }

  package enum Body: Sendable {
    case command(CommandField, String, environment: [String: String])
    case http(URL, headers: [String: String], allowedVariables: Set<String>)
  }

  package let event: LifecycleEvent
  package let index: Int
  package let body: Body
  package let timeout: Int
  package let authored: DeclarationValue
}

package struct LifecycleDeclaration: Sendable {
  package let actions: [DeclaredLifecycleAction]
  package let issues: [LifecycleDeclarationIssue]

  package init(_ value: DeclarationValue) {
    guard case .dictionary(let events) = value else {
      actions = []
      issues = [.init(event: nil, index: nil, field: "", message: "Expected an event mapping.")]
      return
    }
    var actions: [DeclaredLifecycleAction] = []
    var issues: [LifecycleDeclarationIssue] = []
    for name in events.keys.sorted() where LifecycleEvent(rawValue: name) == nil {
      issues.append(.init(event: name, index: nil, field: "", message: "Unknown lifecycle event."))
    }
    for event in LifecycleEvent.allCases {
      guard let value = events[event.rawValue] else { continue }
      guard let entries = value.elements, entries.count <= 128 else {
        issues.append(
          .init(
            event: event.rawValue, index: nil, field: "",
            message: "Expected a sequence of up to 128 actions."))
        continue
      }
      for (index, entry) in entries.enumerated() {
        var validation = ActionValidation(event: event, index: index)
        if let action = validation.action(entry) { actions.append(action) }
        issues += validation.issues
      }
    }
    self.actions = issues.isEmpty ? actions : []
    self.issues = issues
  }

  package static func isVariable(_ text: String) -> Bool {
    let bytes = text.utf8
    guard let first = bytes.first, isLetter(first) || first == 95 else { return false }
    return bytes.allSatisfy { isLetter($0) || $0 == 95 || (48...57).contains($0) }
  }

  private static func isLetter(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte)
  }
}

private struct ActionValidation {
  let event: LifecycleEvent
  let index: Int
  var issues: [LifecycleDeclarationIssue] = []

  mutating func action(_ entry: DeclarationValue) -> DeclaredLifecycleAction? {
    guard case .dictionary(let fields) = entry else {
      issue("", "Expected an action mapping.")
      return nil
    }
    let commandFields = DeclaredLifecycleAction.CommandField.allCases
    let presentCommands = commandFields.filter { fields[$0.rawValue] != nil }
    let type = fields["type"]?.string
    let httpFields: Set<String> = ["url", "headers", "allowedEnvVars"]
    let commandNames = Set(commandFields.map(\.rawValue) + ["env"])
    let common: Set<String> = ["type", "timeout"]
    let permitted: Set<String>
    let body: DeclaredLifecycleAction.Body?
    switch type {
    case "command":
      permitted = common.union(commandNames)
      if presentCommands.count != 1 {
        issue("", "A command action requires exactly one of bash, command, or run.")
      }
      var command: (DeclaredLifecycleAction.CommandField, String)?
      for field in presentCommands {
        if let value = string(fields[field.rawValue], field: field.rawValue, nonempty: true) {
          command = (field, value)
        }
      }
      let environment = mapping(
        fields["env"], field: "env", keyIsValid: LifecycleDeclaration.isVariable)
      body = command.map { .command($0.0, $0.1, environment: environment) }
    case "http":
      permitted = common.union(httpFields)
      let urlText = string(fields["url"], field: "url", nonempty: true)
      let url = urlText.flatMap { httpURL($0) }
      let headers = mapping(fields["headers"], field: "headers", keyIsValid: validHeaderName)
      var fieldNames: Set<String> = []
      for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        if !fieldNames.insert(name.lowercased()).inserted {
          issue("headers." + name, "Duplicate HTTP field name.")
        }
        if !Self.validHeaderValue(value) {
          issue("headers." + name, "Header values must be printable and contain no line breaks.")
        }
      }
      let variables = allowedVariables(fields["allowedEnvVars"])
      body = url.map { .http($0, headers: headers, allowedVariables: variables) }
    default:
      permitted = common.union(httpFields).union(commandNames)
      issue("type", "Expected command or http.")
      body = nil
    }
    for name in fields.keys.sorted() where !permitted.contains(name) {
      issue(name, "Field is not permitted for this action.")
    }
    var timeout = 30
    if let value = fields["timeout"] {
      if case .integer(let seconds) = value, (1...300).contains(seconds) {
        timeout = seconds
      } else {
        issue("timeout", "Expected an integer from 1 through 300 seconds.")
      }
    }
    guard issues.isEmpty, let body else { return nil }
    return .init(event: event, index: index, body: body, timeout: timeout, authored: entry)
  }

  mutating func issue(_ field: String, _ message: String) {
    issues.append(.init(event: event.rawValue, index: index, field: field, message: message))
  }

  mutating func string(_ input: DeclarationValue?, field: String, nonempty: Bool = false) -> String?
  {
    guard let value = input?.string, !value.utf8.contains(0), !nonempty || !value.isEmpty else {
      issue(field, nonempty ? "Expected a nonempty string." : "Expected a string without NUL.")
      return nil
    }
    return value
  }

  mutating func mapping(
    _ input: DeclarationValue?, field: String, keyIsValid: (String) -> Bool
  ) -> [String: String] {
    guard let input else { return [:] }
    guard case .dictionary(let fields) = input, fields.count <= 128 else {
      issue(field, "Expected a mapping of up to 128 strings.")
      return [:]
    }
    var result: [String: String] = [:]
    for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
      let path = field + "." + key
      if !keyIsValid(key) { issue(path, "Invalid name.") }
      if let value = string(value, field: path) { result[key] = value }
    }
    return result
  }

  mutating func httpURL(_ value: String) -> URL? {
    guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.fragment == nil, let url = parts.url,
      !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 })
    else {
      issue("url", "Expected an HTTPS URL without embedded credentials, spaces, or a fragment.")
      return nil
    }
    return url
  }

  func validHeaderName(_ name: String) -> Bool {
    let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
    let transportHeaders: Set<String> = [
      "connection", "content-length", "content-type", "host", "proxy-authorization", "te",
      "trailer",
      "transfer-encoding", "upgrade",
    ]
    return !name.isEmpty && !transportHeaders.contains(name.lowercased())
      && name.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || punctuation.contains($0)
      }
  }

  static func validHeaderValue(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
  }

  mutating func allowedVariables(_ input: DeclarationValue?) -> Set<String> {
    guard let input else { return [] }
    guard let values = input.elements, values.count <= 128 else {
      issue("allowedEnvVars", "Expected a sequence of up to 128 environment variable names.")
      return []
    }
    var valid: Set<String> = []
    for (index, value) in values.enumerated() {
      guard let name = value.string, LifecycleDeclaration.isVariable(name) else {
        issue("allowedEnvVars.\(index)", "Invalid environment variable name.")
        continue
      }
      valid.insert(name)
    }
    return valid
  }
}

extension LifecycleDeclaration {
  package static func equivalent(_ lhs: DeclarationValue?, _ rhs: DeclarationValue?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let lhs?, let rhs?):
      guard let left = try? digest(lhs), let right = try? digest(rhs) else { return false }
      return left == right
    default: return false
    }
  }

  /// Versioned, type-tagged UTF-8 encoding. Lengths and counts delimit values independently
  /// of YAML spelling, Unicode normalization, escape choices and dictionary enumeration.
  package static func digest(_ value: DeclarationValue) throws -> String {
    var bytes = Data("agents.lifecycle.v1\0".utf8)
    func append(_ text: String) { bytes.append(contentsOf: text.utf8) }
    func string(_ text: String) {
      append("s\(text.utf8.count):")
      append(text)
    }
    func encode(_ value: DeclarationValue) throws {
      switch value {
      case .string(let text): string(text)
      case .integer(let integer): append("i\(integer):")
      case .boolean(let flag): append(flag ? "t" : "f")
      case .null: append("n")
      case .array(let entries):
        append("a\(entries.count):")
        for entry in entries { try encode(entry) }
      case .dictionary(let entries):
        append("m\(entries.count):")
        for (key, value) in entries.sorted(by: {
          $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }) {
          string(key)
          try encode(value)
        }
      case .record, .requirement:
        throw CoreError.invalidState("Unsupported lifecycle scalar.")
      }
    }
    try encode(value)
    return "sha256:" + FileHash.sha256Hex(data: bytes)
  }
}
