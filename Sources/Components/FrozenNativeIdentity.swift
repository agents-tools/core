import AgentsCore
import Foundation

/// Uses C's exact ephemeral pairing, never equal bytes or graph-local occurrence numbers alone.
enum FrozenNativeIdentity {
  static func match(
    _ linked: LinkedComponent, frozen: LedgerFreeze.Result,
    agent: AgentID, scope: InstallScope
  ) throws -> (id: String, occurrences: [Int]) {
    let ledger = frozen.ledger
    try ResolvedLedgerCodec.checkModel(ledger, limits: .standard)
    try ledger.validate()
    let sourceIDs = frozen.sources
    func invalid(_ detail: String) -> CoreError { .invalidState(detail) }
    guard linked.recipients.contains(agent) else {
      throw invalid("the linked component does not target this recipient")
    }
    let payload: LedgerValue
    var registry: MCPRegistryEvidence?
    switch linked.payload {
    case .declaration(let declaration):
      payload = try LedgerPayload.component(declaration)
      registry = declaration.mcpRegistry
    case .skill(let skill, let mode, let native):
      payload = .init(object: [
        "name": .init(skill.name), "description": .init(skill.description),
        "mode": .init(mode.rawValue), "native": LedgerPayload.native(native),
      ])
    case .instruction: throw invalid("instructions use their existing domain renderer")
    }
    let ids = Set(linked.origins.map(\.occurrence))
    let occurrences = ledger.occurrences.filter { ids.contains($0.id) }
    let owners = Set(occurrences.map(\.component))
    guard !ids.isEmpty, occurrences.count == ids.count, owners.count == 1,
      let id = owners.first, let record = ledger.components[id],
      record.kind == linked.key.kind.rawValue,
      record.name.utf8.elementsEqual(linked.key.name.utf8),
      record.chatGPT == linked.chatGPT,
      record.declaringSource == sourceIDs[linked.declaringSnapshot],
      record.source == sourceIDs[linked.snapshot],
      linked.key.source.utf8.elementsEqual(linked.declaringSnapshot.source.utf8),
      record.revision == linked.pin?.revision,
      record.version == (registry?.version ?? linked.pin?.version),
      record.mcpRegistry == registry,
      record.root.utf8.elementsEqual(linked.key.root.utf8),
      record.group.map({ Data($0.utf8) }) == linked.key.group.map({ Data($0.utf8) }),
      record.containerRoot.map({ Data($0.utf8) })
        == linked.key.containerRoot.map({ Data($0.utf8) }),
      try ResolvedLedgerCodec.bytes(record.payload) == ResolvedLedgerCodec.bytes(payload),
      record.conditions == linked.conditions.map(LedgerCondition.init),
      Set(record.recipients) == linked.recipients,
      record.resources.count == linked.resources.count
    else { throw invalid("linked component and frozen occurrence graph do not match") }
    for (origin, frozen) in zip(linked.origins, occurrences) {
      guard origin.occurrence == frozen.id, origin.reference == frozen.reference,
        frozen.declaringSource == record.declaringSource,
        origin.provenance.sourceIdentity == linked.declaringSnapshot.source,
        origin.dependencies.compactMap({ sourceIDs[$0] }) == frozen.dependencies,
        origin.dependencies.allSatisfy({ sourceIDs[$0] != nil }),
        LedgerCondition(origin.condition) == frozen.condition,
        origin.provenance.relativePath.utf8.elementsEqual(frozen.manifestPath.utf8),
        Set(origin.recipients) == Set(frozen.recipients),
        origin.consumerEditable == frozen.consumerEditable,
        origin.provenance.pointer.map({ Data($0.utf8) })
          == frozen.input?.pointer.map({ Data($0.utf8) }),
        (origin.provenance.format == "yaml"
          ? nil
          : LedgerInputProvenance(
            format: origin.provenance.format, adapterVersion: origin.provenance.adapterVersion,
            pointer: origin.provenance.pointer)) == frozen.input,
        origin.pluginMember.map { member in
          let selector = LedgerPayload.reference(member.selector).object!
          return LedgerPluginMember(
            parent: member.parentOccurrence,
            kind: selector["kind"]!.text!, name: selector["name"]!.text!)
        } == frozen.pluginMember,
        origin.pluginExpansion.map { expansion in
          LedgerPluginExpansion(
            source: sourceIDs[expansion.snapshot] ?? "", root: expansion.root,
            containerRoot: expansion.containerRoot, document: expansion.document,
            input: expansion.input, children: expansion.children)
        } == frozen.pluginExpansion
      else { throw invalid("linked origin and frozen occurrence do not match") }
    }
    for (resource, frozen) in zip(linked.resources, record.resources) {
      guard let item = ledger.resources[frozen], item.path.utf8.elementsEqual(resource.path.utf8),
        item.source == sourceIDs[resource.snapshot], item.artifact == resource.artifact,
        item.hash == resource.hash, try ResolvedLedgerCodec.digest(item) == frozen
      else { throw invalid("linked resource and frozen evidence do not match") }
      let flags = try executableFlags(item)
      guard resource.executableFlags.isEmpty || resource.executableFlags == flags else {
        throw invalid("linked executable flags and frozen resource do not match")
      }
    }
    let selected = occurrences.filter {
      $0.recipients.contains(agent) && ($0.condition.scopes?.contains(scope) ?? true)
        && ($0.condition.agents?.contains(agent) ?? true)
    }
    guard !selected.isEmpty else {
      throw invalid("component has no active frozen occurrence for this recipient/scope")
    }
    return (id, selected.map(\.id))
  }

