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
  /// Scope metadata and read-admission entries, including absent paths and logical/physical
  /// root aliases. Retained for every status; bodies, append files and target bytes are not read.
  public let readDependencies: [ReadDependency]
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
    var readLocations = Set(store.metadataReadLocations.map(\.standardizedFileURL))
    func dependencies() -> [ReadDependency] {
      readLocations.sorted { $0.path < $1.path }.map(ReadDependency.entry)
    }
    func empty(_ status: InstructionMapping.Status) -> InstructionMapping {
      InstructionMapping(
        scope: scope, root: root, status: status, targets: [], unplaced: [], prompts: [:],
        readDependencies: dependencies())
    }
    do {
      return try store.withReadLock(
        onPendingRecovery: { empty(.pendingRecovery) },
        onReadLocation: { readLocations.insert($0.standardizedFileURL) },
        {
          _ = try store.readDeclaration()
          guard try store.existingData(store.resolvedURL) != nil else {
            return empty(.missingLock)
          }
          let ledger = try store.readLedger()
          let roots = store.ledgerRoots(recordedIn: ledger)
          let lock = try ledger.domainProjection(roots: roots)
          let targets = try ledger.deployments.filter {
            InstructionLocations.isInstructionFormat($0.route)
          }.map { deployment in
            let file = try deployment.target.resolve(roots: roots)
            let key = InstructionLocations.key(for: file, store: store)
            var seenResources = Set<String>()
            let sections = try deployment.owners.compactMap { ledger.components[$0] }.compactMap {
              component throws -> LockedSection? in
              guard deployment.ownership != .importBlock, let id = component.resources.first,
                let resource = ledger.resources[id], seenResources.insert(id).inserted
              else { return nil }
              let source = try ledger.sourceIdentity(component.source, roots: roots)
              let own =
                resource.path.hasPrefix(".agent/instructions/")
                && ledger.sources[component.source]?.revision == "live"
                && ledger.sources[component.source]?.location?.root == "project"
              return LockedSection(
                name: component.name, source: own ? "." : source,
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
            prompts: lock.instructions.chatgpt.mapValues(\.sections),
            readDependencies: dependencies())
        })
    } catch {
      return empty(.unavailable(String(describing: error)))
    }
  }
}
