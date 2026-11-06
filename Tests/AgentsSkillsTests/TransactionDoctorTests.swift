import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation
import Testing

@testable import AgentsCore

@Suite("Transaction conflict diagnostics")
struct TransactionDoctorTests {
  @Test func bothDoctorsReportOwnerActionAndPreservedLocationsWithoutReplay() throws {
    let fixture = try SkillFixture()
    let store = fixture.store()
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let target = fixture.environment.projectDirectory.appendingPathComponent("AGENTS.md")
    try Data("original".utf8).write(to: target)
    let saved = fixture.root.appendingPathComponent("saved-original")
    #expect(throws: CoreError.invalidState("interrupt after removing preimage")) {
      try store.withLock {
        let transaction = FileTransaction(store: store) { point in
          if point == TransactionCheckpoint.progress(0, .applied).name {
            let journal = try StateStore.decode(
              Data(contentsOf: store.directory.appendingPathComponent("transaction.json")),
              as: TransactionJournal.self)
            let backup = target.deletingLastPathComponent().appendingPathComponent(
              journal.containerName(0)
            ).appendingPathComponent(TransactionSlot.exchanged.name(0))
            try FileManager.default.moveItem(at: backup, to: saved)
            throw CoreError.invalidState("interrupt after removing preimage")
          }
        }
        try transaction.replace(target, with: .data(Data("published".utf8)))
        try transaction.commit()
      }
    }
    let before = try FileSnapshot.read(at: fixture.root)
    let skills = try SkillOperations.doctor(environment: fixture.environment)
    #expect(skills.checks.map(\.id) == ["unresolved-transaction"])
    let instructions = try InstructionOperations.doctor(environment: fixture.environment)
    #expect(instructions.diagnostics.map(\.kind) == [.unresolvedTransaction])
    for message in skills.checks.map(\.message) + instructions.diagnostics.map(\.message) {
      #expect(message.contains("owner action is required"))
      #expect(message.contains("expected slots: " + TransactionSlot.exchanged.name(0)))
      #expect(message.contains("instructions-project/AGENTS.md"))
      #expect(message.contains(".agents-"))
    }
    #expect(try FileSnapshot.read(at: fixture.root) == before)
  }

  @Test func equalBytesInAnotherTargetDescendantInvalidatePreparation() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "original")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let target = fixture.target("demo").appendingPathComponent("SKILL.md")
    let state = try FileSnapshot.read(at: fixture.store().resolvedURL)
    var replacement: FileSnapshot?
    #expect {
      try SkillOperations.updateInstalled(
        environment: fixture.environment, apply: true,
        beforeApply: { _ in
          let bytes = try Data(contentsOf: target)
          try bytes.write(to: target, options: .atomic)
          replacement = try FileSnapshot.read(at: target)
        })
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("target changed during preparation")
    }
    #expect(replacement != nil)
    #expect(try FileSnapshot.read(at: target) == replacement)
    #expect(try FileSnapshot.read(at: fixture.store().resolvedURL) == state)
  }

  @Test func instructionCallbackCannotReplacePreparedInodeWithEqualBytes() throws {
    let fixture = try SkillFixture()
    let root = fixture.environment.projectDirectory
    let own = root.appendingPathComponent(".agent/instructions")
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try Data("---\ndescription: Rules\n---\n\n# Rules\n\nOriginal\n".utf8)
      .write(to: own.appendingPathComponent("rules.md"))
    _ = try InstructionOperations.add(
      InstructionAddOptions(
        source: ".", names: ["rules"], agents: [.codex],
        environment: fixture.environment))
    let target = root.appendingPathComponent("AGENTS.md")
    let state = try FileSnapshot.read(at: fixture.store().resolvedURL)
    var external: FileSnapshot?
    #expect {
      try InstructionOperations.updateInstalled(environment: fixture.environment, apply: true) {
        _ in
        try Data(contentsOf: target).write(to: target, options: .atomic)
        external = try FileSnapshot.read(at: target)
      }
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("path changed during preparation")
    }
    #expect(try FileSnapshot.read(at: target) == external)
    #expect(try FileSnapshot.read(at: fixture.store().resolvedURL) == state)
  }
}
