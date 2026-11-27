import AgentsCore
import AgentsInstructions
import AgentsSkills
import Components
import Foundation

/// Builds the resolved ledger from saved installation records and independently pinned sources.
struct ImportedConfigurationLedger {
  let store: StateStore
  let declaration: Declaration
  let saved: ResolvedState
  var ledger = ResolvedLedger()
  var evidence: [URL: TargetPrecondition] = [:]
  var installations: [SkillInstallationTarget] = []
  var editSources: [URL: EditSourceEvidence] = [:]
  var offlinePins: [ConfigurationImportEvidence.OfflinePin] = []
  var installed = Set<String>()
  private var skillTargets: [String: InstallMode] = [:]
  private var declaringSource = ""
  private var objectBytes = 0

  private var cache: SourceCache { SourceCache(store: store) }

  init(store: StateStore, declaration: Declaration, saved: ResolvedState) {
    self.store = store
    self.declaration = declaration
    self.saved = saved
  }

  mutating func convert() throws -> ResolvedLedger {
    let root = LedgerSource(
      kind: .local, location: .init(kind: .registered, root: "state", path: "."), revision: "live")
    declaringSource = try ResolvedLedgerCodec.digest(root)
    ledger.sources[declaringSource] = root
    for name in saved.skills.keys.sorted() {
      try Task.checkCancellation()
      try addSkill(name, locked: saved.skills[name]!)
    }
    try addInstructions()
    if ledger.occurrences.isEmpty { ledger.sources.removeValue(forKey: declaringSource) }
    let roots = store.ledgerRoots(recordedIn: ledger)
    return try LedgerReplay.withPreparedLowerings(
      ledger, store: store, roots: roots, limits: .standard, offline: true
    ) { prepared, outputs, _, _ in
      let rendered = Dictionary(uniqueKeysWithValues: outputs.map { ($0.name, $0) })
      for deployment in prepared.deployments
      where InstructionLocations.isInstructionFormat(deployment.route) {
        guard let bytes = rendered[deployment.id]?.bytes,
          Instructions.hash(bytes) == deployment.expectedHash
        else {
          throw ExistingGlobalConfigurationError.conflict(
            "The pinned sections do not reproduce \(deployment.id). Restore the pinned "
              + "sources and reconcile the recorded instruction target before previewing again.")
        }
      }
      var expected = saved.normalized
      let sourceIDs = Set(
        saved.skills.values.map(\.source) + saved.instructions.sections.map(\.source)
          + saved.instructions.chatgpt.values.flatMap { $0.sections.map(\.source) })
      expected.sources = expected.sources.filter { sourceIDs.contains($0.key) }
      for id in expected.sources.keys {
        let path = try PathSafety.sanitizeSubpath(expected.sources[id]?.path ?? ".")
        expected.sources[id]?.path = path == "." ? nil : path
      }
      guard try prepared.domainProjection(roots: roots).normalized == expected else {
        throw ExistingGlobalConfigurationError.conflict(
          "The selected configuration cannot represent the recorded items or targets. "
            + "Reconcile agents.json and agents.resolved before previewing again.")
      }
      return prepared
    }
  }

