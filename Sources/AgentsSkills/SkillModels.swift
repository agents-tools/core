import AgentsCore
import Foundation

public struct AddOptions: Sendable {
  public var source: String
  public var alias: String?
  public var agents: [AgentID]?
  public var skillNames: [String]
  public var scope: InstallScope
  public var mode: InstallMode
  public var listOnly: Bool
  public var all: Bool
  public var fullDepth: Bool
  public var path: String?
  public var sourceRequirement: SourceRequirement?
  public var environment: RuntimeEnvironment

  public init(
    source: String, alias: String? = nil, agents: [AgentID]? = nil, skillNames: [String] = [],
    scope: InstallScope = .project, mode: InstallMode = .link, listOnly: Bool = false,
    all: Bool = false, fullDepth: Bool = false, path: String? = nil,
    sourceRequirement: SourceRequirement? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) {
    self.source = source
    self.alias = alias
    self.agents = agents
    self.skillNames = skillNames
    self.scope = scope
    self.mode = mode
    self.listOnly = listOnly
    self.all = all
    self.fullDepth = fullDepth
    self.path = path
    self.sourceRequirement = sourceRequirement
    self.environment = environment
  }
}

public struct AddOutcome: Sendable {
  public var source: SourceDeclaration
  public var sourceID: String
  public var availableSkills: [Skill]
  /// Empty when inspection or multiple unselected skills require a CLI choice.
  public var installed: [InstallResult]
}

public struct InstallResult: Codable, Equatable, Sendable {
  public var skill: String
  public var agent: AgentID
  public var scope: InstallScope
  public var mode: InstallMode
  public var path: String
}

public struct ResolvedInstallReport: Sendable {
  public var installed: [InstallResult]
}

public enum InstalledSkillStatus: String, Codable, Sendable {
  case installed, missing
  case copyDrift = "copy-drift"
  case brokenLink = "broken-link"
  case editLinked = "edit-linked"
  case installedOnly = "installed-only"
}

public struct InstalledSkill: Codable, Equatable, Sendable {
  public var name: String
  public var agent: AgentID
  public var scope: InstallScope
  public var path: String
  public var sourceIdentity: String?
  public var isInstalled: Bool
  public var status: InstalledSkillStatus
  public var mode: InstallMode?
}

/// File bytes before and after an update, so callers can present a diff before applying.
public struct SkillFileChange: Codable, Equatable, Sendable {
  public var path: String
  public var before: Data?
  public var after: Data?
}

public struct UpdateResult: Codable, Equatable, Sendable {
  public var skill: String
  public var sourceIdentity: String
  public var changed: Bool
  public var oldRevision: String?
  public var newRevision: String?
  public var oldHash: String?
  public var newHash: String?
  public var changes: [SkillFileChange]
  public var installed: [InstallResult]
}

public enum DoctorCheckStatus: String, Codable, Sendable { case ok, warning, error }

public struct DoctorCheck: Codable, Equatable, Sendable {
  public var id: String
  public var status: DoctorCheckStatus
  public var message: String
  public var path: String?
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public var checks: [DoctorCheck]
  public var ok: Bool { !checks.contains { $0.status == .error } }
}
