import AgentsCore
import AgentsManifest
import Foundation

struct DiscoveredSource {
  var id: String
  var root: URL
  var skills: [Skill]
}

package final class SkillLifecycle {
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

  func discover(
    _ source: SourceDeclaration, live: Bool, fullDepth: Bool, names: [String]? = nil,
    exclude: [String] = [], cacheSource: Bool = true
  ) throws -> DiscoveredSource {
    let id = try source.identity(environment: store.environment)
    let root: URL
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
      func copy(_: SourceRevision, _ snapshot: URL) throws {
        try FileSystem.withAccessErrors(at: root) {
          try FileManager.default.copyItem(at: snapshot, to: root)
        }
      }
      if let resolutions {
        if try resolutions.isGitSource(source) {
          try resolutions.withSnapshot(source, copy)
        } else {
          let view = try resolutions.localSnapshot(source)
          try FileManager.default.copyItem(at: view.root, to: root)
        }
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
    return DiscoveredSource(id: id, root: root, skills: skills)
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

  package static func installationTargets(_ ledger: ResolvedLedger, store: StateStore) throws
    -> [String: SkillInstallationTarget]
  {
    var targets: [String: SkillInstallationTarget] = [:]
    for deployment in ledger.deployments where deployment.route == "agents/skill@1" {
      guard deployment.target.kind == .registered,
        let agent = deployment.recipients.first, deployment.recipients.count == 1,
        deployment.target.root == "skills-" + agent.rawValue
      else { throw CoreError.invalidState("invalid skill installation recipient") }
      let name = deployment.target.path
      targets[agent.rawValue + "/" + name] = try store.skillInstallationTarget(
        for: agent, named: name)
    }
    return targets
  }

  private struct RequiredInstallations: Error {
    let targets: [String: SkillInstallationTarget]
  }

  /// Capture all managed slots before admitting physical reads; never recover during inventory.
  static func withInstallationReadLock<T>(
    store: StateStore, onPendingRecovery: (() throws -> T)? = nil,
    _ body: (ResolvedLedger) throws -> T
  ) throws -> T {
    var targets: [String: SkillInstallationTarget] = [:]
    while true {
      do {
        return try store.withReadLock(
          onPendingRecovery: onPendingRecovery, installations: Array(targets.values)
        ) {
          let ledger = try store.readLedger()
          let required = try installationTargets(ledger, store: store)
          guard Set(required.keys).isSubset(of: Set(targets.keys)) else {
            throw RequiredInstallations(targets: required)
          }
          return try body(ledger)
        }
      } catch let required as RequiredInstallations {
        targets.merge(required.targets, uniquingKeysWith: { _, next in next })
      }
    }
  }

  package static func target(name: String, agent: AgentID, store: StateStore) -> URL {
    AgentRegistry.installSkillsDirectory(
      for: agent, scope: store.scope, environment: store.environment
    ).appendingPathComponent(name).standardizedFileURL
  }

  package static func holdsContent(atPath path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      return false
    }
    return attributes[.type] as? FileAttributeType != .typeSymbolicLink
      || FileManager.default.fileExists(atPath: path)
  }

  package static func physicalTarget(_ url: URL) -> URL {
    url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
  }

  private func write(_ files: [String: Data], to directory: URL) throws {
    try FileSystem.createDirectory(at: directory)
    for (path, data) in files {
      let url = try PathSafety.resolvedChild(base: directory, subpath: path)
      try FileSystem.createDirectory(at: url.deletingLastPathComponent())
      try FileSystem.write(data, to: url)
    }
  }

  package static func entries(_ directory: URL, followRoot: Bool = true) throws -> [String:
    SkillFileEntry]
  {
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
