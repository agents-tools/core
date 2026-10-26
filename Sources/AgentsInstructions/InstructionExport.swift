import AgentsCore
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
  /// Locked sections whose placement cannot be read, such as an own file changed since the lock.
  public let unplaced: [LockedSection]
  public let prompts: [String: [LockedSection]]
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
    func empty(_ status: InstructionMapping.Status) -> InstructionMapping {
      InstructionMapping(
        scope: scope, root: root, status: status, targets: [], unplaced: [], prompts: [:])
    }
    do {
      return try store.withReadLock(
        onPendingRecovery: { empty(.pendingRecovery) },
        {
          _ = try store.readDeclaration()
          guard try store.existingData(store.resolvedURL) != nil else {
            return empty(.missingLock)
          }
          let lock = try store.readResolved()
          let sources = InstructionSources(store: store)
          var directories: [String: String] = [:]
          var unplaced: [LockedSection] = []
          for record in lock.instructions.sections {
            if let unit = try? sources.restore([record], sources: lock.sources, cachedOnly: true)
              .first
            {
              directories[InstructionSources.identity(record)] =
                scope == .project ? unit.section.directory : ""
            } else {
              unplaced.append(record)
            }
          }
          let targets = lock.instructions.targets.sorted { $0.key < $1.key }.map { key, value in
            let directory = scope == .project ? (key as NSString).deletingLastPathComponent : ""
            return InstructionMapping.Target(
              target: key, agents: value.agents,
              sections: value.import != nil
                ? []
                : lock.instructions.sections.filter {
                  directories[InstructionSources.identity($0)] == directory
                },
              import: value.import)
          }
          return InstructionMapping(
            scope: scope, root: root, status: .locked, targets: targets, unplaced: unplaced,
            prompts: lock.instructions.chatgpt.mapValues(\.sections))
        })
    } catch {
      return empty(.unavailable(String(describing: error)))
    }
  }
}
