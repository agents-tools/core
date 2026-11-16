import AgentsCore
import AgentsInstructions
import AgentsSkills
import Components
import Foundation

/// Public domain reports expose owned content. Shared native documents never enter these diffs.
enum UpdateReporting {
  static func skills(
    previous: ResolvedLedger, next: ResolvedLedger, resources: [String: URL],
    changes: [AggregatedChange], store: StateStore, lockMissing: Bool, included: Bool
  ) throws -> [UpdateResult] {
    guard included else { return [] }
    struct Item {
      let name: String
      var record: LockedSkill
      let resource: String
    }
    func items(_ ledger: ResolvedLedger) throws -> [String: Item] {
      var result: [String: Item] = [:]
      for component in ledger.components.values
      where component.kind == "skills" && !component.recipients.isEmpty {
        guard let id = component.resources.first, let resource = ledger.resources[id] else {
          continue
        }
        let source = try ledger.sourceIdentity(component.source, roots: store.ledgerRoots)
        let producer = try ledger.sourceIdentity(
          component.declaringSource, roots: store.ledgerRoots)
        let identity = try ResolvedLedgerCodec.digest(
          LedgerValue(object: [
            "producer": LedgerValue(producer), "source": .init(source),
            "root": .init(component.root),
            "group": component.group.map { .init($0) } ?? .init(),
            "name": .init(PathSafety.sanitizeName(component.name)),
            "path": .init(resource.path),
            "conditions": .init(try ResolvedLedgerCodec.digest(component.conditions)),
          ]))
        let mode =
          component.payload.object?["mode"]?.text.flatMap(InstallMode.init(rawValue:)) ?? .copy
        var record =
          result[identity]?.record
          ?? LockedSkill(
            source: source, revision: component.revision,
            version: component.version, artifact: resource.artifact, path: resource.path,
            hash: mode == .edit ? nil : resource.hash, installs: [:])
        for agent in component.recipients { record.installs[agent.rawValue] = mode }
        result[identity] = Item(
          name: PathSafety.sanitizeName(component.name), record: record, resource: id)
      }
      return result
    }
    let before = try items(previous)
    let after = try items(next)
    return try Set(before.keys).union(after.keys).sorted().map { identity in
      let old = before[identity]?.record
      let new = after[identity]?.record
      let name = after[identity]?.name ?? before[identity]!.name
      let membership = Set((old?.installs ?? [:]).keys).union((new?.installs ?? [:]).keys).sorted()
        .compactMap { raw -> SkillMembershipChange? in
          guard let agent = AgentID(rawValue: raw) else { return nil }
          let path = SkillLifecycle.target(name: name, agent: agent, store: store).path
          return SkillMembershipChange(
            agent: agent, path: path,
            before: old?.installs[raw].map { .installed(mode: $0) } ?? .absent,
            after: new?.installs[raw].map { .installed(mode: $0) } ?? .absent)
        }
      let installed = (new?.installs ?? [:]).keys.sorted().compactMap { raw -> InstallResult? in
        guard let agent = AgentID(rawValue: raw), let mode = new?.installs[raw] else { return nil }
        return InstallResult(
          skill: name, agent: agent, scope: store.scope, mode: mode,
          path: SkillLifecycle.target(name: name, agent: agent, store: store).path)
      }
      let content = after[identity].flatMap { resources[$0.resource] }
      var diffs: [SkillFileChange] = []
      for member in membership {
        let oldFiles = try entries(URL(fileURLWithPath: member.path))
        var newFiles =
          try new?.installs[member.agent.rawValue] == nil ? [:] : content.map(entries) ?? [:]
        if let change = changes.first(where: { $0.url.path == member.path }),
          let destination = change.afterLink
        {
          newFiles["."] = .symbolicLink(
            FileTransaction.linkDestination(
              destination, parent: URL(fileURLWithPath: member.path).deletingLastPathComponent(),
              store: store))
        }
        for path in Set(oldFiles.keys).union(newFiles.keys).sorted()
        where oldFiles[path] != newFiles[path] {
          diffs.append(
            SkillFileChange(
              path: path == "."
                ? member.path : URL(fileURLWithPath: member.path).appendingPathComponent(path).path,
              before: oldFiles[path], after: newFiles[path]))
        }
      }
      let paths = Set(membership.map(\.path))
      let physical = changes.contains {
        $0.deployment.route == "agents/skill@1" && paths.contains($0.url.path) && $0.changed
      }
      return UpdateResult(
        skill: name, sourceIdentity: new?.source ?? old?.source ?? "",
        changed: old != new || physical,
        oldRevision: old?.revision, newRevision: new?.revision, oldVersion: old?.version,
        newVersion: new?.version,
        oldHash: old?.hash, newHash: new?.hash, lockMissing: lockMissing, membership: membership,
        changes: diffs, installed: installed)
    }.sorted {
      ($0.skill, $0.sourceIdentity, $0.membership.first?.path ?? "") < (
        $1.skill, $1.sourceIdentity, $1.membership.first?.path ?? ""
      )
    }
  }

  static func instructions(
    before: LockedInstructions, after: LockedInstructions, changes: [AggregatedChange],
    lockMissing: Bool, included: Bool, store: StateStore, stateChanged: Bool
  ) throws -> InstructionUpdateReport {
    guard included else {
      return InstructionUpdateReport(
        sections: [], targets: [], changedPrompts: [], lockMissing: lockMissing, hasChanges: false)
    }
    func identity(_ section: LockedSection) -> String { section.source + ":" + section.name }
    let sectionChanges = Set((before.sections + after.sections).map(identity)).sorted().compactMap {
      id -> InstructionSectionChange? in
      let old = before.sections.first { identity($0) == id }
      let new = after.sections.first { identity($0) == id }
      return old == new ? nil : InstructionSectionChange(before: old, after: new)
    }
    let targets = try changes.filter { !$0.native && $0.deployment.route != "agents/skill@1" }.map {
      change in
      let key = InstructionLocations.key(for: change.url, store: store)
      let old = before.targets[key]
      let drift = try old.map { old -> InstructionDrift in
        guard let bytes = change.before else { return .missing }
        if old.import != nil {
          return try Instructions.detectDrift(in: bytes, lockedBlockHash: old.blockHash)
        }
        return ("sha256:" + FileHash.sha256Hex(data: bytes)) == old.blockHash ? .clean : .drifted
      }
      return InstructionTargetChange(
        target: key, url: change.url,
        before: try change.deployment.ownership == .importBlock
          ? InstructionTargets.ownedImportBytes(change.before) : change.before,
        after: try change.deployment.ownership == .importBlock
          ? InstructionTargets.ownedImportBytes(change.after) : change.after,
        beforeAgents: old?.agents,
        afterAgents: change.after == nil ? [] : change.deployment.recipients,
        drift: drift,
        foreign: change.deployment.ownership != .importBlock
          && change.before.map { $0 != change.after && !Instructions.isOwned($0) } ?? false)
    }
    let prompts = Set(before.chatgpt.keys).union(after.chatgpt.keys).filter {
      let old = before.chatgpt[$0]
      let new = after.chatgpt[$0]
      return old?.append != new?.append
        || old?.sections.map { identity($0) + $0.hash }
          != new?.sections.map { identity($0) + $0.hash }
    }.sorted()
    return InstructionUpdateReport(
      sections: sectionChanges, targets: targets, changedPrompts: prompts,
      lockMissing: lockMissing,
      hasChanges: stateChanged || before != after || targets.contains(where: \.changed))
  }

  private static func entries(_ root: URL) throws -> [String: SkillFileEntry] {
    try SkillLifecycle.entries(root)
  }
}
