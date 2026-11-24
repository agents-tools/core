import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite struct ProcessLimitsTests {
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

  @Test func executableOptInPreservesHardLimitAndAdmitsLargeScope() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try createSkillLocks(at: root, count: 96)
    func run(_ mode: String) throws -> (soft: UInt64, hard: UInt64, raised: UInt64, result: String)
    {
      let child = try stateTestProcess(
        root: root, arguments: ["open-file-limit", mode, "--scope", "user"])
      defer { terminateProcess(child) }
      try ProcessWait.exit(child, root: root, timeout: 30)
      try #require(child.terminationStatus == 0)
      let lines = try String(
        contentsOf: root.appendingPathComponent("open-file-limit-\(mode)"), encoding: .utf8
      ).split(separator: "\n")
      try #require(lines.count == 5)
      let soft = try #require(UInt64(lines[0]))
      let hard = try #require(UInt64(lines[1]))
      let raised = try #require(UInt64(lines[2]))
      #expect(UInt64(lines[3]) == hard)
      return (soft, hard, raised, String(lines[4]))
    }
    let original = try run("original")
    #expect(original.raised == original.soft)
    #expect(original.result.hasPrefix("Too many open files for this process:"))
    let raised = try run("raised")
    #expect(raised.soft == original.soft)
    if raised.hard > 256 {
      #expect(raised.raised > 256)
      #expect(raised.result == "admitted")
    }
    let bounded = try run("bounded")
    #expect(bounded.hard <= 64)
    #expect(bounded.raised == bounded.hard)
    #expect(bounded.result.hasPrefix("Too many open files for this process:"))
  }

  @Test func heldSharedFootprintFitsBoundedWorkerStack() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try createSkillLocks(at: root, count: 196)
    let child = try stateTestProcess(
      root: root, arguments: ["open-file-limit", "worker", "--scope", "user"])
    defer { terminateProcess(child) }
    try ProcessWait.exit(child, root: root, timeout: 30)
    #expect(child.terminationReason == .exit)
    #expect(child.terminationStatus == 0)
  }
}
