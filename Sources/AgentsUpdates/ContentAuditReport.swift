import Foundation

public enum ContentAuditSeverity: String, Codable, Sendable {
  case critical, warning, info
}

public enum ContentAuditOwnership: String, Codable, Sendable {
  case managedFile, managedRegion, untracked, unknown
}

public enum ContentAuditReason: String, CaseIterable, Codable, Sendable {
  case tagCharacter, bidiControl, supplementaryVariationSelector
  case zeroWidthCharacter, variationSelector, bidiMark, invisibleOperator
  case annotationMarker, deprecatedFormatting, softHyphen, interiorBOM
  case unusualWhitespace, emojiPresentation, contextualJoiner, emojiTagSequence
  case unreadable, unsupportedContent, outsideScope, pendingRecovery, ownershipUnavailable,
    contentDrift

  public var message: String {
    switch self {
    case .tagCharacter: "Invisible Unicode tag character."
    case .bidiControl: "Bidirectional embedding, override, or isolate control."
    case .supplementaryVariationSelector: "Supplementary Unicode variation selector."
    case .zeroWidthCharacter: "Zero-width space or joiner without a recognized context."
    case .variationSelector: "Invisible variation selector."
    case .bidiMark: "Invisible bidirectional text mark."
    case .invisibleOperator: "Invisible mathematical operator."
    case .annotationMarker: "Interlinear annotation marker."
    case .deprecatedFormatting: "Deprecated bidirectional formatting control."
    case .softHyphen: "Conditional soft hyphen."
    case .interiorBOM: "Byte order mark inside prompt content."
    case .unusualWhitespace: "Non-breaking or unusual whitespace."
    case .emojiPresentation: "Text or emoji presentation selector."
    case .contextualJoiner: "Join control in a recognized text or emoji sequence."
    case .emojiTagSequence: "Standard emoji flag tag sequence."
    case .unreadable: "An admitted prompt or discovery location could not be read."
    case .unsupportedContent: "The prompt format, syntax, or structure could not be inspected."
    case .outsideScope: "The prompt is outside the selected filesystem scope."
    case .pendingRecovery: "Scope recovery is pending."
    case .ownershipUnavailable: "Recorded prompt ownership could not be verified."
    case .contentDrift: "The managed prompt content differs from its recorded hash."
    }
  }
}

public struct ContentAuditLocation: Codable, Equatable, Sendable {
  /// Relative to the selected project or home, with '/' separators.
  public let path: String
  /// RFC 6901 pointer for a structured field.
  public let field: String?
  /// One-based source coordinates in UTF-16 code units. A field with no source
  /// mapping has only its pointer and decoded prompt coordinates.
  public let line: Int?
  public let column: Int?
  public let promptLine: Int?
  public let promptColumn: Int?
}

public struct ContentAuditFinding: Codable, Equatable, Sendable {
  public let severity: ContentAuditSeverity
  public let reason: ContentAuditReason
  public let location: ContentAuditLocation
  public let ownership: ContentAuditOwnership
  public let codePoint: UInt32?
  public var message: String {
    guard let codePoint else { return reason.message }
    return "U+" + String(format: "%04X", codePoint) + " " + reason.message
  }
}

public struct ContentAuditTarget: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case scanned, skipped, incomplete }
  public let path: String
  public let ownership: ContentAuditOwnership
  public let status: Status
}

public enum ContentAuditReportFormat: Sendable {
  case json, sarif, markdown
}

public struct ContentAuditReport: Encodable, Sendable {
  public let targets: [ContentAuditTarget]
  public let findings: [ContentAuditFinding]
  /// Scope-relative diagnostic locations are exported. Absolute inputs are available
  /// separately to a local consumer that refreshes its inspection when files change.
  public let readLocations: [URL]

  public var passesCI: Bool { !findings.contains { $0.severity == .critical } }
  public var ciExitCode: Int32 { passesCI ? 0 : 1 }
  public var scanExitCode: Int32 {
    if !passesCI { return 1 }
    return findings.contains { $0.severity == .warning } ? 2 : 0
  }

  private enum CodingKeys: String, CodingKey { case targets, findings, passesCI, ciExitCode }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(targets, forKey: .targets)
    try values.encode(findings, forKey: .findings)
    try values.encode(passesCI, forKey: .passesCI)
    try values.encode(ciExitCode, forKey: .ciExitCode)
  }

  public func export(_ format: ContentAuditReportFormat) throws -> Data {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(self)
    case .sarif: return try sarif()
    case .markdown: return Data(markdown().utf8)
    }
  }

  private func sarif() throws -> Data {
    let results: [[String: Any]] = findings.map { finding in
      let location = finding.location
      var physical: [String: Any] = [
        "artifactLocation": ["uri": Self.relativeURI(location.path)]
      ]
      if let line = location.line, let column = location.column {
        physical["region"] = ["startLine": line, "startColumn": column]
      }
      var properties: [String: Any] = ["ownership": finding.ownership.rawValue]
      if let field = location.field { properties["field"] = field }
      if let line = location.promptLine { properties["promptLine"] = line }
      if let column = location.promptColumn { properties["promptColumn"] = column }
      let level: String =
        switch finding.severity {
        case .critical: "error"
        case .warning: "warning"
        case .info: "note"
        }
      return [
        "ruleId": finding.reason.rawValue, "level": level,
        "message": ["text": finding.message], "properties": properties,
        "locations": [["physicalLocation": physical]],
      ]
    }
    let rules = Set(findings.map(\.reason)).sorted { $0.rawValue < $1.rawValue }.map {
      ["id": $0.rawValue, "shortDescription": ["text": $0.message]] as [String: Any]
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "$schema":
          "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "version": "2.1.0",
        "runs": [
          [
            "tool": ["driver": ["name": "Agents Content Audit", "rules": rules]],
            "columnKind": "utf16CodeUnits", "results": results,
          ]
        ],
      ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  private func markdown() -> String {
    let counts = Dictionary(grouping: targets, by: \.status).mapValues(\.count)
    var lines = [
      "# Content audit", "", passesCI ? "CI gate passed." : "CI gate failed.",
      "\(counts[.scanned, default: 0]) scanned, \(counts[.skipped, default: 0]) skipped, \(counts[.incomplete, default: 0]) incomplete.",
    ]
    if !findings.isEmpty { lines.append("") }
    for finding in findings {
      let location = finding.location
      var coordinate = Self.relativeURI(location.path)
      if let line = location.line, let column = location.column {
        coordinate += ":\(line):\(column)"
      }
      if let field = location.field {
        coordinate += " at " + Self.relativeURI(field)
        if let line = location.promptLine, let column = location.promptColumn {
          coordinate += " (decoded \(line):\(column))"
        }
      }
      lines.append(
        "- **\(finding.severity.rawValue)** `\(coordinate)` (\(finding.ownership.rawValue)) — \(finding.message)"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func relativeURI(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "."
  }
}
