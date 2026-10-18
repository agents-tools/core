import AgentsCore
import Foundation

public struct InstructionAddOptions: Sendable {
  public var source: String
  public var alias: String?
  public var names: [String]
  public var all: Bool
  public var listOnly: Bool
  public var replace: Bool
  public var agents: [AgentID]?
  public var scope: InstallScope
  public var path: String?
  public var sourceRequirement: SourceRequirement?
  public var environment: RuntimeEnvironment

  public init(
    source: String, alias: String? = nil, names: [String] = [], all: Bool = false,
    listOnly: Bool = false, replace: Bool = false, agents: [AgentID]? = nil,
    scope: InstallScope = .project, path: String? = nil,
    sourceRequirement: SourceRequirement? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) {
    self.source = source
    self.alias = alias
    self.names = names
    self.all = all
    self.listOnly = listOnly
    self.replace = replace
    self.agents = agents
    self.scope = scope
    self.path = path
    self.sourceRequirement = sourceRequirement
    self.environment = environment
  }
}

/// A validated unit discovered in the committed tree, with its immutable coordinates.
public struct InstructionUnit: Sendable, Equatable {
  public let record: LockedSection
  public let section: InstructionSection
}

public struct InstructionAddOutcome: Sendable {
  public let sourceID: String
  public let available: [InstructionUnit]
  /// Nil means source inspection or a multi-unit source awaiting a selection.
  public let result: InstructionUpdateReport?
}

public struct InstructionSectionChange: Sendable, Equatable {
  public let before: LockedSection?
  public let after: LockedSection?
}

public struct InstructionTargetChange: Sendable, Equatable {
  /// The lock's physical target key; user paths outside home are absolute.
  public let target: String
  public let url: URL
  public let before: Data?
  /// Nil deletes the file, subject to the previous lock's ownership record.
  public let after: Data?
  /// Previous lock recipients in raw-value order, or nil when the target had no lock entry.
  public let beforeAgents: [AgentID]?
  /// Planned recipients in raw-value order; empty when the target is no longer managed.
  public let afterAgents: [AgentID]
  public let assembly: InstructionAssembly
  /// Nil when no previous lock entry exists. Missing files report `missingBlock`.
  public let drift: InstructionDrift?
  public var changed: Bool { before != after }
  public var agentsChanged: Bool { beforeAgents != afterAgents }
}

public struct InstructionUpdateReport: Sendable, Equatable {
  public let sections: [InstructionSectionChange]
  /// Every affected target, including unchanged adoptions after loss of a lock.
  public let targets: [InstructionTargetChange]
  /// Prompts whose section bytes, order, membership or append path changed.
  public let changedPrompts: [String]
  public let lockMissing: Bool

  /// Whether applying changes the declaration, locked state (including section order and pins,
  /// target recipients, and prompts), target bytes, or reconstructs a missing lock with targets.
  /// Consumers should use this property to detect updates, including changes with identical bytes.
  public let hasChanges: Bool
}

public struct InstructionDiagnostic: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case missingBlock
    case drift
    case invalidTarget
    case missingLock
    case adoption
    case conflict
    case duplicateScope
    case claudeForwarding
    case claudeAncestor
    case codexOverride
    case codexSize
    case uncommittedSource
    case sourceUpdateAvailable
    case sourceResolutionFailed
    case invalidConfiguration
    case stateUnavailable
    case pendingRecovery
  }

  public let kind: Kind
  public let message: String
  public let path: URL?
}

public struct InstructionDoctorReport: Sendable, Equatable {
  public let root: URL
  public let diagnostics: [InstructionDiagnostic]
}
