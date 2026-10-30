import AgentsManifest
import Foundation
import StateTestSupport
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
        if checkpoint == TransactionCheckpoint.progress(1, .applied).name { throw Interrupted() }
      }
      for file in files {
        try transaction.replace(file.resolvingSymlinksInPath(), with: .data(Data("new".utf8)))
      }
      try transaction.replace(
        store.declarationURL, with: .data(manifestText("defaultAgents: [.codex]")))
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
    #expect(throws: CoreError.unsafePath("unmanaged project instruction path")) {
      try paths.components("instructions-project/other.md")
    }
    #expect(throws: CoreError.invalidState("invalid scope-relative transaction path")) {
      try paths.components("instructions-project/../AGENTS.md")
    }
    #expect(throws: CoreError.unsafePath("unmanaged installation transaction path")) {
      try paths.components("instructions-codex/AGENTS.md")
    }
    #expect(throws: CoreError.unsafePath("unmanaged project instruction path")) {
      try paths.components("instructions-project/.git/AGENTS.md")
    }
    #expect(throws: CoreError.unsafePath("unmanaged project instruction path")) {
      try paths.components("instructions-project/.agent/instructions/AGENTS.md")
    }
    #expect(throws: CoreError.unsafePath("unmanaged project instruction path")) {
      try paths.components("instructions-project/Sources/CLAUDE.md")
    }
    #expect(throws: Never.self) {
      try paths.components("instructions-project/Sources/Render/AGENTS.md")
    }
    #expect(throws: Never.self) { try paths.components("instructions-project/Sources/GEMINI.md") }
    #expect(throws: Never.self) {
      try paths.components("instructions-authoring/.agent/instructions/new-rules.md")
    }
    for path in [
      "instructions-authoring/new-rules.md", "instructions-authoring/.agent/new-rules.md",
      "instructions-authoring/.agent/instructions/epd/review.md",
      "instructions-authoring/.agent/instructions/Rules.md",
      "instructions-authoring/.agent/instructions/notes.txt",
    ] {
      #expect(throws: CoreError.unsafePath("invalid instruction authoring path")) {
        try paths.components(path)
      }
    }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("owner".utf8).write(to: outside.appendingPathComponent("CLAUDE.md"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".claude"), withDestinationURL: outside)
    try store.withLock {
      let transaction = FileTransaction(store: store)
      try transaction.replace(
        root.appendingPathComponent(".claude/CLAUDE.md"), with: .data(Data("new".utf8)))
      #expect {
        try transaction.commit()
      } throws: { error in
        guard case CoreError.unsafePath(let reason) = error else { return false }
        return reason.contains("unsafe directory") && reason.contains(".claude")
      }
    }
    #expect(
      try String(contentsOf: outside.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        == "owner")
  }
}
