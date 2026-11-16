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
  private var unownedInstructions: [String] = []
  private var targets: [String: TargetPrecondition] = [:]
  private var writes: [String: FileTransaction.Source] = [:]
  private var deletes = Set<String>()
  private var capsules: [String: URL] = [:]
  private var skillContent: [String: (String, [String: Bool])] = [:]
  private var privateWrites:
    [(PreparedPrivateMaterialization, Set<String>, (RuntimeBindingValues) throws -> Data)] = []
  private var resourceEvidence: [TargetPrecondition] = []

  package init(
    ledger: ResolvedLedger, previous: ResolvedLedger, artifacts: [ReplayedArtifact],
    resources: [String: URL], workspace: URL, store: StateStore, replace: Bool,
    changingAccess: Bool,
    kinds: Set<DeclaredComponentKind>? = nil
  ) throws {
    self.ledger = ledger
    self.store = store
    self.resources = resources
    self.replace = replace
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
    where lowering.format.hasSuffix("-mcp@1") && (kinds == nil || kinds!.contains(.mcpServer)) {
      let contribution = try MCPLayoutV1.contribution(lowering, ledger: ledger)
      let route = try DeploymentConstruction.route(contribution)
      let target = try store.nativeTarget(for: route)
      native[target.url.path, default: []].append((lowering, contribution, target))
    }
    // Removed native regions still participate in the same physical aggregation.
    for lowering in previous.lowerings
    where lowering.format.hasSuffix("-mcp@1") && (kinds == nil || kinds!.contains(.mcpServer)) {
      let c = try MCPLayoutV1.contribution(lowering, ledger: previous)
      let target = try store.nativeTarget(for: DeploymentConstruction.route(c))
      if native[target.url.path] == nil { native[target.url.path] = [] }
    }
    for path in native.keys.sorted() {
      try prepareNative(
        path: path, contributions: native[path]!, previous: previous,
        changingAccess: changingAccess)
      byPath.removeValue(forKey: path)
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
        guard
          !old.isEmpty
            || !FileManager.default.fileExists(atPath: path)
        else {
          throw CoreError.invalidSkill(
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
          if let real = PathSafety.realPath(tree.path),
            let children = FileManager.default.enumerator(
              at: tree, includingPropertiesForKeys: [.isSymbolicLinkKey])
          {
            for case let child as URL in children
            where try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
              guard try PathSafety.linkStaysInside(child, root: real) else {
                throw CoreError.unsafePath("copied skill link escapes its installed subtree")
              }
            }
          }
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
    let ledger = selected ?? self.ledger
    guard let resource = ledger.resources[id] else {
      throw CoreError.invalidState("missing deployment resource")
    }
    if let location = resource.location { return try location.resolve(roots: store.ledgerRoots) }
    if let root = try gitDestination(resource, ledger: ledger) {
      return root.appendingPathComponent(resource.path)
    }
    let base = store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + String(id.dropFirst(7)))
    return base.appendingPathComponent(resource.support.isEmpty ? "payload" : resource.path)
  }

  private func gitDestination(_ resource: LedgerResource, ledger: ResolvedLedger) throws -> URL? {
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

  private func prepareNative(
    path: String, contributions: [(LockedLowering, NativeMCPContribution, MaterializationTarget)],
    previous: ResolvedLedger, changingAccess: Bool
  ) throws {
    let url = URL(fileURLWithPath: path)
    let capture = try TargetPrecondition.readingFile(url)
    targets[path] = try capture.evidence.capturingPublicationAccess()
    fingerprints.append(try capture.evidence.displayEvidence(includeContent: false))
    let old = try previous.lowerings.filter { $0.format.hasSuffix("-mcp@1") }.compactMap {
      lowering -> NativeMCPContribution? in
      let c = try MCPLayoutV1.contribution(lowering, ledger: previous)
      return try store.nativeTarget(for: DeploymentConstruction.route(c)).url.path == path ? c : nil
    }
    guard let descriptor = contributions.first?.1.descriptor ?? old.first?.descriptor else {
      return
    }
    let document = try NativeDocument(
      bytes: capture.bytes ?? Data("{}\n".utf8),
      format: descriptor.documentFormat,
      budget: NativeDocumentBudget(
        limits: .init(
          storage: LedgerLimits.standard.resourceBytes, work: LedgerLimits.standard.encodedBytes,
          nodes: LedgerLimits.standard.nodes, depth: LedgerLimits.standard.depth,
          uninterruptedBytes: LedgerLimits.standard.keyBytes)))
    var desired: [String: NativeMCPContribution] = [:]
    for (_, c, _) in contributions {
      if let prior = desired[c.name],
        prior.value != c.value || prior.bindings != c.bindings
          || prior.resourcePlacements != c.resourcePlacements
      {
        throw CoreError.invalidState("conflicting native region contributions")
      }
      desired[c.name] = c
    }
    let oldByName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let names = Set(desired.keys).union(oldByName.keys).sorted()
    let sensitive = (old + contributions.map(\.1)).contains {
      $0.bindings.contains { !$0.reference }
    }
    let target: MaterializationTarget
    if let provided = contributions.first?.2 {
      target = provided
    } else {
      target = try store.nativeTarget(for: DeploymentConstruction.route(old[0]))
    }
    let privatePlan =
      try sensitive
      ? store.preparePrivateMaterialization(
        target, changingAccess: changingAccess,
        requiringReceiptForExistingTarget: old.contains { $0.bindings.contains { !$0.reference } })
      : nil
    var expected: [String: NativeExpectedRegion] = [:]
    for name in names {
      let region = try descriptor.region(
        server: name,
        nativeProjectKey: descriptor.request.scope == .local
          ? try store.nativeTarget(for: .claudeMCPProject).url.deletingLastPathComponent().path
          : nil)
      if let observation = try document.read(region) {
        guard let prior = oldByName[name] else {
          throw NativeDocumentError.ownershipMismatch(region)
        }
        if !prior.bindings.contains(where: { !$0.reference }) {
          guard observation.value == (try nativeValue(prior, values: nil, ledger: previous)) else {
            throw NativeDocumentError.ownershipMismatch(region)
          }
        }
        expected[name] = .owned(observation)
      } else {
        expected[name] = .absent
      }
    }
    func edits(_ values: RuntimeBindingValues?) throws -> [NativeRegionEdit] {
      try names.map { name in
        let region = try descriptor.region(
          server: name,
          nativeProjectKey: descriptor.request.scope == .local
            ? try self.store.nativeTarget(for: .claudeMCPProject).url.deletingLastPathComponent()
              .path : nil)
        if let c = desired[name] {
          return .put(
            region: region, expected: expected[name]!,
            value: try self.nativeValue(c, values: values, ledger: self.ledger))
        }
        return .remove(region: region, expected: expected[name]!)
      }
    }
    // Symbolic placeholders never leave the private plan. A staged literal render consumes
    // all regions together after Core has verified private staging and resolved bindings.
    let preview = try document.prepare(edits(nil))
    let changed = preview.bytes != (capture.bytes ?? Data("{}\n".utf8))
    if let privatePlan {
      let bindings = Set(
        contributions.flatMap {
          $0.1.bindings.filter { !$0.reference }.map { placement in
            switch placement.binding {
            case .environment(let n), .secret(let n): n
            case .literal: ""
            }
          }
        })
      privateWrites.append(
        (privatePlan, bindings, { values in try document.prepare(edits(values)).bytes }))
    } else if changed {
      writes[path] = .data(preview.bytes)
    }
    for (lowering, contribution, _) in contributions {
      let id = lowering.id
      let deployment = LedgerDeployment(
        id: id,
        target: .init(
          kind: .registered, root: String(target.path.split(separator: "/")[0]),
          path: url.lastPathComponent),
        route: lowering.format, owners: [contribution.component],
        recipients: contribution.recipients,
        ownership: .ownedValues, expectedHash: try ResolvedLedgerCodec.digest(contribution.value),
        created: previous.deployments.first(where: { $0.id == id })?.created
          ?? (capture.bytes == nil))
      ledger.deployments.removeAll { $0.id == id }
      ledger.deployments.append(deployment)
      if let i = ledger.lowerings.firstIndex(where: { $0.id == lowering.id }) {
        ledger.lowerings[i].deployments = [id]
      }
      changes.append(
        .init(
          deployment: deployment, url: url, before: nil, after: nil, changed: changed || sensitive,
          native: true, accessChange: privatePlan?.accessChange, privateMaterialization: sensitive,
          requiredBindings: contribution.bindings.filter { !$0.reference }.map {
            switch $0.binding {
            case .environment(let name), .secret(let name): name
            case .literal: ""
            }
          }.sorted(), symbolicBefore: oldByName[contribution.name]?.value,
          symbolicAfter: contribution.value))
    }
    for name in Set(oldByName.keys).subtracting(desired.keys).sorted() {
      let old = oldByName[name]!
      if let prior = previous.deployments.first(where: {
        $0.ownership == .ownedValues && $0.owners.contains(old.component)
          && (try? $0.target.resolve(roots: store.ledgerRoots).path) == path
      }) {
        let removed: Bool
        if case .absent = expected[name] { removed = false } else { removed = true }
        changes.append(
          .init(
            deployment: prior, url: url, before: nil, after: nil, changed: removed,
            native: true, accessChange: privatePlan?.accessChange,
            privateMaterialization: sensitive,
            symbolicBefore: old.value))
      }
    }
  }

  private func nativeValue(
    _ contribution: NativeMCPContribution, values: RuntimeBindingValues?, ledger: ResolvedLedger
  ) throws -> NativeValue {
    func convert(_ value: LedgerValue, path: [MCPValueStep]) throws -> NativeValue {
      if let resource = contribution.resourcePlacements.first(where: { $0.path == path }),
        ledger.resources[resource.resource] != nil
      {
        let destination = try resourceDestination(resource.resource, in: ledger)
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

  package func requireOwnership() throws {
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
