import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite struct ProcessLimitsTests {
  private struct Probe {
    let soft: UInt64
    let hard: UInt64
    let after: UInt64
    let result: String
  }

  private func createSkillLocks(at root: URL, count: Int) throws {
    let store = StateStore(
      scope: .user,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
        environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path]
      ))
    for index in 0..<count {
      let route = try NativeTargetRoute.named(
        .claudeSkillPlugin, scope: .user, name: "generated-\(index)")
      let resource = try SharedResource(store: store, route: route, create: true)
      let metadata = try #require(resource.metadata)
      _ = try metadata.createPrivateFile("lock")
    }
  }

  private func runProbe(_ mode: String, at root: URL) throws -> Probe {
    let child = try stateTestProcess(
      root: root, arguments: ["open-file-limit", mode, "--scope", "user"])
    defer { terminateProcess(child) }
    try ProcessWait.exit(child, root: root, timeout: 30)
    try #require(child.terminationReason == .exit)
    try #require(child.terminationStatus == 0)
    let lines = try String(
      contentsOf: root.appendingPathComponent("open-file-limit-\(mode)"), encoding: .utf8
    ).split(separator: "\n")
    try #require(lines.count == 5)
    let soft = try #require(UInt64(lines[0]))
    let hard = try #require(UInt64(lines[1]))
    let after = try #require(UInt64(lines[2]))
    #expect(UInt64(lines[3]) == hard)
    return Probe(soft: soft, hard: hard, after: after, result: String(lines[4]))
  }

  private func checkLargeAdmission(_ probe: Probe, count: UInt64) {
    // The probe sets a comfortably sufficient budget of 4096 when testing the worker.
    // Below three pinned descriptors per route, the full footprint cannot fit.
    if probe.after >= 4096 {
      #expect(probe.result == "admitted")
    } else if probe.after < 3 * count {
      #expect(probe.result.hasPrefix("Too many open files for this process:"))
    }
  }

  @Test func executableOptInPreservesHardLimitAndUsesAvailableCapacity() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try createSkillLocks(at: root, count: 96)
    let original = try runProbe("original", at: root)
    #expect(original.after == original.soft)
    #expect(original.result.hasPrefix("Too many open files for this process:"))
    let raised = try runProbe("raised", at: root)
    #expect(raised.soft == original.soft)
    #expect(raised.after <= raised.hard)
    if raised.hard > raised.soft { #expect(raised.after > raised.soft) }
    checkLargeAdmission(raised, count: 96)
    let bounded = try runProbe("bounded", at: root)
    #expect(bounded.hard <= 64)
    #expect(bounded.after == bounded.hard)
    #expect(bounded.result.hasPrefix("Too many open files for this process:"))
  }

  @Test func heldSharedFootprintFitsBoundedWorkerStack() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try createSkillLocks(at: root, count: 196)
    let worker = try runProbe("worker", at: root)
    checkLargeAdmission(worker, count: 196)
  }
}
