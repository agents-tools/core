import AgentsCore
import Foundation

/// Assembly and retention inputs for one scope generation; the caller owns commit and pruning.
package final class InstructionUpdatePlan {
  package let next: ResolvedState
  package let report: InstructionUpdateReport
  private let sources: InstructionSources
  private let identities: [TargetPrecondition]
  private let replace: Bool

  init(
    next: ResolvedState, report: InstructionUpdateReport, sources: InstructionSources,
    replace: Bool, expectedTargets: [String: TargetPrecondition]
  ) throws {
    self.next = next
    self.report = report
    self.sources = sources
    self.replace = replace
    let store = sources.store
    var paths = report.targets.map(\.url)
    for agent in Set(report.targets.flatMap { ($0.beforeAgents ?? []) + $0.afterAgents }) {
      if let logical = InstructionLocations.file(
        for: agent, scope: store.scope, environment: store.environment)
      {
        paths.append(logical)
      }
    }
    if store.scope == .project,
      next.instructions.targets.values.contains(where: { $0.agents.contains(.claudeCode) })
    {
      let candidates = ClaudeInstructionPath.allCases.map {
        store.environment.projectDirectory.appendingPathComponent($0.rawValue)
      }
      paths.append(contentsOf: candidates)
      paths.append(contentsOf: candidates.map { $0.resolvingSymlinksInPath() })
    }
    var evidence = expectedTargets
    for path in Set(paths.map { $0.standardizedFileURL.path }) where evidence[path] == nil {
      evidence[path] = try TargetPrecondition(URL(fileURLWithPath: path))
    }
    identities = evidence.keys.sorted().map { evidence[$0]! }
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    if !replace { try InstructionOperations.requireOwnership(report) }
    for identity in identities where !targets.contains(identity.url.path) {
      try identity.validate()
    }
    try InstructionTargets.validateSourceDirectories(report.targets, sources: next.sources)
  }

  package func retain() throws { try sources.retain(next) }

  package func stage(transaction: FileTransaction) throws {
    for change in report.targets.sorted(by: { $0.url.path < $1.url.path }) where change.changed {
      guard
        let evidence = identities.first(where: {
          $0.url.path == change.url.standardizedFileURL.path
        })
      else {
        throw CoreError.invalidState("instruction target has no prepared preimage")
      }
      try transaction.replace(change.url, content: nil, data: change.after, expecting: evidence)
    }
  }
}
