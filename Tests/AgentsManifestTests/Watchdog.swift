import AgentsCore
import AgentsManifest
import Foundation
import ManifestTestSupport
import Testing

struct ProbeResult: Codable {
  let name: String
  let configuration: String
  let watchdogSeconds: Double
  let wallSeconds: Double
  let report: ProbeReport
}

private final class ManifestTestBundle {}

func testProcessURL() throws -> URL {
  var directory = Bundle(for: ManifestTestBundle.self).bundleURL
  for _ in 0..<6 {
    let candidate = directory.appendingPathComponent("ManifestTestProcess")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  throw CocoaError(.fileNoSuchFile)
}

func probe(
  _ name: String, _ bytes: [UInt8], semantics: Bool = false, extraArguments: [String] = [],
  in directory: URL
) throws
  -> ProbeResult
{
  let input = directory.appendingPathComponent("input.swift")
  let output = directory.appendingPathComponent("output.json")
  let errors = directory.appendingPathComponent("stderr.txt")
  try Data(bytes).write(to: input)
  FileManager.default.createFile(atPath: output.path, contents: nil)
  FileManager.default.createFile(atPath: errors.path, contents: nil)
  let stdout = try FileHandle(forWritingTo: output)
  let stderr = try FileHandle(forWritingTo: errors)
  defer {
    try? stdout.close()
    try? stderr.close()
  }
  let process = Process()
  process.executableURL = try testProcessURL()
  process.arguments = [input.path] + (semantics ? ["--semantics"] : []) + extraArguments
  process.standardOutput = stdout
  process.standardError = stderr
  let clock = ContinuousClock()
  let start = clock.now
  try process.run()
  // The timer starts before launch and remains active through child exit and teardown.
  while process.isRunning && start.duration(to: clock.now) < .seconds(probeWatchdogSeconds) {
    Thread.sleep(forTimeInterval: 0.002)
  }
  let timedOut = process.isRunning
  if timedOut {
    process.interrupt()
    process.terminate()
  }
  if timedOut {
    #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    #else
      _ = Glibc.kill(process.processIdentifier, SIGKILL)
    #endif
  }
  process.waitUntilExit()
  let duration = start.duration(to: clock.now).components
  let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
  let errorText = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
  try #require(
    !timedOut,
    "\(name) [\(probeConfiguration)] exceeded \(probeWatchdogSeconds) seconds: \(elapsed); \(errorText)"
  )
  try #require(
    process.terminationReason == .exit && process.terminationStatus == 0,
    "\(name) crashed or signaled: \(process.terminationStatus); \(errorText)")
  #expect(elapsed < probeWatchdogSeconds, "\(name): launch-to-exit deadline")
  let report = try JSONDecoder().decode(ProbeReport.self, from: Data(contentsOf: output))
  #expect(report.configuration == probeConfiguration, "\(name): child build configuration")
  // A loose runaway-process guard, not a platform-specific memory promise. 512 MiB
  // leaves room for the Swift runtime, Debug SwiftSyntax and bounded source/IR copies;
  // it is well above the contract's 2 MiB input, 16 MiB values and 32 MiB encoding caps.
  #expect(report.peakMemoryBytes < 536_870_912, "\(name): peak memory \(report.peakMemoryBytes)")
  #expect(report.status != "unexpected", "\(report.message)")
  if report.stage == .admission { #expect(report.metrics.parserCalls == 0) }
  if report.status == "accepted" {
    #expect(report.operation == .frontEnd)
    #expect(report.stage == .teardown)
    #expect(report.metrics.parserCalls == 1)
    #expect(report.metrics.syntaxNodes <= report.metrics.syntaxReservation)
  }
  return ProbeResult(
    name: name, configuration: probeConfiguration, watchdogSeconds: probeWatchdogSeconds,
    wallSeconds: elapsed, report: report)
}

func temporaryManifestDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "manifest-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func recordProbeResults(_ results: [ProbeResult], name: String) throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let evidenceRoot =
    ProcessInfo.processInfo.environment["MANIFEST_TEST_EVIDENCE"].map {
      URL(fileURLWithPath: $0)
    } ?? root.appendingPathComponent(".build/manifest-test-evidence")
  let directory = evidenceRoot.appendingPathComponent(probeConfiguration)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let path = directory.appendingPathComponent(name + ".json")
  try encoder.encode(results).write(to: path)
  let compiler = try ProcessRunner.run("/usr/bin/env", arguments: ["swift", "--version"])
  struct Runner: Encodable {
    let configuration: String
    let watchdogSeconds: Double
    let operatingSystem: String
    let compiler: String
  }
  let runner = Runner(
    configuration: probeConfiguration, watchdogSeconds: probeWatchdogSeconds,
    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, compiler: compiler.stdout
  )
  try encoder.encode(runner).write(
    to: directory.appendingPathComponent(name + "-runner.json"))
  print("MANIFEST_EVIDENCE \(path.path)")
}

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
