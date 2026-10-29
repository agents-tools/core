import AgentsCore
import AgentsDescription
import AgentsManifest
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

#if DEBUG
  let manifestTestConfiguration = "debug"
#else
  let manifestTestConfiguration = "release"
#endif

struct Report: Codable {
  var configuration = manifestTestConfiguration
  var status: String
  var stage: String
  var offset: Int
  var line: Int
  var column: Int
  var message: String
  var metrics: FrontEndMetrics
  var peakMemoryBytes: UInt64
}

func progress(_ stage: String, _ metrics: FrontEndMetrics) {
  struct Progress: Encodable {
    let configuration: String
    let stage: String
    let metrics: FrontEndMetrics
  }
  if let data = try? JSONEncoder().encode(
    Progress(configuration: manifestTestConfiguration, stage: stage, metrics: metrics))
  {
    FileHandle.standardError.write(data + Data([10]))
  }
}

func peakMemory() -> UInt64 {
  var usage = rusage()
  #if canImport(Darwin)
    _ = getrusage(RUSAGE_SELF, &usage)
    return UInt64(max(0, usage.ru_maxrss))
  #else
    _ = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
    return UInt64(max(0, usage.ru_maxrss)) * 1024
  #endif
}

func run(_ bytes: [UInt8], semantics: Bool) -> Report {
  var metrics = FrontEndMetrics()
  let clock = ContinuousClock()
  let start = clock.now
  let source = SourceText(Array(bytes.prefix(2_097_153)), identity: DocumentIdentity("manifest"))
  var stage = "admission"
  var stageStart = clock.now
  progress(stage, metrics)
  do {
    let admission = try Recognizer(source: source).recognize()
    metrics.admissionSeconds = seconds(start.duration(to: clock.now))
    metrics.tokens = admission.tokens.count
    metrics.syntaxReservation = admission.reservation
    stage = "parser"
    var enteringParser = metrics
    enteringParser.parserCalls = 1
    progress(stage, enteringParser)
    var syntax: CheckedSyntax? = try SyntaxValidation.parse(
      source, admission: admission, metrics: metrics)
    metrics = syntax!.metrics
    if semantics {
      stage = "evaluation"
      stageStart = clock.now
      progress(stage, metrics)
      let evaluation = try Evaluator(source: source, admission: admission).evaluate()
      metrics.evaluationSeconds = seconds(stageStart.duration(to: clock.now))
      metrics.evaluationSteps = evaluation.steps
      metrics.expandedNodes = evaluation.total.nodes
      metrics.decodedBytes = evaluation.total.strings
      stage = "domain"
      stageStart = clock.now
      progress(stage, metrics)
      _ = try DomainValidator(source: source, admission: admission, evaluation: evaluation)
        .validate()
      metrics.domainSeconds = seconds(stageStart.duration(to: clock.now))
      stage = "lowering"
      stageStart = clock.now
      progress(stage, metrics)
      _ = Lowering.declaration(evaluation.root.value)
      metrics.loweringSeconds = seconds(stageStart.duration(to: clock.now))
      stage = "sourceMap"
      stageStart = clock.now
      progress(stage, metrics)
      _ = try MapBuilder(source: source, admission: admission, digest: "probe").build(evaluation)
      metrics.sourceMapSeconds = seconds(stageStart.duration(to: clock.now))
    }
    stage = "teardown"
    let teardown = clock.now
    syntax = nil
    metrics.teardownSeconds = seconds(teardown.duration(to: clock.now))
    return Report(
      status: "accepted", stage: "complete", offset: 0, line: 1, column: 1, message: "",
      metrics: metrics, peakMemoryBytes: peakMemory())
  } catch let error as ManifestFailure {
    let diagnostic = error.diagnostics[0]
    if stage == "admission" {
      metrics = error.metrics
      metrics.admissionSeconds = seconds(start.duration(to: clock.now))
    } else if stage == "parser" {
      metrics = error.metrics
    } else {
      let elapsed = seconds(stageStart.duration(to: clock.now))
      switch stage {
      case "evaluation": metrics.evaluationSeconds = elapsed
      case "domain": metrics.domainSeconds = elapsed
      case "sourceMap": metrics.sourceMapSeconds = elapsed
      default: break
      }
    }
    return Report(
      status: diagnostic.code, stage: stage, offset: diagnostic.span.start,
      line: diagnostic.span.line, column: diagnostic.span.column, message: diagnostic.message,
      metrics: metrics, peakMemoryBytes: peakMemory())
  } catch {
    return Report(
      status: "unexpected", stage: stage, offset: 0, line: 0, column: 0,
      message: String(describing: error), metrics: metrics, peakMemoryBytes: peakMemory())
  }
}

let path = CommandLine.arguments[1]
let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
var bytes: [UInt8] = []
while bytes.count < 2_097_153 {
  let data = try handle.read(upToCount: 2_097_153 - bytes.count) ?? Data()
  if data.isEmpty { break }
  bytes.append(contentsOf: data)
}
try handle.close()
let report: Report
if CommandLine.arguments.contains("--edit-oversized") {
  do {
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    let component = Component.ignore(
      name: "large", patterns: [String(repeating: "x", count: 20_000_000)])
    _ = try document.preparing([.insertComponent(component, into: .root, at: .first)])
    report = Report(
      status: "accepted", stage: "editing", offset: 0, line: 1, column: 1, message: "",
      metrics: document.metrics, peakMemoryBytes: peakMemory())
  } catch let error as ManifestFailure {
    let diagnostic = error.diagnostics[0]
    report = Report(
      status: diagnostic.code, stage: "editing", offset: diagnostic.span.start,
      line: diagnostic.span.line, column: diagnostic.span.column, message: diagnostic.message,
      metrics: error.metrics, peakMemoryBytes: peakMemory())
  }
} else {
  report = run(bytes, semantics: CommandLine.arguments.contains("--semantics"))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
