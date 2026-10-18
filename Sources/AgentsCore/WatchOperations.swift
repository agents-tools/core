import Foundation

/// Scope-bound subscriptions. Discovery and artifact loading are supplied by the owning module.
public struct WatchOperations: Sendable {
  private let discoverSkills: @Sendable (URL) throws -> [WatchSkill]
  private let fetchArtifacts: @Sendable (String) throws -> [WatchArtifact]
  private let checkpoint: @Sendable (String) throws -> Void

  public init(
    discoverSkills: @escaping @Sendable (URL) throws -> [WatchSkill],
    fetchArtifacts: @escaping @Sendable (String) throws -> [WatchArtifact]
  ) {
    self.init(discoverSkills: discoverSkills, fetchArtifacts: fetchArtifacts, checkpoint: { _ in })
  }

  package init(
    discoverSkills: @escaping @Sendable (URL) throws -> [WatchSkill],
    fetchArtifacts: @escaping @Sendable (String) throws -> [WatchArtifact],
    checkpoint: @escaping @Sendable (String) throws -> Void
  ) {
    self.discoverSkills = discoverSkills
    self.fetchArtifacts = fetchArtifacts
    self.checkpoint = checkpoint
  }

  /// Declares a source when needed and acknowledges its current content without installing it.
  @discardableResult
  public func add(
    _ source: String, alias: String? = nil, requirement: SourceRequirement? = nil,
    path: String? = nil, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchSeen {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withLock(checkpoint: checkpoint) {
      var declaration = try store.readDeclaration()
      let lock = try store.readResolved()
      var watch = try store.readWatch()
      let parsed = try sourceDeclaration(source, declaration: declaration, environment: environment)
      let id = try parsed.identity(environment: environment)
      let existing = try declaration.sources.keys.sorted().first {
        try declaration.sources[$0]?.identity(environment: environment) == id
      }
      let name =
        alias ?? existing
        ?? PathSafety.sanitizeName(
          URL(fileURLWithPath: parsed.location).deletingPathExtension().lastPathComponent)
      if let current = declaration.sources[name],
        try current.identity(environment: environment) != id
      {
        throw CoreError.invalidState("source alias already refers to another source: \(name)")
      }
      var declared = existing.flatMap { declaration.sources[$0] } ?? parsed
      if let requirement { declared.requirement = requirement }
      if let path { declared.path = try PathSafety.sanitizeSubpath(path) }
      declaration.sources[name] = declared
      declaration.watch = Array(Set((declaration.watch ?? []) + [name])).sorted()
      try declaration.validate(environment: environment)
      let current = try acknowledge(declared, revision: nil, store: store)
      watch.sources[id] = WatchSourceState(seen: current)
      try commit(declaration: declaration, watch: watch, lock: lock, store: store)
      return current
    }
  }

  /// Fetches upstream content without writing declaration, lock, watch state, or retained trees.
  public func status(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [WatchStatus] {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let declaration = try store.readDeclaration()
      _ = try store.readResolved()
      let watch = try store.readWatch()
      return try (declaration.watch ?? []).sorted().map { alias in
        try inspect(alias: alias, declaration: declaration, watch: watch, store: store)
      }
    }
  }

  /// Returns typed before/after file contents. Kind can disambiguate equal skill and section names.
  public func diff(
    _ source: String, name: String? = nil, kind: WatchItemKind? = nil,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchStatus {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      let declaration = try store.readDeclaration()
      _ = try store.readResolved()
      let watch = try store.readWatch()
      let alias = try subscription(source, declaration: declaration, environment: environment)
      var result = try inspect(alias: alias, declaration: declaration, watch: watch, store: store)
      result.changes = result.changes.filter {
        (name == nil || $0.name == name) && (kind == nil || $0.kind == kind)
      }
      return result
    }
  }

  @discardableResult
  public func seen(
    _ source: String, revision: String? = nil, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> WatchSeen {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withLock(checkpoint: checkpoint) {
      let declaration = try store.readDeclaration()
      let lock = try store.readResolved()
      var watch = try store.readWatch()
      let alias = try subscription(source, declaration: declaration, environment: environment)
      let declared = declaration.sources[alias]!
      let id = try declared.identity(environment: environment)
      let current = try acknowledge(declared, revision: revision, store: store)
      watch.sources[id] = WatchSourceState(seen: current)
      try commit(declaration: nil, watch: watch, lock: lock, store: store)
      return current
    }
  }

  /// Removes only the subscription and baseline. Source declarations and installations remain.
  public func remove(
    _ source: String, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws {
    let store = StateStore(scope: scope, environment: environment)
    try store.withLock(checkpoint: checkpoint) {
      var declaration = try store.readDeclaration()
      let lock = try store.readResolved()
      var watch = try store.readWatch()
      let alias = try subscription(source, declaration: declaration, environment: environment)
      let id = try declaration.sources[alias]!.identity(environment: environment)
      declaration.watch?.removeAll { $0 == alias }
      watch.sources.removeValue(forKey: id)
      try commit(declaration: declaration, watch: watch, lock: lock, store: store)
    }
  }

  private func sourceDeclaration(
    _ input: String, declaration: Declaration, environment: RuntimeEnvironment
  ) throws -> SourceDeclaration {
    if let source = declaration.sources[input] { return source }
    let parsed = try SourceParser.parse(
      input, currentDirectory: environment.projectDirectory,
      homeDirectory: environment.homeDirectory)
    return SourceDeclaration(
      kind: parsed.type, location: parsed.localPath ?? parsed.url,
      requirement: parsed.requirement, path: parsed.subpath)
  }

  private func subscription(
    _ input: String, declaration: Declaration, environment: RuntimeEnvironment
  ) throws -> String {
    if (declaration.watch ?? []).contains(input) { return input }
    for alias in declaration.watch ?? [] {
      if try declaration.sources[alias]!.identity(environment: environment) == input {
        return alias
      }
    }
    let id = try sourceDeclaration(input, declaration: declaration, environment: environment)
      .identity(environment: environment)
    for alias in declaration.watch ?? [] {
      if try declaration.sources[alias]!.identity(environment: environment) == id { return alias }
    }
    throw CoreError.notFound("source is not subscribed: \(input)")
  }

  private func commit(
    declaration: Declaration?, watch: WatchState, lock: ResolvedState, store: StateStore
  ) throws {
    try watch.validate()
    let transaction = FileTransaction(store: store, checkpoint: checkpoint)
    if let declaration {
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(declaration.normalized))
    }
    try transaction.replace(store.watchURL, content: nil, data: StateStore.encode(watch))
    try SourceCache(store: store).prune(referencedBy: lock, watch: watch, transaction: transaction)
    try transaction.commit()
  }

  private func acknowledge(
    _ source: SourceDeclaration, revision: String?, store: StateStore
  ) throws -> WatchSeen {
    let cache = SourceCache(store: store, checkpoint: checkpoint)
    let id = try source.identity(environment: store.environment)
    if source.kind != .wellKnown {
      let head = try cache.watchRevision(source, revision: revision)
      try checkpoint("watch.mirror.fetched")
      try cache.retainWatchRevision(sourceID: id, source: source.location, revision: head)
      return .revision(head)
    }
    guard revision == nil else {
      throw CoreError.invalidSource("well-known subscriptions do not accept Git revisions")
    }
    let artifacts = try artifacts(source)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-watch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for artifact in artifacts {
      let directory = root.appendingPathComponent(artifact.name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (path, data) in artifact.files {
        let destination = try PathSafety.resolvedChild(base: directory, subpath: path)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
      }
      for (digest, data) in artifact.payloads { _ = try cache.storeArtifact(data, digest: digest) }
      _ = try cache.materializeArtifact(
        directory, digest: artifact.artifact.digest,
        hash: "sha256:" + FileHash.folderHash(directory))
    }
    return .artifacts(
      Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.artifact.digest) }))
  }

