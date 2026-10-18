import Foundation

/// Journal paths are relative to scope-owned state or registered installation roots.
/// Physical roots come from the runtime environment, never from journal input.
struct TransactionPaths {
  let store: StateStore

  func path(for destination: URL) throws -> String {
    let base =
      store.scope == .project ? store.environment.projectDirectory : store.environment.homeDirectory
    let physicalState = base.resolvingSymlinksInPath().appendingPathComponent(
      store.directory.lastPathComponent)
    for agent in AgentID.allCases {
      let logical = AgentRegistry.installSkillsDirectory(
        for: agent, scope: store.scope, environment: store.environment)
      let physical = logical.resolvingSymlinksInPath()
      let parent = destination.deletingLastPathComponent().standardizedFileURL
      if parent.path == logical.standardizedFileURL.path || parent.path == physical.path {
        let path = agent.rawValue + "/" + destination.lastPathComponent
        _ = try components(path)
        return path
      }
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

  func root(_ key: String, create: Bool = false, checkpoint: (String) throws -> Void = { _ in })
    throws -> DirectoryHandle
  {
    let url: URL
    if key == "state" {
      let base =
        store.scope == .project
        ? store.environment.projectDirectory : store.environment.homeDirectory
      url = base.resolvingSymlinksInPath().appendingPathComponent(store.directory.lastPathComponent)
    } else if let agent = AgentID(rawValue: key) {
      // Configured agent containers are trusted inputs. Resolve that boundary once;
      // journal descendants are opened without following links and roots are identity-bound.
      url = AgentRegistry.installSkillsDirectory(
        for: agent, scope: store.scope, environment: store.environment
      ).resolvingSymlinksInPath()
    } else {
      throw CoreError.invalidState("unknown transaction root")
    }
    return try DirectoryHandle(at: url, create: create, checkpoint: checkpoint)
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
      let stateFile =
        descendants.count == 1
        && ["agents.json", "agents.resolved", "agents.watch"].contains(descendants[0])
      let cache =
        descendants.first == "cache" && descendants.count >= 3
        && ((descendants[1] == "materialized" && (3...4).contains(descendants.count))
          || (["artifacts", "artifact-content"].contains(descendants[1]) && descendants.count == 3))
      guard stateFile || cache else {
        throw CoreError.unsafePath("unmanaged state transaction path")
      }
    } else {
      guard AgentID(rawValue: key) != nil, descendants.count == 1,
        PathSafety.sanitizeName(descendants[0]) == descendants[0]
      else { throw CoreError.unsafePath("unmanaged installation transaction path") }
    }
    return (key, descendants)
  }

  func parent(
    for path: String, roots: [String: DirectoryHandle], create: Bool = false,
    checkpoint: (String) throws -> Void = { _ in }
  ) throws -> DirectoryHandle {
    let components = try components(path)
    guard var directory = roots[components.root] else {
      throw CoreError.invalidState("missing transaction root")
    }
    for name in components.descendants.dropLast() {
      if create {
        if try directory.info(name) == nil { try directory.makeDirectory(name) }
        try directory.sync()
        try checkpoint("directory.synced.\(name)")
      }
      directory = try directory.child(name)
    }
    return directory
  }
}
