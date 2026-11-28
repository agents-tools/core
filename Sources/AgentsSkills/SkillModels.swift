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

  package init(
    source: SourceDeclaration, sourceID: String, availableSkills: [Skill],
    installed: [InstallResult]
  ) {
    self.source = source
    self.sourceID = sourceID
    self.availableSkills = availableSkills
    self.installed = installed
  }
}

public struct InstallResult: Codable, Equatable, Sendable {
  public var skill: String
  public var agent: AgentID
  public var scope: InstallScope
  public var mode: InstallMode
  public var path: String

  package init(skill: String, agent: AgentID, scope: InstallScope, mode: InstallMode, path: String)
  {
    self.skill = skill
    self.agent = agent
    self.scope = scope
    self.mode = mode
    self.path = path
  }
}

public struct ResolvedInstallReport: Sendable {
  public var installed: [InstallResult]

  package init(installed: [InstallResult]) {
    self.installed = installed
  }
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

/// The physical entry type and payload shown in an update preview.
public enum SkillFileEntry: Codable, Equatable, Sendable {
  case file(Data, executable: Bool)
  case directory
  case symbolicLink(String)
}

/// Entry snapshots before and after the planned replacement or removal.
public struct SkillFileChange: Codable, Equatable, Sendable {
  public var path: String
  public var before: SkillFileEntry?
  public var after: SkillFileEntry?

  package init(path: String, before: SkillFileEntry?, after: SkillFileEntry?) {
    self.path = path
    self.before = before
    self.after = after
  }
}

/// Membership recorded by the lock, independent of filesystem presence.
public enum SkillMembership: Codable, Equatable, Sendable {
  case absent
  case installed(mode: InstallMode)
}

public struct SkillMembershipChange: Codable, Equatable, Sendable {
  public let agent: AgentID
  public let path: String
  public let before: SkillMembership
  public let after: SkillMembership

  package init(agent: AgentID, path: String, before: SkillMembership, after: SkillMembership) {
    self.agent = agent
    self.path = path
    self.before = before
    self.after = after
  }
}

public struct UpdateResult: Codable, Equatable, Sendable {
  public var skill: String
  public var sourceIdentity: String
  public var changed: Bool
  public var oldRevision: String?
  public var newRevision: String?
  public var oldVersion: String?
  public var newVersion: String?
  public var oldHash: String?
  public var newHash: String?
  public var lockMissing: Bool
  public var membership: [SkillMembershipChange]
  public var changes: [SkillFileChange]
  public var installed: [InstallResult]

  package init(
    skill: String, sourceIdentity: String, changed: Bool, oldRevision: String?,
    newRevision: String?, oldVersion: String?, newVersion: String?, oldHash: String?,
    newHash: String?, lockMissing: Bool, membership: [SkillMembershipChange],
    changes: [SkillFileChange], installed: [InstallResult]
  ) {
    self.skill = skill
    self.sourceIdentity = sourceIdentity
    self.changed = changed
    self.oldRevision = oldRevision
    self.newRevision = newRevision
    self.oldVersion = oldVersion
    self.newVersion = newVersion
    self.oldHash = oldHash
    self.newHash = newHash
    self.lockMissing = lockMissing
    self.membership = membership
    self.changes = changes
    self.installed = installed
  }
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
