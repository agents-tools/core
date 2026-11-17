import AgentsCore
import AgentsUpdates
import Foundation
import Testing

private final class MCPFacadeBundle: NSObject {}

/// Only the call list mutates, under lock; values are immutable fixture input.
final class MCPBindingSpy: RuntimeBindingProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  let values: [String: Data]
  let delay: TimeInterval
  init(_ values: [String: Data] = [:], delay: TimeInterval = 0) {
    self.values = values
    self.delay = delay
  }
  var calls: [String] { lock.withLock { names } }
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    lock.withLock { names.append(binding) }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    guard let value = values[binding] else { throw MCPConnectionPreparationError.invalidSelection }
    return value
  }
}

private struct MCPRemovingDirectoryProvider: RuntimeBindingProvider {
  let directory: URL
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    try FileManager.default.removeItem(at: directory)
    return Data("unused-after-path-removal".utf8)
  }
}

final class MCPFacadeFixture {
  let root: URL
  let observation: URL
  let environment: RuntimeEnvironment
  static var executable: URL {
    var directory = Bundle(for: MCPFacadeBundle.self).bundleURL
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("MCPTestProcess")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      directory.deleteLastPathComponent()
    }
    return directory.appendingPathComponent("MCPTestProcess")
  }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-facade-" + UUID().uuidString)
    observation = root.appendingPathComponent("observed")
    environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
      environment: [
        "PATH": Self.executable.deletingLastPathComponent().path + ":/usr/bin:/bin",
        "SELECTED_ENV": "environment-canary",
      ])
    try FileManager.default.createDirectory(at: observation, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".agent"), withIntermediateDirectories: true)
    try Data("untouched declaration".utf8).write(
      to: root.appendingPathComponent(".agent/agents.yaml"))
    try Data("untouched ledger".utf8).write(
      to: root.appendingPathComponent(".agent/agents.resolved"))
  }
  func snapshot(
    _ mode: String = "normal", selection: String = "source-a/same-name",
    values: [String: RuntimeBinding] = [:]
  ) throws -> MCPConnectionSnapshot {
    try MCPConnectionOperations.snapshot(
      selectionID: selection,
      transport: .stdio(
        .init(
          executable: "MCPTestProcess", arguments: [mode, observation.path], environment: values)),
      workingDirectory: .live(root))
  }
  func text(_ path: String) -> String? {
    try? String(contentsOf: observation.appendingPathComponent(path), encoding: .utf8)
  }
  func waitFor(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return true
  }
  func unchanged() throws {
    #expect(
      try String(contentsOf: root.appendingPathComponent(".agent/agents.yaml"), encoding: .utf8)
        == "untouched declaration")
    #expect(
      try String(contentsOf: root.appendingPathComponent(".agent/agents.resolved"), encoding: .utf8)
        == "untouched ledger")
  }
  deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct MCPConnectionOperationsTests {
  @Test func describeIsPureAndExactSelectionUsesOnlyNecessaryBindings() async throws {
    let fixture = try MCPFacadeFixture()
    let spy = MCPBindingSpy([
      "wanted": Data("provider-canary".utf8), "controlled": Data("control-\ncanary".utf8),
    ])
    let selected = try fixture.snapshot(
      "facade",
      values: [
        "FACADE_SECRET": .secret("wanted"), "SECOND_SECRET": .secret("wanted"),
        "FACADE_LITERAL": .literal("literal-canary"), "FACADE_ENV": .environment("SELECTED_ENV"),
        "FACADE_CONTROLLED": .secret("controlled"),
      ])
    let other = try fixture.snapshot(
      "wrong-version", selection: "source-b/same-name", values: ["UNUSED": .secret("unused")])
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
    let description = MCPConnectionOperations.describe(selected)
    #expect(description.snapshotID == selected.id && selected.id != other.id)
    #expect(description.startsOwnedProcess)
    #expect(description.requiredBindings == ["controlled", "wanted"])
    #expect(description.environmentBindings == ["SELECTED_ENV"])
    #expect(spy.calls.isEmpty && fixture.text("pid") == nil)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
    #expect(Mirror(reflecting: selected).children.isEmpty)
    #expect(!String(reflecting: selected).contains("literal-canary"))
    let result = await MCPConnectionOperations.test(
      selected, environment: fixture.environment, bindings: spy)
    #expect(result.snapshotID == selected.id)
    #expect(result.outcome == .discovered && result.issue == nil)
    #expect(result.cleanupComplete && result.startedAt <= result.finishedAt)
    #expect(result.elapsed >= 0 && result.transport == .stdio)
    #expect(result.tools.map(\.name) == ["first", "second"])
    #expect(spy.calls == ["controlled", "wanted"])
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    for secret in [
      "provider-canary", "control-canary", "literal-canary", "environment-canary",
      fixture.root.path,
    ] {
      #expect(!encoded.contains(secret))
    }
    #expect(result.tools.allSatisfy { $0.description?.contains("[redacted]") == true })
    #expect(
      result.tools.allSatisfy {
        $0.description?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
          == false
      })
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    try fixture.unchanged()
  }

  @Test func confirmationShowsFixedCommandAndSafeEndpointWithoutEffects() throws {
    let fixture = try MCPFacadeFixture()
    let live = try MCPConnectionResource.live(fixture.root)
    let snapshot = try MCPConnectionOperations.snapshot(
      selectionID: "description-only",
      transport: .stdio(
        .init(
          executable: "safe-command", arguments: ["--mode", "read-only", "literal-\ncanary", "é"],
          environment: ["TOKEN": .literal("literal-canary"), "SECRET": .secret("named-secret")])),
      workingDirectory: live)
    let before = try FileHash.folderHash(fixture.root)
    let description = MCPConnectionOperations.describe(snapshot)
    #expect(description.executable == "safe-command")
    #expect(description.arguments == ["--mode", "read-only", "[redacted]", "é"])
    #expect(description.workingDirectory == fixture.root.path)
    #expect(!description.workingDirectoryIsCaptured && !description.executableIsCaptured)
    #expect(description.endpoint == nil && description.startsOwnedProcess)
    #expect(description.requiredBindings == ["named-secret"])
    #expect(description.readLocations == snapshot.readLocations)
    #expect(snapshot.readLocations.contains { $0.path == fixture.root.path })
    #expect(try FileHash.folderHash(fixture.root) == before && fixture.text("pid") == nil)
    for transport: MCPTransportDeclaration in [
      .sse(
        url: "http://127.0.0.1:1/private-path?token=query-canary",
        headers: [
          "Authorization": .literal("header-canary"), "X-Secret": .secret("remote-secret"),
        ]),
      .streamableHTTP(url: "http://127.0.0.1:1/private-path?token=query-canary", headers: [:]),
    ] {
      // Projection only. No test() call is admitted for these endpoint values.
      let remote = try MCPConnectionOperations.snapshot(selectionID: "remote", transport: transport)
      let info = MCPConnectionOperations.describe(remote)
      #expect(info.endpoint == "http://127.0.0.1:1/[redacted]")
      #expect(!info.startsOwnedProcess && info.executable == nil && info.arguments == nil)
      #expect(info.workingDirectory == nil && info.readLocations.isEmpty)
      let text = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
      for hidden in ["private-path", "query-canary", "header-canary"] {
        #expect(!text.contains(hidden))
      }
    }
    let credentialInOrigin = try MCPConnectionOperations.snapshot(
      selectionID: "header-redaction-only",
      transport: .sse(
        url: "http://127.0.0.1:1/mcp",
        headers: [
          "Authorization": .literal("Bearer 127.0.0.1")
        ]))
    #expect(
      MCPConnectionOperations.describe(credentialInOrigin).endpoint
        == "http://[redacted]:1/[redacted]")
    let long = try MCPConnectionOperations.snapshot(
      selectionID: "bounded",
      transport: .stdio(
        .init(
          executable: "safe-command", arguments: ["a" + String(repeating: "é", count: 20_000)])),
      workingDirectory: live)
    let projected = try #require(MCPConnectionOperations.describe(long).arguments?.first)
    #expect(projected.utf8.count == 4095 && projected.hasPrefix("a"))
    #expect(String(data: Data(projected.utf8), encoding: .utf8) != nil)
    #expect(fixture.text("pid") == nil)
    try FileManager.default.removeItem(at: fixture.root)
    #expect(MCPConnectionOperations.describe(snapshot) == description)
  }

  @Test func invalidOptionsAndUnavailableEnvironmentDoNotConsultProvider() async throws {
    let fixture = try MCPFacadeFixture()
    let spy = MCPBindingSpy()
    let snapshot = try fixture.snapshot(values: ["TOKEN": .secret("unused")])
    var options = MCPConnectionTestOptions()
    options.totalTimeout = .infinity
    let invalid = await MCPConnectionOperations.test(
      snapshot, options: options, environment: fixture.environment, bindings: spy)
    #expect(invalid.issue == .invalidInput && invalid.cleanupComplete)
    let missing = try fixture.snapshot(values: [
      "TOKEN": .secret("unused"), "MISSING": .environment("MISSING"),
    ])
    let unavailable = await MCPConnectionOperations.test(
      missing, environment: fixture.environment, bindings: spy)
    #expect(unavailable.issue == .bindingUnavailable && unavailable.cleanupComplete)
    #expect(spy.calls.isEmpty && fixture.text("pid") == nil)
    let cancelled = Task { [environment = fixture.environment] in
      withUnsafeCurrentTask { $0?.cancel() }
      return await MCPConnectionOperations.test(
        snapshot, environment: environment, bindings: spy)
    }
    #expect(await cancelled.value.issue == .cancelled)
    #expect(spy.calls.isEmpty)
    // This bounded synchronous provider deliberately consumes the total budget.
    let slow = MCPBindingSpy(["unused": Data("deadline-canary".utf8)], delay: 0.03)
    options.totalTimeout = 0.001
    let expired = await MCPConnectionOperations.test(
      snapshot, options: options, environment: fixture.environment, bindings: slow)
    #expect(expired.issue == .timeout && expired.cleanupComplete)
    #expect(slow.calls == ["unused"] && fixture.text("pid") == nil)
    try fixture.unchanged()
  }

  @Test func invalidHeaderBindingsFailBeforeNetworkWithoutLeakingValues() async throws {
    let fixture = try MCPFacadeFixture()
    let snapshot = try MCPConnectionOperations.snapshot(
      selectionID: "fixed-remote",
      transport: .streamableHTTP(
        url: "http://127.0.0.1:1/mcp", headers: ["Authorization": .secret("token")]))
    let spy = MCPBindingSpy(["token": Data("credential-canary\r\nInjected: value".utf8)])
    let result = await MCPConnectionOperations.test(
      snapshot, environment: fixture.environment, bindings: spy)
    #expect(result.issue == .invalidBinding && result.cleanupComplete)
    #expect(spy.calls == ["token"])
    #expect(
      !String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(
        "credential-canary"))
    #expect(throws: MCPConnectionPreparationError.invalidConfiguration) {
      try MCPConnectionOperations.snapshot(
        selectionID: "invalid",
        transport: .sse(url: "http://127.0.0.1/mcp", headers: ["bad\nkey": .secret("unused")]))
    }
    for headers: [String: RuntimeBinding] in [
      ["MCP-Session-ID": .secret("unused")],
      ["Authorization": .secret("one"), "authorization": .secret("two")],
      ["Authorization": .secret("")],
    ] {
      #expect(throws: MCPConnectionPreparationError.invalidConfiguration) {
        try MCPConnectionOperations.snapshot(
          selectionID: "invalid", transport: .sse(url: "http://127.0.0.1/mcp", headers: headers))
      }
    }
    try fixture.unchanged()
  }

  @Test func capturedBorrowedResourcesSurviveCancellationUntilOwnedCleanup() async throws {
    let fixture = try MCPFacadeFixture()
    let borrowed = fixture.root.appendingPathComponent("borrowed")
    try FileManager.default.createDirectory(at: borrowed, withIntermediateDirectories: false)
    let tool = borrowed.appendingPathComponent("tool")
    try FileManager.default.copyItem(at: MCPFacadeFixture.executable, to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let content = borrowed.appendingPathComponent("content")
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
    try Data("required-support".utf8).write(to: content.appendingPathComponent("support"))
    let directoryLink = borrowed.appendingPathComponent("cwd")
    try FileManager.default.createSymbolicLink(
      atPath: directoryLink.path, withDestinationPath: "content")
    let executable = try MCPConnectionResource.capture(
      sourceRoot: borrowed, path: "tool",
      expectedHash: "sha256:" + FileHash.sha256Hex(file: tool), expectedExecutableFiles: [".": true]
    )
    let cwd = try MCPConnectionResource.capture(
      sourceRoot: borrowed, path: "cwd",
      expectedHash: "sha256:" + FileHash.folderHash(directoryLink),
      expectedExecutableFiles: FileHash.executableFlags(directoryLink))
    let snapshot = try MCPConnectionOperations.snapshot(
      selectionID: "fixed-source/entry",
      transport: .stdio(
        .init(executable: "./tool", arguments: ["stubborn", fixture.observation.path])),
      workingDirectory: cwd, executable: executable)
    try FileManager.default.removeItem(at: borrowed)
    let spy = MCPBindingSpy()
    let task = Task { [environment = fixture.environment] in
      await MCPConnectionOperations.test(snapshot, environment: environment, bindings: spy)
    }
    let ready = await fixture.waitFor { fixture.text("stubborn-ready") != nil }
    #expect(ready)
    let records = (fixture.text("wire.jsonl") ?? "").split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
    let staged = records.first?["cwd"] as? String
    if let staged {
      #expect(FileManager.default.fileExists(atPath: staged + "/support"))
      #expect(!staged.hasPrefix(borrowed.path))
    } else {
      Issue.record("Missing owned resource working directory")
    }
    task.cancel()
    let result = await task.value
    #expect(result.issue == .cancelled && result.cleanupComplete)
    #expect(result.outcome == .incomplete)
    if let staged { #expect(!FileManager.default.fileExists(atPath: staged)) }
    let pid = try #require(Int32(fixture.text("pid") ?? ""))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(spy.calls.isEmpty)
    try fixture.unchanged()
  }

  @Test func replacedLiveDirectoryRequiresNewSnapshotBeforeBinding() async throws {
    let fixture = try MCPFacadeFixture()
    let live = fixture.root.appendingPathComponent("live")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false)
    let snapshot = try MCPConnectionOperations.snapshot(
      selectionID: "live-entry",
      transport: .stdio(
        .init(
          executable: "MCPTestProcess", arguments: ["normal", fixture.observation.path],
          environment: ["TOKEN": .secret("unused")])), workingDirectory: .live(live))
    try FileManager.default.moveItem(at: live, to: fixture.root.appendingPathComponent("old-live"))
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false)
    let spy = MCPBindingSpy()
    let result = await MCPConnectionOperations.test(
      snapshot, environment: fixture.environment, bindings: spy)
    #expect(result.issue == .resourceChanged && result.cleanupComplete)
    #expect(spy.calls.isEmpty && fixture.text("pid") == nil)
    let selected = try MCPConnectionOperations.snapshot(
      selectionID: "live-entry",
      transport: .stdio(
        .init(executable: "MCPTestProcess", environment: ["TOKEN": .secret("remove-directory")])),
      workingDirectory: .live(live))
    let removedDuringBinding = await MCPConnectionOperations.test(
      selected, environment: fixture.environment,
      bindings: MCPRemovingDirectoryProvider(directory: live))
    #expect(removedDuringBinding.issue == .resourceChanged && removedDuringBinding.cleanupComplete)
    #expect(!FileManager.default.fileExists(atPath: live.path) && fixture.text("pid") == nil)
    try fixture.unchanged()
  }
}
