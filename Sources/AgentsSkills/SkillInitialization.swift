import AgentsCore
import Foundation

package struct SkillInitialization: Sendable {
  package let store: StateStore
  package let root: ExistingProjectRoot
  package let file: URL
  private let resultDirectory: URL
  package let template: Data
  private let name: String?
  private let selectedChild: String?

  package init(
    named requestedName: String?, directory: URL, environment: RuntimeEnvironment,
    requiresExistingDirectory: Bool = false, validateState: Bool = true
  ) throws {
    let directory = directory.standardizedFileURL
    let canonicalName = requestedName.map(PathSafety.sanitizeName)
    resultDirectory = canonicalName.map { directory.appendingPathComponent($0) } ?? directory
    var environment = environment
    if requiresExistingDirectory || FileManager.default.fileExists(atPath: directory.path) {
      environment.projectDirectory = directory
      name = canonicalName
      selectedChild = nil
    } else {
      environment.projectDirectory = directory.deletingLastPathComponent()
      name = canonicalName
      selectedChild = directory.lastPathComponent
    }
    store = StateStore(scope: .project, environment: environment)
    root = try store.captureExistingProjectRoot()
    let observedDirectory = root.directory.resolvingSymlinksInPath()
    let selectedDirectory =
      selectedChild.map { observedDirectory.appendingPathComponent($0) }
      ?? observedDirectory
    file = (name.map { selectedDirectory.appendingPathComponent($0) } ?? selectedDirectory)
      .appendingPathComponent("SKILL.md")
    let title = canonicalName ?? PathSafety.sanitizeName(directory.lastPathComponent)
    template = Data(
      "---\nname: \(title)\ndescription: Describe when to use this skill\n---\n\n# \(title)\n\nWrite the skill instructions here.\n"
        .utf8)
    if validateState {
      try store.withReadLock {
        let target =
          try selectedChild.map {
            try store.skillInitializationTarget(inChildDirectory: $0, named: name)
          } ?? store.skillInitializationTarget(named: name)
        guard target.file == file else {
          throw CoreError.invalidState("skill initialization target changed")
        }
        _ = try store.declarationBytes()
        _ = try store.readLedger()
      }
    }
  }

  package func apply(outcome: TransactionOutcome, checkpoint: @escaping (String) throws -> Void)
    throws -> URL
  {
    try store.withLock(checkpoint: checkpoint, outcome: outcome, existingRoot: root) {
      _ = try store.declarationBytes()
      _ = try store.readLedger()
      let target =
        try selectedChild.map {
          try store.skillInitializationTarget(inChildDirectory: $0, named: name)
        } ?? store.skillInitializationTarget(named: name)
      guard target.file == file else {
        throw CoreError.invalidState("skill initialization target changed")
      }
      let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
      try transaction.initializeSkill(target, bytes: template)
      try transaction.commit()
      return resultDirectory
    }
  }
}
