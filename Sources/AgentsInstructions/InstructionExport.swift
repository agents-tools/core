import AgentsCore
import AgentsManifest
import Foundation

/// One scope's locked instruction mapping. It describes the lock, not the files on disk.
public struct InstructionMapping: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case locked
    case missingLock
    case pendingRecovery
    case unavailable(String)
  }

  public struct Target: Sendable, Equatable {
    /// The lock's target key: project-relative, `~`-relative under home, or absolute.
    public let target: String
    public let agents: [AgentID]
    /// Locked sections written to this target, in declared order; empty for a Claude import.
    public let sections: [LockedSection]
    /// The imported file, for a Claude forwarding target.
    public let `import`: String?
  }

  public let scope: InstallScope
  public let root: URL
  public let status: Status
  public let targets: [Target]
  /// Locked sections without a target assignment.
  public let unplaced: [LockedSection]
  public let prompts: [String: [LockedSection]]
  /// Durable scope-state and read-admission dependencies, including absent leaves and their
  /// scope directory. Retained for every status; section bodies, append files and target bytes
  /// are not read by this mapping operation.
  public let readLocations: [URL]
}

extension InstructionOperations {
  /// Reads the user scope and each project root's lock without fetching, recovering or writing.
  /// A missing, pending or unreadable scope is reported in its status, never omitted.
  public static func export(
    projectRoots: [URL], environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> [InstructionMapping] {
    var seen = Set<String>()
    let roots = projectRoots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    return [mapping(scope: .user, environment: environment)]
      + roots.map { root in
        var runtime = environment
        runtime.projectDirectory = root
        return mapping(scope: .project, environment: runtime)
      }
  }

  private static func mapping(scope: InstallScope, environment: RuntimeEnvironment)
    -> InstructionMapping
  {
    let store = StateStore(scope: scope, environment: environment)
    let root = scope == .project ? environment.projectDirectory : environment.homeDirectory
    let readLocations = Array(
      Set(
        (store.readLockLocations + [store.declarationURL, store.resolvedURL, store.watchURL])
          .map(\.standardizedFileURL))
    ).sorted { $0.path < $1.path }
    func empty(_ status: InstructionMapping.Status) -> InstructionMapping {
      InstructionMapping(
        scope: scope, root: root, status: status, targets: [], unplaced: [], prompts: [:],
        readLocations: readLocations)
    }
    do {
      return try store.withReadLock(
        onPendingRecovery: { empty(.pendingRecovery) },
        {
          _ = try store.readDeclaration()
          guard try store.existingData(store.resolvedURL) != nil else {
            return empty(.missingLock)
          }
          let ledger = try store.readLedger()
          let lock = try ledger.domainProjection(roots: store.ledgerRoots)
          let targets = try ledger.deployments.filter {
            ["agents/instructions@1", "agents/claude-import@1"].contains($0.route)
          }.map { deployment in
            let file = try deployment.target.resolve(roots: store.ledgerRoots)
            let key = InstructionLocations.key(for: file, store: store)
            let sections = try deployment.owners.compactMap { ledger.components[$0] }.compactMap {
              component throws -> LockedSection? in
              guard deployment.ownership != .importBlock, let id = component.resources.first,
                let resource = ledger.resources[id]
              else { return nil }
              return LockedSection(
                name: component.name,
                source: try lock.instructions.sections.first(where: {
                  $0.name == component.name && $0.path == resource.path
                    && $0.revision == component.revision
                })?.source
                  ?? (try ledger.sourceIdentity(component.source, roots: store.ledgerRoots)),
                revision: component.revision, version: component.version,
                artifact: resource.artifact,
                path: resource.path,
                hash: component.payload.object?["sourceHash"]?.text ?? resource.hash)
            }
            return InstructionMapping.Target(
              target: key, agents: deployment.recipients, sections: sections,
              import: deployment.importReference)
          }.sorted { $0.target < $1.target }

          return InstructionMapping(
            scope: scope, root: root, status: .locked, targets: targets, unplaced: [],
            prompts: lock.instructions.chatgpt.mapValues(\.sections), readLocations: readLocations)
        })
    } catch {
      return empty(.unavailable(String(describing: error)))
    }
  }
}
