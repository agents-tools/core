import AgentsCore

public struct ManifestDiagnostic: Sendable, Equatable {
  public enum Severity: String, Sendable { case warning, error }
  public let code: String
  public let severity: Severity
  public let message: String
  public let span: SourceSpan
  public let related: [SourceSpan]
  public let fixIt: SourcePatch?

  public init(
    code: String, severity: Severity = .error, message: String, span: SourceSpan,
    related: [SourceSpan] = [], fixIt: SourcePatch? = nil
  ) {
    self.code = code
    self.severity = severity
    self.message = message
    self.span = span
    self.related = related
    self.fixIt = fixIt
  }
}

public struct ManifestFailure: Error, Sendable {
  public let diagnostics: [ManifestDiagnostic]
  public let metrics: FrontEndMetrics
  package init(_ diagnostic: ManifestDiagnostic, metrics: FrontEndMetrics = FrontEndMetrics()) {
    diagnostics = [diagnostic]
    self.metrics = metrics
  }
}

public struct SourcePatch: Sendable, Equatable {
  public let range: Range<Int>
  public let replacement: [UInt8]
  package init(range: Range<Int>, replacement: [UInt8]) {
    self.range = range
    self.replacement = replacement
  }
}

public struct FrontEndMetrics: Sendable, Codable {
  public package(set) var parserCalls = 0
  public package(set) var tokens = 0
  public package(set) var syntaxReservation = 0
  public package(set) var syntaxNodes = 0
  public package(set) var syntaxDepth = 0
  public package(set) var evaluationSteps = 0
  public package(set) var expandedNodes = 0
  public package(set) var decodedBytes = 0
  public package(set) var admissionSeconds = 0.0
  public package(set) var parsingSeconds = 0.0
  public package(set) var guardSeconds = 0.0
  public package(set) var inspectionSeconds = 0.0
  public package(set) var evaluationSeconds = 0.0
  public package(set) var domainSeconds = 0.0
  public package(set) var loweringSeconds = 0.0
  public package(set) var sourceMapSeconds = 0.0
  public package(set) var teardownSeconds = 0.0
  public init() {}
}

package struct SourceText: Sendable {
  package let bytes: [UInt8]
  package let identity: DocumentIdentity
  private let lines: [Int]

  package init(_ bytes: [UInt8], identity: DocumentIdentity) {
    self.bytes = bytes
    self.identity = identity
    var starts = [0]
    var i = 0
    while i < min(bytes.count, 2_097_153) {
      if bytes[i] == 13 {
        if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 1 }
        starts.append(i + 1)
      } else if bytes[i] == 10 {
        starts.append(i + 1)
      }
      i += 1
    }
    lines = starts
  }

  package func span(_ range: Range<Int>) -> SourceSpan {
    let start = min(max(0, range.lowerBound), bytes.count)
    var lo = 0
    var hi = lines.count
    while lo + 1 < hi {
      let mid = (lo + hi) / 2
      if lines[mid] <= start { lo = mid } else { hi = mid }
    }
    return SourceSpan(
      document: identity, start: start, end: min(max(start, range.upperBound), bytes.count),
      line: lo + 1, column: start - lines[lo] + 1)
  }

  package func failure(_ code: String, _ message: String, _ offset: Int, end: Int? = nil)
    -> ManifestFailure
  {
    ManifestFailure(
      ManifestDiagnostic(code: code, message: message, span: span(offset..<(end ?? offset))))
  }

  package func spelling(_ range: Range<Int>) -> String {
    String(decoding: bytes[range], as: UTF8.self)
  }
}
