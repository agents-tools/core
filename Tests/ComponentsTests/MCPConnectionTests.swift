import AgentsCore
import CPlatform
import Foundation
import Testing

@testable import Components

private final class MCPTestBundle: NSObject {}

private final class MCPFixture {
  let root: URL
  private var server: Process?
  static var executable: URL {
    var directory = Bundle(for: MCPTestBundle.self).bundleURL
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("MCPTestProcess")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      directory.deleteLastPathComponent()
    }
    return directory.appendingPathComponent("MCPTestProcess")
  }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-io-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var environment: [String: String] {
    [
      "PATH": MCPFixture.executable.deletingLastPathComponent().path + ":/usr/bin:/bin",
      "HOME": root.path, "FIXTURE_VALUE": "explicit-environment",
    ]
  }
  func input(_ mode: String, extra: [String: String] = [:]) -> MCPConnectionInput {
    .stdio(configuration(mode, extra: extra))
  }
  func configuration(_ mode: String, extra: [String: String] = [:]) -> DuplexProcessConfiguration {
    DuplexProcessConfiguration(
      executable: "MCPTestProcess", arguments: [mode, root.path], directory: root,
      environment: environment.merging(extra, uniquingKeysWith: { _, new in new }))
  }
  func text(_ name: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
  }
  func records() -> [[String: Any]] {
    (text("wire.jsonl") ?? "").split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
  }
  func methods() -> [String] { records().compactMap { $0["method"] as? String } }
  func waitFor(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return true
  }
  func startHTTP(_ mode: String) async throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let file = Bundle.module.url(
      forResource: "MCPHTTPServer", withExtension: "py", subdirectory: "Fixtures")!
    process.arguments = ["python3", file.path, mode, root.path]
    var environment = self.environment
    // Python is an existing test tool, not a downloaded service/client.
    environment["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    server = process
    guard await waitFor({ self.text("endpoint") != nil }),
      let endpoint = text("endpoint"), let url = URL(string: endpoint),
      url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port)
    else {
      throw MCPConnectionIssue.connectionFailed
    }
    return url
  }
  func stopHTTP() {
    if let server, server.isRunning {
      _ = kill(server.processIdentifier, SIGTERM)
      let deadline = Date().addingTimeInterval(2)
      while server.isRunning && Date() < deadline { usleep(1000) }
      if server.isRunning { _ = kill(server.processIdentifier, SIGKILL) }
      let killedDeadline = Date().addingTimeInterval(2)
      while server.isRunning && Date() < killedDeadline { usleep(1000) }
      if server.isRunning { Issue.record("Owned HTTP fixture did not terminate") }
    }
    server = nil
  }
  deinit {
    stopHTTP()
    try? FileManager.default.removeItem(at: root)
  }
}

private func runConnection(_ input: MCPConnectionInput, limits: MCPConnectionLimits = .init()) async
  -> MCPConnectionOutcome
{
  await MCPConnectionRunner.run(
    input, client: MCPConnectionClient(name: "fixture-client", version: "1"), limits: limits)
}