  private func artifacts(_ source: SourceDeclaration) throws -> [WatchArtifact] {
    let artifacts = try fetchArtifacts(source.location)
    try Declaration.validateNames(artifacts.map(\.name))
    for artifact in artifacts {
      try artifact.artifact.validate()
      for path in artifact.files.keys { _ = try PathSafety.sanitizeSubpath(path) }
      for (digest, data) in artifact.payloads {
        guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
          throw CoreError.invalidState("watch artifact payload digest mismatch")
        }
      }
      if artifact.artifact.type == .files {
        let records = artifact.artifact.files ?? []
        guard try LockedArtifact.filesDigest(records) == artifact.artifact.digest,
          Set(records.map(\.path)) == Set(artifact.files.keys)
        else { throw CoreError.invalidState("watch files artifact digest mismatch") }
        for record in records {
          guard let data = artifact.files[record.path],
            "sha256:" + FileHash.sha256Hex(data: data) == record.digest
          else { throw CoreError.invalidState("watch artifact file digest mismatch") }
        }
      } else {
        guard artifact.payloads[artifact.artifact.digest] != nil else {
          throw CoreError.invalidState("watch artifact is missing its download bytes")
        }
        if artifact.artifact.type == .skillMD,
          artifact.files != ["SKILL.md": artifact.payloads[artifact.artifact.digest]!]
        {
          throw CoreError.invalidState("watch Markdown artifact differs from its download")
        }
      }
    }
    return artifacts
  }

  private func inspect(
    alias: String, declaration: Declaration, watch: WatchState, store: StateStore
  ) throws -> WatchStatus {
    let source = declaration.sources[alias]!
    let id = try source.identity(environment: store.environment)
    guard let seen = watch.sources[id]?.seen else {
      throw CoreError.invalidState("subscription has no seen state: \(alias)")
    }
    let cache = SourceCache(store: store)
    let current: WatchSeen
    let count: Int?
    let before: [WatchItemKey: WatchUnit]
    let after: [WatchItemKey: WatchUnit]
    switch seen {
    case .revision(let revision):
      guard source.kind != .wellKnown else { throw CoreError.invalidState("watch kind mismatch") }
      let head = try cache.watchRevision(source)
      current = .revision(head)
      count = try cache.watchCommitCount(
        sourceID: id, source: source.location, seen: revision, current: head)
      before = try units(source, revision: revision, cache: cache)
      after = revision == head ? before : try units(source, revision: head, cache: cache)
    case .artifacts(let digests):
      guard source.kind == .wellKnown else { throw CoreError.invalidState("watch kind mismatch") }
      let artifacts = try artifacts(source)
      current = .artifacts(
        Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.artifact.digest) }))
      count = nil
      var old: [WatchItemKey: WatchUnit] = [:]
      for (name, digest) in digests {
        let directory = store.cacheDirectory.appendingPathComponent(
          "artifact-content/\(digest.dropFirst(7))")
        try cache.validatePath(directory)
        old[WatchItemKey(kind: .artifact, name: name)] = WatchUnit(
          path: nil, digest: digest, files: try WatchUnit.read(directory))
      }
      before = old
      after = Dictionary(
        uniqueKeysWithValues: artifacts.map {
          (
            WatchItemKey(kind: .artifact, name: $0.name),
            WatchUnit(
              path: nil, digest: $0.artifact.digest,
              files: $0.files.mapValues { .file($0, executable: false) })
          )
        })
    }
    let keys = Set(before.keys).union(after.keys).sorted {
      $0.kind.rawValue == $1.kind.rawValue ? $0.name < $1.name : $0.kind.rawValue < $1.kind.rawValue
    }
    let changes = keys.compactMap { key -> WatchItemChange? in
      let old = before[key]
      let new = after[key]
      guard old != new else { return nil }
      let paths = Set(old?.files.keys.map { $0 } ?? []).union(new?.files.keys.map { $0 } ?? [])
      let files = paths.sorted().compactMap { path -> WatchFileChange? in
        let left = old?.files[path]
        let right = new?.files[path]
        return left == right ? nil : WatchFileChange(path: path, before: left, after: right)
      }
      return WatchItemChange(
        name: key.name, kind: key.kind,
        change: old == nil ? .new : new == nil ? .removed : .changed,
        oldPath: old?.path, newPath: new?.path, oldDigest: old?.digest, newDigest: new?.digest,
        files: files)
    }
    return WatchStatus(
      alias: alias, sourceID: id, seen: seen, current: current, commitCount: count, changes: changes
    )
  }

  private func units(
    _ source: SourceDeclaration, revision: String, cache: SourceCache
  ) throws -> [WatchItemKey: WatchUnit] {
    let id = try source.identity(environment: cache.store.environment)
    let locked = LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
    return try cache.withSnapshot(sourceID: id, source: locked, revision: revision) { snapshot in
      let root = try PathSafety.resolvedChild(base: snapshot, subpath: source.path ?? ".")
      guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
      var result: [WatchItemKey: WatchUnit] = [:]
      let skills = try discoverSkills(root)
      try Declaration.validateNames(skills.map(\.name))
      for skill in skills {
        let directory = try PathSafety.resolvedChild(base: root, subpath: skill.path)
        result[WatchItemKey(kind: .skill, name: skill.name)] = WatchUnit(
          path: skill.path, digest: nil, files: try WatchUnit.read(directory))
      }
      for path in ["instructions", ".agents/instructions"] {
        let directory = try PathSafety.resolvedChild(base: root, subpath: path)
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        let handle = try DirectoryHandle(at: directory)
        for file in try handle.names() where file.hasSuffix(".md") {
          guard try (handle.info(file)?.st_mode ?? 0) & 0o170000 != 0o040000 else { continue }
          let key = WatchItemKey(kind: .instructions, name: String(file.dropLast(3)))
          guard result[key] == nil else {
            throw CoreError.invalidSource("duplicate instructions name: \(key.name)")
          }
          result[key] = WatchUnit(
            path: path + "/" + file, digest: nil,
            files: [file: try WatchUnit.entry(file, in: handle)])
        }
      }
      return result
    }
  }
}

