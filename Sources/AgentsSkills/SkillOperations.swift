import AgentsCore
import AgentsManifest
import Foundation

public enum SkillOperations {
  public static func removableSkillNames(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [String] {
    Array(Set(try listManaged(scope: scope, agents: agents, environment: environment).map(\.name)))
      .sorted()
  }

  public static func listManaged(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstalledSkill] {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      _ = try store.readDeclaration()
      let ledger = try store.readLedger()
      return try managedInventory(store: store, ledger: ledger, agents: agents)
    }
  }

  private static func managedInventory(
    store: StateStore, ledger: ResolvedLedger, agents: [AgentID]?
  ) throws -> [InstalledSkill] {
    var result: [InstalledSkill] = []
    for deployment in ledger.deployments where deployment.route == "agents/skill@1" {
      guard
        let lowering = ledger.lowerings.first(where: { $0.deployments.contains(deployment.id) }),
        let component = deployment.owners.first.flatMap({ ledger.components[$0] }),
        let resource = component.resources.first.flatMap({ ledger.resources[$0] })
      else { continue }
      let mode = lowering.layout.object?["mode"]?.text.flatMap(InstallMode.init(rawValue:)) ?? .copy
      let target = try deployment.target.resolve(roots: store.ledgerRoots)
      let present = FileManager.default.fileExists(
        atPath: target.appendingPathComponent("SKILL.md").path)
      var status: InstalledSkillStatus =
        present ? (mode == .edit ? .editLinked : .installed) : .missing
      if present, mode != .edit {
        let flags = Dictionary(
          uniqueKeysWithValues: resource.entries.filter { $0.kind == .file }.map {
            ($0.path, $0.executable)
          })
        if try "sha256:" + FileHash.folderHash(target) != resource.hash
          || FileHash.executableFlags(target) != flags
        {
          status = .copyDrift
        }
      }
      if !present, (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
      {
        status = .brokenLink
      }
      for agent in deployment.recipients where agents?.contains(agent) ?? true {
        if !result.contains(where: {
          $0.name == PathSafety.sanitizeName(component.name) && $0.agent == agent
            && $0.path == target.path
        }) {
          result.append(
            InstalledSkill(
              name: PathSafety.sanitizeName(component.name), agent: agent, scope: store.scope,
              path: target.path,
              sourceIdentity: try ledger.sourceIdentity(component.source, roots: store.ledgerRoots),
              isInstalled: present, status: status, mode: mode))
        }
      }
    }
    return result.sorted {
      ($0.name, $0.agent.rawValue, $0.path) < ($1.name, $1.agent.rawValue, $1.path)
    }
  }

  public static func listInstalled(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstalledSkill] {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock {
      _ = try store.readDeclaration()
      let ledger = try store.readLedger()
      var result = try managedInventory(store: store, ledger: ledger, agents: agents).filter {
        $0.isInstalled
          && (try? Discovery.parseSkill(
            at: URL(fileURLWithPath: $0.path).appendingPathComponent("SKILL.md"),
            includeInternal: true)) != nil
      }
      for agent in agents ?? AgentID.allCases {
        let roots =
          scope == .project
          ? AgentRegistry.projectScanDirectories(for: agent, environment: environment)
          : AgentRegistry.nativeUserScanDirectories(for: agent, environment: environment)
        for root in roots {
          for path
            in (try? FileManager.default.contentsOfDirectory(
              at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
          {
            guard
              (try? Discovery.parseSkill(
                at: path.appendingPathComponent("SKILL.md"), includeInternal: true)) != nil,
              !result.contains(where: {
                $0.agent == agent
                  && SkillLifecycle.physicalTarget(URL(fileURLWithPath: $0.path)).path
                    == SkillLifecycle.physicalTarget(path).path
              })
            else { continue }
            result.append(
              InstalledSkill(
                name: path.lastPathComponent, agent: agent, scope: scope,
                path: path.standardizedFileURL.path,
                sourceIdentity: nil, isInstalled: true, status: .installedOnly, mode: nil))
          }
        }
      }
      return result.sorted {
        ($0.name, $0.agent.rawValue, $0.path) < ($1.name, $1.agent.rawValue, $1.path)
      }
    }
  }

  /// Audits state and upstream refs without fetching, creating locks or recovering transactions.
  public static func doctor(
    scope: InstallScope = .project, agents: [AgentID]? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> DoctorReport {
    let store = StateStore(scope: scope, environment: environment)
    return try store.withReadLock(
      onPendingRecovery: {
        let recovery = FileTransaction.recoveryDiagnostic(store: store)
        return DoctorReport(checks: [
          DoctorCheck(
            id: recovery.requiresOwner ? "unresolved-transaction" : "pending-recovery",
            status: .warning,
            message: recovery.message,
            path: store.directory.path)
        ])
      },
      {
        let declaration = try store.readDeclaration()
        let ledger = try store.readLedger()
        var checks = try managedInventory(store: store, ledger: ledger, agents: agents).filter {
          $0.status != .installed && $0.status != .editLinked
        }.map {
          DoctorCheck(
            id: $0.status.rawValue, status: .warning, message: "\($0.name): \($0.status.rawValue)",
            path: $0.path)
        }
        let cache = SourceCache(store: store)
        for (alias, source) in declaration.sources.sorted(by: { $0.key < $1.key }) {
          let id = try source.identity(environment: environment)
          let skills = try ledger.components.values.filter {
            guard $0.kind == "skills", !$0.recipients.isEmpty else { return false }
            return try ledger.sourceIdentity($0.source, roots: store.ledgerRoots) == id
          }
          guard !skills.isEmpty else { continue }
          if source.kind == .local {
            let paths = skills.flatMap { $0.resources.compactMap { ledger.resources[$0]?.path } }
            let output = try? ProcessRunner.git(
              [
                "--no-optional-locks", "-C", source.localURL(environment: environment).path,
                "status", "--porcelain",
                "--",
              ] + paths, operation: .readStatus, source: source.location
            ).stdout
            if let output, !output.isEmpty {
              checks.append(
                DoctorCheck(
                  id: "uncommitted-source", status: .warning,
                  message: "\(alias) has uncommitted changes in selected paths",
                  path: source.localURL(environment: environment).path))
            }
          }
          if source.kind != .wellKnown, skills.contains(where: { $0.revision != nil }) {
            do {
              let current = try cache.inspectRevision(source)
              if skills.contains(where: { $0.revision != nil && $0.revision != current.revision }) {
                checks.append(
                  DoctorCheck(
                    id: "source-update", status: .warning,
                    message:
                      "\(alias) has a newer matching revision\(current.version.map { " (\($0))" } ?? "")",
                    path: nil))
              }
            } catch {
              checks.append(
                DoctorCheck(
                  id: "source-unavailable", status: .warning, message: "\(alias): \(error)",
                  path: nil
                ))
            }
          }
        }
        return DoctorReport(checks: checks)
      })
  }

  public static func initializeSkill(named name: String?, directory: URL) throws -> URL {
    try SkillInitialization(
      named: name, directory: directory, environment: RuntimeEnvironment(), validateState: false
    )
    .apply(outcome: TransactionOutcome(), checkpoint: { _ in })
  }

}

extension SkillOperations {
  package static func inspect(
    _ options: AddOptions, declaration: Declaration
  ) throws -> (SourceDeclaration, String, [Skill]) {
    let argument = try SourceArgument(options.source).selection(
      in: declaration, requirement: options.sourceRequirement, path: options.path,
      environment: options.environment)
    let source = argument.applied(to: argument.source)
    if options.mode == .edit, source.kind != .local || source.requirement != nil {
      throw CoreError.invalidSource("edit requires a local source with no requirement")
    }
    let store = StateStore(scope: options.scope, environment: options.environment)
    return try SourceResolutionSession.withTemporaryRead(store: store) { session in
      let lifecycle = try SkillLifecycle(
        store: store, provider: WellKnownProvider(), resolutions: session)
      let found = try lifecycle.discover(
        source,
        live: options.mode == .edit
          || (options.listOnly && source.kind == .local && source.requirement == nil),
        fullDepth: options.fullDepth, cacheSource: false)
      let selected = try lifecycle.select(found.skills, names: options.skillNames)
      let available = selected.map { skill in
        var skill = skill
        if PathSafety.isContained(URL(fileURLWithPath: skill.path), in: found.root) {
          skill.path = PathSafety.relativePath(skill.path, to: found.root.path)
          skill.skillFile = PathSafety.relativePath(skill.skillFile, to: found.root.path)
        }
        return skill
      }
      return (source, found.id, available)
    }
  }
}

extension SkillOperations {
  package static func validateLiveMetadata(at directory: URL, name: String) throws {
    let metadata = try Discovery.parseSkill(
      at: directory.appendingPathComponent("SKILL.md"), includeInternal: true)
    guard metadata?.name == name else {
      throw CoreError.invalidSkill("live skill metadata changed during preparation")
    }
  }
}
