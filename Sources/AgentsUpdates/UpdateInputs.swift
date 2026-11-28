import AgentsCore
import AgentsSkills
import Foundation

/// Live skill content remains live; its authored directory identity and valid metadata cannot change.
final class UpdateInputs: PreparedEvidence {
  private struct LiveSkill {
    let resource: LedgerResource
    let name: String
    let logical: PathIdentity
    let physical: PathIdentity
  }
  private let frozen: [TargetPrecondition]
  private let live: [LiveSkill]
  private let ledger: ResolvedLedger
  private let roots: [String: URL]

  init(
    ledger: ResolvedLedger, roots: [String: URL], resources: [String: URL],
    decisions: [TargetPrecondition],
    originals: [TargetPrecondition]
  ) throws {
    frozen = decisions + originals
    self.ledger = ledger
    self.roots = roots
    live = try ledger.components.values.compactMap { component in
      guard component.kind == "skills", let id = component.resources.first,
        let resource = ledger.resources[id], resource.kind == .liveEdit, let url = resources[id]
      else { return nil }
      return try LiveSkill(
        resource: resource, name: component.payload.object?["name"]?.text ?? component.name,
        logical: PathIdentity(url), physical: PathIdentity(url.resolvingSymlinksInPath()))
    }
  }

  func validate(excludingTargets targets: Set<String> = []) throws {
    for evidence in frozen where !targets.contains(evidence.url.path) {
      if targets.isEmpty {
        try evidence.validate()
      } else {
        try evidence.validateDuringPublication()
      }
    }
    for item in live {
      let edit = try LedgerResources.liveEditSource(item.resource, ledger: ledger, roots: roots)
      try item.logical.validate()
      try item.physical.validate()
      try SkillOperations.validateLiveMetadata(at: edit.directory, name: item.name)
    }
  }
}
