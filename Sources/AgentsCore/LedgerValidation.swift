import Foundation

extension ResolvedLedger {
  package func validate() throws {
    guard version == 2 else { throw CoreError.invalidState("unsupported ledger version") }
    for (id, source) in sources {
      guard !id.isEmpty, !source.revision.isEmpty else {
        throw CoreError.invalidState("invalid ledger source")
      }
      if let container = source.container {
        guard sources[container] != nil, container != id else {
          throw CoreError.invalidState("dangling source container")
        }
      }
      try source.location?.validate()
      if source.kind == .git {
        guard let transport = source.transport, !transport.isEmpty,
          SourceCache.isObjectID(source.revision)
        else {
          throw CoreError.invalidState("Git ledger source needs exact transport and commit")
        }
      }
      var visited: Set<String> = [id]
      var current = source.container
      while let next = current {
        guard visited.insert(next).inserted else { throw CoreError.invalidState("source cycle") }
        current = sources[next]?.container
      }
    }
    for use in sourceUses {
      try requireSource(use.source)
      try ledgerPath(use.root)
      try use.requirement?.validate()
    }
    for (digest, bytes) in contentObjects {
      try StateValidation.digest(digest)
      guard "sha256:" + FileHash.sha256Hex(data: bytes) == digest else {
        throw CoreError.invalidState("content object digest mismatch")
      }
    }
    for (id, resource) in resources {
      guard !id.isEmpty else { throw CoreError.invalidState("empty resource ID") }
      try requireSource(resource.source)
      try ledgerPath(resource.path)
      try StateValidation.digest(resource.hash)
      try resource.location?.validate()
      if resource.kind == .liveEdit {
        guard resource.location != nil, resource.artifact == nil, resource.entries.isEmpty,
          resource.support.isEmpty
        else {
          throw CoreError.invalidState("invalid live edit resource")
        }
      } else {
        guard resource.location == nil, !resource.entries.isEmpty else {
          throw CoreError.invalidState("incomplete locked resource")
        }
      }
      if resource.kind == .git {
        var source = sources[resource.source]!
        while let parent = source.container { source = sources[parent]! }
        guard SourceCache.isObjectID(source.revision) else {
          throw CoreError.invalidState("resource requires exact Git commit")
        }
      }
      if resource.kind == .artifact {
        guard let artifact = resource.artifact else {
          throw CoreError.invalidState("artifact resource needs immutable coordinates")
        }
        try artifact.validate()
      } else if resource.artifact != nil {
        throw CoreError.invalidState("unexpected resource artifact")
      }
      guard Set(resource.entries.map(\.path)).count == resource.entries.count,
        Set(resource.support.map(\.path)).count == resource.support.count
      else {
        throw CoreError.invalidState("duplicate resource path")
      }
      var entries: [String: LedgerEntry] = [:]
      var treeEntries = resource.support
      treeEntries += resource.entries.map { original in
        var entry = original
        entry.path =
          original.path == "."
          ? resource.path
          : resource.path == "." ? original.path : resource.path + "/" + original.path
        return entry
      }
      for entry in treeEntries {
        try ledgerPath(entry.path)
        guard entries[entry.path] == nil || entries[entry.path] == entry else {
          throw CoreError.invalidState("conflicting resource path")
        }
        entries[entry.path] = entry
        switch entry.kind {
        case .file:
          guard let byteCount = entry.byteCount, byteCount >= 0 else {
            throw CoreError.invalidState("file requires byte count")
          }
          guard entry.link == nil else { throw CoreError.invalidState("file has link target") }
          if let object = entry.object {
            guard contentObjects[object]?.count == byteCount else {
              throw CoreError.invalidState("dangling content object")
            }
          } else if resource.kind == .embedded || resource.kind == .artifact {
            throw CoreError.invalidState("embedded file lacks content")
          }
        case .directory:
          guard entry.object == nil, entry.link == nil, entry.byteCount == nil, !entry.executable
          else {
            throw CoreError.invalidState("invalid directory entry")
          }
        case .symlink:
          guard let link = entry.link, entry.object == nil, entry.byteCount == nil,
            !entry.executable,
            !link.hasPrefix("/"), !link.contains("\0"), !link.contains("\\")
          else {
            throw CoreError.invalidState("invalid resource link")
          }
        }
      }
      if resource.kind != .liveEdit, !resource.entries.contains(where: { $0.path == "." }) {
        throw CoreError.invalidState("missing resource root entry")
      }
      _ = try LedgerResources.validatedEntries(resource)
      if let root = resource.entries.first(where: { $0.path == "." }), root.kind != .directory,
        resource.entries.count != 1
      {
        throw CoreError.invalidState("file resource has descendants")
      }
    }
    for component in components.values {
      try requireSource(component.declaringSource)
      try requireSource(component.source)
      try ledgerPath(component.root)
      guard DeclaredComponentKind(rawValue: component.kind) != nil, !component.name.isEmpty else {
        throw CoreError.invalidState("invalid component identity")
      }
      try component.payload.validate()
      try requireResources(component.resources)
      for condition in component.conditions { try validate(condition) }
    }
    let groupIDs = Set(groups.map(\.id))
    let occurrenceIDs = Set(occurrences.map(\.id))
    guard groupIDs.count == groups.count, occurrenceIDs.count == occurrences.count,
      groupIDs.isDisjoint(with: occurrenceIDs)
    else {
      throw CoreError.invalidState("duplicate ledger occurrence")
    }
    var children: [Int: [Int]] = [:]
    for group in groups {
      if let parent = group.parent { children[parent, default: []].append(group.id) }
    }
    for occurrence in occurrences {
      if let parent = occurrence.reference { children[parent, default: []].append(occurrence.id) }
    }
    for group in groups {
      try requireSource(group.source)
      try ledgerPath(group.root)
      try group.requirement?.validate()
      try StateValidation.digest(group.manifestHash)
      guard group.id >= 0, group.parent.map({ groupIDs.contains($0) && $0 < group.id }) ?? true,
        Set(group.children).count == group.children.count,
        group.children.allSatisfy({ groupIDs.contains($0) || occurrenceIDs.contains($0) })
      else {
        throw CoreError.invalidState("invalid group closure")
      }
      guard group.children == (children[group.id] ?? []).sorted() else {
        throw CoreError.invalidState("incomplete group child closure")
      }
    }
    for occurrence in occurrences {
      try requireSource(occurrence.declaringSource)
      try ledgerPath(occurrence.manifestPath)
      guard occurrence.id >= 0, components[occurrence.component] != nil,
        occurrence.reference.map({ groupIDs.contains($0) && $0 < occurrence.id }) ?? true
      else {
        throw CoreError.invalidState("dangling component occurrence")
      }
      for dependency in occurrence.dependencies { try requireSource(dependency) }
      try validate(occurrence.condition)
    }
    let deploymentIDs = Set(deployments.map(\.id))
    guard deploymentIDs.count == deployments.count else {
      throw CoreError.invalidState("duplicate deployment")
    }
    for deployment in deployments {
      let producers = lowerings.filter { $0.deployments.contains(deployment.id) }
      guard !producers.isEmpty,
        producers.allSatisfy({
          Set(deployment.owners).isSubset(of: Set($0.inputs)) && $0.format == deployment.route
        })
      else { throw CoreError.invalidState("deployment has incomplete lowering ownership") }
      try deployment.target.validate()
      guard deployment.target.kind != .authoringRelative else {
        throw CoreError.invalidState("authoring coordinates cannot be deployment targets")
      }
      try StateValidation.digest(deployment.expectedHash)
      guard !deployment.id.isEmpty, !deployment.route.isEmpty, !deployment.owners.isEmpty,
        deployment.owners.allSatisfy({ components[$0] != nil }),
        deployment.ownership != .importBlock || deployment.importReference != nil
      else {
        throw CoreError.invalidState("invalid deployment ownership")
      }
    }
    guard Set(lowerings.map(\.id)).count == lowerings.count else {
      throw CoreError.invalidState("duplicate lowering")
    }
    for lowering in lowerings {
      guard !lowering.id.isEmpty, !lowering.format.isEmpty,
        DeclarationPlatform(rawValue: lowering.platform) != nil,
        lowering.inputs.allSatisfy({ components[$0] != nil }),
        lowering.deployments.allSatisfy({ deploymentIDs.contains($0) }),
        Set(lowering.artifacts.map(\.name)).count == lowering.artifacts.count
      else {
        throw CoreError.invalidState("invalid locked lowering references")
      }
      try lowering.layout.validate()
      try requireResources(lowering.resources)
      for artifact in lowering.artifacts { try StateValidation.digest(artifact.hash) }
    }
  }

  private func requireSource(_ id: String) throws {
    guard sources[id] != nil else { throw CoreError.invalidState("dangling ledger source") }
  }

  private func requireResources(_ ids: [String]) throws {
    guard ids.allSatisfy({ resources[$0] != nil }) else {
      throw CoreError.invalidState("dangling ledger resource")
    }
  }

  private func validate(_ condition: LedgerCondition) throws {
    guard condition.platforms?.allSatisfy({ DeclarationPlatform(rawValue: $0) != nil }) ?? true
    else {
      throw CoreError.invalidState("unknown ledger platform")
    }
  }
}
