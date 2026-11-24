import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation
import NativeDocuments

package struct AggregatedChange {
  package let deployment: LedgerDeployment
  package let url: URL
  package let before: Data?
  package let after: Data?
  package let changed: Bool
  package let native: Bool
  package var afterLink: URL? = nil
  package var accessChange: PrivateAccessChange? = nil
  package var effectiveReaders: [AgentID] = []
  package var privateMaterialization = false
  package var requiredBindings: [String] = []
  package var memberAccessChanges: [PrivateTreeAccessChange] = []
  package var symbolicBefore: LedgerValue? = nil
  package var symbolicAfter: LedgerValue? = nil
  package var configurationBefore: String? = nil
  package var configurationAfter: String? = nil
}

/// One prepared physical replacement owns all logical contributions at that destination.
package final class ArtifactAggregation: PreparedEvidence {
  package private(set) var ledger: ResolvedLedger
  package private(set) var changes: [AggregatedChange] = []
  package private(set) var fingerprints: [String] = []
  private let store: StateStore
  private let roots: [String: URL]
  private let resources: [String: URL]
  private let replace: Bool
  private let selectedKinds: Set<DeclaredComponentKind>?
  private let selectedNames: Set<String>
  private let selectedIdentities: Set<String>?
  private let retargetedInstructions: Set<String>
  private var unownedInstructions: [String] = []
  private var unownedSkills: [String] = []
  private var targets: [String: TargetPrecondition] = [:]
  private var writes: [String: FileTransaction.Source] = [:]
  private var deletes = Set<String>()
  private var capsules: [String: URL] = [:]
  private var skillTargets: [String: SkillInstallationTarget] = [:]
  private var skillWritePaths = Set<String>()
  private var skillDeletePaths = Set<String>()
  private var skillContent: [String: (String, [String: Bool])] = [:]
  private var privateWrites:
    [(PreparedPrivateMaterialization, Set<String>, (RuntimeBindingValues) throws -> Data)] = []
  private var nativePrivateWrites:
    [(
      PreparedPrivateMaterialization, Set<String>,
      (RuntimeBindingValues) throws -> PrivateMaterializationResult
    )] = []
  private var privateTrees: [(PreparedPrivateMaterialization, [PrivateTreeEntry])] = []
  private var resourceEvidence: [TargetPrecondition] = []
  private var physicalPaths: [NativeTargetIdentity: String] = [:]

  package init(
    ledger: ResolvedLedger, previous: ResolvedLedger, artifacts: [ReplayedArtifact],
    resources: [String: URL], workspace: URL, store: StateStore, roots: [String: URL],
    replace: Bool,
    changingAccess: Bool,
    kinds: Set<DeclaredComponentKind>? = nil, names: Set<String> = [],
    selectedIdentities: Set<String>? = nil,
    installations: [SkillInstallationTarget] = [], retargetedInstructions: Set<String> = []
  ) throws {
    self.ledger = ledger
    self.store = store
    self.roots = roots
    self.resources = resources
    self.replace = replace
    for target in installations { skillTargets[target.url.path] = target }
    selectedKinds = kinds
    selectedNames = names
    self.selectedIdentities = selectedIdentities
    self.retargetedInstructions = retargetedInstructions
    for (id, file) in resources where ledger.resources[id]?.kind != .liveEdit {
      resourceEvidence.append(try TargetPrecondition(file))
    }
    func selected(_ deployment: LedgerDeployment, in ledger: ResolvedLedger) throws -> Bool {
      try deployment.owners.contains { try isSelected($0, in: ledger) }
    }
    for (id, source) in resources where ledger.resources[id]?.kind != .liveEdit {
      let resource = ledger.resources[id]!
      let destination = try resourceDestination(id)
      if FileManager.default.fileExists(atPath: destination.path) {
        resourceEvidence.append(try TargetPrecondition(destination))
      }
      if resource.kind == .embedded || resource.kind == .artifact {
        let capsule = workspace.appendingPathComponent(
          "capsule-" + FileHash.sha256Hex(data: Data(id.utf8)))
        try FileSystem.createDirectory(at: capsule)
        if resource.support.isEmpty {
          try FileManager.default.copyItem(
            at: source, to: capsule.appendingPathComponent("payload"))
        } else {
          var sourceRoot = source
          if resource.path != "." {
            for _ in resource.path.split(separator: "/") { sourceRoot.deleteLastPathComponent() }
          }
          let captured = try LedgerResources.capture(
            source, embed: true, limits: .standard, sourceRoot: sourceRoot)
          guard captured.hash == resource.hash else {
            throw CoreError.invalidState("retention input changed")
          }
          var embedded = resource
          embedded.kind = .embedded
          embedded.entries = captured.entries
          embedded.support = captured.support
          try LedgerResources.materialize(embedded, objects: captured.objects, at: capsule)
        }
        capsules[id] = capsule
        resourceEvidence.append(try TargetPrecondition(capsule))
      }
    }
    let artifacts = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0) })
    let affectedPaths = try Set(
      previous.deployments.filter { try selected($0, in: previous) }.map {
        try installationURL($0).path
      }
        + ledger.deployments.filter { try selected($0, in: ledger) }.map {
          try installationURL($0).path
        })
    let previousByPath = try Dictionary(
      grouping: previous.deployments.filter { try affectedPaths.contains(installationURL($0).path) }
    ) { try installationURL($0).path }
    var byPath = try Dictionary(
      grouping: ledger.deployments.filter { try affectedPaths.contains(installationURL($0).path) }
    ) { try installationURL($0).path }
    var native: [String: [(LockedLowering, NativeMCPContribution, MaterializationTarget)]] = [:]
    for lowering in ledger.lowerings
    where lowering.format.hasSuffix("-mcp@1") {
      let contribution = try MCPLayoutV1.contribution(lowering, ledger: ledger)
      let route = try DeploymentConstruction.physicalRoute(
        DeploymentConstruction.route(contribution), ledger: previous, store: store)
      let target = try store.nativeTarget(for: route)
      native[try physicalPath(route), default: []].append((lowering, contribution, target))
    }
    // Removed native regions still participate in the same physical aggregation.
    for lowering in previous.lowerings
    where lowering.format.hasSuffix("-mcp@1") {
      let c = try MCPLayoutV1.contribution(lowering, ledger: previous)
      let path = try physicalPath(
        DeploymentConstruction.physicalRoute(
          DeploymentConstruction.route(c), ledger: previous, store: store))
      if native[path] == nil { native[path] = [] }
    }
    let currentComponents = try componentOutputs(ledger, artifacts: artifacts, routing: previous)
    let oldNative = Set(
      previous.lowerings.filter {
        $0.format.hasSuffix("-components@1") || $0.format.hasSuffix("-generated-plugin@1")
      }.map(\.id))
    try LedgerReplay.withLockedResources(
      previous, store: store, roots: roots, limits: .standard, lowerings: oldNative
    ) {
      oldArtifacts, _, _ in
      let oldComponents = try componentOutputs(
        previous,
        artifacts: Dictionary(uniqueKeysWithValues: oldArtifacts.map { ($0.name, $0) }),
        routing: previous)
      let generatedPaths = try prepareGeneratedPlugins(
        previous: previous, artifacts: artifacts,
        oldArtifacts: Dictionary(uniqueKeysWithValues: oldArtifacts.map { ($0.name, $0) }),
        workspace: workspace, changingAccess: changingAccess)
      guard
        generatedPaths.isDisjoint(
          with: Set(currentComponents.keys).union(oldComponents.keys).union(native.keys))
      else {
        throw CoreError.invalidState("generated native container overlaps another native target")
      }
      for path in generatedPaths {
        native[path] = []
        byPath.removeValue(forKey: path)
      }
      for path in Set(native.keys).union(currentComponents.keys).union(oldComponents.keys)
        .subtracting(generatedPaths).sorted()
      {
        let next = currentComponents[path] ?? []
        let old = oldComponents[path] ?? []
        let entries = next + old
        if let first = entries.first {
          switch first.output.content {
          case .file, .nativePlugin, .generatedLSPPlugin:
            guard native[path] == nil else {
              throw CoreError.invalidState("whole native object overlaps a shared document")
            }
            if try entries.contains(where: {
              try isSelected(
                $0.contribution.component,
                in: ledger.components[$0.contribution.component] == nil ? previous : ledger)
            }) {
              try prepareWholeNative(
                path: path, next: next, old: old, previous: previous,
                artifacts: artifacts, workspace: workspace, changingAccess: changingAccess)
            } else {
              for entry in next {
                let privatePlan =
                  try store.materializationReceipt(for: entry.target) == nil
                  ? nil : store.preparePrivateMaterialization(entry.target)
                try record(
                  entry, previous: previous, changed: false,
                  readers: Array(
                    Set(
                      entry.contribution.knownReaders
                        + DeploymentConstruction.route(
                          entry.output, request: entry.contribution.request
                        )
                        .knownReaders)
                  ).sorted { $0.rawValue < $1.rawValue },
                  privatePlan: privatePlan, ownership: .generated)
              }
            }
          case .ignore:
            guard native[path] == nil else {
              throw CoreError.invalidState("ignore block overlaps a structured document")
            }
            try prepareIgnore(path: path, next: next, old: old, previous: previous)
          default:
            try prepareNative(
              path: path, contributions: native[path] ?? [], previous: previous,
              changingAccess: changingAccess, components: next, oldComponents: old)
          }
        } else {
          try prepareNative(
            path: path, contributions: native[path] ?? [], previous: previous,
            changingAccess: changingAccess)
        }
        native[path] = native[path] ?? []
        byPath.removeValue(forKey: path)
      }
    }
    for path in Set(byPath.keys).union(previousByPath.keys).sorted() where native[path] == nil {
      let url = URL(fileURLWithPath: path)
      let capture = try TargetPrecondition(url).capturingPublicationAccess()
      targets[path] = capture
      let old = previousByPath[path] ?? []
      let next = byPath[path] ?? []
      let sharedImport = (old + next).contains { $0.ownership == .importBlock }
      fingerprints.append(try capture.displayEvidence(includeContent: !sharedImport))
      if sharedImport {
        let observed = try InstructionTargets.ownedImportBytes(
          TargetPrecondition.readingFile(url).bytes)
        fingerprints.append(try ResolvedLedgerCodec.digest([path: observed]))
      }
      if next.isEmpty {
        guard let deployment = old.first else { continue }
        if deployment.route == "agents/skill@1" {
          deletes.insert(path)
          skillDeletePaths.insert(path)
          changes.append(
            .init(
              deployment: deployment, url: url, before: nil, after: nil,
              changed: FileManager.default.fileExists(atPath: path), native: false))
        } else {
          let before = try TargetPrecondition.readingFile(url).bytes
          let after = try InstructionCompatibility.obsolete(deployment, before: before)
          if before != after {
            if let after { writes[path] = .data(after) } else { deletes.insert(path) }
          }
          changes.append(
            .init(
              deployment: deployment, url: url, before: before, after: after,
              changed: before != after, native: false))
        }
        continue
      }
      let entries = try next.map {
        deployment -> (LedgerDeployment, ReplayedArtifact, LockedLowering) in
        guard
          let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) }),
          let name = lowering.artifacts.first?.name, let artifact = artifacts[name]
        else { throw CoreError.invalidState("deployment has no rendered artifact") }
        return (deployment, artifact, lowering)
      }
      let first = entries[0]
      guard
        try entries.allSatisfy({
          try $0.1.digest(limits: .standard).hash == first.1.digest(limits: .standard).hash
            && $0.1.kind == first.1.kind
            && $0.2.layout.object?["mode"] == first.2.layout.object?["mode"]
        })
      else {
        throw CoreError.invalidState("incompatible contributions share a physical target")
      }
      let deployment = first.0
      let artifact = first.1
      if deployment.route == "agents/skill@1" {
        if let prior = old.first,
          previous.components[prior.owners[0]]?.payload.object?["mode"]?.text != "edit",
          url.resolvingSymlinksInPath().path != url.path
        {
          resourceEvidence.append(try TargetPrecondition(url.resolvingSymlinksInPath()))
        }
        if old.isEmpty, FileManager.default.fileExists(atPath: path) {
          unownedSkills.append(
            "skill '\(ledger.components[deployment.owners[0]]!.name)' in \(store.scope.rawValue) scope has unmanaged content at \(path); move or remove it first"
          )
        }
        let mode = first.2.layout.object?["mode"]?.text ?? "copy"
        let source: FileTransaction.Source
        if let location = artifact.location {
          source = .link(try location.resolve(roots: roots))
        } else if mode == InstallMode.link.rawValue {
          source = .link(try resourceDestination(first.2.resources[0]))
        } else if let tree = artifact.tree {
          try DeploymentConstruction.validateCopiedSkill(tree)
          source = .copy(tree)
        } else {
          throw CoreError.invalidState("skill artifact has no content")
        }
        let changed: Bool
        switch source {
        case .link(let destination):
          let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
          let current = existing.map {
            URL(fileURLWithPath: $0, relativeTo: url.deletingLastPathComponent())
              .standardizedFileURL.path
          }
          changed = current != destination.standardizedFileURL.path
        case .copy(let tree):
          let hash = try FileHash.folderHash(tree)
          let flags = try FileHash.executableFlags(tree)
          let type =
            try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
          changed =
            type != .typeDirectory || (try? FileHash.folderHash(url)) != hash
            || (try? FileHash.executableFlags(url)) != flags
        default: changed = true
        }
        if let tree = artifact.tree, let id = first.2.resources.first,
          let resource = ledger.resources[id]
        {
          skillContent[path] = (resource.hash, try FileHash.executableFlags(tree))
        }
        if changed {
          writes[path] = source
          skillWritePaths.insert(path)
        }
        changes.append(
          .init(
            deployment: deployment, url: url, before: nil, after: nil,
            changed: changed, native: false,
            afterLink: { if case .link(let url) = source { url } else { nil } }()))
      } else {
        let before = try TargetPrecondition.readingFile(url).bytes
        var after = artifact.bytes
        if deployment.route == "agents/instructions@1", let after {
          try InstructionTargets(store: store).validateRenderedLinks(after, at: url)
        }
        if deployment.ownership == .importBlock {
          guard let path = ClaudeInstructionPath(rawValue: deployment.target.path) else {
            throw CoreError.invalidState("invalid locked import location")
          }
          after =
            before == nil && !old.isEmpty
            ? nil : try InstructionTargets.importBlock(in: before ?? Data(), at: path).bytes
        } else if let before, before != after, !Instructions.isOwned(before), !replace {
          unownedInstructions.append(InstructionLocations.key(for: url, store: store))
        }
        if before != after {
          if let after { writes[path] = .data(after) } else { deletes.insert(path) }
        }
        changes.append(
          .init(
            deployment: deployment, url: url, before: before, after: after,
            changed: before != after, native: false))
      }
    }
    try validate()
  }

  private func resourceDestination(_ id: String, in selected: ResolvedLedger? = nil) throws -> URL {
    try Self.resourceDestination(id, ledger: selected ?? ledger, store: store, roots: roots)
  }

  private func installationURL(_ deployment: LedgerDeployment) throws -> URL {
    guard deployment.route == "agents/skill@1" else {
      return InstructionLocations.physical(try deployment.target.resolve(roots: roots))
    }
    guard let agent = deployment.recipients.first else {
      throw CoreError.invalidState("missing skill recipient")
    }
    let target = try store.skillInstallationTarget(for: agent, named: deployment.target.path)
    guard let admitted = skillTargets[target.url.path] else {
      throw CoreError.invalidState("skill installation was not admitted")
    }
    return admitted.url
  }

  package static func resourceDestination(
    _ id: String, ledger: ResolvedLedger, store: StateStore, roots: [String: URL]? = nil
  ) throws -> URL {
    guard let resource = ledger.resources[id] else {
      throw CoreError.invalidState("missing deployment resource")
    }
    if let location = resource.location {
      return try location.resolve(roots: roots ?? store.ledgerRoots)
    }
    if let root = try gitDestination(resource, ledger: ledger, store: store, roots: roots) {
      return root.appendingPathComponent(resource.path)
    }
    let base = store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + String(id.dropFirst(7)))
    return base.appendingPathComponent(resource.support.isEmpty ? "payload" : resource.path)
  }

  private static func gitDestination(
    _ resource: LedgerResource, ledger: ResolvedLedger, store: StateStore, roots: [String: URL]?
  ) throws -> URL? {
    guard resource.kind == .git else { return nil }
    var sourceID = resource.source
    while let parent = ledger.sources[sourceID]?.container { sourceID = parent }
    guard let source = ledger.sources[sourceID] else {
      throw CoreError.invalidState("missing resource source")
    }
    return SourceCache(store: store).materializedURL(
      sourceID: try ledger.sourceIdentity(sourceID, roots: roots ?? store.ledgerRoots),
      revision: source.revision)
  }

  private func physicalPath(_ requested: NativeTargetRoute) throws -> String {
    let route = try DeploymentConstruction.physicalRoute(requested, ledger: ledger, store: store)
    let target = try store.nativeTarget(for: route)
    guard let identity = try store.nativeTargetIdentity(for: route) else { return target.url.path }
    if let path = physicalPaths[identity] {
      if path != target.url.path { resourceEvidence.append(try TargetPrecondition(target.url)) }
      return path
    }
    physicalPaths[identity] = target.url.path
    return target.url.path
  }

  private func isSelected(_ id: String, in selected: ResolvedLedger) throws -> Bool {
    guard let c = selected.components[id] else { return false }
    if try retargetedInstructions.contains(
      LedgerImpact.identity(c, ledger: selected, roots: roots))
    {
      return true
    }
    if let selectedIdentities {
      return try selectedIdentities.contains(
        LedgerImpact.identity(c, ledger: selected, roots: roots))
    }
    return (selectedKinds?.contains(DeclaredComponentKind(rawValue: c.kind)!) ?? true)
      && (selectedNames.isEmpty
        || selectedNames.contains(c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name))
  }

  private struct ComponentOutputEntry {
    let lowering: LockedLowering
    let contribution: NativeComponentContribution
    let output: NativeComponentOutput
    let target: MaterializationTarget
    let index: Int
    var id: String { lowering.id + ":" + String(index) }
  }

  private func componentOutputs(
    _ selected: ResolvedLedger, artifacts: [String: ReplayedArtifact], routing: ResolvedLedger
  ) throws -> [String: [ComponentOutputEntry]] {
    var result: [String: [ComponentOutputEntry]] = [:]
    for lowering in selected.lowerings where lowering.format.hasSuffix("-components@1") {
      let contribution = try NativeComponentLayoutsV1.contribution(
        lowering, ledger: selected,
        artifacts: try lowering.artifacts.map { digest in
          guard let artifact = artifacts[digest.name] else {
            throw CoreError.invalidState("missing sealed native output")
          }
          return artifact
        }, limits: .standard)
      for (index, output) in contribution.outputs.enumerated() {
        let route = try DeploymentConstruction.physicalRoute(
          DeploymentConstruction.route(output, request: contribution.request),
          ledger: selected.deployments.contains(where: { $0.route.hasPrefix("agents/opencode-") })
            ? selected : routing, store: store)
        let target = try store.nativeTarget(for: route)
        result[try physicalPath(route), default: []].append(
          .init(
            lowering: lowering, contribution: contribution,
            output: output, target: target, index: index))
      }
    }
    return result
  }

  private func location(_ target: MaterializationTarget) -> LedgerLocation {
    let parts = target.path.split(separator: "/", maxSplits: 1)
    return .init(kind: .registered, root: String(parts[0]), path: String(parts[1]))
  }

  private func record(
    _ entry: ComponentOutputEntry, previous: ResolvedLedger, changed: Bool,
    readers: [AgentID], privatePlan: PreparedPrivateMaterialization? = nil,
    bindings: [String] = [], ownership: LedgerDeployment.Ownership = .ownedValues
  ) throws {
    let identity = try LedgerImpact.identity(
      ledger.components[entry.contribution.component]!, ledger: ledger, roots: roots)
    let oldComponent = try previous.components.values.first {
      try LedgerImpact.identity($0, ledger: previous, roots: roots) == identity
    }
    let deployment = LedgerDeployment(
      id: entry.id, target: location(entry.target), route: entry.lowering.format,
      owners: [entry.contribution.component], recipients: entry.contribution.recipients,
      ownership: ownership, expectedHash: entry.lowering.artifacts[0].hash,
      created: previous.deployments.first {
        $0.route == entry.lowering.format
          && (try? $0.target.resolve(roots: roots).path) == entry.target.url.path
      }?.created ?? !FileManager.default.fileExists(atPath: entry.target.url.path))
    ledger.deployments.removeAll { $0.id == entry.id }
    ledger.deployments.append(deployment)
    if let i = ledger.lowerings.firstIndex(where: { $0.id == entry.lowering.id }) {
      if !ledger.lowerings[i].deployments.contains(entry.id) {
        ledger.lowerings[i].deployments.append(entry.id)
      }
    }
    changes.append(
      .init(
        deployment: deployment, url: entry.target.url, before: nil, after: nil,
        changed: changed, native: true, accessChange: privatePlan?.accessChange,
        effectiveReaders: readers,
        privateMaterialization: privatePlan != nil, requiredBindings: bindings,
        memberAccessChanges: privatePlan?.memberAccessChanges ?? [],
        symbolicBefore: oldComponent?.payload,
        symbolicAfter: ledger.components[entry.contribution.component]?.payload))
  }

  private func componentValue(
    _ value: NativeComponentValue, values: RuntimeBindingValues?,
    selected: ResolvedLedger
  ) throws -> NativeValue {
    try Self.componentValue(value, values: values, selected: selected, store: store, roots: roots)
  }

  private static func componentValue(
    _ value: NativeComponentValue, values: RuntimeBindingValues?,
    selected: ResolvedLedger, store: StateStore, roots: [String: URL], symbolicVariant: Int = 0
  ) throws -> NativeValue {
    var environment = store.environment
    var symbolic: [String: Data] = [:]
    if values == nil {
      // Preview converts the typed program without reading runtime values.
      for placement in value.bindings {
        switch placement.binding {
        case .secret(let name):
          symbolic[name] = Data(
            ("agents-symbolic-secret-" + String(symbolicVariant) + "-"
              + FileHash.sha256Hex(data: Data(name.utf8))).utf8)
        case .environment(let name):
          environment.environment[name] =
            "agents-symbolic-environment-" + String(symbolicVariant) + "-"
            + FileHash.sha256Hex(data: Data(name.utf8))
        case .literal: break
        }
      }
    }
    let paths = try selected.resources.keys.reduce(into: [String: String]()) {
      $0[$1] = try Self.resourceDestination($1, ledger: selected, store: store, roots: roots).path
    }
    return try value.stagedValue(
      bindings: values ?? RuntimeBindingValues(symbolic), environment: environment,
      resourcePaths: paths,
      budget: NativeDocumentBudget(
        limits: .init(
          storage: LedgerLimits.standard.resourceBytes,
          work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
          depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes)),
      codexCommandShell: .posix, cursorCommandShell: .posix)
  }

  private static func generatedManifestMatches(
    _ manifest: NativeComponentValue, observed: NativeValue?, selected: ResolvedLedger,
    privateGeneration: Bool, store: StateStore, roots: [String: URL]
  ) throws -> Bool {
    guard let observed else { return false }
    let first = try Self.componentValue(
      manifest, values: nil, selected: selected, store: store, roots: roots)
    guard privateGeneration, !manifest.bindings.isEmpty else { return observed == first }
    let second = try Self.componentValue(
      manifest, values: nil, selected: selected, store: store, roots: roots, symbolicVariant: 1)
    // F determines the native positions. Only leaves changed by its binding conversion vary.
    func matches(_ actual: NativeValue, _ a: NativeValue, _ b: NativeValue) -> Bool {
      if a == b { return actual == a }
      switch (actual, a, b) {
      case (.string, .string, .string): return true
      case (.object(let actual), .object(let a), .object(let b)):
        guard Set(actual.keys) == Set(a.keys), Set(a.keys) == Set(b.keys) else { return false }
        return a.allSatisfy { matches(actual[$0.key]!, $0.value, b[$0.key]!) }
      case (.array(let actual), .array(let a), .array(let b)):
        guard actual.count == a.count, a.count == b.count else { return false }
        return a.indices.allSatisfy { matches(actual[$0], a[$0], b[$0]) }
      default: return false
      }
    }
    return matches(observed, first, second)
  }

  private func generatedManifestBytes(
    _ manifest: NativeComponentValue, values: RuntimeBindingValues?
  ) throws -> Data {
    try Self.generatedManifestBytes(
      manifest, values: values, selected: ledger, store: store, roots: roots)
  }

  /// Renders a selected symbolic value with the native JSON serializer, without physical input.
  package static func configurationPreview(_ value: NativeValue) throws -> String {
    func document(_ bytes: Data) throws -> NativeDocument {
      try NativeDocument(
        bytes: bytes, format: .json,
        budget: NativeDocumentBudget(
          limits: .init(
            storage: LedgerLimits.standard.resourceBytes, work: LedgerLimits.standard.encodedBytes,
            nodes: LedgerLimits.standard.nodes, depth: LedgerLimits.standard.depth,
            uninterruptedBytes: LedgerLimits.standard.keyBytes)))
    }
    let region = NativeRegion(keys: ["selected"])
    let bytes = try document(Data("{}".utf8)).prepare([
      .put(region: region, expected: .absent, value: value)
    ]).bytes
    guard let range = try document(bytes).read(region)?.valueRange else {
      throw CoreError.invalidState("selected configuration has no rendered range")
    }
    return String(decoding: bytes.subdata(in: range), as: UTF8.self)
  }

  private static func generatedManifestBytes(
    _ manifest: NativeComponentValue, values: RuntimeBindingValues?,
    selected: ResolvedLedger, store: StateStore, roots: [String: URL]
  ) throws -> Data {
    guard
      case .object(let fields) = try componentValue(
        manifest, values: values, selected: selected, store: store, roots: roots)
    else { throw CoreError.invalidState("generated native manifest must be an object") }
    let document = try NativeDocument(
      bytes: Data("{}".utf8), format: .json,
      budget: NativeDocumentBudget(
        limits: .init(
          storage: LedgerLimits.standard.resourceBytes, work: LedgerLimits.standard.encodedBytes,
          nodes: LedgerLimits.standard.nodes, depth: LedgerLimits.standard.depth,
          uninterruptedBytes: LedgerLimits.standard.keyBytes)))
    return try document.prepare(
      fields.keys.sorted().map {
        .put(region: .init(keys: [$0]), expected: .absent, value: fields[$0]!)
      }
    ).bytes
  }

  private func prepareWholeNative(
    path: String, next: [ComponentOutputEntry], old: [ComponentOutputEntry],
    previous: ResolvedLedger, artifacts: [String: ReplayedArtifact], workspace: URL,
    changingAccess: Bool
  ) throws {
    guard let target = (next.first ?? old.first)?.target else { return }
    let capture = try TargetPrecondition(target.url).capturingPublicationAccess()
    targets[path] = capture
    fingerprints.append(try capture.displayEvidence(includeContent: false))
    var physicalReaders = Set((next + old).flatMap { $0.contribution.knownReaders })
    for entry in next + old {
      physicalReaders.formUnion(
        try DeploymentConstruction.route(entry.output, request: entry.contribution.request)
          .knownReaders)
    }
    let readers = physicalReaders.sorted { $0.rawValue < $1.rawValue }
    guard next.count <= 1, old.count <= 1 else {
      throw CoreError.invalidState("conflicting native whole-object owners")
    }
    let hasBindings: Bool = next.contains {
      if case .generatedLSPPlugin(_, _, let manifest) = $0.output.content {
        return !manifest.bindings.isEmpty
      }
      return false
    }
    let hadBindings: Bool = old.contains {
      if case .generatedLSPPlugin(_, _, let manifest) = $0.output.content {
        return !manifest.bindings.isEmpty
      }
      return false
    }
    let receipt = try store.materializationReceipt(for: target)
    let privatePlan =
      try hasBindings || hadBindings || receipt != nil
      ? store.preparePrivateMaterialization(
        target, changingAccess: changingAccess,
        requiringReceiptForExistingTarget: hadBindings) : nil
    if let privatePlan {
      struct MemberAccess: Encodable {
        let path: String
        let before: String
        let afterOwner: UInt32
        let afterMode: UInt32
      }
      fingerprints.append(
        try ResolvedLedgerCodec.digest(
          privatePlan.memberAccessChanges.map {
            let file = try PathSafety.resolvedChild(base: target.url, subpath: $0.path)
            return MemberAccess(
              path: $0.path,
              before: try TargetPrecondition(file).displayEvidence(includeContent: false),
              afterOwner: $0.owner, afterMode: $0.mode)
          }))
    }
    func bindingNames(_ entry: ComponentOutputEntry) -> Set<String> {
      guard case .generatedLSPPlugin(_, _, let manifest) = entry.output.content else { return [] }
      return Set(
        manifest.bindings.compactMap {
          if case .secret(let name) = $0.binding { return name }
          return nil
        })
    }
    func source(_ entry: ComponentOutputEntry) throws -> FileTransaction.Source {
      switch entry.output.content {
      case .file(_, let bytes): return .data(bytes)
      case .nativePlugin(_, let resource, _):
        guard let artifact = artifacts[entry.lowering.id + "/bundle"], let tree = artifact.tree,
          ledger.resources[resource] != nil
        else { throw CoreError.invalidState("missing frozen native container") }
        return .copy(tree)
      case .generatedLSPPlugin(_, let manifestPath, let manifest):
        let tree = workspace.appendingPathComponent(
          "native-tree-" + FileHash.sha256Hex(data: Data(entry.id.utf8)))
        let file = try PathSafety.resolvedChild(base: tree, subpath: manifestPath)
        try FileSystem.createDirectory(at: file.deletingLastPathComponent())
        let bytes = try generatedManifestBytes(manifest, values: nil)
        try bytes.write(to: file)
        return .copy(tree)
      default: throw CoreError.invalidState("native whole-object content has a regional shape")
      }
    }
    let exists = FileManager.default.fileExists(atPath: path)
    if exists {
      guard let old = old.first,
        let deployment = previous.deployments.first(where: { $0.id == old.id }),
        deployment.ownership == .generated
      else {
        throw CoreError.invalidState("native target contains unmanaged content")
      }
      switch old.output.content {
      case .file(_, let bytes):
        guard try Data(contentsOf: target.url) == bytes else {
          throw CoreError.invalidState("owned native file drifted")
        }
      case .nativePlugin(_, let resource, _):
        let observed = try LedgerResources.capture(target.url, embed: false, limits: .standard)
        guard observed.hash == previous.resources[resource]?.hash,
          observed.entries.map(\.executable)
            == previous.resources[resource]?.entries.map(\.executable)
        else { throw CoreError.invalidState("owned native tree drifted") }
      case .generatedLSPPlugin(_, let manifestPath, let manifest):
        let captured = try LedgerResources.capture(target.url, embed: false, limits: .standard)
        let expectedPaths = Set([
          ".", manifestPath, (manifestPath as NSString).deletingLastPathComponent,
        ])
        guard captured.entries.allSatisfy({ expectedPaths.contains($0.path) && !$0.executable })
        else {
          throw CoreError.invalidState("generated native container has unmanaged members")
        }
        let current = try NativeDocument(
          bytes: Data(contentsOf: target.url.appendingPathComponent(manifestPath)), format: .json,
          budget: nativeBudget())
        guard
          try Self.generatedManifestMatches(
            manifest, observed: current.read(.init(keys: []))?.value, selected: previous,
            privateGeneration: receipt != nil, store: store, roots: roots)
        else { throw CoreError.invalidState("owned generated native tree drifted") }
      default: throw CoreError.invalidState("invalid whole-object ownership")
      }
    }
    if let entry = next.first {
      let desired = try source(entry)
      let changed: Bool
      switch desired {
      case .data(let bytes): changed = try !exists || Data(contentsOf: target.url) != bytes
      case .copy(let tree):
        changed = try !exists || FileHash.folderHash(target.url) != FileHash.folderHash(tree)
      default: throw CoreError.invalidState("invalid native whole-object source")
      }
      if let privatePlan {
        switch entry.output.content {
        case .generatedLSPPlugin(_, let manifestPath, let manifest):
          let parts = manifestPath.split(separator: "/")
          var members: [PrivateTreeEntry] = []
          for count in 1..<parts.count {
            members.append(.init(parts.prefix(count).joined(separator: "/"), content: .directory))
          }
          let selected = ledger
          let selectedStore = store
          members.append(
            .init(
              manifestPath,
              content: .boundFile(bindings: bindingNames(entry)) {
                values in
                try Self.generatedManifestBytes(
                  manifest, values: values, selected: selected, store: selectedStore,
                  roots: selectedStore.ledgerRoots(recordedIn: previous))
              }))
          privateTrees.append((privatePlan, members))
        case .nativePlugin:
          guard case .copy(let tree) = desired else {
            throw CoreError.invalidState("native container has no frozen tree")
          }
          let captured = try LedgerResources.capture(tree, embed: false, limits: .standard)
          let members = try captured.entries.filter { $0.path != "." }.map { item in
            let content: PrivateTreeEntry.Content
            switch item.kind {
            case .directory: content = .directory
            case .file:
              content = .file(
                try Data(contentsOf: PathSafety.resolvedChild(base: tree, subpath: item.path)),
                executable: item.executable)
            case .symlink: content = .symlink(item.link!)
            }
            return PrivateTreeEntry(item.path, content: content)
          }
          privateTrees.append((privatePlan, members))
        case .file(_, let bytes):
          privateWrites.append((privatePlan, [], { _ in bytes }))
        default: throw CoreError.invalidState("invalid private whole-object output")
        }
      } else if changed {
        writes[path] = desired
      }
      try record(
        entry, previous: previous, changed: changed || privatePlan != nil,
        readers: readers, privatePlan: privatePlan, bindings: bindingNames(entry).sorted(),
        ownership: .generated)
    } else if let entry = old.first,
      let deployment = previous.deployments.first(where: { $0.id == entry.id })
    {
      if exists { deletes.insert(path) }
      changes.append(
        .init(
          deployment: deployment, url: target.url, before: nil, after: nil,
          changed: exists, native: true, accessChange: privatePlan?.accessChange,
          effectiveReaders: readers, privateMaterialization: privatePlan != nil,
          symbolicBefore: previous.components[entry.contribution.component]?.payload))
    }
  }

  private func prepareIgnore(
    path: String, next: [ComponentOutputEntry], old: [ComponentOutputEntry],
    previous: ResolvedLedger
  ) throws {
    let url = URL(fileURLWithPath: path)
    let capture = try TargetPrecondition.readingFile(url)
    targets[path] = try capture.evidence.capturingPublicationAccess()
    fingerprints.append(try capture.evidence.displayEvidence(includeContent: false))
    let opening = "# >>> agents context ignore v1\n"
    let closing = "# <<< agents context ignore v1\n"
    func block(_ entries: [ComponentOutputEntry]) throws -> String {
      let lines = try entries.flatMap { entry -> [String] in
        guard case .ignore(let lines) = entry.output.content else {
          throw CoreError.invalidState("incompatible ignore owners")
        }
        return lines
      }
      return entries.isEmpty ? "" : opening + lines.joined(separator: "\n") + "\n" + closing
    }
    let before = capture.bytes ?? Data()
    guard let text = String(data: before, encoding: .utf8) else {
      throw CoreError.invalidState("ignore document is not UTF8")
    }
    let starts = text.components(separatedBy: opening).count - 1
    let ends = text.components(separatedBy: closing).count - 1
    guard starts == ends, starts <= 1 else {
      throw CoreError.invalidState("ambiguous managed ignore block")
    }
    let after: String
    let desired = try block(next)
    if let start = text.range(of: opening), let end = text.range(of: closing),
      start.lowerBound < end.upperBound
    {
      let range = start.lowerBound..<end.upperBound
      guard !old.isEmpty, String(text[range]) == (try block(old)) else {
        throw CoreError.invalidState("ignore block is unmanaged or drifted")
      }
      after = text.replacingCharacters(in: range, with: desired)
    } else {
      after =
        text + (!text.isEmpty && !text.hasSuffix("\n") && !desired.isEmpty ? "\n" : "") + desired
    }
    let changed = before != Data(after.utf8)
    if changed {
      if after.isEmpty,
        previous.deployments.contains(where: {
          $0.created && (try? $0.target.resolve(roots: roots).path) == path
        })
      {
        deletes.insert(path)
      } else {
        writes[path] = .data(Data(after.utf8))
      }
    }
    let readers = Array(Set((next + old).flatMap { $0.contribution.knownReaders })).sorted {
      $0.rawValue < $1.rawValue
    }
    for entry in next { try record(entry, previous: previous, changed: changed, readers: readers) }
    if next.isEmpty {
      for deployment in previous.deployments
      where (try? deployment.target.resolve(roots: roots).path) == path {
        changes.append(
          .init(
            deployment: deployment, url: url, before: nil, after: nil, changed: changed,
            native: true, effectiveReaders: readers,
            symbolicBefore: previous.components[deployment.owners[0]]?.payload))
      }
    }
  }

  private struct NativeRegionOwner {
    let key: String
    var region: NativeRegion
    var deployments: [String] = []
    var append = false
    var selected = true
    var bindings: Set<String>
    let symbolic: LedgerValue
    var render: (RuntimeBindingValues?) throws -> NativeValue
  }

  private func prepareNative(
    path: String, contributions: [(LockedLowering, NativeMCPContribution, MaterializationTarget)],
    previous: ResolvedLedger, changingAccess: Bool,
    components: [ComponentOutputEntry] = [], oldComponents: [ComponentOutputEntry] = []
  ) throws {
    let url = URL(fileURLWithPath: path)
    let capture = try TargetPrecondition.readingFile(url)
    targets[path] = try capture.evidence.capturingPublicationAccess()
    fingerprints.append(try capture.evidence.displayEvidence(includeContent: false))
    let old = try previous.lowerings.filter { $0.format.hasSuffix("-mcp@1") }.compactMap {
      lowering -> NativeMCPContribution? in
      let c = try MCPLayoutV1.contribution(lowering, ledger: previous)
      return try physicalPath(
        DeploymentConstruction.physicalRoute(
          DeploymentConstruction.route(c), ledger: previous, store: store)) == path ? c : nil
    }
    let priorTarget = try old.first.map {
      try store.nativeTarget(
        for: DeploymentConstruction.physicalRoute(
          DeploymentConstruction.route($0), ledger: previous, store: store))
    }
    guard
      let target = contributions.first?.2 ?? components.first?.target ?? oldComponents.first?.target
        ?? priorTarget
    else { return }
    let format =
      components.first?.output.route.documentFormat ?? oldComponents.first?.output.route
      .documentFormat
      ?? contributions.first?.1.descriptor.documentFormat ?? old.first!.descriptor.documentFormat
    let budget = nativeBudget()
    let document = try NativeDocument(
      bytes: capture.bytes ?? Data((format == .toml ? "" : "{}\n").utf8),
      format: format, budget: budget)
    let selectedStore = store
    let planningRoots = roots
    func valueRoots(_ values: RuntimeBindingValues?) -> [String: URL] {
      values == nil ? planningRoots : selectedStore.ledgerRoots(recordedIn: previous)
    }
    func names(_ bindings: [NativeComponentBindingPlacement]) -> Set<String> {
      Set(
        bindings.compactMap {
          switch $0.binding {
          case .environment(let n), .secret(let n): n
          case .literal: nil
          }
        })
    }
    func mcp(_ c: NativeMCPContribution, selected: ResolvedLedger) throws -> NativeRegionOwner? {
      let region = try c.descriptor.region(
        server: c.name,
        nativeProjectKey: c.descriptor.request.scope == .local
          ? try store.nativeTarget(for: .claudeMCPProject).url.deletingLastPathComponent().path
          : nil)
      let key = try ResolvedLedgerCodec.digest(c.descriptor.request.scope.rawValue + ":" + c.name)
      if try !isSelected(c.component, in: selected) {
        guard let observed = try document.read(region)?.value else { return nil }
        return .init(
          key: key, region: region,
          deployments: [
            contributions.first(where: { $0.1.component == c.component })?.0.id
              ?? previous.lowerings.first(where: {
                $0.inputs.contains(c.component) && $0.format.hasSuffix("-mcp@1")
              })!.id
          ], bindings: [], symbolic: c.value, render: { _ in observed })
      }
      let bindings = Set(
        c.bindings.filter { !$0.reference }.compactMap {
          switch $0.binding {
          case .environment(let n), .secret(let n): n
          case .literal: nil
          }
        })
      return .init(
        key: key, region: region,
        deployments: [
          contributions.first(where: { $0.1.component == c.component })?.0.id
            ?? previous.lowerings.first(where: {
              $0.inputs.contains(c.component) && $0.format.hasSuffix("-mcp@1")
            })!.id
        ], bindings: bindings, symbolic: c.value,
        render: {
          try Self.nativeValue(
            c, values: $0, ledger: selected, store: selectedStore,
            roots: valueRoots($0))
        })
    }
    func regional(_ entry: ComponentOutputEntry, selected: ResolvedLedger) throws
      -> [NativeRegionOwner]
    {
      func region(
        _ keys: [String], symbolic: LedgerValue,
        bindings: Set<String> = [], render: @escaping (RuntimeBindingValues?) throws -> NativeValue
      ) throws -> NativeRegionOwner {
        .init(
          key: try ResolvedLedgerCodec.digest(keys), region: .init(keys: keys),
          deployments: [entry.id], bindings: bindings,
          symbolic: symbolic, render: render)
      }
      switch entry.output.content {
      case .member(let member, let value):
        if try !isSelected(entry.contribution.component, in: selected) {
          guard let observed = try document.read(.init(keys: member.keys))?.value else { return [] }
          return [
            try region(
              member.keys, symbolic: selected.components[entry.contribution.component]!.payload,
              render: { _ in observed })
          ]
        }
        return [
          try region(
            member.keys, symbolic: selected.components[entry.contribution.component]!.payload,
            bindings: names(value.bindings),
            render: {
              try Self.componentValue(
                value, values: $0, selected: selected, store: selectedStore, roots: valueRoots($0))
            })
        ]
      case .claudePermissions(let policy):
        var values: [(String, NativeValue)] = []
        for (key, strings) in [("allow", policy.allow), ("ask", policy.ask), ("deny", policy.deny)]
        {
          if let strings { values.append((key, .array(strings.map(NativeValue.string)))) }
        }
        if let mode = policy.defaultMode { values.append(("defaultMode", .string(mode))) }
        return try values.map { key, value in
          try region(
            ["permissions", key],
            symbolic: selected.components[entry.contribution.component]!.payload,
            render: { _ in value })
        }
      case .hook(let hook):
        let identity = try LedgerImpact.identity(
          selected.components[entry.contribution.component]!, ledger: selected,
          roots: roots)
        return [
          .init(
            key: "hook:" + identity + ":" + String(entry.index), region: .init(keys: hook.keys),
            deployments: [entry.id], append: true,
            selected: try isSelected(entry.contribution.component, in: selected),
            bindings: names(hook.value.bindings),
            symbolic: selected.components[entry.contribution.component]!.payload,
            render: {
              try Self.componentValue(
                hook.value, values: $0, selected: selected, store: selectedStore,
                roots: valueRoots($0))
            })
        ]
      case .orderedPermissions(let rules):
        let identity = try LedgerImpact.identity(
          selected.components[entry.contribution.component]!, ledger: selected,
          roots: roots)
        let selectedOwner = try isSelected(entry.contribution.component, in: selected)
        return rules.enumerated().map { index, rule in
          .init(
            key: "permission:" + identity + ":" + String(index),
            region: .init(keys: ["permissions"]), deployments: [entry.id], append: true,
            selected: selectedOwner,
            bindings: [], symbolic: selected.components[entry.contribution.component]!.payload,
            render: { _ in
              .object([
                "action": .string(rule.tool), "resource": .string(rule.resource),
                "effect": .string(rule.effect.rawValue),
              ])
            })
        }
      default:
        throw CoreError.invalidState("whole native content cannot be prepared as a shared region")
      }
    }
    let desiredItems =
      try contributions.compactMap { try mcp($0.1, selected: ledger) }
      + components.flatMap { try regional($0, selected: ledger) }
    let oldItems =
      try old.compactMap { try mcp($0, selected: previous) }
      + oldComponents.flatMap { try regional($0, selected: previous) }
    func keyed(_ items: [NativeRegionOwner]) throws -> [String: NativeRegionOwner] {
      var result: [String: NativeRegionOwner] = [:]
      for item in items {
        if let existing = result[item.key] {
          guard
            (existing.bindings.isEmpty && item.bindings.isEmpty)
              || existing.symbolic == item.symbolic,
            try existing.render(nil) == item.render(nil)
          else { throw CoreError.invalidState("conflicting native physical region owners") }
        }
        var combined = item
        combined.deployments = Array(Set((result[item.key]?.deployments ?? []) + item.deployments))
          .sorted()
        result[item.key] = combined
      }
      return result
    }
    var desired = try keyed(desiredItems)
    var prior = try keyed(oldItems)
    let keys = Set(desired.keys).union(prior.keys).sorted()
    func componentBindings(_ entries: [ComponentOutputEntry]) -> Bool {
      entries.contains { entry in
        switch entry.output.content {
        case .member(_, let value): !value.bindings.isEmpty
        case .hook(let hook): !hook.value.bindings.isEmpty
        case .generatedLSPPlugin(_, _, let value): !value.bindings.isEmpty
        default: false
        }
      }
    }
    let recordedOldBindings =
      old.contains { $0.bindings.contains { !$0.reference } } || componentBindings(oldComponents)
    let sensitiveBindings =
      recordedOldBindings
      || contributions.contains { $0.1.bindings.contains { !$0.reference } }
      || componentBindings(components)
    let sensitive = try sensitiveBindings || store.materializationReceipt(for: target) != nil
    let privatePlan =
      try sensitive
      ? store.preparePrivateMaterialization(
        target, changingAccess: changingAccess,
        requiringReceiptForExistingTarget: recordedOldBindings) : nil
    let receiptArrays = try store.materializationReceipt(for: target)?.nativeArrays ?? []
    let authority = previous.nativeAuthorities?.first {
      (try? $0.target.resolve(roots: roots).path) == path
    }
    var retained: [NativeObservation] = []
    var retainedOwners: [[String]] = []
    var expected: [String: NativeExpectedRegion] = [:]
    var staleKeys = Set<String>()
    var staleRegions: [LedgerNativeOwnedRegion] = []
    for key in keys {
      if let old = prior[key], old.append, capture.bytes != nil {
        let records =
          authority?.regions.filter { !Set($0.deployments).isDisjoint(with: old.deployments) } ?? []
        let index =
          oldItems.filter { $0.deployments == old.deployments && $0.append }.firstIndex {
            $0.key == key
          } ?? 0
        guard records.indices.contains(index) else {
          throw CoreError.invalidState("missing durable native occurrence authority")
        }
        let region: NativeRegion
        do {
          region = try NativeAuthorityComposition.region(
            records[index].path, document: document, arrays: receiptArrays)
        } catch {
          guard let next = desired[key], !next.selected else { throw error }
          staleKeys.insert(key)
          staleRegions.append(.init(deployments: next.deployments, path: records[index].path))
          desired[key]!.bindings = []
          continue
        }
        prior[key]!.region = region
        if desired[key] != nil { desired[key]!.region = region }
      }
      let region = (prior[key] ?? desired[key])!.region
      if prior[key] == nil, desired[key]?.append == true {
        expected[key] = try document.read(region).map(NativeExpectedRegion.owned) ?? .absent
        continue
      }
      if let observation = try document.read(region) {
        guard let old = prior[key] else { throw NativeDocumentError.ownershipMismatch(region) }
        if old.bindings.isEmpty, try observation.value != old.render(nil) {
          throw NativeDocumentError.ownershipMismatch(region)
        }
        expected[key] = .owned(observation)
        if var next = desired[key] {
          if !next.selected {
            next.bindings = []
            next.render = { _ in observation.value! }
            desired[key] = next
          }
          retained.append(observation)
          retainedOwners.append(next.deployments)
        }
      } else {
        expected[key] = .absent
      }
    }
    var created: [NativeRegion] = []
    for container in authority?.createdContainers ?? [] where capture.bytes != nil {
      let region = try NativeAuthorityComposition.region(
        container.path, document: document, arrays: receiptArrays)
      if try document.read(region) != nil { created.append(region) }
    }
    var editKeys: [String] = []
    func edits(_ values: RuntimeBindingValues?) throws -> [NativeRegionEdit] {
      var result: [NativeRegionEdit] = []
      editKeys = []
      for key in keys where !staleKeys.contains(key) {
        if let next = desired[key] {
          if !next.selected { continue }
          editKeys.append(key)
          if next.append, prior[key] == nil || capture.bytes == nil {
            let array = try document.read(next.region)
            result.append(
              .append(
                region: next.region, expected: array.map(NativeExpectedRegion.owned) ?? .absent,
                value: try next.render(values)))
          } else {
            result.append(
              .put(region: next.region, expected: expected[key]!, value: try next.render(values)))
          }
        } else if case .owned = expected[key] {
          editKeys.append(key)
          result.append(.remove(region: prior[key]!.region, expected: expected[key]!))
        }
      }
      if (components + oldComponents).contains(where: {
        if case .hook(let hook) = $0.output.content { return hook.layout == .cursorVersion1 }
        return false
      }),
        try document.read(.init(keys: ["version"])) == nil
      {
        result.append(.put(region: .init(keys: ["version"]), expected: .absent, value: .integer(1)))
      }
      let selectedOldDeployments = Set(prior.values.filter(\.selected).flatMap(\.deployments))
      for region in created
      where authority?.createdContainers.contains(where: { record in
        !Set(record.deployments).isDisjoint(with: selectedOldDeployments)
          && (try? NativeAuthorityComposition.region(
            record.path, document: document, arrays: receiptArrays)) == region
      }) == true {
        result.append(.pruneCreatedContainer(region: region, observed: try document.read(region)!))
      }
      return result
    }
    let tracking =
      try capture.bytes == nil
      ? []
      : receiptArrays.map {
        try NativeAuthorityComposition.region($0.path, document: document)
      }
    let preview = try document.prepare(edits(nil), retaining: retained, trackingArrays: tracking)
    let confirmedKeys = editKeys
    let changed = preview.bytes != (capture.bytes ?? Data((format == .toml ? "" : "{}\n").utf8))
    let bindings = desired.values.reduce(into: Set<String>()) { $0.formUnion($1.bindings) }
    let selectedTarget = location(target)
    let authorityRoute: NativeTargetRoute
    if let entry = (components + oldComponents).first {
      authorityRoute = try DeploymentConstruction.route(
        entry.output, request: entry.contribution.request)
    } else {
      authorityRoute = try DeploymentConstruction.route((contributions.map(\.1) + old).first!)
    }
    let targetRoute = try DeploymentConstruction.physicalRoute(
      authorityRoute, ledger: previous, store: store
    ).rawValue
    func finish(_ result: PreparedNativeChange) throws -> NativeAuthorityComposition.Result {
      let final = try NativeDocument(bytes: result.bytes, format: format, budget: budget)
      var owners: [(NativeObservation, [String])] = []
      for remap in result.survivingRegions {
        if let observation = remap.observation {
          owners.append((observation, retainedOwners[remap.index]))
        }
      }
      for append in result.appendedOccurrences {
        owners.append((append.observation, desired[confirmedKeys[append.editIndex]]!.deployments))
      }
      // Keyed regions replaced by put retain their stable address even when their old value changes.
      for key in keys where desired[key]?.append == false {
        if let next = desired[key], let observation = try final.read(next.region),
          !owners.contains(where: { $0.0.region == observation.region })
        {
          owners.append((observation, next.deployments))
        }
      }
      let finalEvidence = try NativeAuthorityComposition.finish(
        result, document: final, owners: owners,
        containers: created + result.createdContainers,
        previousArrays: capture.bytes == nil ? [] : receiptArrays,
        sensitive: sensitive, format: format)
      var containers = finalEvidence.containers
      for original in authority?.createdContainers ?? [] {
        guard
          staleRegions.contains(where: { region in
            region.path.count > original.path.count
              && Array(region.path.prefix(original.path.count)) == original.path
          }), !containers.contains(where: { $0.path == original.path })
        else { continue }
        let owners = Set(
          staleRegions.filter {
            $0.path.count > original.path.count
              && Array($0.path.prefix(original.path.count)) == original.path
          }.flatMap(\.deployments))
        containers.append(
          .init(deployments: owners.sorted(), path: original.path, kind: original.kind))
      }
      if capture.bytes == nil {
        return .init(
          regions: finalEvidence.regions + staleRegions, containers: containers,
          transitions: receiptArrays.map { .init(previous: $0, current: nil) }
            + finalEvidence.transitions)
      }
      return .init(
        regions: finalEvidence.regions + staleRegions, containers: containers,
        transitions: finalEvidence.transitions)
    }
    let previewAuthority = try finish(preview)
    recordNativeAuthority(
      previewAuthority, target: selectedTarget, route: targetRoute, path: path, format: format)
    if let privatePlan {
      nativePrivateWrites.append(
        (
          privatePlan, bindings,
          { [unowned self] values in
            let actual = try document.prepare(
              edits(values), retaining: retained, trackingArrays: tracking)
            guard
              actual.appendedOccurrences.map(\.editIndex)
                == preview.appendedOccurrences.map(\.editIndex),
              actual.createdContainers == preview.createdContainers,
              actual.survivingRegions.map({ $0.observation != nil })
                == preview.survivingRegions.map({ $0.observation != nil })
            else {
              throw CoreError.invalidState("private rendering changed confirmed native structure")
            }
            let evidence = try finish(actual)
            self.recordNativeAuthority(
              evidence, target: selectedTarget, route: targetRoute, path: path, format: format)
            return .init(bytes: actual.bytes, nativeArrayTransitions: evidence.transitions)
          }
        ))
    } else if changed {
      writes[path] = .data(preview.bytes)
    }
    var readers = Set((old + contributions.map(\.1)).flatMap { $0.descriptor.knownReaders })
    readers.formUnion((components + oldComponents).flatMap { $0.contribution.knownReaders })
    for entry in components + oldComponents {
      readers.formUnion(
        try DeploymentConstruction.route(entry.output, request: entry.contribution.request)
          .knownReaders)
    }
    let effectiveReaders = readers.sorted { $0.rawValue < $1.rawValue }
    for (lowering, contribution, _) in contributions {
      let deployment = LedgerDeployment(
        id: lowering.id, target: location(target), route: lowering.format,
        owners: [contribution.component], recipients: contribution.recipients,
        ownership: .ownedValues,
        expectedHash: try ResolvedLedgerCodec.digest(contribution.value),
        created: previous.deployments.first { $0.id == lowering.id }?.created
          ?? (capture.bytes == nil))
      ledger.deployments.removeAll { $0.id == lowering.id }
      ledger.deployments.append(deployment)
      if let i = ledger.lowerings.firstIndex(where: { $0.id == lowering.id }) {
        ledger.lowerings[i].deployments = [lowering.id]
      }
      changes.append(
        .init(
          deployment: deployment, url: url, before: nil, after: nil, changed: changed || sensitive,
          native: true, accessChange: privatePlan?.accessChange, effectiveReaders: effectiveReaders,
          privateMaterialization: sensitive,
          requiredBindings: contribution.bindings.filter { !$0.reference }.compactMap {
            switch $0.binding {
            case .environment(let n), .secret(let n): n
            case .literal: nil
            }
          }.sorted(),
          symbolicBefore: old.first { $0.name == contribution.name }?.value,
          symbolicAfter: contribution.value))
    }
    for entry in components {
      let ownBindings: [String]
      switch entry.output.content {
      case .member(_, let value): ownBindings = Array(names(value.bindings)).sorted()
      case .hook(let hook): ownBindings = Array(names(hook.value.bindings)).sorted()
      default: ownBindings = []
      }
      try record(
        entry, previous: previous, changed: changed || sensitive, readers: effectiveReaders,
        privatePlan: privatePlan, bindings: ownBindings)
    }
    for deployment in previous.deployments
    where (try? deployment.target.resolve(roots: roots).path) == path {
      let oldOwners = try Set(
        deployment.owners.map {
          try LedgerImpact.identity(
            previous.components[$0]!, ledger: previous, roots: roots)
        })
      let retained = try ledger.deployments.contains { next in
        guard next.route == deployment.route,
          (try? next.target.resolve(roots: roots).path) == path
        else { return false }
        return try Set(
          next.owners.map {
            try LedgerImpact.identity(
              ledger.components[$0]!, ledger: ledger, roots: roots)
          }) == oldOwners
      }
      if retained { continue }
      changes.append(
        .init(
          deployment: deployment, url: url, before: nil, after: nil, changed: changed,
          native: true, accessChange: privatePlan?.accessChange, effectiveReaders: effectiveReaders,
          privateMaterialization: sensitive,
          symbolicBefore: previous.components[deployment.owners[0]]?.payload))
    }
  }

  private func recordNativeAuthority(
    _ result: NativeAuthorityComposition.Result, target: LedgerLocation,
    route: String, path: String, format: NativeDocumentFormat
  ) {
    var records = ledger.nativeAuthorities ?? []
    records.removeAll { (try? $0.target.resolve(roots: roots).path) == path }
    if !result.regions.isEmpty {
      records.append(
        .init(
          target: target, targetRoute: route,
          documentFormat: NativeAuthorityComposition.dialect(format), regions: result.regions,
          createdContainers: result.containers))
    }
    ledger.nativeAuthorities = records.isEmpty ? nil : records
  }

  private func prepareGeneratedPlugins(
    previous: ResolvedLedger, artifacts: [String: ReplayedArtifact],
    oldArtifacts: [String: ReplayedArtifact],
    workspace: URL, changingAccess: Bool
  ) throws -> Set<String> {
    typealias Entry = (LockedLowering, NativeGeneratedPluginContribution, MaterializationTarget)
    func entries(_ selected: ResolvedLedger, _ outputs: [String: ReplayedArtifact]) throws
      -> [String: Entry]
    {
      var result: [String: Entry] = [:]
      for lowering in selected.lowerings where lowering.format.hasSuffix("-generated-plugin@1") {
        let contribution = try NativeGeneratedPluginContribution.decode(
          lowering, ledger: selected,
          artifacts: lowering.artifacts.map {
            guard let output = outputs[$0.name] else {
              throw CoreError.invalidState("missing generated native artifact")
            }
            return output
          }, limits: .standard)
        let route = try DeploymentConstruction.generatedRoute(lowering, ledger: selected)
        let target = try store.nativeTarget(for: route)
        let path = try physicalPath(route)
        guard result[path] == nil else {
          throw CoreError.invalidState("overlapping generated native containers")
        }
        result[path] = (lowering, contribution, target)
      }
      return result
    }
    let next = try entries(ledger, artifacts)
    let old = try entries(previous, oldArtifacts)
    func bindings(_ contribution: NativeGeneratedPluginContribution) -> Set<String> {
      var names = Set<String>()
      func collect(_ binding: RuntimeBinding) {
        switch binding {
        case .secret(let name), .environment(let name): names.insert(name)
        case .literal: break
        }
      }
      for member in contribution.members {
        switch member.content {
        case .mcp(let value):
          for placement in value.bindings where !placement.reference { collect(placement.binding) }
        case .component(let value):
          for output in value.outputs {
            switch output.content {
            case .hook(let hook):
              for placement in hook.value.bindings { collect(placement.binding) }
            case .generatedLSPPlugin(_, _, let manifest):
              for placement in manifest.bindings { collect(placement.binding) }
            default: break
            }
          }
        case .skill: break
        }
      }
      return names
    }
    func bindingPlaceholder(_ name: String) -> String {
      "agents-symbolic-binding-" + FileHash.sha256Hex(data: Data(name.utf8))
    }
    let selectedEnvironment = store.environment
    let generatedBudget = nativeBudget()
    func bundle(
      _ contribution: NativeGeneratedPluginContribution, target: MaterializationTarget,
      values: RuntimeBindingValues, symbolic: Bool = false
    ) throws -> [String: Data] {
      var environment = selectedEnvironment
      if symbolic {
        for name in bindings(contribution) {
          environment.environment[name] = bindingPlaceholder(name)
        }
      }
      return try Self.generatedPluginFiles(
        contribution, target: target, values: values, environment: environment,
        budget: generatedBudget)
    }
    func symbolicFiles(
      _ contribution: NativeGeneratedPluginContribution, target: MaterializationTarget
    ) throws -> [String: Data] {
      let values = RuntimeBindingValues(
        Dictionary(
          uniqueKeysWithValues: bindings(contribution).map {
            ($0, Data(bindingPlaceholder($0).utf8))
          }))
      return try bundle(contribution, target: target, values: values, symbolic: true)
    }
    func preview(
      _ contribution: NativeGeneratedPluginContribution, target: MaterializationTarget,
      selected: ResolvedLedger, files: [String: Data]
    ) throws -> String {
      var sections = ["Target: " + target.url.path]
      for path in files.keys.sorted() {
        guard let text = String(data: files[path]!, encoding: .utf8) else {
          throw CoreError.invalidState("generated native preview is not UTF-8")
        }
        var displayed = text
        for name in bindings(contribution).sorted() {
          // Native conversion sees inert literals; display labels use the native JSON escaper.
          let label = try Self.configurationPreview(.string("«binding:" + name + "»"))
          displayed = displayed.replacingOccurrences(
            of: bindingPlaceholder(name), with: String(label.dropFirst().dropLast()))
        }
        sections.append(path + "\n" + displayed)
      }
      let skillResources = Set(
        contribution.members.compactMap { member -> String? in
          if case .skill(_, let resource) = member.content { return resource }
          return nil
        })
      for placement in contribution.resourcePlacements {
        let resource = contribution.resources[placement.resource]!
        sections.append("Resource: " + placement.path)
        for entry in resource.entries where entry.kind != .directory {
          let suffix = entry.path == "." ? "" : "/" + entry.path
          let detail =
            entry.kind == .symlink
            ? " -> " + (entry.link ?? "") : entry.executable ? " (executable)" : ""
          sections.append(placement.path + suffix + detail)
          if skillResources.contains(placement.resource), entry.path == "SKILL.md" {
            let bytes: Data?
            if let object = entry.object, let captured = selected.contentObjects[object] {
              bytes = captured
            } else if let source = resources[placement.resource] {
              bytes = try Data(
                contentsOf: PathSafety.resolvedChild(base: source, subpath: entry.path))
            } else {
              bytes = nil
            }
            if let bytes, let text = String(data: bytes, encoding: .utf8) {
              sections.append(text)
            } else {
              sections.append("Recorded skill content is unavailable in this preview.")
            }
          }
        }
      }
      return sections.joined(separator: "\n\n")
    }
    for path in Set(next.keys).union(old.keys).sorted() {
      let entry = next[path] ?? old[path]!
      let target = entry.2
      let capture = try TargetPrecondition(target.url).capturingPublicationAccess()
      targets[path] = capture
      fingerprints.append(try capture.displayEvidence(includeContent: false))
      let receipt = try store.materializationReceipt(for: target)
      let selected = try isSelected(entry.1.component, in: next[path] == nil ? previous : ledger)
      let names = bindings(entry.1)
      let priorNames = old[path].map { bindings($0.1) } ?? []
      let sensitive = !names.isEmpty || !priorNames.isEmpty || receipt != nil
      let privatePlan =
        try sensitive
        ? store.preparePrivateMaterialization(
          target, changingAccess: changingAccess,
          requiringReceiptForExistingTarget: !priorNames.isEmpty) : nil
      let exists = FileManager.default.fileExists(atPath: path)
      let priorFiles = try old[path].map { try symbolicFiles($0.1, target: target) }
      let configurationBefore = try old[path].map {
        try preview($0.1, target: target, selected: previous, files: priorFiles!)
      }
      if exists && selected {
        guard let prior = old[path],
          previous.deployments.contains(where: { $0.id == prior.0.id && $0.ownership == .generated }
          )
        else {
          throw CoreError.invalidState("generated native container contains unmanaged content")
        }
        if receipt == nil {
          let expected = priorFiles!
          guard try Self.generatedTreeMatches(prior.1, target: target, files: expected) else {
            throw CoreError.invalidState("owned generated native container drifted")
          }
        }
      }
      if let current = next[path] {
        let deployment = LedgerDeployment(
          id: current.0.id, target: location(target), route: current.0.format,
          owners: [current.1.component], recipients: current.1.recipients, ownership: .generated,
          expectedHash: current.0.artifacts[0].hash,
          created: previous.deployments.first { $0.id == current.0.id }?.created ?? !exists)
        ledger.deployments.removeAll { $0.id == deployment.id }
        ledger.deployments.append(deployment)
        if let index = ledger.lowerings.firstIndex(where: { $0.id == current.0.id }) {
          ledger.lowerings[index].deployments = [deployment.id]
        }
        let symbolic = try symbolicFiles(current.1, target: target)
        if selected {
          let tree = workspace.appendingPathComponent(
            "generated-" + FileHash.sha256Hex(data: Data(path.utf8)))
          try FileSystem.createDirectory(at: tree)
          for placement in current.1.resourcePlacements {
            guard let source = resources[placement.resource],
              let resource = ledger.resources[placement.resource]
            else { throw CoreError.invalidState("missing generated native resource") }
            var sourceRoot = source
            if resource.path != "." {
              for _ in resource.path.split(separator: "/") { sourceRoot.deleteLastPathComponent() }
            }
            let captured = try LedgerResources.capture(
              source, embed: true, limits: .standard, sourceRoot: sourceRoot)
            guard captured.hash == resource.hash else {
              throw CoreError.invalidState("generated native resource changed")
            }
            var embedded = resource
            embedded.kind = .embedded
            embedded.entries = captured.entries
            embedded.support = captured.support
            let base = Self.generatedResourceBase(placement, resource: resource)
            let destination = try PathSafety.resolvedChild(base: tree, subpath: base)
            try LedgerResources.materialize(embedded, objects: captured.objects, at: destination)
            if !resource.support.isEmpty && placement.path.hasPrefix("skills/") {
              let alias = try PathSafety.resolvedChild(base: tree, subpath: placement.path)
              try FileSystem.createDirectory(at: alias.deletingLastPathComponent())
              try FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: "../" + base + "/" + resource.path)
            }
          }
          for (file, bytes) in symbolic {
            let destination = try PathSafety.resolvedChild(base: tree, subpath: file)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
              throw CoreError.invalidState("generated native bundle collision")
            }
            try FileSystem.createDirectory(at: destination.deletingLastPathComponent())
            try bytes.write(to: destination)
          }
          if let privatePlan {
            let captured = try LedgerResources.capture(tree, embed: false, limits: .standard)
            let members = try captured.entries.filter { $0.path != "." }.map {
              item -> PrivateTreeEntry in
              if symbolic[item.path] != nil {
                return .init(
                  item.path,
                  content: .boundFile(bindings: names) { values in
                    let actual = try bundle(current.1, target: target, values: values)
                    guard Set(actual.keys) == Set(symbolic.keys), let bytes = actual[item.path]
                    else {
                      throw CoreError.invalidState(
                        "private rendering changed generated native structure")
                    }
                    return bytes
                  })
              }
              switch item.kind {
              case .directory: return .init(item.path, content: .directory)
              case .file:
                return .init(
                  item.path,
                  content: .file(
                    try Data(contentsOf: tree.appendingPathComponent(item.path)),
                    executable: item.executable))
              case .symlink: return .init(item.path, content: .symlink(item.link!))
              }
            }
            privateTrees.append((privatePlan, members))
          } else if try !exists || FileHash.folderHash(tree) != FileHash.folderHash(target.url) {
            writes[path] = .copy(tree)
          }
        }
        changes.append(
          .init(
            deployment: deployment, url: target.url, before: nil, after: nil,
            changed: selected && (writes[path] != nil || privatePlan != nil), native: true,
            accessChange: privatePlan?.accessChange, effectiveReaders: current.1.knownReaders,
            privateMaterialization: sensitive, requiredBindings: names.sorted(),
            configurationBefore: configurationBefore,
            configurationAfter: try preview(
              current.1, target: target, selected: ledger, files: symbolic)))
      } else if selected,
        let deployment = previous.deployments.first(where: { $0.id == entry.0.id })
      {
        if exists { deletes.insert(path) }
        changes.append(
          .init(
            deployment: deployment, url: target.url, before: nil, after: nil, changed: exists,
            native: true,
            privateMaterialization: sensitive,
            configurationBefore: configurationBefore))
      }
    }
    return Set(next.keys).union(old.keys)
  }

  private static func generatedTreeMatches(
    _ contribution: NativeGeneratedPluginContribution,
    target: MaterializationTarget, files: [String: Data]
  ) throws -> Bool {
    var entries: [String: LedgerEntry] = [
      ".": .init(path: ".", kind: .directory, executable: false)
    ]
    func add(_ entry: LedgerEntry, at path: String) throws {
      var copy = entry
      copy.path = path
      if let existing = entries[path], existing != copy {
        throw CoreError.invalidState("conflicting generated native resource placement")
      }
      entries[path] = copy
      let parents = path.split(separator: "/").dropLast()
      if !parents.isEmpty {
        for count in 1...parents.count {
          let parent = parents.prefix(count).joined(separator: "/")
          let directory = LedgerEntry(path: parent, kind: .directory, executable: false)
          if let existing = entries[parent], existing.kind != .directory {
            throw CoreError.invalidState("generated native resource ancestor collision")
          }
          entries[parent] = directory
        }
      }
    }
    for (path, bytes) in files {
      try add(
        .init(
          path: path, kind: .file, object: "sha256:" + FileHash.sha256Hex(data: bytes),
          executable: false, byteCount: bytes.count), at: path)
    }
    for placement in contribution.resourcePlacements {
      let resource = contribution.resources[placement.resource]!
      let base = generatedResourceBase(placement, resource: resource)
      let primary = generatedResourcePath(placement, resource: resource)
      for entry in resource.entries {
        try add(entry, at: entry.path == "." ? primary : primary + "/" + entry.path)
      }
      for entry in resource.support {
        try add(entry, at: entry.path == "." ? base : base + "/" + entry.path)
      }
      if !resource.support.isEmpty && placement.path.hasPrefix("skills/") {
        try add(
          .init(
            path: placement.path, kind: .symlink, link: "../" + base + "/" + resource.path,
            executable: false), at: placement.path)
      }
    }
    let actual = try LedgerResources.capture(target.url, embed: true, limits: .standard)
    guard actual.entries.count == entries.count else { return false }
    guard
      actual.entries.allSatisfy({ entry in
        guard let expected = entries[entry.path] else { return false }
        return entry.kind == expected.kind && entry.executable == expected.executable
          && (expected.object == nil || entry.object == expected.object)
          && entry.link == expected.link
      })
    else { return false }
    for placement in contribution.resourcePlacements {
      let resource = contribution.resources[placement.resource]!
      let observed = try LedgerResources.capture(
        target.url.appendingPathComponent(generatedResourcePath(placement, resource: resource)),
        embed: false, limits: .standard)
      guard observed.hash == resource.hash else { return false }
    }
    return true
  }

  private static func generatedResourceBase(
    _ placement: NativeGeneratedPluginContribution.ResourcePlacement,
    resource: LedgerResource
  ) -> String {
    resource.support.isEmpty
      ? placement.path
      : "resources/" + placement.resource.replacingOccurrences(of: "sha256:", with: "")
  }

  private static func generatedResourcePath(
    _ placement: NativeGeneratedPluginContribution.ResourcePlacement,
    resource: LedgerResource
  ) -> String {
    resource.support.isEmpty
      ? placement.path : generatedResourceBase(placement, resource: resource) + "/" + resource.path
  }

  private static func generatedPluginFiles(
    _ contribution: NativeGeneratedPluginContribution,
    target: MaterializationTarget, values: RuntimeBindingValues, environment: RuntimeEnvironment,
    budget: NativeDocumentBudget
  ) throws -> [String: Data] {
    let paths = try Dictionary(
      contribution.resourcePlacements.map {
        (
          $0.resource,
          try PathSafety.resolvedChild(
            base: target.url,
            subpath: Self.generatedResourcePath($0, resource: contribution.resources[$0.resource]!)
          ).path
        )
      }, uniquingKeysWith: { a, _ in a })
    let rendered = try contribution.stagedBundle(
      bindings: values, environment: environment,
      resourcePaths: paths, budget: budget, cursorCommandShell: .posix)
    var result = rendered.files
    for (path, value) in rendered.documents {
      guard result[path] == nil else {
        throw CoreError.invalidState("generated native file collision")
      }
      guard case .object(let fields) = value else {
        throw CoreError.invalidState("generated native document must be an object")
      }
      let document = try NativeDocument(bytes: Data("{}".utf8), format: .json, budget: budget)
      result[path] = try document.prepare(
        fields.keys.sorted().map { key in
          .put(region: .init(keys: [key]), expected: .absent, value: fields[key]!)
        }
      ).bytes
    }
    return result
  }

  private func nativeBudget() -> NativeDocumentBudget {
    NativeDocumentBudget(
      limits: .init(
        storage: LedgerLimits.standard.resourceBytes,
        work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
        depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes))
  }

  private static func nativeValue(
    _ contribution: NativeMCPContribution, values: RuntimeBindingValues?, ledger: ResolvedLedger,
    store: StateStore, roots: [String: URL]
  ) throws -> NativeValue {
    func convert(_ value: LedgerValue, path: [MCPValueStep]) throws -> NativeValue {
      if let resource = contribution.resourcePlacements.first(where: { $0.path == path }),
        ledger.resources[resource.resource] != nil
      {
        let destination = try resourceDestination(
          resource.resource, ledger: ledger, store: store, roots: roots)
        return .string(destination.path)
      }
      switch value.kind {
      case .environment, .secret:
        guard let name = value.text else { throw CoreError.invalidState("missing binding name") }
        if let values {
          guard let text = String(data: try values.value(for: name), encoding: .utf8) else {
            throw CoreError.invalidState("runtime binding is not UTF8")
          }
          return .string(text)
        }
        return .string("<binding:" + name + ">")
      case .string, .literal: return .string(value.text!)
      case .integer: return .integer(value.integer!)
      case .decimal: return .decimal(value.text!)
      case .boolean: return .boolean(value.boolean!)
      case .null: return .null
      case .array:
        return .array(
          try value.array!.enumerated().map {
            try convert($0.element, path: path + [.index($0.offset)])
          })
      case .object:
        return .object(
          try value.object!.mapValuesWithKey { try convert($1, path: path + [.key($0)]) })
      }
    }
    return try convert(contribution.value, path: [])
  }

  package func validate(excludingTargets excluded: Set<String> = []) throws {
    for change in changes
    where change.deployment.route == "agents/instructions@1"
      && ledger.deployments.contains(where: { $0.id == change.deployment.id })
    {
      if let bytes = change.after {
        try InstructionTargets(store: store).validateRenderedLinks(bytes, at: change.url)
      }
    }
    let paths = targets.keys.sorted().map { URL(fileURLWithPath: $0) }
    for (index, path) in paths.enumerated() {
      if paths.prefix(index).contains(where: {
        PathSafety.isContained(path, in: $0) || PathSafety.isContained($0, in: path)
      }) {
        throw CoreError.invalidState("overlapping deployment targets")
      }
    }
    for (path, evidence) in targets where !excluded.contains(path) { try evidence.validate() }
    for evidence in resourceEvidence
    where !excluded.contains(where: {
      PathSafety.isContained(evidence.url, in: URL(fileURLWithPath: $0))
    }) { try evidence.validate() }
  }

  package func requireSkillOwnership() throws {
    if let reason = unownedSkills.sorted().first { throw CoreError.invalidSkill(reason) }
  }

  package func requireOwnership() throws {
    try requireSkillOwnership()
    guard replace || unownedInstructions.isEmpty else {
      throw InstructionError.unownedTargets(unownedInstructions.sorted())
    }
  }

  package func stage(
    transaction: FileTransaction, provider: any RuntimeBindingProvider, roots: [String: URL]
  ) throws {
    var staged = Set<String>()
    for (id, source) in resources.sorted(by: { $0.key < $1.key }) {
      guard let resource = ledger.resources[id], resource.kind != .liveEdit else { continue }
      let destination = try Self.resourceDestination(id, ledger: ledger, store: store, roots: roots)
      let git = try Self.gitDestination(resource, ledger: ledger, store: store, roots: roots)
      let container =
        git
        ?? store.cacheDirectory.appendingPathComponent(
          "artifact-content/" + String(id.dropFirst(7)))
      guard staged.insert(container.path).inserted else { continue }
      if FileManager.default.fileExists(atPath: container.path) {
        let actual = try LedgerResources.capture(destination, embed: false, limits: .standard)
        guard actual.hash == resource.hash else {
          throw CoreError.invalidState("retained resource mismatch")
        }
      } else if git != nil {
        var root = source
        if resource.path != "." {
          for _ in resource.path.split(separator: "/") { root.deleteLastPathComponent() }
        }
        try transaction.replace(container, with: .copy(root))
      } else if let capsule = capsules[id] {
        try transaction.replace(container, with: .copy(capsule))
      } else {
        throw CoreError.invalidState("missing retained resource capsule")
      }
    }
    for path in writes.keys.sorted() {
      let source = writes[path]!
      let hash: String? = { if case .link = source { nil } else { skillContent[path]?.0 } }()
      if skillWritePaths.contains(path), let target = skillTargets[path] {
        try transaction.replaceSkill(
          target, with: source, expectedHash: hash, expecting: targets[path])
      } else {
        try transaction.replace(
          URL(fileURLWithPath: path), with: source, expectedHash: hash,
          executableFlags: skillContent[path]?.1, expecting: targets[path])
      }
    }
    for path in deletes.sorted() {
      if skillDeletePaths.contains(path), let target = skillTargets[path] {
        try transaction.deleteSkill(target, expecting: targets[path])
      } else {
        try transaction.delete(URL(fileURLWithPath: path), expecting: targets[path])
      }
    }
    for (prepared, entries) in privateTrees {
      try transaction.replacePrivateTree(prepared, entries: entries, provider: provider)
    }
    for (prepared, bindings, produce) in nativePrivateWrites {
      try transaction.replacePrivate(
        prepared, bindings: bindings, provider: provider, produce: produce)
    }
    for (prepared, bindings, render) in privateWrites {
      try transaction.replacePrivate(
        prepared, bindings: bindings, provider: provider, render: render)
    }
  }
}

