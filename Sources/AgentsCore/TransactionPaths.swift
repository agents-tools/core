import Foundation

/// Journal paths are relative to scope-owned state or registered installation roots.
/// Physical roots come from the runtime environment, never from journal input.
struct TransactionPaths {
  let store: StateStore

  func path(for destination: URL, skillInitialization: SkillInitializationTarget? = nil) throws
    -> String
  {
    let base =
      store.scope == .project ? store.environment.projectDirectory : store.environment.homeDirectory
    let physicalState = base.resolvingSymlinksInPath().appendingPathComponent(
      store.directory.lastPathComponent)
    let admitted =
      Array(TransactionLockContext.current(store)?.requestedRoutes ?? [])
      + (TransactionLockContext.current(store)?.admissions.map(\.route) ?? [])
    let nativeRoutes = Array(Set(admitted + NativeTargetRoute.allCases)).sorted {
      if $0.shared != $1.shared { return $0.shared }
      if admitted.contains($0) != admitted.contains($1) { return admitted.contains($0) }
      return $0.shared == $1.shared ? $0.rawValue < $1.rawValue : $0.shared
    }
    for route in nativeRoutes where route.shared || route.permits(store.scope) {
      guard destination.lastPathComponent.utf8.elementsEqual(route.basename.utf8) else { continue }
      let registered = try route.physicalDirectory(store.environment)
        .appendingPathComponent(route.basename)
      guard registered.path.utf8.elementsEqual(destination.standardizedFileURL.path.utf8) else {
        continue
      }
      guard route.permits(store.scope) else {
        throw CoreError.unsafePath("native target belongs to another scope")
      }
      let target = try store.nativeTarget(for: route)
      if target.url.path.utf8.elementsEqual(destination.standardizedFileURL.path.utf8) {
        if route.shared {
          guard let context = TransactionLockContext.current(store) else {
            throw CoreError.invalidState("shared target requires its held footprint")
          }
          _ = try context.targetDirectory(for: route)
        }
        if !route.shared { try store.requireProjectNativeAuthority(at: target.url) }
        return target.path
      }
    }
    try store.requireProjectNativeAuthority(at: destination)
    if let initialization = skillInitialization,
      initialization.scope.path.utf8.elementsEqual(store.directory.path.utf8),
      initialization.file.path.utf8.elementsEqual(destination.standardizedFileURL.path.utf8)
    {
      let path = "skill-authoring/" + initialization.descendants.joined(separator: "/")
      _ = try components(path)
      return path
    }
    if store.scope == .project {
      let relative = PathSafety.relativePath(
        destination.path, to: base.resolvingSymlinksInPath().path)
      if InstructionLocations.isProjectTarget(relative) {
        return "instructions-project/" + relative
      }
      if isAuthoringFile(relative.split(separator: "/").map(String.init)) {
        return "instructions-authoring/" + relative
      }
    } else {
      for agent in AgentID.allCases {
        if let file = InstructionLocations.file(
          for: agent, scope: .user, environment: store.environment),
          InstructionLocations.physical(file) == destination.standardizedFileURL
        {
          return "instructions-" + agent.rawValue + "/" + file.lastPathComponent
        }
      }
    }
    var matchingInstallation = false
    for agent in AgentID.allCases {
      let logical = AgentRegistry.installSkillsDirectory(
        for: agent, scope: store.scope, environment: store.environment)
      let physical = logical.resolvingSymlinksInPath()
      let parent = destination.deletingLastPathComponent().standardizedFileURL
      if parent.path.utf8.elementsEqual(logical.standardizedFileURL.path.utf8)
        || parent.path.utf8.elementsEqual(physical.path.utf8)
      {
        matchingInstallation = true
        guard
          try PathSafety.sanitizeName(destination.lastPathComponent)
            == destination.lastPathComponent
            || persistedInstallation(destination.lastPathComponent, agent: agent)
        else { continue }
        let path = agent.rawValue + "/" + destination.lastPathComponent
        _ = try components(path)
        return path
      }
    }
    if matchingInstallation {
      throw CoreError.unsafePath("unrecorded noncanonical installation target")
    }
    for state in [store.directory.standardizedFileURL, physicalState] {
      if PathSafety.isContained(destination.standardizedFileURL, in: state) {
        let path = "state/" + PathSafety.relativePath(destination.path, to: state.path)
        _ = try components(path)
        return path
      }
    }
    throw CoreError.unsafePath("transaction destination is outside managed paths")
  }

