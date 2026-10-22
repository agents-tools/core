import AgentsCore
import Foundation

/// Assembly and retention inputs for one scope generation; the caller owns commit and pruning.
package final class InstructionUpdatePlan {
  package let next: ResolvedState
  package let report: InstructionUpdateReport
  private let sources: InstructionSources
  private let identities: [PathIdentity]
  private let forwardingInputs: [(URL, Data?)]

  init(next: ResolvedState, report: InstructionUpdateReport, sources: InstructionSources) throws {
    self.next = next
    self.report = report
    self.sources = sources
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
      forwardingInputs = try candidates.map { url in
        let resolved = url.resolvingSymlinksInPath()
        paths.append(resolved)
        return (resolved, try InstructionTargets.read(resolved))
      }
    } else {
      forwardingInputs = []
    }
    identities = try paths.map { try PathIdentity($0) }
  }

  package func validate() throws {
    for identity in identities { try identity.validate() }
    for (url, bytes) in forwardingInputs {
      guard try InstructionTargets.read(url) == bytes else {
        throw CoreError.invalidState("Claude forwarding changed during preparation: \(url.path)")
      }
    }
    for change in report.targets {
      guard try InstructionTargets.read(change.url) == change.before else {
        throw CoreError.invalidState(
          "instruction target changed during preparation: \(change.target)")
      }
    }
    try InstructionTargets.validateSourceDirectories(report.targets, sources: next.sources)
  }

  package func retain() throws { try sources.retain(next) }

  package func stage(transaction: FileTransaction) throws {
    for change in report.targets.sorted(by: { $0.url.path < $1.url.path }) where change.changed {
      try transaction.replace(change.url, content: nil, data: change.after)
    }
  }
}
