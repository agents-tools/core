import AgentsCore
import AgentsSkills
import Foundation

/// Live skill content remains live; its authored directory identity and valid metadata cannot change.
final class UpdateInputs: PreparedEvidence {
  private struct LiveSkill {
    let url: URL
    let name: String
    let logical: PathIdentity
    let physical: PathIdentity
  }
  private let frozen: [TargetPrecondition]
  private let live: [LiveSkill]

  init(
    ledger: ResolvedLedger, resources: [String: URL], decisions: [TargetPrecondition],
    originals: [TargetPrecondition]
  ) throws {
    frozen = decisions + originals
    live = try ledger.components.values.compactMap { component in
      guard component.kind == "skills", let id = component.resources.first,
        ledger.resources[id]?.kind == .liveEdit, let url = resources[id]
      else { return nil }
      return try LiveSkill(
        url: url, name: component.payload.object?["name"]?.text ?? component.name,
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
      try item.logical.validate()
      try item.physical.validate()
      try SkillOperations.validateLiveMetadata(at: item.url, name: item.name)
    }
  }
}