  private mutating func addSkill(_ name: String, locked: LockedSkill) throws {
    let source = saved.sources[locked.source]!
    let path = try PathSafety.sanitizeSubpath(locked.path ?? ".")
    let edit = locked.installs.values.contains(.edit)
    let sourceID = try addSource(
      locked.source, revision: locked.revision ?? locked.artifact?.digest ?? "live",
      version: locked.version)
    var resource: LedgerResource
    let metadata: Skill
    let linkDestination: URL
    if edit {
      let root = URL(fileURLWithPath: String(locked.source.dropFirst("local:".count)))
      let item = try contained(path, in: root)
      let physical = item.resolvingSymlinksInPath()
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: physical.path, isDirectory: &directory),
        directory.boolValue
      else {
        throw unavailable("live skill \(name)", at: item.path)
      }
      let metadataFile = try contained(
        path == "." ? "SKILL.md" : path + "/SKILL.md", in: root)
      let edit = try EditSourceEvidence(
        authoredURL: item, directory: physical, metadata: metadataFile.resolvingSymlinksInPath())
      editSources[item] = edit
      metadata = try SkillOperations.lockedMetadata(at: physical, installedName: name)
      resource = .init(
        kind: .liveEdit, source: sourceID, path: path,
        hash: edit.hash, entries: [],
        location: .init(kind: .absolute, path: item.path))
      linkDestination = item
    } else if let artifact = locked.artifact {
      let item = try cache.artifactContentURL(digest: artifact.digest)
      guard try remember(item).exists else {
        throw unavailable("skill \(name)", at: item.path)
      }
      resource = try capture(
        item, path: path, source: sourceID, expectedHash: locked.hash!,
        root: item, artifact: artifact)
      resource.location = try SourceCache.artifactContentLocation(digest: artifact.digest)
      metadata = try SkillOperations.lockedMetadata(at: item, installedName: name)
      linkDestination = item
    } else {
      let revision = locked.revision!
      (resource, metadata) = try withPin(locked.source, source: source, revision: revision) {
        conversion, root, durable in
        let item = try conversion.contained(path, in: root)
        let captured = try conversion.capture(
          item, path: path, source: sourceID, expectedHash: locked.hash!, root: root)
        if durable { try conversion.remember(captured, at: item, in: root) }
        return (captured, try SkillOperations.lockedMetadata(at: item, installedName: name))
      }
      linkDestination = try PathSafety.resolvedChild(
        base: cache.materializedURL(sourceID: locked.source, revision: revision), subpath: path)
    }
    let resourceID = try storeResource(resource)
    let modes = Dictionary(grouping: locked.installs.keys.sorted(), by: { locked.installs[$0]! })
    for mode in modes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      let agents = try modes[mode]!.map { raw in
        guard let agent = AgentID(rawValue: raw), agent.supportsSkills else {
          throw ExistingGlobalConfigurationError.conflict(
            "Skill \(name) has an unsupported recipient \(raw).")
        }
        return agent
      }
      let occurrence = ledger.occurrences.count
      let owner = try addComponent(
        kind: .skills, name: name, source: sourceID,
        revision: locked.revision, version: locked.version,
        payload: [
          "name": .init(metadata.name), "description": .init(metadata.description),
          "mode": .init(mode.rawValue), "native": .init(object: [:]),
        ], agents: agents, prompt: nil, resource: resourceID)
      for agent in agents {
        let target = try store.skillInstallationTarget(for: agent, named: name)
        try inspectSkill(target.url, mode: mode, resource: resource, link: linkDestination)
        installations.append(target)
        let id = "skill:\(occurrence):\(agent.rawValue)"
        addLowering(
          id: id, format: "agents/skill@1", owners: [owner], resources: [resourceID],
          target: .init(
            id: id, target: .init(kind: .registered, root: "skills-" + agent.rawValue, path: name),
            route: "agents/skill@1", owners: [owner], recipients: [agent], ownership: .generated,
            expectedHash: resource.hash, created: false, headingOffset: 0),
          layout: ["name": .init(id), "mode": .init(mode.rawValue)])
      }
    }
  }

  private mutating func inspectSkill(
    _ target: URL, mode: InstallMode, resource: LedgerResource, link: URL
  ) throws {
    let physical = InstructionLocations.physical(target)
    if let previous = skillTargets.updateValue(mode, forKey: physical.path), previous != mode {
      throw ExistingGlobalConfigurationError.conflict(
        "Conflicting installation modes share \(target.path).")
    }
    guard try remember(target).exists else { return }
    if mode == .copy {
      let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
      let flags = Dictionary(
        uniqueKeysWithValues: resource.entries.filter { $0.kind == .file }.map {
          ($0.path, $0.executable)
        })
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        try "sha256:" + FileHash.folderHash(target) == resource.hash,
        try FileHash.executableFlags(target) == flags
      else { throw modifiedSkill(target) }
    } else {
      guard PathSafety.matchesSymbolicLink(at: target, destination: link)
      else { throw modifiedSkill(target) }
      if !FileManager.default.fileExists(atPath: target.path) { return }
    }
    installed.insert(physical.path)
  }

  private func modifiedSkill(_ target: URL) -> ExistingGlobalConfigurationError {
    .conflict(
      "The skill at \(target.path) differs from its installation record. Restore the recorded "
        + "contents or move the changed entry aside before previewing again.")
  }

  private mutating func addInstructions() throws {
    let instructions = saved.instructions
    let recipients = Set(instructions.targets.values.flatMap(\.agents))
    let declared = try declaration.instructions
    let agents =
      (recipients.isEmpty ? Set(declared?.agents ?? declaration.defaultAgents) : recipients)
      .sorted { $0.rawValue < $1.rawValue }
    guard instructions.sections.isEmpty || !agents.isEmpty else {
      throw ExistingGlobalConfigurationError.conflict(
        "Saved instruction sections have no recipients. Reconcile the instruction selection "
          + "in agents.json before previewing again.")
    }
    var owners: [String] = []
    for section in instructions.sections {
      owners.append(try addSection(section, agents: agents))
    }
    let resources = owners.map { ledger.components[$0]!.resources[0] }
    for key in instructions.targets.keys.sorted() {
      let target = instructions.targets[key]!
      let file = try InstructionLocations.file(for: key, store: store)
      let agents = target.agents.sorted { $0.rawValue < $1.rawValue }
      let locations = agents.compactMap {
        InstructionLocations.file(for: $0, scope: .user, environment: store.environment)
      }
      guard !owners.isEmpty, let agent = agents.first, Set(agents).count == agents.count,
        locations.count == agents.count,
        locations.allSatisfy({ InstructionLocations.physical($0) == file })
      else {
        throw ExistingGlobalConfigurationError.conflict(
          "The agent home settings do not resolve to the recorded target \(key). "
            + "Check those settings before previewing again.")
      }
      let input = try TargetPrecondition.readingFile(locations[0])
      evidence[locations[0]] = input.evidence
      for location in locations.dropFirst() { try remember(location) }
      guard locations.allSatisfy({ InstructionLocations.physical($0) == file }) else {
        throw ExistingGlobalConfigurationError.stalePreview(file.path)
      }
      let id = "instructions:" + key
      let format: String
      var layout: [String: LedgerValue] = ["name": .init(id)]
      if let reference = target.import {
        guard agents == [.claudeCode],
          let path = ClaudeInstructionPath(rawValue: file.lastPathComponent),
          reference == String(path.importLine.dropFirst()),
          try input.bytes == nil
            || InstructionTargets.ownedImportBytes(input.bytes).map(Instructions.hash)
              == target.blockHash
        else {
          throw ExistingGlobalConfigurationError.conflict(
            "The forwarding block at \(file.path) differs from the recorded block. "
              + "Restore the recorded block before previewing again.")
        }
        format = "agents/claude-import@1"
      } else {
        format = "agents/instructions@1"
        layout["headingOffset"] = .init(integer: 0)
      }
      addLowering(
        id: id, format: format, owners: owners, resources: target.import == nil ? resources : [],
        target: .init(
          id: id,
          target: .init(
            kind: .registered, root: "instructions-" + agent.rawValue, path: file.lastPathComponent),
          route: format, owners: owners, recipients: agents,
          ownership: target.import == nil ? .generated : .importBlock,
          expectedHash: target.blockHash,
          created: target.created, importReference: target.import,
          headingOffset: target.headingOffset),
        layout: layout)
    }
    for name in instructions.chatgpt.keys.sorted() {
      let prompt = instructions.chatgpt[name]!
      guard !prompt.sections.isEmpty else {
        throw ExistingGlobalConfigurationError.conflict(
          "Locked ChatGPT prompt \(name) has no sections.")
      }
      var inputs: [String] = []
      for section in prompt.sections {
        inputs.append(try addSection(section, agents: [], prompt: name, append: prompt.append))
      }
      let id = "prompt:" + name
      addLowering(
        id: id, format: "agents/chatgpt@1", owners: inputs,
        resources: inputs.map { ledger.components[$0]!.resources[0] }, target: nil,
        layout: ["name": .init(id), "sectionCount": .init(integer: inputs.count)])
    }
  }

  private mutating func addSection(
    _ section: LockedSection, agents: [AgentID], prompt: String? = nil, append: String? = nil
  ) throws -> String {
    guard let source = saved.sources[section.source], let revision = section.revision else {
      throw ExistingGlobalConfigurationError.conflict(
        "Locked section \(section.name) requires a named Git source and an exact commit.")
    }
    let path = try PathSafety.sanitizeSubpath(section.path)
    let sourceID = try addSource(section.source, revision: revision, version: section.version)
    let resource = try withPin(section.source, source: source, revision: revision) {
      conversion, root, durable in
      let file = try conversion.contained(path, in: root)
      let resource = try conversion.capture(
        file, path: path, source: sourceID, expectedHash: section.hash, root: root)
      if durable { try conversion.remember(resource, at: file, in: root) }
      return resource
    }
    var payload: [String: LedgerValue] = [
      "name": .init(section.name), "sourceHash": .init(section.hash), "native": .init(object: [:]),
    ]
    payload["prompt"] = prompt.map { .init($0) }
    if let append {
      let location = LedgerLocation(
        kind: .registered, root: "home", path: try PathSafety.sanitizeSubpath(append))
      payload["localAppend"] = location.ledgerValue
    }
    let resourceID = try storeResource(resource)
    return try addComponent(
      kind: .instructions, name: section.name, source: sourceID,
      revision: revision, version: section.version, payload: payload,
      agents: agents, prompt: prompt, resource: resourceID)
  }

  private mutating func withPin<T>(
    _ identity: String, source: LockedSource, revision: String,
    _ body: (inout Self, URL, Bool) throws -> T
  ) throws -> T {
    let sourceCache = cache
    do {
      return try sourceCache.withOfflineSnapshot(
        sourceID: identity, source: source, revision: revision
      ) { root, durable in
        if !durable {
          let materialized = sourceCache.materializedURL(sourceID: identity, revision: revision)
          guard try !remember(materialized).exists else {
            throw ExistingGlobalConfigurationError.stalePreview(materialized.path)
          }
          let pin = ConfigurationImportEvidence.OfflinePin(
            identity: identity, source: source, revision: revision)
          if !offlinePins.contains(pin) { offlinePins.append(pin) }
        }
        return try body(&self, root, durable)
      }
    } catch CoreError.notFound(let item) {
      throw ExistingGlobalConfigurationError.conflict(
        "Cannot read \(item) at locked commit \(revision) for \(identity). "
          + "Restore the original cached content or the exact commit in the local source before retrying."
      )
    }
  }

  private func contained(_ path: String, in root: URL) throws -> URL {
    let file = try PathSafety.resolvedChild(base: root, subpath: path)
    guard PathSafety.isContained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath())
    else { throw CoreError.unsafePath("locked resource escapes \(root.path)") }
    return file
  }

  private mutating func capture(
    _ file: URL, path: String, source: String, expectedHash: String, root: URL,
    artifact: LockedArtifact? = nil
  ) throws -> LedgerResource {
    let captured = try LedgerResources.capture(
      file, embed: artifact != nil, limits: .standard, sourceRoot: root)
    guard captured.hash == expectedHash else {
      throw ExistingGlobalConfigurationError.conflict(
        "Pinned content differs from the saved contents at \(path). Restore the matching "
          + "cached content before previewing again.")
    }
    for (key, bytes) in captured.objects where ledger.contentObjects[key] == nil {
      guard bytes.count <= LedgerLimits.standard.objectBytes - objectBytes else {
        throw CoreError.invalidState("ledger aggregate content budget")
      }
      ledger.contentObjects[key] = bytes
      objectBytes += bytes.count
    }
    return .init(
      kind: artifact == nil ? .git : .artifact, source: source, path: path,
      hash: expectedHash, entries: captured.entries, support: captured.support, artifact: artifact)
  }

  @discardableResult
  private mutating func remember(_ file: URL) throws -> TargetPrecondition {
    if let existing = evidence[file] { return existing }
    let item = try TargetPrecondition(file)
    evidence[file] = item
    return item
  }

  private mutating func remember(_ resource: LedgerResource, at file: URL, in root: URL) throws {
    try remember(file)
    for entry in resource.support where entry.kind != .directory {
      try remember(try contained(entry.path, in: root))
    }
  }

  private func unavailable(_ name: String, at path: String) -> ExistingGlobalConfigurationError {
    .conflict(
      "The source for \(name) is missing at \(path). Restore the source or its cached contents "
        + "and preview again.")
  }

  private mutating func addSource(_ identity: String, revision: String, version: String?) throws
    -> String
  {
    let locked = saved.sources[identity]!
    let location: LedgerLocation? =
      locked.kind == .local
      ? .init(kind: .absolute, path: String(identity.dropFirst("local:".count))) : nil
    let source = LedgerSource(
      kind: locked.kind, transport: locked.kind == .wellKnown ? identity : locked.url,
      location: location, revision: revision, version: version)
    let id = try ResolvedLedgerCodec.digest(source)
    if ledger.sources.updateValue(source, forKey: id) == nil {
      ledger.sourceUses.append(
        .init(
          source: id, root: try PathSafety.sanitizeSubpath(locked.path ?? "."),
          requirement: locked.requirement?.canonical))
    }
    return id
  }

  private mutating func storeResource(_ resource: LedgerResource) throws -> String {
    let id = try ResolvedLedgerCodec.digest(resource)
    ledger.resources[id] = resource
    return id
  }

  private mutating func addComponent(
    kind: DeclaredComponentKind, name: String, source: String,
    revision: String?, version: String?, payload: [String: LedgerValue],
    agents: [AgentID], prompt: String?, resource: String
  ) throws -> String {
    let condition = LedgerCondition(DeclarationCondition())
    let component = LedgerComponent(
      declaringSource: declaringSource, source: source, root: ".",
      kind: kind.rawValue, name: name, revision: revision, version: version,
      payload: .init(object: payload), conditions: [condition], recipients: agents,
      chatGPT: prompt != nil, resources: [resource])
    let id = try ResolvedLedgerCodec.digest(component)
    ledger.components[id] = component
    ledger.occurrences.append(
      .init(
        declaringSource: declaringSource, manifestPath: StateStore.declarationFileName,
        id: ledger.occurrences.count, component: id, dependencies: [source],
        condition: condition, recipients: agents, consumerEditable: true))
    return id
  }

  private mutating func addLowering(
    id: String, format: String, owners: [String], resources: [String],
    target: LedgerDeployment?, layout: [String: LedgerValue]
  ) {
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    if let target { ledger.deployments.append(target) }
    ledger.lowerings.append(
      .init(
        id: id, format: format, inputs: owners, resources: resources,
        deployments: target.map { [$0.id] } ?? [], layout: .init(object: layout),
        platform: platform.rawValue, artifacts: []))
  }
}
