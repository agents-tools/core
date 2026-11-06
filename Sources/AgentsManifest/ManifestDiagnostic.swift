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
  package let metrics: FrontEndMetrics
  package let stage: FrontEndStage
  package init(
    _ diagnostic: ManifestDiagnostic, metrics: FrontEndMetrics = FrontEndMetrics(),
    stage: FrontEndStage = .admission
  ) {
    diagnostics = [diagnostic]
    self.metrics = metrics
    self.stage = stage
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

package struct FrontEndMetrics: Sendable, Codable {
  package var parserCalls = 0
  package var tokens = 0
  package var syntaxReservation = 0
  package var syntaxNodes = 0
  package var syntaxDepth = 0
  package var evaluationSteps = 0
  package var expandedNodes = 0
  package var decodedBytes = 0
  package var admissionSeconds = 0.0
  package var parsingSeconds = 0.0
  package var guardSeconds = 0.0
  package var inspectionSeconds = 0.0
  package var evaluationSeconds = 0.0
  package var domainSeconds = 0.0
  package var loweringSeconds = 0.0
  package var sourceMapSeconds = 0.0
  package var teardownSeconds = 0.0
  package init() {}
}
