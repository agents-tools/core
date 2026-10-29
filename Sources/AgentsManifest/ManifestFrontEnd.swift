import AgentsCore
import AgentsDescription
import Foundation
import SwiftSyntax

package enum FrontEndStage: String, Sendable, Codable {
  case admission, parser, evaluation, domain, lowering, sourceMap, teardown
}

package enum FrontEndCheck: Sendable, Equatable {
  case syntax, declaration
}

struct FrontEndDeclaration {
  let evaluation: Evaluation
  let ir: DeclarationIR
  let diagnostics: [ManifestDiagnostic]
  let digest: String
  let map: BuiltMap
}

struct FrontEndResult {
  let source: SourceText
  let admission: Admission
  let syntax: SourceFileSyntax
  let declaration: FrontEndDeclaration?
  let metrics: FrontEndMetrics
}

/// Owns phase ordering for document construction and bounded syntax inspection.
/// Observers receive phase-entry metrics; failures retain the phase and work already done.
package enum ManifestFrontEnd {
  /// `.syntax` runs admission, parsing, tree guards and projection comparison.
  /// `.declaration` also evaluates and validates values, lowers IR and builds source maps.
  /// Both release the retained syntax tree before returning.
  package static func inspect(
    bytes: [UInt8], identity: DocumentIdentity, checking: FrontEndCheck,
    observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws -> FrontEndMetrics {
    var result: FrontEndResult? = try run(
      bytes: bytes, identity: identity, checking: checking, observe: observe)
    var metrics = result!.metrics
    observe?(.teardown, metrics)
    let clock = ContinuousClock()
    let start = clock.now
    // Keep ARC from releasing the tree before teardown timing starts.
    withExtendedLifetime(result) {}
    result = nil
    metrics.teardownSeconds = seconds(start.duration(to: clock.now))
    return metrics
  }

  static func run(
    bytes: [UInt8], identity: DocumentIdentity, checking: FrontEndCheck,
    validateDomain: Bool = true, observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws -> FrontEndResult {
    let clock = ContinuousClock()
    var stage = FrontEndStage.admission
    var stageStart = clock.now
    var metrics = FrontEndMetrics()
    let source = SourceText(Array(bytes.prefix(ManifestLimits.Input.bytes + 1)), identity: identity)
    func enter(_ next: FrontEndStage) {
      stage = next
      stageStart = clock.now
      var progress = metrics
      if next == .parser { progress.parserCalls += 1 }
      observe?(next, progress)
    }
    enter(.admission)
    do {
      if bytes.count > ManifestLimits.Input.bytes {
        throw source.failure("manifest.limit", "input byte limit", ManifestLimits.Input.bytes)
      }
      let admission = try Recognizer(source: source).recognize()
      metrics.admissionSeconds = seconds(stageStart.duration(to: clock.now))
      metrics.tokens = admission.tokens.count
      metrics.syntaxReservation = admission.reservation
      enter(.parser)
      let checked = try SyntaxValidation.parse(source, admission: admission, metrics: metrics)
      metrics = checked.metrics
      if checking == .syntax {
        return FrontEndResult(
          source: source, admission: admission, syntax: checked.tree, declaration: nil,
          metrics: metrics)
      }
      enter(.evaluation)
      let evaluation = try Evaluator(source: source, admission: admission).evaluate()
      metrics.evaluationSeconds = seconds(stageStart.duration(to: clock.now))
      metrics.evaluationSteps = evaluation.steps
      metrics.expandedNodes = evaluation.total.nodes
      metrics.decodedBytes = evaluation.total.strings
      enter(.domain)
      let diagnostics =
        validateDomain
        ? try DomainValidator(source: source, admission: admission, evaluation: evaluation)
          .validate()
        : []
      metrics.domainSeconds = seconds(stageStart.duration(to: clock.now))
      enter(.lowering)
      let ir = Lowering.declaration(evaluation.root.value)
      metrics.loweringSeconds = seconds(stageStart.duration(to: clock.now))
      enter(.sourceMap)
      let digest = "sha256:" + FileHash.sha256Hex(data: Data(bytes))
      let map = try MapBuilder(source: source, admission: admission, digest: digest).build(
        evaluation)
      metrics.sourceMapSeconds = seconds(stageStart.duration(to: clock.now))
      return FrontEndResult(
        source: source, admission: admission, syntax: checked.tree,
        declaration: FrontEndDeclaration(
          evaluation: evaluation, ir: ir, diagnostics: diagnostics, digest: digest, map: map),
        metrics: metrics)
    } catch let failure as ManifestFailure {
      let elapsed = seconds(stageStart.duration(to: clock.now))
      switch stage {
      case .admission:
        metrics = failure.metrics
        metrics.admissionSeconds = elapsed
      case .parser: metrics = failure.metrics
      case .evaluation: metrics.evaluationSeconds = elapsed
      case .domain: metrics.domainSeconds = elapsed
      case .lowering: metrics.loweringSeconds = elapsed
      case .sourceMap: metrics.sourceMapSeconds = elapsed
      default: break
      }
      throw ManifestFailure(failure.diagnostics[0], metrics: metrics, stage: stage)
    }
  }
}