  func root(
    _ key: String, create: Bool = false,
    checkpoint: (DirectoryHandle.AncestryStep) throws -> Void = { _ in }
  ) throws -> DirectoryHandle {
    let url = try rootURL(key)
    if let context = TransactionLockContext.current(store), let root = context.projectRootDirectory,
      let observation = context.existingProjectRoot,
      let anchored = try observation.descendant(
        at: url, from: root, create: create, checkpoint: checkpoint)
    {
      return anchored
    }
    return try DirectoryHandle(at: url, create: create, checkpoint: checkpoint)
  }

  func rootURL(_ key: String) throws -> URL {
    let url: URL
    if key == "state" {
      let base =
        store.scope == .project
        ? store.environment.projectDirectory : store.environment.homeDirectory
      url = base.resolvingSymlinksInPath().appendingPathComponent(store.directory.lastPathComponent)
    } else if let route = NativeTargetRoute.targetRoute(key) {
      guard route.permits(store.scope) else {
        throw CoreError.unsafePath("project native targets require their project scope")
      }
      if route.shared {
        guard let context = TransactionLockContext.current(store) else {
          throw CoreError.invalidState("shared target requires its held footprint")
        }
        url = try context.targetDirectory(for: route)
      } else {
        url = try route.physicalDirectory(store.environment)
      }
    } else if let route = NativeTargetRoute.metadataRoute(key) {
      guard let context = TransactionLockContext.current(store),
        let metadata = try context.resource(for: route).metadata
      else {
        throw CoreError.invalidState("shared metadata directory is missing")
      }
      url = metadata.url
    } else if key == "skill-authoring", store.scope == .project {
      url = store.environment.projectDirectory.resolvingSymlinksInPath()
    } else if key == "instructions-project" || key == "instructions-authoring",
      store.scope == .project
    {
      url = store.environment.projectDirectory.resolvingSymlinksInPath()
    } else if key.hasPrefix("instructions-"), store.scope == .user,
      let agent = AgentID(rawValue: String(key.dropFirst("instructions-".count))),
      let file = InstructionLocations.file(for: agent, scope: .user, environment: store.environment)
    {
      url = file.deletingLastPathComponent().resolvingSymlinksInPath()
    } else if let agent = AgentID(rawValue: key) {
      // Configured agent containers are trusted inputs. Resolve that boundary once;
      // journal descendants are opened without following links and roots are identity-bound.
      url = AgentRegistry.installSkillsDirectory(
        for: agent, scope: store.scope, environment: store.environment
      ).resolvingSymlinksInPath()
    } else {
      throw CoreError.invalidState("unknown transaction root")
    }
    return url
  }

  func nativeRootAuthorities(_ keys: Set<String>) throws -> [String: NativeRootAuthority] {
    var result: [String: NativeRootAuthority] = [:]
    for key in keys {
      if let route = NativeTargetRoute.targetRoute(key), !route.shared {
        result[key] = try route.rootAuthority(store.environment)
      }
    }
    return result
  }

  /// Only committed exact recipients authorize legacy spellings at the queue boundary.
  /// Recovery instead consumes the journal's already-admitted single-component path.
  private func persistedInstallation(_ name: String, agent: AgentID) throws -> Bool {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.contains("\\"), !name.contains("\0"),
      let bytes = try store.existingData(store.resolvedURL)
    else { return false }
    try LedgerAdmission.check(bytes, limits: .standard)
    struct Version: Decodable { let version: Int }
    if try JSONDecoder().decode(Version.self, from: bytes).version == 2 {
      let ledger = try ResolvedLedgerCodec.decode(bytes, limits: .standard)
      return ledger.deployments.contains {
        $0.target.kind == .registered && $0.target.root == "skills-" + agent.rawValue
          && $0.target.path.utf8.elementsEqual(name.utf8) && $0.recipients.contains(agent)
          && $0.route == "agents/skill@1"
      }
    }
    return false
  }

