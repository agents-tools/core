import AgentsCore

/// Uses C's exact ephemeral pairing, never equal bytes or graph-local occurrence numbers alone.
enum FrozenNativeIdentity {
  static func match(
    _ linked: LinkedComponent, frozen: LedgerFreeze.Result,
    agent: AgentID, scope: InstallScope
  ) throws -> (id: String, occurrences: [Int]) {
    let ledger = frozen.ledger
    let sourceIDs = frozen.sources
    func invalid(_ detail: String) -> CoreError { .invalidState(detail) }
    guard linked.recipients.contains(agent), case .declaration(let declaration) = linked.payload,
      let name = declaration.name
    else { throw invalid("the linked component does not target this recipient") }
    let ids = Set(linked.origins.map(\.occurrence))
    let occurrences = ledger.occurrences.filter { ids.contains($0.id) }
    let owners = Set(occurrences.map(\.component))
    guard !ids.isEmpty, occurrences.count == ids.count, owners.count == 1,
      let id = owners.first, let record = ledger.components[id],
      record.kind == linked.key.kind.rawValue, record.kind == declaration.kind.rawValue,
      record.name == name,
      record.chatGPT == linked.chatGPT,
      record.declaringSource == sourceIDs[linked.declaringSnapshot],
      record.source == sourceIDs[linked.snapshot], linked.key.source == linked.snapshot.source,
      record.revision == linked.pin?.revision, record.version == linked.pin?.version,
      record.root == linked.key.root, record.group == linked.key.group,
      record.payload == (try LedgerPayload.component(declaration)),
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
        origin.provenance.relativePath == frozen.manifestPath,
        Set(origin.recipients) == Set(frozen.recipients),
        origin.consumerEditable == frozen.consumerEditable
      else { throw invalid("linked origin and frozen occurrence do not match") }
    }
    for (resource, frozen) in zip(linked.resources, record.resources) {
      guard let item = ledger.resources[frozen], item.path == resource.path,
        item.source == sourceIDs[resource.snapshot], item.artifact == resource.artifact,
        item.hash == resource.hash
      else { throw invalid("linked resource and frozen evidence do not match") }
      let flags: [String: Bool]
      if item.entries.count == 1, item.entries[0].kind == .file, item.entries[0].path == "." {
        flags = [resource.path: item.entries[0].executable]
      } else {
        flags = Dictionary(
          uniqueKeysWithValues: item.entries.filter { $0.kind == .file }.map {
            ($0.path, $0.executable)
          })
      }
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
}
