import Foundation

/// Validated live cache references. Publication owns when a reduced set becomes authoritative.
package struct RetentionReferences: Sendable {
  package struct Git: Hashable, Sendable {
    package var source: String
    package var revision: String
  }
  package var git: Set<Git> = []
  package var artifacts: Set<String> = []
  package var live: [URL] = []
  package var sourceLocations: [String: String] = [:]

  package init() {}

  package init(ledger: ResolvedLedger, roots: [String: URL]) throws {
    try ledger.validate()
    // Every source is part of the accepted closure, including empty groups and container parents.
    for source in ledger.sources.values {
      guard source.container == nil, SourceCache.isObjectID(source.revision) else { continue }
      let location: String
      let identity: String
      if let transport = source.transport {
        location = transport
        identity = try SourceDeclaration(kind: .git, location: transport).identity(
          environment: RuntimeEnvironment())
      } else if let authored = source.location {
        location = try authored.resolve(roots: roots).path
        identity = "local:" + location
      } else {
        throw CoreError.invalidState("missing retained source coordinates")
      }
      git.insert(.init(source: identity, revision: source.revision))
      sourceLocations[identity] = location
    }
    artifacts.formUnion(ledger.resources.filter { $0.value.kind != .liveEdit }.keys)
    for resource in ledger.resources.values {
      if let artifact = resource.artifact { retain(artifact) }
      if resource.kind == .liveEdit, let location = resource.location {
        live.append(try location.resolve(roots: roots).resolvingSymlinksInPath())
      }
    }
  }

  package mutating func include(watch: WatchState) throws {
    try watch.validate()
    for (id, source) in watch.sources {
      sourceLocations[id] = id.hasPrefix("local:") ? String(id.dropFirst(6)) : id
      switch source.seen {
      case .revision(let revision): git.insert(.init(source: id, revision: revision))
      case .artifacts(let objects): artifacts.formUnion(objects.values)
      }
    }
  }

  private mutating func retain(_ artifact: LockedArtifact) {
    artifacts.insert(artifact.digest)
    artifacts.formUnion((artifact.files ?? []).map(\.digest))
  }
}
