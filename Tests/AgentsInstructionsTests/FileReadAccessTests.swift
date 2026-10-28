import AgentsCore
import Foundation
import Testing

@testable import AgentsInstructions

@Suite(
  "Instruction file read access",
  .enabled(if: geteuid() != 0, "Permission-denial checks require an unprivileged user"),
  .timeLimit(.minutes(1)))
struct InstructionFileReadAccessTests {
  @Test func unreadableTargetReportsItsPath() throws {
    let fixture = try InstructionFixture()
    let file = fixture.project.appendingPathComponent("AGENTS.md")
    try fixture.write("User content", to: file)
    let before = try fixture.snapshot()
    try withUnreadableFile(file) {
      #expect(throws: accessError(file)) { try InstructionTargets.read(file) }
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func unreadableOwnInstructionsReportTheirPath() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    let file = fixture.project.appendingPathComponent(".agent/instructions/guide.md")
    let before = try fixture.snapshot()
    try withUnreadableFile(file) {
      #expect {
        try InstructionOperations.listOwn(environment: fixture.environment)
      } throws: { error in
        guard case CoreError.invalidState(let message) = error else { return false }
        let prefix = "permission denied: "
        let suffix = "; check the directory's permissions and default ACL"
        guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return false }
        let path = String(message.dropFirst(prefix.count).dropLast(suffix.count))
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
          == file.resolvingSymlinksInPath()
      }
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test(arguments: ["config", "target"])
  func doctorReportsUnreadableFiles(_ kind: String) throws {
    let fixture = try InstructionFixture()
    let file =
      kind == "config"
      ? fixture.home.appendingPathComponent(".codex/config.toml")
      : fixture.project.appendingPathComponent("AGENTS.md")
    try fixture.write("", to: file)
    let before = try fixture.snapshot()
    try withUnreadableFile(file) {
      let report = try InstructionOperations.doctor(environment: fixture.environment)
      #expect(
        report.diagnostics.contains {
          $0.path == file && $0.message.contains(accessError(file).description)
        })
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func doctorReportsAnUnreadableManagedTargetOnce() throws {
    let fixture = try InstructionFixture()
    try fixture.own("guide")
    try fixture.addOwn(names: ["guide"], agents: [.codex])
    let file = fixture.project.appendingPathComponent("AGENTS.md")
    try withUnreadableFile(file) {
      let report = try InstructionOperations.doctor(environment: fixture.environment)
      #expect(report.diagnostics.filter { $0.message.contains("permission denied: ") }.count == 1)
    }
  }
}

private func accessError(_ file: URL) -> CoreError {
  .invalidState(
    "permission denied: \(file.path); check the directory's permissions and default ACL")
}

private func withUnreadableFile(_ file: URL, _ body: () throws -> Void) throws {
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  let mode = try #require(attributes[.posixPermissions] as? NSNumber)
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
  defer {
    do {
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    } catch { Issue.record(error) }
  }
  for _ in 0..<2 {
    try body()
    let current = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((current[.posixPermissions] as? NSNumber)?.intValue == 0)
    #expect(current[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber)
  }
}
