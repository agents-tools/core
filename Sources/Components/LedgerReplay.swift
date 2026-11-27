import AgentsCore
import AgentsInstructions
import Foundation

/// Borrowed trees are valid only inside the replay closure. Shared-file values are intentions;
/// physical ownership, secret binding and publication remain with the applying operation.
package struct ReplayedArtifact {
  package var name: String
  package var kind: LedgerArtifactDigest.Kind
  package var bytes: Data?
  package var tree: URL?
  package var values: LedgerValue?
  package var location: LedgerLocation?

  package init(
    name: String, kind: LedgerArtifactDigest.Kind, bytes: Data? = nil,
    tree: URL? = nil, values: LedgerValue? = nil, location: LedgerLocation? = nil
  ) {
    self.name = name
    self.kind = kind
    self.bytes = bytes
    self.tree = tree
    self.values = values
    self.location = location
  }

  package func digest(limits: LedgerLimits) throws -> LedgerArtifactDigest {
    let hash: String
    switch kind {
    case .link:
      guard let location, bytes == nil, tree == nil, values == nil else {
        throw CoreError.invalidState("invalid live link")
      }
      hash = try ResolvedLedgerCodec.digest(location)
    case .file, .registration:
      guard let bytes, tree == nil, values == nil else {
        throw CoreError.invalidState("invalid rendered file")
      }
      hash = "sha256:" + FileHash.sha256Hex(data: bytes)
    case .tree:
      guard let tree, bytes == nil, values == nil else {
        throw CoreError.invalidState("invalid rendered tree")
      }
      let captured = try LedgerResources.capture(tree, embed: false, limits: limits)
      hash = try ResolvedLedgerCodec.digest(
        TreeDigest(content: captured.hash, entries: captured.entries))
    case .ownedValues:
      guard let values, bytes == nil, tree == nil else {
        throw CoreError.invalidState("invalid owned values")
      }
      hash = try ResolvedLedgerCodec.digest(values)
    }
    return .init(name: name, kind: kind, hash: hash)
  }

  private struct TreeDigest: Encodable {
    let content: String
    let entries: [LedgerEntry]
  }
}

package typealias LedgerRenderer = (
  _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
) throws -> [ReplayedArtifact]

