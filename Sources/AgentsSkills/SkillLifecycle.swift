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
  let executableFlags: [String: Bool]?
  let identity: PathIdentity
  let sourceIdentity: PathIdentity

  init(lock: LockedSkill, directory: URL, payloads: [String: Data], sourcePath: URL? = nil) throws {
    self.lock = lock
    self.directory = directory
    self.payloads = payloads
    executableFlags = try lock.hash == nil ? nil : FileHash.executableFlags(directory)
    identity = try PathIdentity(directory.resolvingSymlinksInPath())
    sourceIdentity = try PathIdentity(sourcePath ?? directory)
  }
}

final class SkillLifecycle {
  let store: StateStore
  let cache: SourceCache
  let provider: WellKnownProvider
  let workspace: URL
  let resolutions: SourceResolutionSession?

  init(
    store: StateStore, provider: WellKnownProvider, resolutions: SourceResolutionSession? = nil
  ) throws {
    self.resolutions = resolutions
    self.store = store
    self.cache = SourceCache(store: store)
    self.provider = provider
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-operation-" + UUID().uuidString)
    try FileSystem.createDirectory(at: workspace)
  }

  deinit { try? FileManager.default.removeItem(at: workspace) }

  func lockedSource(_ source: SourceDeclaration) -> LockedSource {
    LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
  }

