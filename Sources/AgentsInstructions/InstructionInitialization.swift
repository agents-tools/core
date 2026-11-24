import AgentsCore
import Foundation

package struct InstructionInitialization: Sendable {
  package let store: StateStore
  package let root: ExistingProjectRoot
  package let file: URL
  package let template: Data

  package init(named name: String, environment: RuntimeEnvironment, validateState: Bool = true)
    throws
  {
    guard Declaration.isInstructionName(name), !name.contains("/") else {
      throw CoreError.invalidSource(
        "instruction names use lowercase letters, digits and hyphens: \(name)")
    }
    store = StateStore(scope: .project, environment: environment)
    root = try store.captureExistingProjectRoot()
    file = root.directory.resolvingSymlinksInPath()
      .appendingPathComponent(InstructionSources.ownContainer).appendingPathComponent(name + ".md")
    template = Data(
      "---\ndescription: Describe what these instructions make the agent do.\n---\n# \(name)\n\nWrite the instructions here.\n"
        .utf8)
    _ = try Instructions.validateSource(template, id: name)
    if validateState {
      try store.withReadLock {
        _ = try store.declarationBytes()
        guard try InstructionTargets.read(file) == nil else {
          throw CoreError.invalidSource("instruction file already exists: \(file.path)")
        }
      }
    }
  }

  package func apply(outcome: TransactionOutcome, checkpoint: @escaping (String) throws -> Void)
    throws -> URL
  {
    try store.withLock(checkpoint: checkpoint, outcome: outcome, existingRoot: root) {
      _ = try store.declarationBytes()
      let evidence = try TargetPrecondition(file)
      guard try InstructionTargets.read(file) == nil else {
        throw CoreError.invalidSource("instruction file already exists: \(file.path)")
      }
      let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
      try transaction.replace(file, with: .data(template), expecting: evidence)
      try transaction.commit()
      return file
    }
  }
}
