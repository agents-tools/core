import AgentsCore
import Foundation
import Testing

@testable import Components

private final class MCPAcceptanceBundle: NSObject {}

@Suite(.serialized) struct MCPConnectionAcceptanceTests {
  @Test func deadlineInterruptsBlockedInitializeWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-blocked-write-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var directory = Bundle(for: MCPAcceptanceBundle.self).bundleURL
    var executable: URL?
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("MCPTestProcess")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        executable = candidate
        break
      }
      directory.deleteLastPathComponent()
    }
    let program = try #require(executable)
    let configuration = DuplexProcessConfiguration(
      executable: program.path, arguments: ["blocked-input", root.path], directory: root,
      environment: ["PATH": "/usr/bin:/bin", "HOME": root.path])
    var limits = MCPConnectionLimits()
    limits.totalTimeout = 1
    limits.requestTimeout = 2
    limits.textBytes = 2_000_000
    limits.sentBytes = 4_000_000
    limits.frameBytes = 4_000_000
    limits.queueBytes = 4_000_000
    let started = ContinuousClock.now
    let result = await MCPConnectionRunner.run(
      .stdio(configuration),
      client: MCPConnectionClient(name: String(repeating: "x", count: 2_000_000), version: "1"),
      limits: limits)
    #expect(result.status == .failed(.timeout))
    #expect(result.cleanupComplete)
    #expect(started.duration(to: .now) < .seconds(4))
    let ready = root.appendingPathComponent("holder-ready")
    #expect(FileManager.default.fileExists(atPath: ready.path))
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("stdin-pending").path))
    let pidText = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
    let pid = try #require(Int32(pidText))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }
}