private struct WatchItemKey: Hashable {
  let kind: WatchItemKind
  let name: String
}

private struct WatchUnit: Equatable {
  let path: String?
  let digest: String?
  let files: [String: WatchFileEntry]

  static func read(_ url: URL) throws -> [String: WatchFileEntry] {
    var files: [String: WatchFileEntry] = [:]
    func collect(_ directory: DirectoryHandle, prefix: String) throws {
      for name in try directory.names() {
        let value = try entry(name, in: directory)
        if value == .directory {
          let child = try directory.child(name)
          if try child.names().isEmpty { files[prefix + name] = value }
          try collect(child, prefix: prefix + name + "/")
        } else {
          files[prefix + name] = value
        }
      }
    }
    try collect(DirectoryHandle(at: url), prefix: "")
    return files
  }

  static func entry(_ name: String, in directory: DirectoryHandle) throws -> WatchFileEntry {
    guard let info = try directory.info(name) else { throw CoreError.notFound(name) }
    switch info.st_mode & 0o170000 {
    case 0o100000: return .file(try directory.read(name), executable: info.st_mode & 0o111 != 0)
    case 0o120000: return .symbolicLink(try directory.readLink(name))
    case 0o040000: return .directory
    default: throw CoreError.invalidSource("unsupported watch entry: \(name)")
    }
  }
}