extension Dictionary {
  fileprivate func mapValuesWithKey<T>(_ transform: (Key, Value) throws -> T) rethrows -> [Key: T] {
    try [Key: T](uniqueKeysWithValues: map { (key, value) in (key, try transform(key, value)) })
  }
}

extension ArtifactAggregation {
  package static func nativeExposure(
    _ deployment: LedgerDeployment, ledger: ResolvedLedger, store: StateStore,
    roots admittedRoots: [String: URL]? = nil
  ) throws -> (readers: [AgentID]?, sensitive: Bool) {
    guard
      deployment.ownership == .ownedValues || deployment.route.hasSuffix("-components@1")
        || deployment.route.hasSuffix("-generated-plugin@1")
    else {
      return (nil, false)
    }
    let roots = admittedRoots ?? store.ledgerRoots
    let path = try deployment.target.resolve(roots: roots).path
    var identities = Set<NativeTargetIdentity>()
    for route in try DeploymentConstruction.routes(ledger) {
      let target = try store.nativeTarget(for: route)
      if target.url.path == path, let identity = try store.nativeTargetIdentity(for: route) {
        identities.insert(identity)
      }
    }
    func matches(_ route: NativeTargetRoute, _ target: MaterializationTarget) throws -> Bool {
      if target.url.path == path { return true }
      return try store.nativeTargetIdentity(for: route).map(identities.contains) ?? false
    }
    var readers = Set<AgentID>()
    var sensitive = false
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-mcp@1") {
      let c = try MCPLayoutV1.contribution(lowering, ledger: ledger)
      let target = try store.nativeTarget(
        for: DeploymentConstruction.physicalRoute(
          DeploymentConstruction.route(c), ledger: ledger, store: store))
      if target.url.path == path {
        readers.formUnion(c.descriptor.knownReaders)
        sensitive =
          try sensitive || c.bindings.contains(where: { !$0.reference })
          || store.materializationReceipt(for: target) != nil
      }
    }
    func hasBinding(_ value: LedgerValue) -> Bool {
      value.kind == .secret || value.kind == .environment
        || (value.array ?? []).contains(where: hasBinding)
        || (value.object?.values ?? [:].values).contains(where: hasBinding)
    }
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-components@1") {
      let input = try NativeComponentLayoutsV1.input(lowering, ledger: ledger, limits: .standard)
      var selected = ledger
      selected.lowerings = [lowering]
      for route in try DeploymentConstruction.routes(selected) {
        let target = try store.nativeTarget(for: route)
        if try matches(route, target) {
          readers.formUnion(
            CapabilityRegistry.componentReaders(
              input.request, kind: DeclaredComponentKind(rawValue: input.record.kind)!))
          readers.formUnion(route.knownReaders)
          sensitive =
            try sensitive || hasBinding(input.record.payload)
            || store.materializationReceipt(for: target) != nil
        }
      }
    }
    for lowering in ledger.lowerings where lowering.format.hasSuffix("-generated-plugin@1") {
      let route = try DeploymentConstruction.generatedRoute(lowering, ledger: ledger)
      let target = try store.nativeTarget(for: route)
      if try matches(route, target) {
        readers.formUnion(route.knownReaders)
        if let surface = lowering.layout.object?["surface"]?.text.flatMap(
          NativeClientSurface.init(rawValue:)),
          let scope = lowering.layout.object?["scope"]?.text.flatMap(InstallScope.init(rawValue:))
        {
          for id in lowering.inputs {
            if let component = ledger.components[id],
              let kind = DeclaredComponentKind(rawValue: component.kind)
            {
              readers.formUnion(
                CapabilityRegistry.componentReaders(
                  .init(surface: surface, scope: scope), kind: kind))
              sensitive = sensitive || hasBinding(component.payload)
            }
          }
        }
        sensitive = try sensitive || store.materializationReceipt(for: target) != nil
      }
    }
    return (readers.isEmpty ? nil : readers.sorted { $0.rawValue < $1.rawValue }, sensitive)
  }

  /// Observes only the owned region. Private receipts validate the entire physical preimage.
  package static func inspectDeployment(
    _ deployment: LedgerDeployment, ledger: ResolvedLedger, store: StateStore,
    roots admittedRoots: [String: URL]? = nil
  ) throws -> (status: String, diagnostic: String?) {
    let roots = admittedRoots ?? store.ledgerRoots
    let url = try deployment.target.resolve(roots: roots)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ("missing", "managed target is missing")
    }
    do {
      if deployment.route == "agents/skill@1" {
        if let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) }),
          lowering.layout.object?["mode"]?.text == InstallMode.edit.rawValue
        {
          guard let owner = deployment.owners.first.flatMap({ ledger.components[$0] }),
            let name = owner.payload.object?["name"]?.text,
            let resource = owner.resources.first.flatMap({ ledger.resources[$0] }),
            resource.kind == .liveEdit, let source = resource.location,
            let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
          else { return ("drifted", "live skill is not linked to its recorded source") }
          let observed = URL(fileURLWithPath: link, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL
          let expected = try source.resolve(roots: roots).standardizedFileURL
          guard observed.path == expected.path else {
            return ("drifted", "live skill is not linked to its recorded source")
          }
          do { try SkillOperations.validateLiveMetadata(at: expected, name: name) } catch {
            return ("drifted", "live skill source metadata changed")
          }
          return ("current", nil)
        }
        let expected = deployment.expectedHash
        let hash = "sha256:" + (try FileHash.folderHash(url))
        let flags = try FileHash.executableFlags(url)
        let resources = deployment.owners.flatMap { ledger.components[$0]?.resources ?? [] }
        let expectedFlags = resources.first.flatMap { ledger.resources[$0] }.map {
          Dictionary(
            uniqueKeysWithValues: $0.entries.filter { $0.kind == .file }.map {
              ($0.path, $0.executable)
            })
        }
        return hash == expected && (expectedFlags == nil || expectedFlags == flags)
          ? ("current", nil) : ("drifted", "managed skill content or executable mode changed")
      }
      if deployment.ownership == .ownedValues,
        let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) }),
        lowering.format.hasSuffix("-mcp@1")
      {
        let c = try MCPLayoutV1.contribution(lowering, ledger: ledger)
        let target = try store.nativeTarget(
          for: DeploymentConstruction.physicalRoute(
            DeploymentConstruction.route(c), ledger: ledger, store: store))
        if try store.materializationReceipt(for: target) != nil { return ("current", nil) }
        if c.bindings.contains(where: { !$0.reference }) {
          return (
            "unverified",
            "native materialization needs its private receipt or resource placement evidence"
          )
        }
        let document = try NativeDocument(
          bytes: FileSystem.read(at: url), format: c.descriptor.documentFormat,
          budget: NativeDocumentBudget(
            limits: .init(
              storage: LedgerLimits.standard.resourceBytes,
              work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
              depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes
            )))
        let region = try c.descriptor.region(
          server: c.name,
          nativeProjectKey: c.descriptor.request.scope == .local
            ? store.nativeTarget(for: .claudeMCPProject).url.deletingLastPathComponent().path : nil)
        guard let observed = try document.read(region) else {
          return ("missing", "managed native region is missing")
        }
        return try observed.value
          == nativeValue(c, values: nil, ledger: ledger, store: store, roots: roots)
          ? ("current", nil) : ("drifted", "managed native region changed")
      }
      if deployment.route.hasSuffix("-generated-plugin@1"),
        let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) })
      {
        return try LedgerReplay.withLockedResources(
          ledger, store: store, roots: roots, limits: .standard,
          lowerings: [lowering.id]
        ) { artifacts, _, _ in
          let contribution = try NativeGeneratedPluginContribution.decode(
            lowering, ledger: ledger, artifacts: artifacts, limits: .standard)
          let target = try store.nativeTarget(
            for: DeploymentConstruction.generatedRoute(lowering, ledger: ledger))
          if try store.materializationReceipt(for: target) != nil { return ("current", nil) }
          let budget = NativeDocumentBudget(
            limits: .init(
              storage: LedgerLimits.standard.resourceBytes,
              work: LedgerLimits.standard.encodedBytes,
              nodes: LedgerLimits.standard.nodes, depth: LedgerLimits.standard.depth,
              uninterruptedBytes: LedgerLimits.standard.keyBytes))
          let files = try generatedPluginFiles(
            contribution, target: target, values: .init([:]), environment: store.environment,
            budget: budget)
          return try generatedTreeMatches(contribution, target: target, files: files)
            ? ("current", nil) : ("drifted", "managed generated native container changed")
        }
      }
      if deployment.route.hasSuffix("-components@1"),
        let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) })
      {
        return try LedgerReplay.withLockedResources(
          ledger, store: store, roots: roots, limits: .standard
        ) {
          artifacts, _, _ in
          let table = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0) })
          let contribution = try NativeComponentLayoutsV1.contribution(
            lowering, ledger: ledger,
            artifacts: try lowering.artifacts.map { item in
              guard let artifact = table[item.name] else {
                throw CoreError.invalidState("missing sealed native output")
              }
              return artifact
            }, limits: .standard)
          guard
            let index = contribution.outputs.indices.first(where: {
              lowering.id + ":" + String($0) == deployment.id
            })
          else {
            throw CoreError.invalidState("missing native deployment output")
          }
          let output = contribution.outputs[index]
          let target = try store.nativeTarget(
            for: DeploymentConstruction.physicalRoute(
              DeploymentConstruction.route(output, request: contribution.request), ledger: ledger,
              store: store))
          let privateGeneration = try store.materializationReceipt(for: target) != nil
          if privateGeneration {
            switch output.content {
            case .file, .nativePlugin, .generatedLSPPlugin, .hook, .orderedPermissions: break
            default: return ("current", nil)
            }
          }
          let budget = NativeDocumentBudget(
            limits: .init(
              storage: LedgerLimits.standard.resourceBytes,
              work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
              depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes
            ))
          let matches: Bool
          switch output.content {
          case .file(_, let bytes): matches = try Data(contentsOf: url) == bytes
          case .member(let member, let value):
            let document = try NativeDocument(
              bytes: Data(contentsOf: url), format: output.route.documentFormat!, budget: budget)
            matches =
              try document.read(.init(keys: member.keys))?.value
              == componentValue(
                value, values: nil, selected: ledger, store: store, roots: roots)
          case .claudePermissions(let policy):
            let document = try NativeDocument(
              bytes: Data(contentsOf: url), format: .json, budget: budget)
            var expected: [(String, NativeValue)] = []
            for (key, strings) in [
              ("allow", policy.allow), ("ask", policy.ask), ("deny", policy.deny),
            ] {
              if let strings { expected.append((key, .array(strings.map(NativeValue.string)))) }
            }
            if let mode = policy.defaultMode { expected.append(("defaultMode", .string(mode))) }
            matches = try expected.allSatisfy {
              try document.read(.init(keys: ["permissions", $0.0]))?.value == $0.1
            }
          case .nativePlugin(_, let resource, _):
            let observed = try LedgerResources.capture(url, embed: false, limits: .standard)
            matches =
              observed.hash == ledger.resources[resource]?.hash
              && observed.entries.map(\.executable)
                == ledger.resources[resource]?.entries.map(\.executable)
          case .ignore:
            var patterns: [String] = []
            for candidate in ledger.lowerings where candidate.format.hasSuffix("-components@1") {
              let other = try NativeComponentLayoutsV1.contribution(
                candidate, ledger: ledger,
                artifacts: try candidate.artifacts.map { item in
                  guard let artifact = table[item.name] else {
                    throw CoreError.invalidState("missing sealed native output")
                  }
                  return artifact
                }, limits: .standard)
              for output in other.outputs {
                let target = try store.nativeTarget(
                  for: DeploymentConstruction.physicalRoute(
                    DeploymentConstruction.route(output, request: other.request), ledger: ledger,
                    store: store))
                if target.url.path == url.path, case .ignore(let lines) = output.content {
                  patterns += lines
                }
              }
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let opening = "# >>> agents context ignore v1\n"
            let closing = "# <<< agents context ignore v1\n"
            matches =
              text.components(separatedBy: opening).count == 2
              && text.components(separatedBy: closing).count == 2
              && text.contains(opening + patterns.joined(separator: "\n") + "\n" + closing)
          case .generatedLSPPlugin(_, let manifestPath, let manifest):
            let captured = try LedgerResources.capture(url, embed: false, limits: .standard)
            let paths = Set([
              ".", manifestPath, (manifestPath as NSString).deletingLastPathComponent,
            ])
            let document = try NativeDocument(
              bytes: Data(contentsOf: url.appendingPathComponent(manifestPath)), format: .json,
              budget: budget)
            matches =
              try captured.entries.allSatisfy {
                paths.contains($0.path) && !$0.executable
              }
              && generatedManifestMatches(
                manifest, observed: document.read(.init(keys: []))?.value, selected: ledger,
                privateGeneration: privateGeneration, store: store, roots: roots)
          case .hook, .orderedPermissions:
            let document = try NativeDocument(
              bytes: Data(contentsOf: url), format: output.route.documentFormat!, budget: budget)
            guard
              let authority = ledger.nativeAuthorities?.first(where: {
                (try? $0.target.resolve(roots: roots)) == url
              })
            else {
              return ("unverified", "managed native occurrence authority is missing")
            }
            let records = authority.regions.filter { $0.deployments.contains(deployment.id) }
            let expected: [NativeValue]
            switch output.content {
            case .hook(let hook):
              expected = [
                try componentValue(
                  hook.value, values: nil, selected: ledger, store: store, roots: roots)
              ]
            case .orderedPermissions(let rules):
              expected = rules.map {
                .object([
                  "action": .string($0.tool), "resource": .string($0.resource),
                  "effect": .string($0.effect.rawValue),
                ])
              }
            default: expected = []
            }
            matches =
              try records.count == expected.count
              && zip(records, expected).allSatisfy { record, value in
                let region = try NativeAuthorityComposition.region(
                  record.path, document: document,
                  arrays: store.materializationReceipt(for: target)?.nativeArrays ?? [])
                return try privateGeneration
                  ? document.read(region) != nil : document.read(region)?.value == value
              }
          }
          return matches ? ("current", nil) : ("drifted", "managed native contribution changed")
        }
      }
      let bytes = try FileSystem.read(at: url)
      let hash =
        deployment.ownership == .importBlock
        ? try InstructionTargets.ownedImportBytes(bytes).map {
          "sha256:" + FileHash.sha256Hex(data: $0)
        }
        : "sha256:" + FileHash.sha256Hex(data: bytes)
      return hash == deployment.expectedHash
        ? ("current", nil) : ("drifted", "managed instructions changed")
    } catch {
      return (
        "unverified", "managed target could not be verified; inspect ownership, format and access"
      )
    }
  }
}
