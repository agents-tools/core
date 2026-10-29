import AgentsCore
import Foundation

/// A domain plan borrows the scope lock and never commits or prunes independently.
package final class SkillUpdatePlan {
  package let next: ResolvedState
  package let results: [UpdateResult]
  package let targetPaths: [URL]
  private let lifecycle: SkillLifecycle
  private let previous: ResolvedState
  private let prepared: [String: PreparedSkill]
  private let names: Set<String>
  private let before: [TargetPrecondition]
  private let linkedInputs: [TargetPrecondition]
  private let recipientPaths: [(URL, PathIdentity)]

  init(
    lifecycle: SkillLifecycle, previous: ResolvedState, next: ResolvedState,
    prepared: [String: PreparedSkill], names: Set<String>, results: [UpdateResult]
  ) throws {
    self.lifecycle = lifecycle
    self.previous = previous
    self.next = next
    self.prepared = prepared
    self.names = names
    self.results = results
    let oldTargets = try lifecycle.targets(previous).filter { names.contains($0.value.name) }
    let newTargets = try lifecycle.targets(next).filter { names.contains($0.value.name) }
    targetPaths = Set(oldTargets.keys).union(newTargets.keys).sorted().map {
      URL(fileURLWithPath: $0)
    }
    before = try targetPaths.map { try TargetPrecondition($0) }
    linkedInputs = try targetPaths.compactMap { url in
      guard oldTargets[url.path]?.mode != .edit else { return nil }
      let physical = url.resolvingSymlinksInPath()
      return physical == url ? nil : try TargetPrecondition(physical)
    }
    recipientPaths = try names.sorted().flatMap { name in
      Set((previous.skills[name]?.installs ?? [:]).keys)
        .union((next.skills[name]?.installs ?? [:]).keys).compactMap { raw in
          AgentID(rawValue: raw).map {
            SkillLifecycle.target(name: name, agent: $0, store: lifecycle.store)
          }
        }
    }.map { (SkillLifecycle.physicalTarget($0), try PathIdentity($0)) }
  }

  package func validateOwnership() throws {
    try lifecycle.validateOwnership(previous: previous, next: next, names: names)
    for (path, target) in try lifecycle.targets(next) {
      if let item = prepared[target.name], item.lock.hash == nil,
        PathSafety.isContained(item.directory, in: URL(fileURLWithPath: path))
      {
        throw CoreError.unsafePath("installation would replace its own source")
      }
    }
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    for (url, identity) in recipientPaths where !targets.contains(url.path) {
      try identity.validate()
    }
    for evidence in before where !targets.contains(evidence.url.path) { try evidence.validate() }
    for evidence in linkedInputs
    where !targets.contains(where: {
      PathSafety.isContained(evidence.url, in: URL(fileURLWithPath: $0))
    }) {
      try evidence.validate()
    }
    for (name, item) in prepared { try lifecycle.validate(item, name: name) }
  }

  package func retain() throws -> [String: URL] {
    try lifecycle.retain(prepared: prepared, next: next)
  }

  package func stage(retained: [String: URL], transaction: FileTransaction) throws {
    try lifecycle.stage(
      previous: previous, next: next, prepared: prepared, retained: retained,
      names: names, transaction: transaction,
      expectations: Dictionary(uniqueKeysWithValues: zip(targetPaths.map(\.path), before)))
  }

  package var receipts: [InstallResult] { lifecycle.receipts(next: next, names: names) }
}