  func discover(
    _ source: SourceDeclaration, live: Bool, fullDepth: Bool, names: [String]? = nil,
    exclude: [String] = [], cacheSource: Bool = true
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
      root = workspace.appendingPathComponent(UUID().uuidString)
      func copy(_ resolved: SourceRevision, _ snapshot: URL) throws {
        pin = resolved
        try FileSystem.withAccessErrors(at: root) {
          try FileManager.default.copyItem(at: snapshot, to: root)
        }
      }
      if let resolutions {
        try resolutions.withSnapshot(source, copy)
      } else {
        try cache.withResolvedSnapshot(source, cacheSource: cacheSource, copy)
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
    return try PreparedSkill(
      lock: lock, directory: directory, payloads: artifact?.payloads ?? [:],
      sourcePath: mode == .edit ? URL(fileURLWithPath: skill.path) : nil)
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
          try FileSystem.withAccessErrors(at: root) {
            try FileManager.default.copyItem(at: snapshot, to: root)
          }
        }
      }
      directory = try PathSafety.resolvedChild(base: root, subpath: path)
    }
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path)
    else { throw CoreError.notFound("locked skill is unavailable: \(name)") }
    if let hash = skill.hash, try "sha256:" + FileHash.folderHash(directory) != hash {
      throw CoreError.invalidState("locked skill digest mismatch: \(name)")
    }
    return try PreparedSkill(lock: skill, directory: directory, payloads: payloads)
  }

  func apply(
    declaration: Declaration, previous: ResolvedState, next: ResolvedState,
    prepared: [String: PreparedSkill], names: Set<String>, baseline: StatePrecondition,
    writeState: Bool = true
  ) throws -> [InstallResult] {
    try declaration.validate(environment: store.environment)
    try next.validate()
    let plan = try SkillUpdatePlan(
      lifecycle: self, previous: previous, next: next, prepared: prepared, names: names, results: []
    )
    try plan.validateOwnership()
    try baseline.validate()
    try plan.validate()
    let retained = try plan.retain()
    let transaction = FileTransaction(store: store)
    transaction.validateBeforePublication = { [unowned transaction] in
      try baseline.validate(excludingTargets: transaction.targetPaths)
      try plan.validate(excludingTargets: transaction.targetPaths)
    }
    try plan.stage(retained: retained, transaction: transaction)
    if writeState {
      try store.stageDeclaration(declaration, in: transaction, prepared: baseline)
      if let data = try next.replacementData(
        comparedTo: baseline.bytes(for: store.resolvedURL))
      {
        try transaction.replace(
          store.resolvedURL, content: nil, data: data,
          expecting: baseline.evidence(for: store.resolvedURL))
      }
    }
    try cache.prune(
      referencedBy: next, watch: store.readWatch(prepared: baseline), transaction: transaction)
    try transaction.commit()
    return receipts(next: next, names: names)
  }

  func validateOwnership(previous: ResolvedState, next: ResolvedState, names: Set<String>) throws {
    let oldTargets = try targets(previous)
    let newTargets = try targets(next)
    // Only recorded targets belong to this scope. Dangling or looping links hold no content.
    for (path, target) in newTargets.sorted(by: { $0.key < $1.key })
    where names.contains(target.name) && oldTargets[path] == nil && Self.holdsContent(atPath: path)
    {
      throw CoreError.invalidSkill(
        "skill '\(target.name)' in \(store.scope.rawValue) scope cannot be installed at \(path): "
          + "an entry this scope does not manage already exists there; move or remove it first")
    }
  }

  func retain(prepared: [String: PreparedSkill], next: ResolvedState) throws -> [String: URL] {
    var retained: [String: URL] = [:]
    for (name, item) in prepared.sorted(by: { $0.key < $1.key }) {
      try validate(item, name: name)
      let skill = item.lock
      let path: URL
      if let revision = skill.revision, let source = next.sources[skill.source] {
        let root = try cache.materialize(sourceID: skill.source, source: source, revision: revision)
        path = try PathSafety.resolvedChild(base: root, subpath: skill.path ?? ".")
      } else if let artifact = skill.artifact {
        for (digest, data) in item.payloads { _ = try cache.storeArtifact(data, digest: digest) }
        guard let hash = skill.hash else {
          throw CoreError.invalidState("missing artifact content hash")
        }
        path = try cache.materializeArtifact(item.directory, digest: artifact.digest, hash: hash)
      } else {
        path = item.directory
      }
      if let hash = skill.hash {
        guard try "sha256:" + FileHash.folderHash(path) == hash,
          try FileHash.executableFlags(path) == item.executableFlags
        else {
          throw CoreError.invalidState("cached skill content or executable mode mismatch: \(name)")
        }
      }
      retained[name] = path
    }
    return retained
  }

  func validate(_ item: PreparedSkill, name: String) throws {
    try item.identity.validate()
    try item.sourceIdentity.validate()
    if let hash = item.lock.hash {
      guard try "sha256:" + FileHash.folderHash(item.directory) == hash,
        try FileHash.executableFlags(item.directory) == item.executableFlags
      else { throw CoreError.invalidState("prepared skill changed: \(name)") }
    } else {
      guard
        let skill = try Discovery.parseSkill(
          at: item.directory.appendingPathComponent("SKILL.md"), includeInternal: true),
        PathSafety.sanitizeName(skill.name) == name
      else { throw CoreError.invalidSkill("live skill is unavailable: \(name)") }
    }
  }

  func stage(
    previous: ResolvedState, next: ResolvedState, prepared: [String: PreparedSkill],
    retained: [String: URL], names: Set<String>, transaction: FileTransaction,
    expectations: [String: TargetPrecondition]
  ) throws {
    let oldTargets = try targets(previous)
    let newTargets = try targets(next)
    for path in Set(oldTargets.keys).union(newTargets.keys).sorted() {
      if let target = newTargets[path], names.contains(target.name),
        let content = retained[target.name], let item = prepared[target.name]
      {
        guard let evidence = expectations[path] else {
          throw CoreError.invalidState("skill target has no prepared preimage")
        }
        guard
          !PathSafety.isContained(
            content.resolvingSymlinksInPath(), in: URL(fileURLWithPath: path).standardizedFileURL)
        else { throw CoreError.unsafePath("installation would replace its own source") }
        try transaction.replace(
          URL(fileURLWithPath: path), content: content, link: target.mode != .copy,
          expectedHash: item.lock.hash,
          executableFlags: item.executableFlags, expecting: evidence)
      } else if let target = oldTargets[path], names.contains(target.name), newTargets[path] == nil
      {
        guard let evidence = expectations[path] else {
          throw CoreError.invalidState("skill target has no prepared preimage")
        }
        try transaction.replace(
          URL(fileURLWithPath: path), content: nil, expecting: evidence)
      }
    }
  }

  func receipts(next: ResolvedState, names: Set<String>) -> [InstallResult] {
    names.sorted().flatMap { name in
      (next.skills[name]?.installs ?? [:]).sorted(by: { $0.key < $1.key }).compactMap { raw, mode in
        guard let agent = AgentID(rawValue: raw) else { return nil }
        return InstallResult(
          skill: name, agent: agent, scope: store.scope, mode: mode,
          path: Self.target(name: name, agent: agent, store: store).path)
      }
    }
  }

  func membership(name: String, old: LockedSkill?, new: LockedSkill?) -> [SkillMembershipChange] {
    Set((old?.installs ?? [:]).keys).union((new?.installs ?? [:]).keys).sorted().compactMap { raw in
      guard let agent = AgentID(rawValue: raw) else { return nil }
      return SkillMembershipChange(
        agent: agent,
        path: Self.physicalTarget(Self.target(name: name, agent: agent, store: store)).path,
        before: old?.installs[raw].map { .installed(mode: $0) } ?? .absent,
        after: new?.installs[raw].map { .installed(mode: $0) } ?? .absent)
    }
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

  static func holdsContent(atPath path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      return false
    }
    return attributes[.type] as? FileAttributeType != .typeSymbolicLink
      || FileManager.default.fileExists(atPath: path)
  }

  static func physicalTarget(_ url: URL) -> URL {
    url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
  }

  func targets(_ lock: ResolvedState) throws -> [String: (name: String, mode: InstallMode)] {
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
    try FileSystem.createDirectory(at: directory)
    for (path, data) in files {
      let url = try PathSafety.resolvedChild(base: directory, subpath: path)
      try FileSystem.createDirectory(at: url.deletingLastPathComponent())
      try FileSystem.write(data, to: url)
    }
  }

  func entries(_ directory: URL, followRoot: Bool = true) throws -> [String: SkillFileEntry] {
    func entry(_ url: URL) throws -> SkillFileEntry? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return nil
      }
      switch attributes[.type] as? FileAttributeType {
      case .typeSymbolicLink:
        return .symbolicLink(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
      case .typeDirectory: return .directory
      case .typeRegular:
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return .file(try FileSystem.read(at: url), executable: mode & 0o111 != 0)
      default: throw CoreError.unsafePath("unsupported installed entry: \(url.path)")
      }
    }
    guard let root = try entry(directory) else { return [:] }
    var result = [".": root]
    if !followRoot, case .symbolicLink = root { return result }
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