  /// FileHash follows the selected root directory link, but does not follow links inside
  /// that directory. Supporting entries use source-root coordinates, unlike selected entries.
  private static func executableFlags(_ resource: LedgerResource) throws -> [String: Bool] {
    guard let root = resource.entries.first(where: { $0.path == "." }) else {
      throw CoreError.invalidState("missing selected resource root")
    }
    if root.kind == .file { return [resource.path: root.executable] }
    if root.kind == .directory {
      return Dictionary(
        uniqueKeysWithValues: resource.entries.filter { $0.kind == .file }.map {
          ($0.path, $0.executable)
        })
    }
    // Core's ledger admission validates containment, ancestors, link cycles and support.
    // This traversal only projects the selected referent's executable flags.
    var entries = Dictionary(uniqueKeysWithValues: resource.support.map { ($0.path, $0) })
    for original in resource.entries {
      var entry = original
      entry.path = original.path == "." ? resource.path : resource.path + "/" + original.path
      entries[entry.path] = entry
    }
    let parents = resource.path.split(separator: "/").dropLast()
    for count in 1..<(parents.count + 1) {
      let ancestor = parents.prefix(count).joined(separator: "/")
      if entries[ancestor] == nil {
        entries[ancestor] = .init(path: ancestor, kind: .directory, executable: false)
      }
    }
    var path: [String] = []
    var pending = resource.path.split(separator: "/").map(String.init).reversed().map { $0 }
    var remainingWork = LedgerLimits.standard.encodedBytes
    while let part = pending.popLast() {
      guard remainingWork > 0 else {
        throw CoreError.invalidState("resource projection work budget")
      }
      remainingWork -= 1
      if part == "." { continue }
      if part == ".." {
        guard !path.isEmpty else { throw CoreError.invalidState("invalid resource referent") }
        path.removeLast()
        continue
      }
      path.append(part)
      let coordinate = path.joined(separator: "/")
      guard let entry = entries[coordinate] else {
        throw CoreError.invalidState("missing resource referent evidence")
      }
      if entry.kind == .symlink {
        guard let link = entry.link, link.utf8.count <= remainingWork else {
          throw CoreError.invalidState("invalid resource referent evidence")
        }
        remainingWork -= link.utf8.count
        path.removeLast()
        pending += link.split(separator: "/").reversed().map(String.init)
      }
    }
    let target = path.isEmpty ? "." : path.joined(separator: "/")
    if let entry = entries[target], entry.kind == .file {
      return [resource.path: entry.executable]
    }
    guard entries[target]?.kind == .directory else {
      throw CoreError.invalidState("selected native resource link is not a directory")
    }
    let prefix = target == "." ? "" : target + "/"
    var flags: [String: Bool] = [:]
    for entry in entries.values where entry.kind == .file && entry.path.hasPrefix(prefix) {
      let relative = String(entry.path.dropFirst(prefix.count))
      flags[relative] = entry.executable
    }
    return flags
  }

}