package enum LedgerReplay {
  /// Only formats with implemented production semantics are registered here. Tests explicitly
  /// supply their own renderer table; a format is never selected by agent or current version.
  package static var compatibilityRenderers: [String: LedgerRenderer] {
    compatibilityRenderers(outputBytes: LedgerLimits.standard.resourceBytes)
  }

  private static func compatibilityRenderers(outputBytes: Int) -> [String: LedgerRenderer] {
    [
      "agents/skill@1": skill,
      AntigravityRuleV1.format: antigravityRule,
      "agents/instructions@1": { try instructions($0, $1, $2, outputBytes: outputBytes) },
      "agents/claude-import@1": { try forwarding($0, $1, $2, outputBytes: outputBytes) },
      "agents/chatgpt@1": { try renderPrompt($0, $1, $2, outputBytes: outputBytes) },
      LockedLowering.instructionCopyFormat: {
        try renderPrompt($0, $1, $2, outputBytes: outputBytes)
      },
    ].merging(MCPLayoutV1.renderers) { existing, _ in existing }
      .merging(NativeComponentLayoutsV1.renderers(limits: .standard)) { existing, _ in existing }
  }

  package static func withReplay<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer]? = nil,
    _ body: ([ReplayedArtifact]) throws -> T
  ) throws -> T {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: renderers,
      recording: false
    ) { artifacts, _, _, _ in try body(artifacts) }
  }

  package static func withPreparedLowerings<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    offline: Bool = false, sourcePolicy: EffectiveSourcePolicy = .init(),
    requireRecordedTransport: Bool = false, acquisitions: GitAcquisitionCaptures? = nil,
    _ body: (ResolvedLedger, [ReplayedArtifact], [String: URL], URL) throws -> T
  ) throws -> T {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: nil, recording: true,
      offline: offline, sourcePolicy: sourcePolicy,
      requireRecordedTransport: requireRecordedTransport, acquisitions: acquisitions
    ) {
      artifacts, lowerings, resources, workspace in
      var candidate = ledger
      candidate.lowerings = lowerings
      try candidate.validate()
      return try body(candidate, artifacts, resources, workspace)
    }
  }

  package static func withLockedResources<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    lowerings selected: Set<String>? = nil, offline: Bool = false,
    sourcePolicy: EffectiveSourcePolicy = .init(), requireRecordedTransport: Bool = false,
    acquisitions: GitAcquisitionCaptures? = nil,
    additionalResources: Set<String> = [], anchorLockedGit: Bool = false,
    _ body: ([ReplayedArtifact], [String: URL], URL) throws -> T
  ) throws -> T {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: nil, recording: false,
      selectedLowerings: selected, offline: offline, sourcePolicy: sourcePolicy,
      requireRecordedTransport: requireRecordedTransport, acquisitions: acquisitions,
      additionalResources: additionalResources, anchorLockedGit: anchorLockedGit
    ) {
      artifacts, _, resources, workspace in try body(artifacts, resources, workspace)
    }
  }

  /// An update reads only the prior native inputs it needs for ownership comparison.
  /// A replaced source still belongs to the old lock, but no read of its former route occurs
  /// unless one of these outputs actually needs bytes from it.
  static func withPriorOutputs<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL],
    lowerings: Set<String>, offline: Bool, sourcePolicy: EffectiveSourcePolicy,
    _ body: ([ReplayedArtifact]) throws -> T
  ) throws -> T {
    try run(
      ledger, store: store, roots: roots, limits: .standard, renderers: nil, recording: false,
      selectedLowerings: lowerings, offline: offline, sourcePolicy: sourcePolicy,
      completeSourceAdmission: false
    ) { artifacts, _, _, _ in try body(artifacts) }
  }

  /// Acquires just the selected locked inputs, independently of their target renderers.
  package static func captureBundleResources(
    _ ids: Set<String>, ledger: ResolvedLedger, store: StateStore, roots: [String: URL],
    sourcePolicy: EffectiveSourcePolicy = .init(), offline: Bool = false
  ) throws -> (resources: [String: LedgerResource], objects: [String: Data]) {
    if offline, ids.contains(where: { ledger.resources[$0]?.kind == .liveEdit }) {
      throw CoreError.invalidState("cannot pack a live resource as a locked dependency")
    }
    var records: [String: LedgerResource] = [:]
    var objects: [String: Data] = [:]
    var remaining = LedgerLimits.standard.objectBytes
    func add(_ digest: String, _ bytes: Data) throws {
      guard objects[digest] == nil else { return }
      guard bytes.count <= remaining else { throw CoreError.invalidState("bundle content budget") }
      remaining -= bytes.count
      objects[digest] = bytes
    }
    func capture(_ id: String, _ file: URL, _ snapshotRoot: URL?) throws {
      var resource = ledger.resources[id]!
      switch resource.kind {
      case .embedded, .artifact:
        for digest in (resource.entries + resource.support).compactMap(\.object) {
          try add(digest, ledger.contentObjects[digest]!)
        }
      case .archive:
        throw SourceAccessError.egressDenied
      case .git where offline:
        guard let snapshotRoot else { throw CoreError.invalidState("missing locked Git snapshot") }
        let captured = try LedgerResources.captureLockedGit(resource, snapshotRoot: snapshotRoot)
        resource.entries = captured.entries
        resource.support = captured.support
        for (digest, bytes) in captured.objects { try add(digest, bytes) }
      case .liveEdit, .git:
        let live = resource.kind == .liveEdit ? try TargetPrecondition(file) : nil
        let sourceRoot =
          try snapshotRoot
          ?? ledger.sources[resource.source]?.location?.resolve(roots: roots)
        let captured = try LedgerResources.capture(
          file, embed: true, limits: .standard, sourceRoot: sourceRoot)
        try live?.validate()
        if resource.kind == .git {
          func withoutObjects(_ entries: [LedgerEntry]) -> [LedgerEntry] {
            entries.map { entry in
              var entry = entry
              entry.object = nil
              return entry
            }
          }
          guard captured.hash == resource.hash,
            withoutObjects(captured.entries) == resource.entries,
            withoutObjects(captured.support) == resource.support
          else { throw CoreError.invalidState("locked bundle resource changed during export") }
        }
        resource.hash = captured.hash
        resource.entries = captured.entries
        resource.support = captured.support
        for (digest, bytes) in captured.objects { try add(digest, bytes) }
      }
      resource.kind = .embedded
      resource.location = nil
      resource.artifact = nil
      records[id] = resource
    }
    try run(
      ledger, store: store, roots: roots, limits: .standard, renderers: nil, recording: false,
      selectedLowerings: [], offline: offline, sourcePolicy: sourcePolicy, selectedResources: ids,
      observeResource: capture
    ) { _, _, _, _ in }
    return (records, objects)
  }

  /// Seals renderer output identities into a candidate before encoding or publication.
  package static func prepareLowerings(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer]? = nil
  ) throws -> ResolvedLedger {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: renderers,
      recording: true
    ) { _, lowerings, _, _ in
      var candidate = ledger
      candidate.lowerings = lowerings
      try candidate.validate()
      return candidate
    }
  }

  private static func run<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer]?, recording: Bool,
    selectedLowerings: Set<String>? = nil, offline: Bool = false,
    sourcePolicy: EffectiveSourcePolicy = .init(), requireRecordedTransport: Bool = false,
    acquisitions: GitAcquisitionCaptures? = nil, selectedResources: Set<String>? = nil,
    additionalResources: Set<String> = [], anchorLockedGit: Bool = false,
    completeSourceAdmission: Bool = true,
    observeResource: ((String, URL, URL?) throws -> Void)? = nil,
    _ body: ([ReplayedArtifact], [LockedLowering], [String: URL], URL) throws -> T
  ) throws -> T {
    try ResolvedLedgerCodec.checkModel(ledger, limits: limits)
    try ledger.validate()
    if completeSourceAdmission { try sourcePolicy.require(ledger, store: store, roots: roots) }
    try Task.checkCancellation()
    let lowerings = ledger.lowerings.filter { selectedLowerings?.contains($0.id) ?? true }
    guard selectedLowerings.map({ $0.isSubset(of: Set(ledger.lowerings.map(\.id))) }) ?? true else {
      throw CoreError.invalidState("unknown selected locked lowering")
    }
    let resourceIDs =
      (selectedResources
      ?? (selectedLowerings == nil
        ? Set(ledger.resources.keys) : Set(lowerings.flatMap(\.resources))))
      .union(additionalResources)
    guard resourceIDs.isSubset(of: Set(ledger.resources.keys)) else {
      throw CoreError.invalidState("unknown selected locked resource")
    }
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    #if os(macOS)
      let current = "macos"
    #else
      let current = "linux"
    #endif
    for lowering in lowerings {
      guard (renderers ?? compatibilityRenderers)[lowering.format] != nil else {
        throw CoreError.invalidState("unknown renderer format")
      }
      guard lowering.platform == current else {
        throw CoreError.invalidState("locked lowering is incompatible with platform: " + platform)
      }
    }
    // Charge every occurrence, not only unique stored resources. Reserve this before reads;
    // the same Core expansion limit also bounds all outputs retained by this replay.
    let sizes = ledger.resources.mapValues { resource in
      (resource.entries + resource.support).reduce(0) { $0 + ($1.byteCount ?? 0) }
    }
    var remaining = limits.resourceBytes
    for lowering in lowerings {
      for id in lowering.resources {
        let size = sizes[id]!
        guard size <= remaining else { throw CoreError.invalidState("replay input byte budget") }
        remaining -= size
      }
    }
    for id in additionalResources.subtracting(lowerings.flatMap(\.resources)) {
      let size = sizes[id]!
      guard size <= remaining else { throw CoreError.invalidState("replay input byte budget") }
      remaining -= size
    }
    let workspace = try SourceCache.privateWorkspace(prefix: "agents-ledger-")
    defer { try? FileManager.default.removeItem(at: workspace) }
    return try SourceResolutionSession.withTemporaryRead(
      store: store, sourcePolicy: sourcePolicy, requireRecordedTransport: requireRecordedTransport,
      acquisitions: acquisitions
    ) { session in
      var acquired: [String: URL] = [:]
      for (id, resource) in ledger.resources.sorted(by: { $0.key < $1.key })
      where resourceIDs.contains(id) {
        try Task.checkCancellation()
        let file: URL
        var snapshotRoot: URL?
        if resource.kind == .liveEdit {
          file = try LedgerResources.liveEditSource(resource, ledger: ledger, roots: roots).authored
        } else if resource.kind == .embedded || resource.kind == .artifact {
          if !completeSourceAdmission, let artifact = resource.artifact {
            for origin in EffectiveSourcePolicy.artifactOrigins(artifact) {
              try sourcePolicy.require(origin)
              guard let location = origin.identity, let url = URL(string: location) else {
                throw SourceAccessError.invalidRepository
              }
              try store.environment.sourceAccess.requireDirectHTTP(url)
            }
          }
          file = try materialize(
            resource, objects: ledger.contentObjects, in: workspace,
            preserveSpelling: anchorLockedGit)
        } else {
          var sourceID = resource.source
          while let parent = ledger.sources[sourceID]?.container { sourceID = parent }
          let source = ledger.sources[sourceID]!
          let identity = try ledger.sourceIdentity(sourceID, roots: roots)
          let cache = SourceCache(
            store: store, sourcePolicy: sourcePolicy,
            requireRecordedTransport: requireRecordedTransport,
            acquisitions: session.acquisitions)
          let declaration: SourceDeclaration
          if let transport = source.transport {
            declaration = SourceDeclaration(
              kind: .git, location: transport, requirement: .revision(source.revision))
          } else if let location = source.location {
            declaration = SourceDeclaration(
              kind: .local, location: try location.resolve(roots: roots).path,
              requirement: .revision(source.revision))
          } else {
            throw CoreError.invalidState("missing pinned source coordinates")
          }
          if source.archive == nil { try cache.requireGit(declaration) }
          let view: SourceSnapshot
          let verifySupport = offline && observeResource != nil && !resource.support.isEmpty
          if let archive = source.archive {
            view = try session.snapshot(
              declaration,
              at: .init(revision: source.revision, version: source.version, archive: archive),
              offline: offline)
          } else if (offline || resource.support.isEmpty) && !verifySupport,
            let tree = try cache.existingPinnedTree(sourceID: identity, revision: source.revision)
          {
            view = try SourceSnapshot(
              snapshot: .init(source: identity, revision: source.revision), pin: nil, root: tree)
          } else if offline {
            let tree = try cache.withOfflineSnapshot(
              sourceID: identity, source: LockedSource(kind: source.kind, url: source.transport),
              revision: source.revision, useMaterializedTree: !verifySupport,
              lockedPaths: anchorLockedGit
                ? [resource.path] + resource.support.filter { $0.kind != .directory }.map(\.path)
                : nil
            ) { tree, durable in
              if durable { return tree }
              let copy = workspace.appendingPathComponent(UUID().uuidString)
              try FileManager.default.moveItem(at: tree, to: copy)
              return copy
            }
            view = try SourceSnapshot(
              snapshot: .init(source: identity, revision: source.revision), pin: nil, root: tree)
          } else {
            view = try session.snapshot(declaration, at: SourceRevision(revision: source.revision))
          }
          snapshotRoot = view.root
          if anchorLockedGit {
            let captured = try LedgerResources.captureLockedGit(resource, snapshotRoot: view.root)
            var frozen = resource
            frozen.kind = .embedded
            frozen.entries = captured.entries
            frozen.support = captured.support
            file = try materialize(
              frozen, objects: captured.objects, in: workspace, preserveSpelling: true)
          } else {
            file = try view.resource(resource.path)
          }
        }
        if resource.kind != .liveEdit
          && !(anchorLockedGit && resource.kind == .git)
          && !(offline && observeResource != nil && resource.kind == .git)
        {
          let captured = try LedgerResources.capture(
            file, embed: false, limits: limits, sourceRoot: snapshotRoot)
          let expected = resource.entries.map { entry -> LedgerEntry in
            var entry = entry
            entry.object = nil
            return entry
          }
          guard captured.hash == resource.hash, captured.entries == expected,
            snapshotRoot == nil || captured.support == resource.support
          else {
            throw CoreError.invalidState("locked resource content or execute bits changed")
          }
        }
        try observeResource?(id, file, snapshotRoot)
        acquired[id] = file
      }
      var result: [ReplayedArtifact] = []
      var sealed: [LockedLowering] = []
      var names = Set<String>()
      for lowering in lowerings {
        try Task.checkCancellation()
        let table = renderers ?? compatibilityRenderers(outputBytes: remaining)
        let rendered = try table[lowering.format]!(lowering, ledger, acquired)
        for artifact in rendered {
          let count: Int
          if let bytes = artifact.bytes {
            count = bytes.count
          } else if let tree = artifact.tree {
            let captured = try LedgerResources.capture(tree, embed: false, limits: limits)
            count = (captured.entries + captured.support).reduce(0) { $0 + ($1.byteCount ?? 0) }
          } else if let values = artifact.values {
            count = try ResolvedLedgerCodec.bytes(values).count
          } else if let location = artifact.location {
            count = try ResolvedLedgerCodec.bytes(location).count
          } else {
            throw CoreError.invalidState("missing rendered output")
          }
          guard count <= remaining else {
            throw CoreError.invalidState("replay output byte budget")
          }
          remaining -= count
        }
        let digests = try rendered.map { try $0.digest(limits: limits) }
        guard recording || digests == lowering.artifacts else {
          throw CoreError.invalidState("locked renderer output hash mismatch")
        }
        for artifact in rendered {
          guard names.insert(artifact.name).inserted else {
            throw CoreError.invalidState("overlapping rendered artifacts")
          }
        }
        var locked = lowering
        locked.artifacts = digests
        sealed.append(locked)
        result += rendered
      }
      return try body(result, sealed, acquired, workspace)
    }
  }

  private static func materialize(
    _ resource: LedgerResource, objects: [String: Data], in workspace: URL,
    preserveSpelling: Bool
  ) throws -> URL {
    var embedded = resource
    embedded.kind = .embedded
    let name = UUID().uuidString
    let destination = workspace.appendingPathComponent(name)
    // A Foundation file URL can normalize Unicode on write. The locked renderer hashes
    // exact UTF-8 entry names, so construct the borrowed tree through directory descriptors.
    if preserveSpelling,
      !resource.support.isEmpty
        || resource.entries.contains(where: { $0.path == "." && $0.kind == .directory })
    {
      let entries = try LedgerResources.validatedEntries(embedded)
      let parent = try DirectoryHandle.readDirectory(at: workspace)
      guard
        try parent.publishPortableTree(
          named: name, entries: Array(entries.values), objects: objects, beforeCommit: {})
      else { throw CoreError.invalidState("replay workspace collision") }
    } else {
      try LedgerResources.materialize(embedded, objects: objects, at: destination)
    }
    return resource.support.isEmpty
      ? destination : try PathSafety.resolvedChild(base: destination, subpath: resource.path)
  }

  private static func skill(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    guard lowering.resources.count == 1, let resource = lowering.resources.first,
      let tree = resources[resource], let name = lowering.layout.object?["name"]?.text
    else {
      throw CoreError.invalidState("invalid skill lowering")
    }
    if let record = ledger.resources[resource], record.kind == .liveEdit {
      return [.init(name: name, kind: .link, location: record.location)]
    }
    return [.init(name: name, kind: .tree, tree: tree)]
  }

  private static func antigravityRule(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    guard let owner = lowering.inputs.first, let component = ledger.components[owner],
      let unitID = lowering.resources.first, let unit = ledger.resources[unitID],
      let file = resources[unitID], let name = lowering.layout.object?["name"]?.text,
      let deployment = ledger.deployments.first(where: { $0.id == lowering.deployments.first })
    else { throw CoreError.invalidState("invalid locked Antigravity rule") }
    var inputs: [String: URL] = [:]
    for id in lowering.resources.dropFirst() {
      guard let input = ledger.resources[id], input.source == component.source,
        let url = resources[id], inputs.updateValue(url, forKey: input.path) == nil
      else { throw CoreError.invalidState("invalid locked Antigravity include") }
    }
    let leaf = deployment.target.path
    let scope: InstallScope =
      deployment.target.root == InstructionLocations.antigravityProjectRoot
      ? .project : .user
    let bytes = try AntigravityRuleV1.render(
      FileSystem.read(at: file), path: unit.path, leaf: leaf, scope: scope
    ) {
      path in
      guard let input = inputs.removeValue(forKey: path) else {
        throw AntigravityRuleV1.failure(leaf, "file reference is missing from the lock: \(path)")
      }
      return try FileSystem.read(at: input)
    }
    guard inputs.isEmpty, Instructions.hash(bytes) == deployment.expectedHash else {
      throw CoreError.invalidState("Antigravity rule does not match its locked inputs: " + leaf)
    }
    return [.init(name: name, kind: .file, bytes: bytes)]
  }

  private static func instructions(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL],
    outputBytes: Int
  ) throws -> [ReplayedArtifact] {
    let bytes = try lowering.resources.map { id in
      guard let resource = resources[id] else {
        throw CoreError.invalidState("missing instruction input")
      }
      return try FileSystem.read(at: resource)
    }
    guard let name = lowering.layout.object?["name"]?.text,
      lowering.layout.object?["headingOffset"]?.integer ?? 0 == 0
    else {
      throw CoreError.invalidState("unsupported instruction layout")
    }
    return [
      .init(
        name: name, kind: .file,
        bytes: try InstructionCompatibility.renderSections(
          bytes, ids: lowering.resources, byteLimit: outputBytes))
    ]
  }

  package static func exportPrompt(
    _ lowering: LockedLowering, ledger: ResolvedLedger, resources: [String: URL],
    roots: [String: URL]
  ) throws -> Data {
    let locations = try lowering.inputs.compactMap {
      try ledger.components[$0]?.payload.object?["localAppend"].map {
        try LedgerLocation(ledgerValue: $0)
      }
    }
    let paths = try Set(locations.map { try $0.resolve(roots: roots) })
    guard paths.count <= 1 else {
      throw CoreError.invalidState("prompt has conflicting consumer append locations")
    }
    let append = try locations.first.map { try $0.readContainedFile(roots: roots) }
    return try renderPrompt(
      lowering, ledger, resources, outputBytes: LedgerLimits.standard.resourceBytes,
      consumerAppend: append
    ).first!.bytes!
  }

  private static func renderPrompt(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL],
    outputBytes: Int, consumerAppend: Data? = nil
  ) throws -> [ReplayedArtifact] {
    guard let count = lowering.layout.object?["sectionCount"]?.integer, count > 0,
      count <= lowering.resources.count, lowering.resources.count <= count + 1,
      let name = lowering.layout.object?["name"]?.text
    else { throw CoreError.invalidState("invalid prompt layout") }
    let sections = try lowering.resources.prefix(count).map { id in
      guard let file = resources[id] else { throw CoreError.invalidState("missing prompt section") }
      return try FileSystem.read(at: file)
    }
    var append = try lowering.resources.dropFirst(count).first.map { id in
      guard let file = resources[id] else { throw CoreError.invalidState("missing prompt append") }
      return try FileSystem.read(at: file)
    }
    if let consumerAppend, !consumerAppend.isEmpty {
      if append?.isEmpty == false {
        append!.append(Data("\n".utf8))
        append!.append(consumerAppend)
      } else {
        append = consumerAppend
      }
    }
    return [
      .init(
        name: name, kind: .file,
        bytes: try InstructionCompatibility.renderPrompt(
          sections, ids: Array(lowering.resources.prefix(count)), append: append,
          byteLimit: outputBytes))
    ]
  }

  private static func forwarding(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL],
    outputBytes: Int
  ) throws -> [ReplayedArtifact] {
    guard let name = lowering.layout.object?["name"]?.text,
      let target = ledger.deployments.first(where: { $0.id == lowering.deployments.first })?.target,
      let path = ClaudeInstructionPath(rawValue: target.path)
    else { throw CoreError.invalidState("invalid forwarding layout") }
    let block = ClaudeForwarding.renderBlock(for: path)
    guard block.utf8.count <= outputBytes else {
      throw CoreError.invalidState("replay output byte budget")
    }
    return [.init(name: name, kind: .file, bytes: Data(block.utf8))]
  }
}
