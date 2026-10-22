import AgentsCore
import AgentsInstructions
import AgentsSkills

public struct CombinedUpdateReport: Sendable, Equatable {
  public let scope: InstallScope
  public let skills: [UpdateResult]
  public let instructions: InstructionUpdateReport
  public let lockMissing: Bool
  /// Includes normalized state changes and missing-lock reconstruction, even without file diffs.
  public let hasChanges: Bool
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
