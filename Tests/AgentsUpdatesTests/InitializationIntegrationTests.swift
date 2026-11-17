import AgentsInstructions
import AgentsSkills
import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsUpdates

@Suite struct InitializationIntegrationTests {
  @Test func descriptionsArePureAndCreationUsesExactTemplates() throws {
    let f = try UpdateFixture()
    let before = try FileSnapshot.read(at: f.root)
    let instruction = try UpdateOperations.describeInstructionsInitialization(
      named: "own", environment: f.environment)
    let skill = try UpdateOperations.describeSkillInitialization(
      named: "My Skill", directory: f.root, environment: f.environment)
    #expect(try FileSnapshot.read(at: f.root) == before)
    #expect(instruction.file == f.root.appendingPathComponent(".agent/instructions/own.md"))
    #expect(skill.file == f.root.appendingPathComponent("my-skill/SKILL.md"))
    for description in [instruction, skill] {
      let completion = UpdateOperations.initialize(description)
      #expect(completion.disposition == .committed && !completion.recovery.pending)
      _ = try completion.result.get()
      #expect(try String(contentsOf: description.file, encoding: .utf8) == description.template)
      let duplicate = UpdateOperations.initialize(description)
      #expect(duplicate.disposition == .unchanged && !duplicate.recovery.pending)
      #expect(throws: (any Error).self) { try duplicate.result.get() }
    }
  }

  @Test func absentStandaloneDirectoryUsesItsExistingParent() throws {
    let f = try UpdateFixture()
    let directory = f.root.appendingPathComponent("My Selected Skill")
    let description = try UpdateOperations.describeSkillInitialization(
      directory: directory, environment: f.environment)
    #expect(description.existingRoot.path == f.root.path)
    #expect(description.file == directory.appendingPathComponent("SKILL.md"))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(try UpdateOperations.initialize(description).result.get().path == directory.path)
  }

  @Test func namedSkillUnderAbsentSelectedDirectoryCapturesBothLevels() throws {
    let f = try UpdateFixture()
    let directory = f.root.appendingPathComponent("Chosen Directory")
    let before = try FileSnapshot.read(at: f.root)
    let description = try UpdateOperations.describeSkillInitialization(
      named: "My Skill", directory: directory, environment: f.environment)
    #expect(description.existingRoot.path == f.root.path)
    #expect(description.file == directory.appendingPathComponent("my-skill/SKILL.md"))
    #expect(try FileSnapshot.read(at: f.root) == before)
    let completion = UpdateOperations.initialize(description)
    let result = try completion.result.get()
    #expect(result.path == directory.appendingPathComponent("my-skill").path)
    #expect(completion.disposition == .committed && !completion.recovery.pending)
    #expect(try String(contentsOf: description.file, encoding: .utf8) == description.template)
  }

  @Test(arguments: [false, true])
  func missingOrReplacedObservedProjectIsNeverRecreated(_ replace: Bool) throws {
    let f = try UpdateFixture()
    let selected = f.root.appendingPathComponent("selected")
    let moved = f.root.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
    var environment = f.environment
    environment.projectDirectory = selected
    let description = try UpdateOperations.describeInstructionsInitialization(
      named: "own", environment: environment)
    let skill = try UpdateOperations.describeProjectSkillInitialization(
      named: "new", environment: environment)
    try FileManager.default.moveItem(at: selected, to: moved)
    if replace {
      try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
    }
    let completion = UpdateOperations.initialize(description)
    #expect(completion.disposition == .unchanged)
    let skillCompletion = UpdateOperations.initialize(skill)
    #expect(skillCompletion.disposition == .unchanged)
    #expect(throws: (any Error).self) { try skillCompletion.result.get() }
    if !replace {
      #expect(throws: (any Error).self) {
        try UpdateOperations.describeProjectSkillInitialization(environment: environment)
      }
    }
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(FileManager.default.fileExists(atPath: selected.path) == replace)
    #expect(!FileManager.default.fileExists(atPath: selected.appendingPathComponent(".agent").path))
    #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent(".agent").path))
  }

  @Test(arguments: [false, true])
  func actualPublicationAndFailedRecoveryKeepDistinctOuterOutcomes(_ committed: Bool) throws {
    let f = try UpdateFixture()
    let description = try UpdateOperations.describeInstructionsInitialization(
      named: "own", environment: f.environment)
    let parent = description.file.deletingLastPathComponent()
    let displaced = f.root.appendingPathComponent("displaced-instructions")
    let stop =
      committed
      ? TransactionCheckpoint.phase(.committed).name
      : TransactionCheckpoint.progress(0, .applied).name
    let completion = UpdateOperations.initialize(description) { point in
      if point == stop {
        try FileManager.default.moveItem(at: parent, to: displaced)
        throw CoreError.invalidState("fixture publication interruption")
      }
    }
    #expect(completion.disposition == (committed ? .committed : .recoveryRequired))
    #expect(completion.recovery.pending)
    #expect(throws: (any Error).self) { try completion.result.get() }
    #expect(
      try String(contentsOf: displaced.appendingPathComponent("own.md"), encoding: .utf8)
        == description.template)
    let blocked = UpdateOperations.initialize(description)
    #expect(blocked.disposition == .unchanged && blocked.recovery.pending)
    #expect(!blocked.recoveredBeforePreparation)
    #expect(throws: (any Error).self) { try blocked.result.get() }
    try FileManager.default.moveItem(at: displaced, to: parent)
    let recovered = UpdateOperations.initialize(description)
    #expect(recovered.disposition == .unchanged && recovered.recoveredBeforePreparation)
    #expect(!recovered.recovery.pending)
    #expect(FileManager.default.fileExists(atPath: description.file.path) == committed)
  }

  @Test func rollbackTerminalSurvivesMovedScopeAndPendingDisposal() throws {
    let f = try UpdateFixture()
    let description = try UpdateOperations.describeInstructionsInitialization(
      named: "own", environment: f.environment)
    let moved = f.root.deletingLastPathComponent().appendingPathComponent(
      f.root.lastPathComponent + "-moved")
    let completion = UpdateOperations.initialize(description) { point in
      if point == TransactionCheckpoint.publication(0, .created).name {
        throw CoreError.invalidState("fixture rollback")
      }
      if point == "recovery." + TransactionCheckpoint.phase(.rolledBack).name {
        try FileManager.default.moveItem(at: f.root, to: moved)
        throw CoreError.invalidState("fixture cleanup unavailable")
      }
    }
    #expect(completion.disposition == .rolledBack && completion.recovery.pending)
    #expect(!FileManager.default.fileExists(atPath: description.file.path))
    try FileManager.default.moveItem(at: moved, to: f.root)
    let recovered = UpdateOperations.initialize(description)
    #expect(recovered.recoveredBeforePreparation && !recovered.recovery.pending)
  }

  @Test func stagingFailureIsUnchangedWithoutACommittedFile() throws {
    let f = try UpdateFixture()
    let description = try UpdateOperations.describeSkillInitialization(
      named: "new", directory: f.root, environment: f.environment)
    let completion = UpdateOperations.initialize(description) { point in
      if point == TransactionCheckpoint.stage(0, .constructed).name {
        throw CoreError.invalidState("fixture staging failure")
      }
    }
    #expect(completion.disposition == .unchanged && !completion.recovery.pending)
    #expect(!FileManager.default.fileExists(atPath: description.file.path))
  }
}