  /// A top-level file in the project's own instructions container, `.agent/instructions/<name>.md`.
  private func isAuthoringFile(_ components: [String]) -> Bool {
    guard components.count == 3, components[0] == store.directory.lastPathComponent,
      components[1] == "instructions", components[2].hasSuffix(".md")
    else { return false }
    return Declaration.isInstructionName(String(components[2].dropLast(3)))
  }

  func components(_ path: String) throws -> (root: String, descendants: [String]) {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
      }),
      let key = parts.first
    else { throw CoreError.invalidState("invalid scope-relative transaction path") }
    let descendants = Array(parts.dropFirst())
    if key == "state" {
      let stateFile = descendants.count == 1 && StateStore.stateFileNames.contains(descendants[0])
      let cache =
        descendants.first == "cache" && descendants.count >= 3
        && ((descendants[1] == "materialized" && (3...4).contains(descendants.count))
          || (["artifacts", "artifact-content"].contains(descendants[1]) && descendants.count == 3))
      guard stateFile || cache else {
        throw CoreError.unsafePath("unmanaged state transaction path")
      }
    } else if let route = NativeTargetRoute.targetRoute(key) {
      guard route.permits(store.scope), descendants == [route.basename] else {
        throw CoreError.unsafePath("unregistered native target")
      }
    } else if NativeTargetRoute.metadataRoute(key) != nil {
      guard descendants == ["receipt"] else {
        throw CoreError.unsafePath("unregistered shared transaction metadata")
      }
    } else if key == "skill-authoring", store.scope == .project {
      guard (1...2).contains(descendants.count), descendants.last == "SKILL.md"
      else { throw CoreError.unsafePath("invalid local skill authoring path") }
    } else if key == "instructions-project", store.scope == .project {
      guard InstructionLocations.isProjectTarget(descendants.joined(separator: "/")) else {
        throw CoreError.unsafePath("unmanaged project instruction path")
      }
    } else if key == "instructions-authoring", store.scope == .project {
      guard isAuthoringFile(descendants) else {
        throw CoreError.unsafePath("invalid instruction authoring path")
      }
    } else if key.hasPrefix("instructions-"), store.scope == .user,
      let agent = AgentID(rawValue: String(key.dropFirst("instructions-".count))),
      let file = InstructionLocations.file(for: agent, scope: .user, environment: store.environment)
    {
      guard descendants == [file.lastPathComponent] else {
        throw CoreError.unsafePath("unmanaged user instruction path")
      }
    } else {
      guard AgentID(rawValue: key) != nil, descendants.count == 1
      else { throw CoreError.unsafePath("unmanaged installation transaction path") }
    }
    return (key, descendants)
  }

  /// With `create`, each descendant's parent is synced. Checkpoints mark only descendants
  /// this call creates; depth counts levels above the returned parent, as for roots.
  func parent(
    for path: String, roots: [String: DirectoryHandle], create: Bool = false,
    checkpoint: (DirectoryHandle.AncestryStep) throws -> Void = { _ in }
  ) throws -> DirectoryHandle {
    let components = try components(path)
    guard var directory = roots[components.root] else {
      throw CoreError.invalidState("missing transaction root")
    }
    let ancestry = components.descendants.dropLast()
    for (index, name) in ancestry.enumerated() {
      if create {
        let depth = ancestry.count - 1 - index
        let created = try directory.info(name) == nil
        if created {
          try directory.makeDirectory(name) { try checkpoint(.created(depth: depth)) }
        }
        try directory.sync()
        if created { try checkpoint(.synced(depth: depth)) }
      }
      directory = try directory.child(name)
    }
    return directory
  }
}
