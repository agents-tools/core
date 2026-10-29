import AgentsCore
import AgentsDescription
import AgentsManifest
import Foundation
import ManifestTestSupport

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

func progress(_ stage: FrontEndStage, _ metrics: FrontEndMetrics) {
  struct Progress: Encodable {
    let configuration: String
    let stage: FrontEndStage
    let metrics: FrontEndMetrics
  }
  if let data = try? JSONEncoder().encode(
    Progress(configuration: probeConfiguration, stage: stage, metrics: metrics))
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

func run(_ bytes: [UInt8], semantics: Bool) -> ProbeReport {
  var stage = FrontEndStage.admission
  do {
    let metrics = try DeclarationDocument.inspect(
      bytes: bytes, identity: DocumentIdentity("manifest"),
      checking: semantics ? .declaration : .syntax
    ) { next, metrics in
      stage = next
      progress(next, metrics)
    }
    return ProbeReport(
      status: "accepted", stage: .complete, metrics: metrics, peakMemoryBytes: peakMemory())
  } catch let failure as ManifestFailure {
    let diagnostic = failure.diagnostics[0]
    return ProbeReport(
      status: diagnostic.code, stage: failure.stage, offset: diagnostic.span.start,
      line: diagnostic.span.line, column: diagnostic.span.column, message: diagnostic.message,
      metrics: failure.metrics, peakMemoryBytes: peakMemory())
  } catch {
    return ProbeReport(
      status: "unexpected", stage: stage, message: String(describing: error),
      metrics: FrontEndMetrics(), peakMemoryBytes: peakMemory())
  }
}

let path = CommandLine.arguments[1]
let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
var bytes: [UInt8] = []
while bytes.count < (ManifestLimits.Input.bytes + 1) {
  let data = try handle.read(upToCount: (ManifestLimits.Input.bytes + 1) - bytes.count) ?? Data()
  if data.isEmpty { break }
  bytes.append(contentsOf: data)
}
try handle.close()
let report: ProbeReport
if CommandLine.arguments.contains("--edit-oversized") {
  do {
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    let component = Component.ignore(
      name: "large", patterns: [String(repeating: "x", count: 20_000_000)])
    _ = try document.preparing([.insertComponent(component, into: .root, at: .first)])
    report = ProbeReport(
      status: "accepted", stage: .editing, offset: 0, line: 1, column: 1, message: "",
      metrics: document.metrics, peakMemoryBytes: peakMemory())
  } catch let error as ManifestFailure {
    let diagnostic = error.diagnostics[0]
    report = ProbeReport(
      status: diagnostic.code, stage: .editing, offset: diagnostic.span.start,
      line: diagnostic.span.line, column: diagnostic.span.column, message: diagnostic.message,
      metrics: error.metrics, peakMemoryBytes: peakMemory())
  }
} else {
  report = run(bytes, semantics: CommandLine.arguments.contains("--semantics"))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