@Suite(.serialized) struct MCPConnectionTests {
  @Test func stdioDiscoversOnlyToolsAndInheritsExplicitValues() async throws {
    let fixture = try MCPFixture()
    let file = fixture.root.appendingPathComponent("lock")
    let original = open(file.path, O_RDWR | O_CREAT, 0o600)
    #expect(original >= 0)
    let high = fcntl(original, F_DUPFD, 200)
    defer {
      close(original)
      if high >= 0 { close(high) }
    }
    let result = await runConnection(fixture.input("normal", extra: ["FD_CHECK": String(high)]))
    #expect(result.status == .discovered)
    #expect(result.negotiatedVersion == "2025-11-25")
    #expect(result.tools.map(\.name) == ["first", "second"])
    #expect(result.cleanupComplete)
    #expect(
      fixture.methods() == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    let startup = try #require(fixture.records().first)
    let cwd = try #require(startup["cwd"] as? String)
    let actual = try FileManager.default.attributesOfItem(atPath: cwd)
    let expected = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
    #expect(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
    #expect(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
    #expect(startup["environment"] as? String == "explicit-environment")
    #expect(startup["inheritedFD"] as? Bool == false)
    let initialize = try #require(
      fixture.records().first { $0["method"] as? String == "initialize" })
    #expect(
      ((initialize["params"] as? [String: Any])?["capabilities"] as? [String: Any])?.isEmpty == true
    )
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test(arguments: ["wrong-version", "no-tools", "cursor-cycle", "stdout-flood", "stderr-flood"])
  func wireAndBudgetFailures(_ mode: String) async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    limits.frameBytes = 1024
    limits.stderrBytes = 1024
    let result = await runConnection(fixture.input(mode), limits: limits)
    let expected: MCPConnectionOutcome.Status
    switch mode {
    case "wrong-version": expected = .failed(.unsupportedVersion)
    case "no-tools": expected = .noTools
    case "cursor-cycle": expected = .incomplete(.cursorCycle)
    case "stdout-flood": expected = .failed(.messageLimit)
    default: expected = .failed(.stderrLimit)
    }
    #expect(result.status == expected)
    #expect(result.cleanupComplete)
    if mode == "wrong-version" { #expect(fixture.methods() == ["initialize"]) }
    if mode == "no-tools" {
      #expect(fixture.methods() == ["initialize", "notifications/initialized"])
    }
  }

  @Test(arguments: ["pending-initialize", "pending-tools"])
  func requestDeadlineActuallyReaps(_ mode: String) async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    limits.totalTimeout = 1
    limits.requestTimeout = 0.08
    let result = await runConnection(fixture.input(mode), limits: limits)
    #expect(
      result.status == (mode == "pending-initialize" ? .failed(.timeout) : .incomplete(.timeout)))
    #expect(result.cleanupComplete)
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1)
  }

  @Test func cancellationKillsStubbornChildAndLeavesSameNameProcess() async throws {
    let fixture = try MCPFixture()
    let unrelated = Process()
    let other = try MCPFixture()
    unrelated.executableURL = MCPFixture.executable
    unrelated.arguments = ["ignore-input", other.root.path]
    unrelated.environment = other.environment
    try unrelated.run()
    defer {
      _ = kill(unrelated.processIdentifier, SIGKILL)
      let deadline = Date().addingTimeInterval(2)
      while unrelated.isRunning && Date() < deadline { usleep(1000) }
      if unrelated.isRunning { Issue.record("Owned unrelated-process fixture did not terminate") }
    }
    #expect(await other.waitFor { other.text("holder-ready") != nil })
    let input = fixture.input("stubborn")
    let task = Task { await runConnection(input) }
    #expect(await fixture.waitFor { fixture.text("stubborn-ready") != nil })
    task.cancel()
    let result = await task.value
    #expect(result.status == .incomplete(.cancelled))
    #expect(result.cleanupComplete)
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1)
    #expect(unrelated.isRunning)
  }

  @Test func groupCleanupAfterLeaderEOFStopsDescendant() async throws {
    let fixture = try MCPFixture()
    let result = await runConnection(fixture.input("descendant"))
    #expect(result.status == .discovered)
    #expect(result.cleanupComplete)
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1)
    guard let child = fixture.text("descendant-pid").flatMap({ Int32($0) }) else {
      Issue.record("Missing owned descendant")
      return
    }
    #if os(Linux)
      let stat = try? String(contentsOfFile: "/proc/\(child)/stat", encoding: .utf8)
      #expect(stat == nil || stat!.split(separator: ")").last!.hasPrefix(" Z"))
    #else
      #expect(await fixture.waitFor { kill(child, 0) == -1 })
    #endif
  }

  #if os(Linux)
    @Test func zombieDescendantLeaderDoesNotHideItsLiveWorker() async throws {
      let fixture = try MCPFixture()
      let process = try OwnedDuplexProcess(fixture.configuration("thread-descendant"))
      func state(_ pid: Int32) -> (state: String, threads: Int)? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
          let delimiter = stat.lastIndex(of: ")")
        else { return nil }
        let fields = stat[stat.index(after: delimiter)...].split(separator: " ")
        guard fields.count > 17, let threads = Int(fields[17]) else { return nil }
        return (String(fields[0]), threads)
      }
      let ready = await fixture.waitFor {
        var exited = false
        guard platform_duplex_observe(process.identifier, &exited) == 0, exited,
          fixture.text("holder-ready") == "ready",
          let child = fixture.text("descendant-pid").flatMap({ Int32($0) }),
          let childState = state(child)
        else { return false }
        return childState.state == "Z" && childState.threads > 1
      }
      #expect(ready)
      var quiescent = true
      let observation = platform_duplex_group_quiescent(process.identifier, &quiescent)
      #expect(observation == 0)
      #expect(!quiescent)
      let cleaned = await process.finish(
        grace: .milliseconds(5), terminate: .milliseconds(5), killWait: .seconds(1))
      #expect(cleaned)
      #expect(kill(process.identifier, 0) == -1 && errno == ESRCH)
      if let child = fixture.text("descendant-pid").flatMap({ Int32($0) }) {
        let final = state(child)
        #expect(final == nil || (final!.state == "Z" && final!.threads == 1))
      } else {
        Issue.record("Missing owned multithreaded descendant")
      }
    }
  #endif

  @Test func blockedKernelPipeWriteIsNonblockingAndCleanupIsFinite() async throws {
    let fixture = try MCPFixture()
    let process = try OwnedDuplexProcess(fixture.configuration("ignore-input"))
    #expect(await fixture.waitFor { fixture.text("holder-ready") != nil })
    let bytes = Data(repeating: 120, count: 256 * 1024)
    var offset = 0
    while offset < bytes.count {
      let count = try process.write(bytes, offset: offset)
      if count == 0 { break }
      offset += count
    }
    #expect(offset < bytes.count)
    let cleaned = await process.finish(
      grace: .milliseconds(5), terminate: .milliseconds(5), killWait: .seconds(1))
    #expect(cleaned)
    #expect(kill(process.identifier, 0) == -1)
  }

  @Test func finiteDiscoveryAndInputAdmission() async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    limits.pages = 1
    let result = await runConnection(fixture.input("normal"), limits: limits)
    #expect(result.status == .incomplete(.pageLimit))
    #expect(result.tools.count == 1)
    #expect(fixture.methods().filter { $0 == "tools/list" }.count == 1)
    let originalWire = fixture.text("wire.jsonl")
    limits.totalTimeout = .infinity
    let invalid = await runConnection(fixture.input("normal"), limits: limits)
    #expect(invalid.status == .failed(.invalidInput))
    #expect(invalid.cleanupComplete)
    #expect(fixture.text("wire.jsonl") == originalWire)
  }

  @Test(arguments: ["tool", "text", "send"])
  func discoveryAndOutputBudgets(_ mode: String) async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    if mode == "tool" { limits.tools = 1 }
    if mode == "text" { limits.textBytes = 16 }
    if mode == "send" { limits.sentBytes = 64 }
    let input = fixture.input(mode == "text" ? "long-text" : "normal")
    let result = await runConnection(input, limits: limits)
    let expected: MCPConnectionOutcome.Status =
      mode == "tool"
      ? .incomplete(.toolLimit)
      : mode == "text" ? .incomplete(.textLimit) : .failed(.sendLimit)
    #expect(result.status == expected)
    #expect(result.cleanupComplete)
    if mode == "send" { #expect(fixture.methods().isEmpty) }
  }

  @Test(arguments: ["eof-initialize", "eof-tools"])
  func stdioEOFJoinsPendingRequestsAndDrainsAcceptedResponse(_ mode: String) async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    limits.frameBytes = 1024 * 1024
    limits.tools = 1000
    let result = await runConnection(fixture.input(mode), limits: limits)
    #expect(result.status == (mode == "eof-tools" ? .discovered : .failed(.connectionClosed)))
    #expect(result.cleanupComplete)
    if mode == "eof-tools" { #expect(result.tools.count == 1000) }
  }

  @Test func finalToolsResponseCannotMaskSameBurstAdmissionFailure() async throws {
    let fixture = try MCPFixture()
    var limits = MCPConnectionLimits()
    limits.frameBytes = 1024
    let result = await runConnection(fixture.input("final-response-limit"), limits: limits)
    #expect(result.status == .incomplete(.messageLimit))
    #expect(result.cleanupComplete)
    #expect(fixture.methods() == ["initialize", "notifications/initialized", "tools/list"])
  }

  @Test(arguments: ["json", "sse", "legacy", "resume"])
  func actualHTTPModesDiscoverAndCleanUp(_ mode: String) async throws {
    let fixture = try MCPFixture()
    let url = try await fixture.startHTTP(mode)
    let input: MCPConnectionInput =
      mode == "legacy" ? .legacySSE(url, headers: [:]) : .streamableHTTP(url, headers: [:])
    let result = await runConnection(input)
    #expect(result.status == .discovered)
    #expect(result.cleanupComplete)
    #expect(result.tools.map(\.name) == ["first", "second"])
    fixture.stopHTTP()
    #expect(
      fixture.methods() == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    if mode != "legacy" {
      let posts = fixture.records().filter { $0["http"] as? String == "POST" }
      #expect(
        posts.dropFirst().allSatisfy {
          $0["session"] as? String == "fixture-session" && $0["version"] as? String == "2025-11-25"
        })
    }
    if mode == "resume" {
      #expect(
        fixture.records().contains {
          $0["http"] as? String == "GET" && $0["lastEventID"] as? String == "1"
        })
    }
  }

  @Test(arguments: [
    "auth", "forbidden", "redirect", "legacy-cross", "event-flood", "comment-flood", "pending-body",
  ])
  func httpAuthorityAndStreamBounds(_ mode: String) async throws {
    let fixture = try MCPFixture()
    let url = try await fixture.startHTTP(mode)
    var limits = MCPConnectionLimits()
    limits.frameBytes = 1024
    limits.receivedBytes = 8192
    if mode == "event-flood" { limits.receivedBytes = 128 * 1024 }
    limits.totalTimeout = 0.12
    limits.requestTimeout = 1
    let headers = ["Authorization": "fixture-canary"]
    let input: MCPConnectionInput =
      mode.hasPrefix("legacy")
      ? .legacySSE(url, headers: headers) : .streamableHTTP(url, headers: headers)
    let result = await runConnection(input, limits: limits)
    let expected: MCPConnectionIssue
    switch mode {
    case "auth": expected = .authenticationRequired
    case "forbidden": expected = .forbidden
    case "redirect", "legacy-cross": expected = .authorityChanged
    case "event-flood": expected = .messageLimit
    case "comment-flood": expected = .receiveLimit
    default: expected = .timeout
    }
    #expect(result.status == .failed(expected))
    #expect(result.cleanupComplete)
    fixture.stopHTTP()
    #expect(fixture.records().filter { $0["http"] != nil }.count == 1)
  }
}
