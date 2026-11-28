import AgentsCore
import Components
import Foundation

/// Reads native target evidence without repairing targets, resolving sources or materializing a lock.
struct OrganizationWorkspaceInspection: PreparedEvidence {
  let findings: [OrganizationPolicyFinding]
  private let reassess: () throws -> [OrganizationPolicyFinding]

  init(
    evaluator: OrganizationPolicyEvaluator, store: StateStore, ledger: ResolvedLedger,
    previous: ResolvedLedger? = nil, roots: [String: URL], inspectDrift: Bool
  ) throws {
    reassess = {
      try Self.inspect(
        evaluator, store: store, ledger: ledger, previous: previous, roots: roots,
        inspectDrift: inspectDrift)
    }
    findings = try reassess()
  }

  func validate(excludingTargets targets: Set<String> = []) throws {
    // During publication the transaction owns changes to admitted target paths.
    if targets.isEmpty, try reassess() != findings {
      throw CoreError.invalidState(
        "organization workspace observations changed; refresh the preview")
    }
  }

  private struct Inventory {
    let files: [String]
    let incomplete: Bool
  }

  private static func inspect(
    _ evaluator: OrganizationPolicyEvaluator, store: StateStore, ledger: ResolvedLedger,
    previous: ResolvedLedger?, roots: [String: URL], inspectDrift: Bool
  ) throws -> [OrganizationPolicyFinding] {
    let layers = evaluator.chains.filter { $0.mode != .off }.flatMap(\.layers)
    let checkDrift = inspectDrift && layers.contains { $0.rules.failOnDrift }
    let checkUnmanaged = layers.contains { $0.rules.unmanagedAction != .ignore }
    guard checkDrift || checkUnmanaged else { return [] }
    var drift: [(String, String)] = []
    if checkDrift {
      for deployment in ledger.deployments {
        try Task.checkCancellation()
        let observed = try ArtifactAggregation.inspectDeployment(
          deployment, ledger: ledger, store: store, roots: roots, permitReplay: false)
        if observed.status != "current" {
          drift.append((deployment.target.path, observed.diagnostic ?? observed.status))
        }
      }
    }
    let defaults = checkUnmanaged ? defaultDirectories(store) : [:]
    let managed =
      checkUnmanaged
      ? try ownedPaths([ledger, previous].compactMap { $0 }, store: store, roots: roots)
      : Ownership()
    var inventories: [String: Inventory] = [:]
    for layer in layers where layer.rules.unmanagedAction != .ignore {
      let directories =
        layer.rules.unmanagedDirectories.isEmpty
        ? Array(defaults.keys) : layer.rules.unmanagedDirectories
      for path in directories where inventories[path] == nil {
        let base =
          store.scope == .project
          ? store.environment.projectDirectory : store.environment.homeDirectory
        let directory = defaults[path] ?? base.appendingPathComponent(path)
        inventories[path] = try inventory(
          directory, displayPath: path, owned: managed)
      }
    }
    return evaluator.findings { rules, context in
      var findings: [OrganizationPolicyFinding] = []
      if checkDrift && rules.failOnDrift {
        findings += drift.map { path, reason in
          context.finding(.workspace, path, "workspace-drift", reason)
        }
      }
      guard rules.unmanagedAction != .ignore else { return findings }
      let exclusions = context.chain.layers.flatMap(\.rules.unmanagedExclude)
      let directories =
        rules.unmanagedDirectories.isEmpty
        ? Array(defaults.keys).sorted() : rules.unmanagedDirectories
      var seen = Set<String>()
      for path in directories {
        guard let inventory = inventories[path] else { continue }
        for file in inventory.files
        where seen.insert(file).inserted
          && !exclusions.contains(where: { OrganizationPolicyEvaluator.glob($0, matches: file) })
        {
          findings.append(
            context.finding(
              .workspace, file, "workspace-unmanaged", "No lock deployment owns this path.",
              advisory: rules.unmanagedAction == .warn))
        }
        if inventory.incomplete {
          findings.append(
            context.finding(
              .workspace, path, "workspace-unmanaged-unverified",
              "Could not inspect the entire directory.",
              advisory: rules.unmanagedAction == .warn))
        }
      }
      return findings
    }
  }

