import AgentsCore
import AgentsInstructions
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
  package var symbolicBefore: LedgerValue? = nil
  package var symbolicAfter: LedgerValue? = nil
}

/// One prepared physical replacement owns all logical contributions at that destination.
package final class ArtifactAggregation: PreparedEvidence {
  package private(set) var ledger: ResolvedLedger
  package private(set) var changes: [AggregatedChange] = []
  package private(set) var fingerprints: [String] = []
  private let store: StateStore
  private let resources: [String: URL]
  private let replace: Bool
  private let selectedKinds: Set<DeclaredComponentKind>?
  private let selectedNames: Set<String>
  private let selectedIdentities: Set<String>?
  private var unownedInstructions: [String] = []
  private var unownedSkills: [String] = []
  private var targets: [String: TargetPrecondition] = [:]
  private var writes: [String: FileTransaction.Source] = [:]
  private var deletes = Set<String>()
  private var capsules: [String: URL] = [:]
  private var skillContent: [String: (String, [String: Bool])] = [:]
  private var privateWrites:
    [(PreparedPrivateMaterialization, Set<String>, (RuntimeBindingValues) throws -> Data)] = []
  private var resourceEvidence: [TargetPrecondition] = []
  private var physicalPaths: [NativeTargetIdentity: String] = [:]

  package init(
    ledger: ResolvedLedger, previous: ResolvedLedger, artifacts: [ReplayedArtifact],
    resources: [String: URL], workspace: URL, store: StateStore, replace: Bool,
    changingAccess: Bool,
    kinds: Set<DeclaredComponentKind>? = nil, names: Set<String> = [],
    selectedIdentities: Set<String>? = nil
  ) throws {
    self.ledger = ledger
    self.store = store
    self.resources = resources
    self.replace = replace
    selectedKinds = kinds
    selectedNames = names
    self.selectedIdentities = selectedIdentities
    for (id, file) in resources where ledger.resources[id]?.kind != .liveEdit {
      resourceEvidence.append(try TargetPrecondition(file))
    }
    func selected(_ deployment: LedgerDeployment, in ledger: ResolvedLedger) -> Bool {
      kinds == nil
        || deployment.owners.contains {
          ledger.components[$0].flatMap { DeclaredComponentKind(rawValue: $0.kind) }.map {
            kinds!.contains($0)
          } ?? false
        }
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
    let roots = store.ledgerRoots
    let artifacts = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0) })
    let previousByPath = try Dictionary(
      grouping: previous.deployments.filter { selected($0, in: previous) }
    ) {
      InstructionLocations.physical(try $0.target.resolve(roots: roots)).path
    }
    var byPath = try Dictionary(grouping: ledger.deployments.filter { selected($0, in: ledger) }) {
      InstructionLocations.physical(try $0.target.resolve(roots: roots)).path
    }
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
    try LedgerReplay.withLockedResources(previous, store: store, roots: roots, limits: .standard) {
      oldArtifacts, _, _ in
      let oldComponents = try componentOutputs(
        previous,
        artifacts: Dictionary(uniqueKeysWithValues: oldArtifacts.map { ($0.name, $0) }),
        routing: previous)
      for path in Set(native.keys).union(currentComponents.keys).union(oldComponents.keys).sorted()
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
                artifacts: artifacts, workspace: workspace)
            } else {
              for entry in next {
                try record(
                  entry, previous: previous, changed: false,
                  readers: entry.contribution.knownReaders, ownership: .generated)
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
        if changed { writes[path] = source }
        changes.append(
          .init(
            deployment: deployment, url: url, before: nil, after: nil,
            changed: changed, native: false,
            afterLink: { if case .link(let url) = source { url } else { nil } }()))
      } else {
        let before = try TargetPrecondition.readingFile(url).bytes
        var after = artifact.bytes
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
    try Self.resourceDestination(id, ledger: selected ?? ledger, store: store)
  }

  package static func resourceDestination(_ id: String, ledger: ResolvedLedger, store: StateStore)
    throws -> URL
  {
    guard let resource = ledger.resources[id] else {
      throw CoreError.invalidState("missing deployment resource")
    }
    if let location = resource.location { return try location.resolve(roots: store.ledgerRoots) }
    if let root = try gitDestination(resource, ledger: ledger, store: store) {
      return root.appendingPathComponent(resource.path)
    }
    let base = store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + String(id.dropFirst(7)))
    return base.appendingPathComponent(resource.support.isEmpty ? "payload" : resource.path)
  }

  private func gitDestination(_ resource: LedgerResource, ledger: ResolvedLedger) throws -> URL? {
    try Self.gitDestination(resource, ledger: ledger, store: store)
  }

  private static func gitDestination(
    _ resource: LedgerResource, ledger: ResolvedLedger, store: StateStore
  ) throws -> URL? {
    guard resource.kind == .git else { return nil }
    var sourceID = resource.source
    while let parent = ledger.sources[sourceID]?.container { sourceID = parent }
    guard let source = ledger.sources[sourceID] else {
      throw CoreError.invalidState("missing resource source")
    }
    return SourceCache(store: store).materializedURL(
      sourceID: try ledger.sourceIdentity(sourceID, roots: store.ledgerRoots),
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
    if let selectedIdentities {
      return try selectedIdentities.contains(
        LedgerImpact.identity(c, ledger: selected, roots: store.ledgerRoots))
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
    for (key, root) in [
      ("project", store.environment.projectDirectory), ("home", store.environment.homeDirectory),
    ] {
      let root = root.resolvingSymlinksInPath().standardizedFileURL
      if PathSafety.isContained(target.url, in: root) {
        return .init(
          kind: .registered, root: key,
          path: String(target.url.path.dropFirst(root.path.count + 1)))
      }
    }
    return .init(kind: .absolute, path: target.url.path)
  }

  private func record(
    _ entry: ComponentOutputEntry, previous: ResolvedLedger, changed: Bool,
    readers: [AgentID], privatePlan: PreparedPrivateMaterialization? = nil,
    bindings: [String] = [], ownership: LedgerDeployment.Ownership = .ownedValues
  ) throws {
    let identity = try LedgerImpact.identity(
      ledger.components[entry.contribution.component]!, ledger: ledger, roots: store.ledgerRoots)
    let oldComponent = try previous.components.values.first {
      try LedgerImpact.identity($0, ledger: previous, roots: store.ledgerRoots) == identity
    }
    let deployment = LedgerDeployment(
      id: entry.id, target: location(entry.target), route: entry.lowering.format,
      owners: [entry.contribution.component], recipients: entry.contribution.recipients,
      ownership: ownership, expectedHash: entry.lowering.artifacts[0].hash,
      created: previous.deployments.first {
        $0.route == entry.lowering.format
          && (try? $0.target.resolve(roots: store.ledgerRoots).path) == entry.target.url.path
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
        symbolicBefore: oldComponent?.payload,
        symbolicAfter: ledger.components[entry.contribution.component]?.payload))
  }

  private func componentValue(
    _ value: NativeComponentValue, values: RuntimeBindingValues?,
    selected: ResolvedLedger
  ) throws -> NativeValue {
    guard let values else { return try value.referenceValue(budget: nativeBudget()) }
    let paths = try selected.resources.keys.reduce(into: [String: String]()) {
      $0[$1] = try Self.resourceDestination($1, ledger: selected, store: store).path
    }
    return try value.stagedValue(
      bindings: values, environment: store.environment,
      resourcePaths: paths,
      budget: NativeDocumentBudget(
        limits: .init(
          storage: LedgerLimits.standard.resourceBytes,
          work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
          depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes)),
      codexCommandShell: .posix, cursorCommandShell: .posix)
  }

  private func prepareWholeNative(
    path: String, next: [ComponentOutputEntry], old: [ComponentOutputEntry],
    previous: ResolvedLedger, artifacts: [String: ReplayedArtifact], workspace: URL
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
    func source(_ entry: ComponentOutputEntry) throws -> FileTransaction.Source {
      switch entry.output.content {
      case .file(_, let bytes): return .data(bytes)
      case .nativePlugin(_, let resource, _):
        guard let artifact = artifacts[entry.lowering.id + "/bundle"], let tree = artifact.tree,
          ledger.resources[resource] != nil
        else { throw CoreError.invalidState("missing frozen native container") }
        return .copy(tree)
      case .generatedLSPPlugin(_, let manifestPath, let manifest):
        guard manifest.bindings.isEmpty else {
          throw CoreError.invalidState(
            "native private container materialization requires the Core tree construction interface"
          )
        }
        let tree = workspace.appendingPathComponent(
          "native-tree-" + FileHash.sha256Hex(data: Data(entry.id.utf8)))
        let file = try PathSafety.resolvedChild(base: tree, subpath: manifestPath)
        try FileSystem.createDirectory(at: file.deletingLastPathComponent())
        let document = try NativeDocument(
          bytes: Data("{}".utf8), format: .json, budget: nativeBudget())
        let observation = try document.read(.init(keys: []))!
        let bytes = try document.prepare([
          .put(
            region: .init(keys: []), expected: .owned(observation),
            value: componentValue(manifest, values: nil, selected: ledger))
        ]).bytes
        try bytes.write(to: file)
        return .copy(tree)
      default: throw CoreError.invalidState("native whole-object content has a regional shape")
      }
    }
    let exists = FileManager.default.fileExists(atPath: path)
    if exists {
      guard let old = old.first,
        let deployment = previous.deployments.first(where: { $0.id == old.id })
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
          manifestPath, (manifestPath as NSString).deletingLastPathComponent,
        ])
        guard captured.entries.allSatisfy({ expectedPaths.contains($0.path) && !$0.executable })
        else {
          throw CoreError.invalidState("generated native container has unmanaged members")
        }
        let current = try NativeDocument(
          bytes: Data(contentsOf: target.url.appendingPathComponent(manifestPath)), format: .json,
          budget: nativeBudget())
        guard
          try current.read(.init(keys: []))?.value
            == componentValue(manifest, values: nil, selected: previous),
          deployment.ownership == .generated
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
      if changed { writes[path] = desired }
      try record(
        entry, previous: previous, changed: changed, readers: readers, ownership: .generated)
    } else if let entry = old.first,
      let deployment = previous.deployments.first(where: { $0.id == entry.id })
    {
      if exists { deletes.insert(path) }
      changes.append(
        .init(
          deployment: deployment, url: target.url, before: nil, after: nil,
          changed: exists, native: true, effectiveReaders: readers,
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
          $0.created && (try? $0.target.resolve(roots: store.ledgerRoots).path) == path
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
      where (try? deployment.target.resolve(roots: store.ledgerRoots).path) == path {
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
    let region: NativeRegion
    let bindings: Set<String>
    let symbolic: LedgerValue
    let render: (RuntimeBindingValues?) throws -> NativeValue
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
    let document = try NativeDocument(
      bytes: capture.bytes ?? Data((format == .toml ? "" : "{}\n").utf8),
      format: format, budget: nativeBudget())
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
          key: key, region: region, bindings: [], symbolic: c.value, render: { _ in observed })
      }
      let bindings = Set(
        c.bindings.filter { !$0.reference }.compactMap {
          switch $0.binding {
          case .environment(let n), .secret(let n): n
          case .literal: nil
          }
        })
      return .init(
        key: key, region: region, bindings: bindings, symbolic: c.value,
        render: { try self.nativeValue(c, values: $0, ledger: selected) })
    }
    func regional(_ entry: ComponentOutputEntry, selected: ResolvedLedger) throws
      -> [NativeRegionOwner]
    {
      func region(
        _ keys: [String], symbolic: LedgerValue,
        bindings: Set<String> = [], render: @escaping (RuntimeBindingValues?) throws -> NativeValue
      ) throws -> NativeRegionOwner {
        .init(
          key: try ResolvedLedgerCodec.digest(keys), region: .init(keys: keys), bindings: bindings,
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
            render: { try self.componentValue(value, values: $0, selected: selected) })
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
      case .hook, .orderedPermissions:
        throw CoreError.invalidState(
          "native occurrence publication requires durable occurrence ownership and append support"
        )
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
        if let existing = result[item.key], try existing.render(nil) != item.render(nil) {
          throw CoreError.invalidState("conflicting native physical region owners")
        }
        result[item.key] = item
      }
      return result
    }
    let desired = try keyed(desiredItems)
    let prior = try keyed(oldItems)
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
    var expected: [String: NativeExpectedRegion] = [:]
    for key in keys {
      let region = (desired[key] ?? prior[key])!.region
      if let observation = try document.read(region) {
        guard let old = prior[key] else { throw NativeDocumentError.ownershipMismatch(region) }
        if old.bindings.isEmpty, try observation.value != old.render(nil) {
          throw NativeDocumentError.ownershipMismatch(region)
        }
        expected[key] = .owned(observation)
      } else {
        expected[key] = .absent
      }
    }
    func edits(_ values: RuntimeBindingValues?) throws -> [NativeRegionEdit] {
      try keys.compactMap { key in
        if let next = desired[key] {
          return .put(region: next.region, expected: expected[key]!, value: try next.render(values))
        }
        if case .absent = expected[key] { return nil }
        return .remove(region: prior[key]!.region, expected: expected[key]!)
      }
    }
    let preview = try document.prepare(edits(nil))
    let changed = preview.bytes != (capture.bytes ?? Data((format == .toml ? "" : "{}\n").utf8))
    let bindings = desiredItems.reduce(into: Set<String>()) { $0.formUnion($1.bindings) }
    if let privatePlan {
      privateWrites.append((privatePlan, bindings, { try document.prepare(edits($0)).bytes }))
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
      if case .member(_, let value) = entry.output.content {
        ownBindings = Array(names(value.bindings)).sorted()
      } else {
        ownBindings = []
      }
      try record(
        entry, previous: previous, changed: changed || sensitive, readers: effectiveReaders,
        privatePlan: privatePlan, bindings: ownBindings)
    }
    for deployment in previous.deployments
    where (try? deployment.target.resolve(roots: store.ledgerRoots).path) == path {
      let oldOwners = try Set(
        deployment.owners.map {
          try LedgerImpact.identity(
            previous.components[$0]!, ledger: previous, roots: store.ledgerRoots)
        })
      let retained = try ledger.deployments.contains { next in
        guard next.route == deployment.route,
          (try? next.target.resolve(roots: store.ledgerRoots).path) == path
        else { return false }
        return try Set(
          next.owners.map {
            try LedgerImpact.identity(
              ledger.components[$0]!, ledger: ledger, roots: store.ledgerRoots)
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

  private func nativeBudget() -> NativeDocumentBudget {
    NativeDocumentBudget(
      limits: .init(
        storage: LedgerLimits.standard.resourceBytes,
        work: LedgerLimits.standard.encodedBytes, nodes: LedgerLimits.standard.nodes,
        depth: LedgerLimits.standard.depth, uninterruptedBytes: LedgerLimits.standard.keyBytes))
  }

  private func nativeValue(
    _ contribution: NativeMCPContribution, values: RuntimeBindingValues?, ledger: ResolvedLedger
  ) throws -> NativeValue {
    try Self.nativeValue(contribution, values: values, ledger: ledger, store: store)
  }

  private static func nativeValue(
    _ contribution: NativeMCPContribution, values: RuntimeBindingValues?, ledger: ResolvedLedger,
    store: StateStore
  ) throws -> NativeValue {
    func convert(_ value: LedgerValue, path: [MCPValueStep]) throws -> NativeValue {
      if let resource = contribution.resourcePlacements.first(where: { $0.path == path }),
        ledger.resources[resource.resource] != nil
      {
        let destination = try resourceDestination(resource.resource, ledger: ledger, store: store)
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

  package func stage(transaction: FileTransaction, provider: any RuntimeBindingProvider) throws {
    var staged = Set<String>()
    for (id, source) in resources.sorted(by: { $0.key < $1.key }) {
      guard let resource = ledger.resources[id], resource.kind != .liveEdit else { continue }
      let destination = try resourceDestination(id)
      let git = try gitDestination(resource, ledger: ledger)
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
      try transaction.replace(
        URL(fileURLWithPath: path), with: writes[path]!,
        expectedHash: { if case .link = writes[path]! { nil } else { skillContent[path]?.0 } }(),
        executableFlags: { if case .link = writes[path]! { nil } else { skillContent[path]?.1 } }(),
        expecting: targets[path])
    }
    for path in deletes.sorted() {
      try transaction.delete(URL(fileURLWithPath: path), expecting: targets[path])
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
    _ deployment: LedgerDeployment, ledger: ResolvedLedger, store: StateStore
  ) throws -> (readers: [AgentID]?, sensitive: Bool) {
    guard deployment.ownership == .ownedValues || deployment.route.hasSuffix("-components@1") else {
      return (nil, false)
    }
    let path = try deployment.target.resolve(roots: store.ledgerRoots).path
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
    return (readers.isEmpty ? nil : readers.sorted { $0.rawValue < $1.rawValue }, sensitive)
  }

  /// Observes only the owned region. Private receipts validate the entire physical preimage.
  package static func inspectDeployment(
    _ deployment: LedgerDeployment, ledger: ResolvedLedger, store: StateStore
  ) throws -> (status: String, diagnostic: String?) {
    let url = try deployment.target.resolve(roots: store.ledgerRoots)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ("missing", "managed target is missing")
    }
    do {
      if deployment.route == "agents/skill@1" {
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
        return try observed.value == nativeValue(c, values: nil, ledger: ledger, store: store)
          ? ("current", nil) : ("drifted", "managed native region changed")
      }
      if deployment.route.hasSuffix("-components@1"),
        let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) })
      {
        return try LedgerReplay.withLockedResources(
          ledger, store: store, roots: store.ledgerRoots, limits: .standard
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
          if try store.materializationReceipt(for: target) != nil { return ("current", nil) }
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
              == value.referenceValue(budget: budget)
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
          case .generatedLSPPlugin, .hook, .orderedPermissions:
            return (
              "unverified", "native ownership observation requires the integrated regional evidence"
            )
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
