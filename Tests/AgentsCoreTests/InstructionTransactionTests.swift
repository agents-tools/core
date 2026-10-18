import Foundation
import Testing

@testable import AgentsCore

@Suite("Instruction transaction destinations")
struct InstructionTransactionTests {
  @Test(arguments: [InstallScope.project, .user])
  func instructionFilesAndStateRollBackTogether(_ scope: InstallScope) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root, environment: [:])
    let store = StateStore(scope: scope, environment: environment)
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let files =
      scope == .project
      ? [
        root.appendingPathComponent("AGENTS.md"), root.appendingPathComponent(".claude/CLAUDE.md"),
      ]
      : AgentID.allCases.compactMap {
        InstructionLocations.file(for: $0, scope: scope, environment: environment)
      }
    for file in files {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("original".utf8).write(to: file)
    }
    let declaration = try Data(contentsOf: store.declarationURL)
    struct Interrupted: Error {}
    try store.withLock {
      let transaction = FileTransaction(store: store) { checkpoint in
        if checkpoint == "replace.1" { throw Interrupted() }
      }
      for file in files {
        try transaction.replace(
          file.resolvingSymlinksInPath(), content: nil, data: Data("new".utf8))
      }
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
      #expect(throws: Interrupted.self) { try transaction.commit() }
    }
    for file in files { #expect(try Data(contentsOf: file) == Data("original".utf8)) }
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
    #expect(
      !FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent("transaction.json").path))
  }

  @Test func journalRejectsUnregisteredInstructionPathsAndLinkedDescendants() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root, environment: [:])
    let store = StateStore(scope: .project, environment: environment)
    let paths = TransactionPaths(store: store)
    #expect(throws: (any Error).self) { try paths.components("instructions-project/other.md") }
    #expect(throws: (any Error).self) { try paths.components("instructions-project/../AGENTS.md") }
    #expect(throws: (any Error).self) { try paths.components("instructions-codex/AGENTS.md") }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("owner".utf8).write(to: outside.appendingPathComponent("CLAUDE.md"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".claude"), withDestinationURL: outside)
    try store.withLock {
      let transaction = FileTransaction(store: store)
      try transaction.replace(
        root.appendingPathComponent(".claude/CLAUDE.md"), content: nil, data: Data("new".utf8))
      #expect(throws: (any Error).self) { try transaction.commit() }
    }
    #expect(
      try String(contentsOf: outside.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        == "owner")
  }
}
