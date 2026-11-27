import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation

/// A pure local authoring request. Its existing root identity is retained through publication.
public struct InitializationDescription: Sendable {
  public enum Kind: String, Sendable { case skill, instructions }
  public let kind: Kind
  public let file: URL
  public let template: String
  public let existingRoot: URL
  public let readLocations: [URL]
  private enum Request: Sendable {
    case skill(SkillInitialization)
    case instructions(InstructionInitialization)
  }
  private let request: Request
  let store: StateStore

  init(skill: SkillInitialization) {
    kind = .skill
    request = .skill(skill)
    store = skill.store
    file = skill.file
    existingRoot = skill.root.directory
    template = String(decoding: skill.template, as: UTF8.self)
    readLocations = [existingRoot, file, store.declarationURL, store.resolvedURL, store.watchURL]
  }

  init(instructions: InstructionInitialization) {
    kind = .instructions
    request = .instructions(instructions)
    store = instructions.store
    file = instructions.file
    existingRoot = instructions.root.directory
    template = String(decoding: instructions.template, as: UTF8.self)
    readLocations = [existingRoot, file, store.declarationURL, store.resolvedURL, store.watchURL]
  }

  func apply(outcome: TransactionOutcome, checkpoint: @escaping (String) throws -> Void) throws
    -> URL
  {
    switch request {
    case .skill(let skill): return try skill.apply(outcome: outcome, checkpoint: checkpoint)
    case .instructions(let instructions):
      return try instructions.apply(outcome: outcome, checkpoint: checkpoint)
    }
  }
}

extension UpdateOperations {
  public static func describeInstructionsInitialization(
    named name: String, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InitializationDescription {
    .init(instructions: try InstructionInitialization(named: name, environment: environment))
  }

  /// Creates in a registered project, which must already exist even during description.
  public static func describeProjectSkillInitialization(
    named name: String? = nil, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InitializationDescription {
    .init(
      skill: try SkillInitialization(
        named: name, directory: environment.projectDirectory, environment: environment,
        requiresExistingDirectory: true))
  }

  /// Explicit standalone authoring. The selected directory may be absent when its immediate parent already exists.
  public static func describeSkillInitialization(
    named name: String? = nil, directory: URL,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> InitializationDescription {
    .init(
      skill: try SkillInitialization(named: name, directory: directory, environment: environment))
  }

  /// Returns after all executing resources are released, including on retained journal recovery.
  public static func initialize(_ description: InitializationDescription) -> UpdateCompletion<URL> {
    initialize(description, checkpoint: { _ in })
  }

  package static func initialize(
    _ description: InitializationDescription, checkpoint: @escaping (String) throws -> Void
  ) -> UpdateCompletion<URL> {
    let outcome = TransactionOutcome()
    var recovered = false
    let result = Result {
      do { return try description.apply(outcome: outcome, checkpoint: checkpoint) } catch {
        if case CoreError.transactionRecovered = error { recovered = true }
        throw error
      }
    }
    return completion(result, outcome: outcome, recovered: recovered, store: description.store)
  }
}
