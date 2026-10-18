import AgentsCore
import Foundation

struct DiscoveredSource {
  var source: SourceDeclaration
  var id: String
  var root: URL
  var pin: SourceRevision?
  var skills: [Skill]
  var artifacts: [String: WellKnownRemoteSkill]
}

struct PreparedSkill {
  var lock: LockedSkill
  var directory: URL
  var payloads: [String: Data]
}

final class SkillLifecycle {
  let store: StateStore
  let cache: SourceCache
  let provider: WellKnownProvider
  let workspace: URL

  init(store: StateStore, provider: WellKnownProvider) throws {
    self.store = store
    self.cache = SourceCache(store: store)
    self.provider = provider
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-operation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: workspace) }

  func lockedSource(_ source: SourceDeclaration) -> LockedSource {
    LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
  }

  func discover(
    _ source: SourceDeclaration, live: Bool, fullDepth: Bool, names: [String]? = nil,
    exclude: [String] = []
  ) throws -> DiscoveredSource {
    let id = try source.identity(environment: store.environment)
    let root: URL
    var pin: SourceRevision?
    var artifacts: [String: WellKnownRemoteSkill] = [:]
    if source.kind == .wellKnown {
      root = workspace.appendingPathComponent(UUID().uuidString)
      let remote = try provider.fetchAllSkills(
        from: source.location, names: names, exclude: exclude)
      for skill in remote {
        guard artifacts[skill.installName] == nil else {
          throw CoreError.invalidSkill("duplicate upstream skill: \(skill.installName)")
        }
        try skill.artifact.validate()
        artifacts[skill.installName] = skill
        try write(skill.files, to: root.appendingPathComponent(skill.installName))
      }
    } else if live {
      guard source.kind == .local, source.requirement == nil else {
        throw CoreError.invalidSource("live content requires an unpinned local source")
      }
      root = source.localURL(environment: store.environment)
    } else {
      let resolved = try cache.resolve(source)
      pin = resolved
      root = workspace.appendingPathComponent(UUID().uuidString)
      try cache.withSnapshot(
        sourceID: id, source: lockedSource(source), revision: resolved.revision
      ) { snapshot in
        try FileManager.default.copyItem(at: snapshot, to: root)
      }
    }
    let skills = try Discovery.discover(
      in: root, subpath: source.path,
      options: DiscoveryOptions(
        includeInternal: ["true", "1"].contains(
          store.environment.environment["INSTALL_INTERNAL_SKILLS"] ?? ""), fullDepth: fullDepth))
    var names = Set<String>()
    for skill in skills {
      guard names.insert(PathSafety.sanitizeName(skill.name)).inserted else {
        throw CoreError.invalidSkill("duplicate skill filesystem name: \(skill.name)")
      }
    }
    if source.kind == .wellKnown {
      for skill in skills where artifacts[PathSafety.sanitizeName(skill.name)] == nil {
        throw CoreError.invalidSkill("artifact name differs from SKILL.md name")
      }
    }
    return DiscoveredSource(
      source: source, id: id, root: root, pin: pin, skills: skills, artifacts: artifacts)
  }

  func select(_ skills: [Skill], names: [String]) throws -> [Skill] {
    guard !names.isEmpty else { return skills }
    var selected: [Skill] = []
    for name in names {
      let matches = Discovery.filter(skills, names: [name])
      guard matches.count == 1, let match = matches.first else {
        throw CoreError.notFound("skill '\(name)' is missing or ambiguous upstream")
      }
      if !selected.contains(where: { $0.path == match.path }) { selected.append(match) }
    }
    return selected
  }

  func prepare(
    _ skill: Skill, in source: DiscoveredSource, declaration: SkillDeclaration,
    defaultAgents: [AgentID]
  ) throws -> PreparedSkill {
    let name = PathSafety.sanitizeName(skill.name)
    let override = declaration.overrides?[name]
    let agents = override?.agents ?? declaration.agents ?? defaultAgents
    let mode = override?.mode ?? declaration.mode ?? .link
    guard !agents.isEmpty else { throw CoreError.invalidSkill("skill has no recipients: \(name)") }
    let path = PathSafety.relativePath(skill.path, to: source.root.path)
    var directory = URL(fileURLWithPath: skill.path)
    let artifact = source.artifacts[name]
    let lock: LockedSkill
    if mode == .edit {
      guard source.source.kind == .local, source.source.requirement == nil else {
        throw CoreError.invalidSource("edit requires a local source with no requirement")
      }
      directory = try PathSafety.resolvedChild(
        base: source.source.localURL(environment: store.environment), subpath: path)
      guard
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path)
      else { throw CoreError.notFound("live skill directory") }
      lock = LockedSkill(
        source: source.id, path: path,
        installs: Dictionary(uniqueKeysWithValues: Set(agents).map { ($0.rawValue, mode) }))
    } else {
      guard source.pin != nil || artifact != nil else {
        throw CoreError.invalidSource("link and copy require committed Git content")
      }
      lock = LockedSkill(
        source: source.id, revision: source.pin?.revision, version: source.pin?.version,
        artifact: artifact?.artifact, path: artifact == nil ? path : nil,
        hash: "sha256:" + (try FileHash.folderHash(directory)),
        installs: Dictionary(uniqueKeysWithValues: Set(agents).map { ($0.rawValue, mode) }))
    }
    return PreparedSkill(lock: lock, directory: directory, payloads: artifact?.payloads ?? [:])
  }

  func restore(name: String, skill: LockedSkill, sources: [String: LockedSource]) throws
    -> PreparedSkill
  {
    guard let source = sources[skill.source] else {
      throw CoreError.invalidState("unknown locked source")
    }
    let directory: URL
    var payloads: [String: Data] = [:]
    if skill.installs.values.allSatisfy({ $0 == .edit }) {
      let declaration = try cache.declaration(sourceID: skill.source, source: source)
      directory = try PathSafety.resolvedChild(
        base: declaration.localURL(environment: store.environment), subpath: skill.path ?? ".")
    } else if let artifact = skill.artifact {
      let restored = try provider.restore(artifact, cache: cache)
      payloads = restored.payloads
      directory = workspace.appendingPathComponent(UUID().uuidString)
      try write(restored.files, to: directory)
    } else {
      guard let revision = skill.revision, let path = skill.path else {
        throw CoreError.invalidState("missing locked revision or path")
      }
      let cached = cache.materializedURL(sourceID: skill.source, revision: revision)
      try cache.validatePath(cached)
      let root: URL
      if FileManager.default.fileExists(atPath: cached.path) {
        root = cached
      } else {
        root = workspace.appendingPathComponent(UUID().uuidString)
        try cache.withSnapshot(sourceID: skill.source, source: source, revision: revision) {
          snapshot in
          try FileManager.default.copyItem(at: snapshot, to: root)
        }
      }
      directory = try PathSafety.resolvedChild(base: root, subpath: path)
    }
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path)
    else { throw CoreError.notFound("locked skill is unavailable: \(name)") }
    if let hash = skill.hash, try "sha256:" + FileHash.folderHash(directory) != hash {
      throw CoreError.invalidState("locked skill digest mismatch: \(name)")
    }
    return PreparedSkill(lock: skill, directory: directory, payloads: payloads)
  }

  func apply(
    declaration: Declaration, previous: ResolvedState, next: ResolvedState,
    prepared: [String: PreparedSkill], names: Set<String>, writeState: Bool = true
  ) throws -> [InstallResult] {
    try declaration.validate(environment: store.environment)
    try next.validate()
    let transaction = FileTransaction(store: store)
    let oldTargets = try targets(previous)
    let newTargets = try targets(next)
    var results: [InstallResult] = []
    var retained: [String: URL] = [:]
    do {
      // Verify every source before preparing any installed replacement.
      for (name, item) in prepared {
        let skill = item.lock
        if let hash = skill.hash, try "sha256:" + FileHash.folderHash(item.directory) != hash {
          throw CoreError.invalidState("prepared skill changed: \(name)")
        }
        if let revision = skill.revision, let source = next.sources[skill.source] {
          let root = try cache.materialize(
            sourceID: skill.source, source: source, revision: revision)
          let path = try PathSafety.resolvedChild(base: root, subpath: skill.path ?? ".")
          guard try "sha256:" + FileHash.folderHash(path) == skill.hash else {
            throw CoreError.invalidState("cached skill digest mismatch: \(name)")
          }
          retained[name] = path
        } else if let artifact = skill.artifact {
          for (digest, data) in item.payloads { _ = try cache.storeArtifact(data, digest: digest) }
          guard let hash = skill.hash else {
            throw CoreError.invalidState("missing artifact content hash")
          }
          retained[name] = try cache.materializeArtifact(
            item.directory, digest: artifact.digest, hash: hash)
        } else {
          retained[name] = item.directory
        }
      }
      for (path, target) in oldTargets where names.contains(target.name) && newTargets[path] == nil
      {
        try transaction.replace(URL(fileURLWithPath: path), content: nil)
      }
      for (path, target) in newTargets.sorted(by: { $0.key < $1.key })
      where names.contains(target.name) {
        guard let content = retained[target.name] else { continue }
        guard
          !PathSafety.isContained(
            content.resolvingSymlinksInPath(), in: URL(fileURLWithPath: path).standardizedFileURL)
        else {
          throw CoreError.unsafePath("installation would replace its own source")
        }
        try transaction.replace(
          URL(fileURLWithPath: path), content: content, link: target.mode != .copy)
      }
      if writeState {
        try transaction.replace(
          store.declarationURL, content: nil, data: StateStore.encode(declaration.normalized))
        try transaction.replace(
          store.resolvedURL, content: nil, data: StateStore.encode(next.normalized))
      }
      try cache.prune(referencedBy: next, transaction: transaction)
      try transaction.commit()
    } catch {
      if let recovered = try? store.readResolved() { try? cache.prune(referencedBy: recovered) }
      throw error
    }
    for name in names.sorted() {
      guard let skill = next.skills[name], prepared[name] != nil else { continue }
      for (raw, mode) in skill.installs.sorted(by: { $0.key < $1.key }) {
        guard let agent = AgentID(rawValue: raw) else { continue }
        results.append(
          InstallResult(
            skill: name, agent: agent, scope: store.scope, mode: mode,
            path: Self.target(name: name, agent: agent, store: store).path))
      }
    }
    return results
  }

  func changes(name: String, old: LockedSkill?, new: PreparedSkill?) throws -> [SkillFileChange] {
    let oldTargets = try targets(ResolvedState(skills: old.map { [name: $0] } ?? [:]))
    let newTargets = try targets(ResolvedState(skills: new.map { [name: $0.lock] } ?? [:]))
    var result: [SkillFileChange] = []
    for path in Set(oldTargets.keys).union(newTargets.keys).sorted() {
      let target = URL(fileURLWithPath: path)
      let before = try entries(target)
      var after: [String: SkillFileEntry] = [:]
      if let planned = newTargets[path], let new {
        after = try entries(new.directory)
        if planned.mode != .copy {
          let content: URL
          if let revision = new.lock.revision {
            content = try PathSafety.resolvedChild(
              base: cache.materializedURL(sourceID: new.lock.source, revision: revision),
              subpath: new.lock.path ?? ".")
          } else if let artifact = new.lock.artifact {
            content = store.cacheDirectory.appendingPathComponent(
              "artifact-content/" + artifact.digest.dropFirst(7))
          } else {
            content = new.directory
          }
          after["."] = .symbolicLink(
            FileTransaction.linkDestination(
              content, parent: target.deletingLastPathComponent(), store: store))
        } else {
          after["."] = .directory
        }
      }
      for relative in Set(before.keys).union(after.keys).sorted()
      where before[relative] != after[relative] {
        result.append(
          SkillFileChange(
            path: relative == "." ? path : target.appendingPathComponent(relative).path,
            before: before[relative], after: after[relative]))
      }
    }
    return result
  }

  static func target(name: String, agent: AgentID, store: StateStore) -> URL {
    AgentRegistry.installSkillsDirectory(
      for: agent, scope: store.scope, environment: store.environment
    ).appendingPathComponent(name).standardizedFileURL
  }

  static func physicalTarget(_ url: URL) -> URL {
    url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
  }

  private func targets(_ lock: ResolvedState) throws -> [String: (name: String, mode: InstallMode)]
  {
    var result: [String: (name: String, mode: InstallMode)] = [:]
    for (name, skill) in lock.skills {
      for (raw, mode) in skill.installs {
        guard let agent = AgentID(rawValue: raw) else {
          throw CoreError.invalidState("unknown locked agent")
        }
        let url = Self.target(name: name, agent: agent, store: store)
        let physical = Self.physicalTarget(url).path
        if let existing = result[physical], existing.name != name || existing.mode != mode {
          throw CoreError.invalidState("agents sharing a skill directory must use the same mode")
        }
        result[physical] = (name, mode)
      }
    }
    return result
  }

  private func write(_ files: [String: Data], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (path, data) in files {
      let url = try PathSafety.resolvedChild(base: directory, subpath: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
  }

  private func entries(_ directory: URL) throws -> [String: SkillFileEntry] {
    func entry(_ url: URL) throws -> SkillFileEntry? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return nil
      }
      switch attributes[.type] as? FileAttributeType {
      case .typeSymbolicLink:
        return .symbolicLink(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
      case .typeDirectory: return .directory
      case .typeRegular: return .file(try Data(contentsOf: url))
      default: throw CoreError.unsafePath("unsupported installed entry: \(url.path)")
      }
    }
    guard let root = try entry(directory) else { return [:] }
    var result = [".": root]
    let resolved = directory.resolvingSymlinksInPath()
    guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      let enumerator = FileManager.default.enumerator(
        at: resolved, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return result }
    for case let file as URL in enumerator {
      let value = try entry(file)
      if case .symbolicLink = value { enumerator.skipDescendants() }
      result[PathSafety.relativePath(file.path, to: resolved.path)] = value
    }
    return result
  }
}
