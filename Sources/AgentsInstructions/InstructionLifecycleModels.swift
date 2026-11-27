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

/// A validated instructions file and its coordinates: a committed source file with its pin, or a
/// project's own file with its hash.
public struct InstructionUnit: Sendable, Equatable {
  public let record: LockedSection
  public let section: InstructionSection
}

public struct InstructionAddOutcome: Sendable {
  public let sourceID: String
  public let available: [InstructionUnit]
  /// Nil means source inspection or a multi-unit source awaiting a selection.
  public let result: InstructionUpdateReport?

  package init(sourceID: String, available: [InstructionUnit], result: InstructionUpdateReport?) {
    self.sourceID = sourceID
    self.available = available
    self.result = result
  }
}

public struct InstructionSectionChange: Codable, Sendable, Equatable {
  public let before: LockedSection?
  public let after: LockedSection?

  package init(before: LockedSection?, after: LockedSection?) {
    self.before = before
    self.after = after
  }
}

public struct InstructionTargetChange: Codable, Sendable, Equatable {
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
  /// Nil when no previous lock entry exists.
  public let drift: InstructionDrift?
  /// Whether the write replaces an existing file that agents did not generate, which needs
  /// `replace`.
  public let foreign: Bool
  /// Whether the file bytes differ; recipient-only changes do not affect this value.
  /// Use `InstructionUpdateReport.hasChanges` to detect any update in the report.
  public var changed: Bool { before != after }
  /// Whether the planned recipients differ from the previous lock's recipients.
  /// A missing previous entry (`beforeAgents == nil`) differs from any planned list.
  /// Use `InstructionUpdateReport.hasChanges` to detect any update in the report.
  public var agentsChanged: Bool { beforeAgents != afterAgents }

  package init(
    target: String, url: URL, before: Data?, after: Data?, beforeAgents: [AgentID]?,
    afterAgents: [AgentID], drift: InstructionDrift?, foreign: Bool
  ) {
    self.target = target
    self.url = url
    self.before = before
    self.after = after
    self.beforeAgents = beforeAgents
    self.afterAgents = afterAgents
    self.drift = drift
    self.foreign = foreign
  }
}

public struct InstructionBuildOutput: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let recipient: InstructionRecipient
  public let displayName: String
  /// The local target URL. Copyable app products have no file URL.
  public let fileURL: URL?
  public let content: Data

  package init(
    id: String, recipient: InstructionRecipient, displayName: String, fileURL: URL?, content: Data
  ) {
    self.id = id
    self.recipient = recipient
    self.displayName = displayName
    self.fileURL = fileURL
    self.content = content
  }
}

public struct InstructionUpdateReport: Codable, Sendable, Equatable {
  public let sections: [InstructionSectionChange]
  /// Every affected target, including unchanged files recorded again after loss of a lock.
  public let targets: [InstructionTargetChange]
  /// Prompts whose section bytes, order, membership or append path changed.
  public let changedPrompts: [String]
  public let lockMissing: Bool

  private let buildOutputs: [InstructionBuildOutput]?
  private let advisoryMessages: [String]?
  private let conflictMessages: [String]?
  /// Complete candidate bytes for each selected recipient and target, including unchanged files.
  public var outputs: [InstructionBuildOutput] { buildOutputs ?? [] }
  /// Informational guidance about applying the selected instructions.
  public var advisories: [String] { advisoryMessages ?? [] }
  /// Conflicts that block publication and must be resolved before applying.
  public var conflicts: [String] { conflictMessages ?? [] }

  private enum CodingKeys: String, CodingKey {
    case sections, targets, changedPrompts, lockMissing, hasChanges
    case buildOutputs = "outputs"
    case advisoryMessages = "advisories"
    case conflictMessages = "conflicts"
  }

  /// Whether applying changes the declaration, locked state (including section order and pins,
  /// target recipients, and prompts), target bytes, or reconstructs a missing lock with targets.
  /// Consumers should use this property to detect updates, including changes with identical bytes.
  public let hasChanges: Bool

  package init(
    sections: [InstructionSectionChange], targets: [InstructionTargetChange],
    changedPrompts: [String], lockMissing: Bool, hasChanges: Bool,
    outputs: [InstructionBuildOutput] = [], advisories: [String] = [], conflicts: [String] = []
  ) {
    self.sections = sections
    self.targets = targets
    self.changedPrompts = changedPrompts
    self.lockMissing = lockMissing
    self.hasChanges = hasChanges
    buildOutputs = outputs.isEmpty ? nil : outputs
    advisoryMessages = advisories.isEmpty ? nil : advisories
    conflictMessages = conflicts.isEmpty ? nil : conflicts
  }
}

public struct InstructionDiagnostic: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case missingTarget
    case drift
    case foreignTarget
    case ownChanged
    case invalidLink
    case invalidTarget
    case missingLock
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
    case pendingRecovery, unresolvedTransaction
  }

  public let kind: Kind
  public let message: String
  public let path: URL?
}

public struct InstructionDoctorReport: Sendable, Equatable {
  public let root: URL
  public let diagnostics: [InstructionDiagnostic]
}
