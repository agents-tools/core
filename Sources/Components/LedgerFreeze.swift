import AgentsCore
import Foundation

/// Explicit authoring coordinates are keyed by B's source identity, before durable IDs are made.
/// The caller supplies their authored meaning; physical containment never infers relocation.
package struct LedgerFreezeLocations {
  package var sources: [String: LedgerLocation]
  package init(sources: [String: LedgerLocation]) { self.sources = sources }
}

package enum LedgerFreeze {
  /// Ephemeral B-to-C identities accompany the frozen ledger during native lowering.
  /// They retain exact snapshots without persisting machine-local source coordinates.
  package struct Result {
    package var ledger: ResolvedLedger
    package let sources: [SourceSnapshotID: String]
  }

  package static func freeze(
    _ linked: LinkedComponents, session: SourceResolutionSession,
    locations: LedgerFreezeLocations, limits: LedgerLimits
  ) throws -> ResolvedLedger {
    try freezeWithSources(linked, session: session, locations: locations, limits: limits).ledger
  }

  package static func freezeWithSources(
    _ linked: LinkedComponents, session: SourceResolutionSession,
    locations: LedgerFreezeLocations, limits: LedgerLimits
  ) throws -> Result {
    var ledger = ResolvedLedger()
    let allSnapshots = linked.sourceSnapshots + linked.declaringSnapshots
    let evidence = Dictionary(
      allSnapshots.map { ($0.snapshot, $0) }, uniquingKeysWith: { first, _ in first })
    var sources: [SourceSnapshotID: String] = [:]
    func sourceID(_ snapshot: SourceSnapshotID) throws -> String {
      if let id = sources[snapshot] { return id }
      guard let item = evidence[snapshot] else {
        throw CoreError.invalidState("missing snapshot evidence")
      }
      let container = try item.container.map(sourceID)
      let descriptor = item.source
      let location = locations.sources[snapshot.source]
      if descriptor?.kind == .local, container == nil, location == nil {
        throw CoreError.invalidState("local source needs explicit authoring coordinates")
      }
      let source = LedgerSource(
        kind: descriptor?.kind ?? .local,
        transport: descriptor?.url ?? (descriptor?.kind == .wellKnown ? snapshot.source : nil),
        location: container == nil ? location : nil,
        revision: snapshot.revision, version: item.pin?.version, container: container,
        namespace: item.container.map { String(snapshot.source.dropFirst($0.source.count)) })
      let id = try ResolvedLedgerCodec.digest(source)
      ledger.sources[id] = source
      sources[snapshot] = id
      return id
    }
    for item in allSnapshots { _ = try sourceID(item.snapshot) }
    let snapshotsBySource = Dictionary(grouping: allSnapshots, by: { $0.snapshot.source })
    for use in linked.sourceUses {
      for snapshot in snapshotsBySource[use.source] ?? [] {
        ledger.sourceUses.append(
          .init(
            source: try sourceID(snapshot.snapshot), root: use.root,
            requirement: use.requirement?.canonical))
      }
    }
    var objectBytes = 0
    for component in linked.components {
      try Task.checkCancellation()
      var resourceIDs: [String] = []
      for resource in component.resources {
        let id = try sourceID(resource.snapshot)
        let mode: InstallMode?
        if case .skill(_, let selection, _) = component.payload {
          mode = selection
        } else {
          mode = nil
        }
        let record: LedgerResource
        if mode == .edit {
          guard let base = locations.sources[resource.snapshot.source] else {
            throw CoreError.invalidState("live skill needs explicit location")
          }
          var location = base
          location.path = base.path == "." ? resource.path : base.path + "/" + resource.path
          record = .init(
            kind: .liveEdit, source: id, path: resource.path, hash: resource.hash,
            entries: [], location: location)
        } else {
          let url = try session.resource(snapshot: resource.snapshot, path: resource.path)
          var source = ledger.sources[id]!
          while let container = source.container { source = ledger.sources[container]! }
          let git = SourceCache.isObjectID(source.revision)
          let kind: LedgerResource.Kind =
            resource.artifact != nil ? .artifact : git ? .git : .embedded
          let captured = try LedgerResources.capture(
            url, embed: kind != .git, limits: limits,
            sourceRoot: try session.resource(snapshot: resource.snapshot, path: "."))
          let flags =
            captured.entries.count == 1 && captured.entries[0].kind == .file
            ? [resource.path: captured.flags["."] ?? false] : captured.flags
          guard captured.hash == resource.hash,
            resource.executableFlags.isEmpty || flags == resource.executableFlags
          else {
            throw CoreError.invalidState("linked resource changed before freeze")
          }
          for (digest, bytes) in captured.objects where ledger.contentObjects[digest] == nil {
            guard bytes.count <= limits.objectBytes - objectBytes else {
              throw CoreError.invalidState("ledger aggregate content budget")
            }
            ledger.contentObjects[digest] = bytes
            objectBytes += bytes.count
          }
          record = .init(
            kind: kind, source: id, path: resource.path, hash: resource.hash,
            entries: captured.entries, support: captured.support, artifact: resource.artifact)
        }
        let resourceID = try ResolvedLedgerCodec.digest(record)
        ledger.resources[resourceID] = record
        resourceIDs.append(resourceID)
      }
      let payload: LedgerValue
      switch component.payload {
      case .declaration(let declaration): payload = try LedgerPayload.component(declaration)
      case .skill(let skill, let mode, let native):
        payload = .init(object: [
          "name": .init(skill.name), "description": .init(skill.description),
          "mode": .init(mode.rawValue), "native": LedgerPayload.native(native),
        ])
      case .instruction(let instruction, let prompt, let native):
        var fields: [String: LedgerValue] = [
          "name": .init(instruction.name),
          "sourceHash": .init(instruction.section.hash), "native": LedgerPayload.native(native),
        ]
        fields["prompt"] = prompt.map { .init($0) }
        payload = .init(object: fields)
      }
      let record = LedgerComponent(
        declaringSource: try sourceID(component.declaringSnapshot),
        source: try sourceID(component.snapshot), root: component.key.root,
        group: component.key.group, kind: component.key.kind.rawValue, name: component.key.name,
        revision: component.pin?.revision, version: component.pin?.version,
        payload: payload, conditions: component.conditions.map(LedgerCondition.init),
        recipients: component.recipients.sorted { $0.rawValue < $1.rawValue },
        chatGPT: component.chatGPT, resources: resourceIDs)
      let id = try ResolvedLedgerCodec.digest(record)
      ledger.components[id] = record
      for origin in component.origins {
        ledger.occurrences.append(
          .init(
            declaringSource: try sourceID(component.declaringSnapshot),
            manifestPath: origin.provenance.relativePath, id: origin.occurrence, component: id,
            reference: origin.reference, dependencies: try origin.dependencies.map(sourceID),
            condition: LedgerCondition(origin.condition),
            recipients: origin.recipients.sorted { $0.rawValue < $1.rawValue },
            consumerEditable: origin.consumerEditable))
      }
    }
    ledger.occurrences.sort { $0.id < $1.id }
    var children: [Int: [Int]] = [:]
    for reference in linked.references {
      if let parent = reference.parent {
        children[parent, default: []].append(reference.occurrence)
      }
    }
    for occurrence in ledger.occurrences {
      if let parent = occurrence.reference { children[parent, default: []].append(occurrence.id) }
    }
    ledger.groups = try linked.references.map { reference in
      LedgerGroup(
        id: reference.occurrence, parent: reference.parent,
        source: try sourceID(reference.snapshot), root: reference.root, name: reference.group,
        requirement: reference.constraint?.requirement?.canonical,
        manifestHash: reference.manifestHash,
        children: (children[reference.occurrence] ?? []).sorted())
    }
    try ledger.validate()
    return Result(ledger: ledger, sources: sources)
  }
}
