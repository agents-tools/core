import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation

public struct CombinedUpdateReport: Codable, Sendable, Equatable {
  public let scope: InstallScope
  public let skills: [UpdateResult]
  public let instructions: InstructionUpdateReport
  public let lockMissing: Bool
  /// Includes normalized state changes and missing-lock reconstruction, even without file diffs.
  public let hasChanges: Bool
  public let displayedFingerprint: String
  /// Durable inputs and absent leaves used to invalidate this exact preview.
  public let readLocations: [URL]
  public let components: [ComponentUpdateChange]
}

public struct UpdateApplyResult: Sendable {
  public let report: CombinedUpdateReport
  public let installedSkills: [InstallResult]
}

public enum UpdateApplyDisposition: Sendable {
  case unchanged
  case committed
  case recoveryRequired
}

/// A failed apply can still have committed. Display the disposition before offering a retry.
public struct UpdateApplyError: Error {
  public let disposition: UpdateApplyDisposition
  public let underlyingError: any Error

  init(outcome: TransactionOutcome, underlyingError: any Error) {
    switch outcome.disposition {
    case .unchanged: disposition = .unchanged
    case .committed: disposition = .committed
    case .recoveryRequired: disposition = .recoveryRequired
    }
    self.underlyingError =
      (underlyingError as? UpdateApplyError)?.underlyingError ?? underlyingError
  }
}

public struct ComponentUpdateChange: Codable, Sendable, Equatable {
  public let sourceIdentity: String
  public let revision: String?
  public let version: String?
  public let format: String
  public let ownership: String
  public let resources: [ComponentResourceInfo]
  public let requiredBindings: [String]
  public let effectiveReaders: [AgentID]
  public let privateMaterialization: Bool
  public let permissionChange: ComponentPermissionChange?
  public let symbolicBefore: String?
  public let symbolicAfter: String?
  public let kind: String
  public let name: String
  public let path: String
  public let agents: [AgentID]
  public let changed: Bool
}

public struct ComponentResourceInfo: Codable, Sendable, Equatable {
  public let path: String
  public let hash: String
  public let executableFiles: [String: Bool]
}

public struct ComponentPermissionChange: Codable, Sendable, Equatable {
  public let beforeOwner: UInt32
  public let beforeGroup: UInt32
  public let beforeMode: UInt32
  public let afterOwner: UInt32
  public let afterMode: UInt32
  public let ownerOnly: Bool
  public let members: [ComponentMemberPermissionChange]
}

public struct ComponentMemberPermissionChange: Codable, Sendable, Equatable {
  public let path: String
  public let beforeOwner: UInt32
  public let beforeGroup: UInt32
  public let beforeMode: UInt32
  public let afterOwner: UInt32
  public let afterMode: UInt32
}