  private static func defaultDirectories(_ store: StateStore) -> [String: URL] {
    let base =
      store.scope == .project
      ? store.environment.projectDirectory : store.environment.homeDirectory
    var directories: [String: URL] = [:]
    for agent in AgentRegistry.skillAgents {
      let url = AgentRegistry.installSkillsDirectory(
        for: agent, scope: store.scope, environment: store.environment
      ).standardizedFileURL
      let relative =
        url.path.hasPrefix(base.path + "/")
        ? String(url.path.dropFirst(base.path.count + 1)) : url.path
      directories[relative] = url
    }
    let rules = store.scope == .project ? ".agents/rules" : ".gemini/config/rules"
    directories[rules] = base.appendingPathComponent(rules)
    return directories
  }

  private struct Ownership {
    var whole = Set<String>()
    var copiedSkills = Set<String>()
  }

  private static func ownedPaths(
    _ ledgers: [ResolvedLedger], store: StateStore, roots: [String: URL]
  ) throws -> Ownership {
    var result = Ownership()
    let metadata = [
      store.declarationURL, store.resolvedURL, store.watchURL, store.cacheDirectory,
      store.directory.appendingPathComponent(".agents.lock"),
      store.directory.appendingPathComponent(BundleSourceLocation.directory),
    ]
    result.whole.formUnion(
      metadata.map { url in
        url.deletingLastPathComponent().resolvingSymlinksInPath()
          .appendingPathComponent(url.lastPathComponent).path
      })
    for ledger in ledgers {
      for deployment in ledger.deployments {
        let target = try deployment.target.resolve(roots: roots)
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appendingPathComponent(target.lastPathComponent).path
        if deployment.route == "agents/skill@1",
          let component = deployment.owners.first.flatMap({ ledger.components[$0] }),
          component.payload.object?["mode"]?.text == InstallMode.copy.rawValue,
          let resource = component.resources.first.flatMap({ ledger.resources[$0] }),
          !resource.entries.isEmpty
        {
          result.copiedSkills.insert(path)
          for entry in resource.entries where entry.kind != .directory {
            result.whole.insert(entry.path == "." ? path : path + "/" + entry.path)
          }
        } else {
          result.whole.insert(path)
        }
      }
    }
    return result
  }

  private static func inventory(
    _ directory: URL, displayPath: String, owned: Ownership
  ) throws -> Inventory {
    let governed = directory.resolvingSymlinksInPath().path
    var pending: [(URL, String)] = [(directory, displayPath)]
    var files: [String] = []
    var seen = 0
    var incomplete = false
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    while let (url, display) = pending.popLast() {
      try Task.checkCancellation()
      seen += 1
      guard seen <= 16_384 else { return .init(files: files.sorted(), incomplete: true) }
      let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent).path
      if owned.whole.contains(path) { continue }
      do {
        let info = try url.resourceValues(forKeys: Set(keys))
        if info.isDirectory == true && info.isSymbolicLink != true {
          let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys)
          if contents.count > 16_384 - seen - pending.count {
            incomplete = true
          } else {
            pending += contents.reversed().map { ($0, display + "/" + $0.lastPathComponent) }
          }
        } else if owned.copiedSkills.contains(path) {
          continue
        } else if url != directory || info.isSymbolicLink == true {
          files.append(display)
        } else {
          incomplete = true
        }
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
      {
        if url != directory || FileManager.default.fileExists(atPath: governed) {
          incomplete = true
        }
      } catch {
        incomplete = true
      }
    }
    return .init(files: files.sorted(), incomplete: incomplete)
  }
}
