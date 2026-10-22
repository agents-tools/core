import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation

/// Domain plans share resolution, but contribute only their owned records to the next generation.
final class UpdatePlan {
  let report: CombinedUpdateReport
  private let store: StateStore
  private let baseline: StatePrecondition
  private let declaration: Declaration
  private let previous: ResolvedState
  private let next: ResolvedState
  private let watch: WatchState
  private let skills: SkillUpdatePlan
  private let instructions: InstructionUpdatePlan
  private let resolutions: SourceResolutionSession
  private let checkpoint: (String) throws -> Void

  init(store: StateStore, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
    self.store = store
    self.checkpoint = checkpoint
    baseline = try StatePrecondition(store: store)
    declaration = try store.readDeclaration()
    previous = try store.readResolved()
    watch = try store.readWatch()
    resolutions = try SourceResolutionSession(store: store)
    skills = try SkillOperations.prepareUpdate(
      store: store, declaration: declaration, previous: previous, resolutions: resolutions)
    try checkpoint("plan.skills")
    instructions = try InstructionOperations.prepareUpdate(
      store: store, declaration: declaration, previousDeclaration: declaration,
      previous: previous, resolutions: resolutions)
    var next = previous
    next.skills = skills.next.skills
    next.instructions = instructions.next.instructions
    for (id, source) in skills.next.sources where source != previous.sources[id] {
      next.sources[id] = source
    }
    for (id, source) in instructions.next.sources where source != previous.sources[id] {
      if let other = skills.next.sources[id], other != previous.sources[id], other != source {
        throw CoreError.invalidState("incompatible planned source records: \(id)")
      }
      next.sources[id] = source
    }
    try declaration.validate(environment: store.environment)
    try next.validate()
    self.next = next
    let lockMissing = try store.existingData(store.resolvedURL) == nil
    report = CombinedUpdateReport(
      scope: store.scope, skills: skills.results, instructions: instructions.report,
      lockMissing: lockMissing,
      hasChanges: next.normalized != previous.normalized
        || skills.results.contains(where: \.changed) || instructions.report.hasChanges
        || (lockMissing && declaration.normalized != Declaration().normalized))
    try baseline.validate()
  }

  func validateOwnership() throws {
    try skills.validateOwnership()
    let paths = skills.targetPaths + instructions.report.targets.map(\.url)
    for (index, path) in paths.enumerated() {
      guard
        !paths.prefix(index).contains(where: {
          PathSafety.isContained(path, in: $0) || PathSafety.isContained($0, in: path)
        })
      else { throw CoreError.invalidState("overlapping update targets") }
    }
    try skills.validate()
    try instructions.validate()
  }

  func apply(outcome: TransactionOutcome) throws -> UpdateApplyResult {
    try validate()
    if report.hasChanges {
      let retained = try skills.retain()
      try instructions.retain()
      try checkpoint("apply.retained")
      try validate()
      let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
      try skills.stage(retained: retained, transaction: transaction)
      try instructions.stage(transaction: transaction)
      let declarationBytes = try StateStore.encode(declaration.normalized)
      if try store.existingData(store.declarationURL) != declarationBytes {
        try transaction.replace(store.declarationURL, content: nil, data: declarationBytes)
      }
      let resolvedBytes = try StateStore.encode(next.normalized)
      if try store.existingData(store.resolvedURL) != resolvedBytes {
        try transaction.replace(store.resolvedURL, content: nil, data: resolvedBytes)
      }
      try SourceCache(store: store).prune(
        referencedBy: next, watch: watch, transaction: transaction)
      try transaction.commit()
    }
    return UpdateApplyResult(report: report, installedSkills: skills.receipts)
  }

  private func validate() throws {
    try baseline.validate()
    try skills.validate()
    try instructions.validate()
  }

  func recover(outcome: TransactionOutcome) {
    do {
      _ = try FileTransaction.recover(store: store, outcome: outcome)
    } catch {
      outcome.disposition = .recoveryRequired
    }
  }
}
