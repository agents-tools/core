import AgentsCore
import AgentsManifest
import Foundation

public enum LifecycleOperationIntent: String, Codable, Sendable {
  case install, update, uninstall, compile

  var events: (pre: LifecycleEvent, post: LifecycleEvent?) {
    switch self {
    case .install: (.preInstall, .postInstall)
    case .update: (.preUpdate, .postUpdate)
    case .uninstall: (.preUninstall, .postUninstall)
    case .compile: (.preCompile, nil)
    }
  }
}

public enum LifecycleAuthority: String, Codable, Sendable {
  case administrator, user, project
}

public struct LifecycleSource: Equatable, Codable, Sendable {
  public let authority: LifecycleAuthority
  public let file: URL
}

public struct LifecycleDiagnostic: Equatable, Codable, Sendable {
  public let source: LifecycleSource
  public let event: String?
  /// Zero-based position in the event's authored sequence.
  public let index: Int?
  public let field: String?
  public let message: String
}

public enum LifecycleWithholding: String, Equatable, Codable, Sendable {
  case administratorSourceInvalid, sourceChanged, projectChanged, receiptUnavailable
  case projectUntrusted, trustChanged, disabled, policyDenied, policyUnavailable, packageAdmission
  case recoveryPending, packageDidNotComplete, cancelled, headerExpansionRefused
}

public struct LifecycleActionSummary: Equatable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case command, http }

  public let source: LifecycleSource
  public let event: LifecycleEvent
  public let index: Int
  public let kind: Kind
  /// Shell name or HTTPS origin. Authored values and expanded headers never appear here.
  public let target: String
  public let timeoutSeconds: Int
  public let withheld: LifecycleWithholding?
}

public struct LifecycleInspection: Sendable, Codable {
  public let actions: [LifecycleActionSummary]
  public let diagnostics: [LifecycleDiagnostic]
  public let project: LifecycleProjectIdentity?
  public let projectTrusted: Bool
  public let allStartsWithheld: LifecycleWithholding?
}

public enum LifecycleActionDisposition: String, Codable, Sendable {
  case withheld, commandSucceeded, commandFailed, commandTimedOut, commandOutputLimit,
    commandCancelled
  case commandLaunchFailed, httpSucceeded, httpRejected, deliveryUnknown
}

public struct LifecycleActionResult: Codable, Sendable {
  public let action: LifecycleActionSummary
  public let disposition: LifecycleActionDisposition
  /// The OS accepted the spawn or URLSession handoff. A handoff does not establish delivery.
  public let dispatched: Bool
  public let withholding: LifecycleWithholding?
  public let exitStatus: Int32?
  public let signal: Int32?
  public let httpStatus: Int?
  public let stdoutBytes: Int
  public let stderrBytes: Int
  public let processGroupCleanedUp: Bool?
  public let diagnostics: [LifecycleDiagnostic]
}

public struct LifecycleInvocationResult<PackageResult: Sendable>: Sendable {
  public let package: UpdateCompletion<PackageResult>
  public let pre: [LifecycleActionResult]
  public let post: [LifecycleActionResult]
}

public enum LifecycleSubmission<Value: Sendable>: Sendable {
  case alreadyRunning
  case completed(Value)
}

/// Each review has one token. Concurrent submission observes its in-progress state, and a
/// later duplicate receives the original result, including failures and withheld actions.
final class LifecycleConfirmation<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case ready, running
    case finished(Value)
  }
  private let lock = NSLock()
  private var state = State.ready

  func submit(_ body: () async -> Value) async -> LifecycleSubmission<Value> {
    let prior = lock.withLock { () -> LifecycleSubmission<Value>? in
      switch state {
      case .ready:
        state = .running
        return nil
      case .running: return .alreadyRunning
      case .finished(let result): return .completed(result)
      }
    }
    if let prior { return prior }
    let result = await body()
    lock.withLock { state = .finished(result) }
    return .completed(result)
  }
}

/// Holds the exact reviewed package preparation and both phases' lifecycle definitions.
public struct LifecyclePackageReview<Report: Sendable, PackageResult: Sendable>: Sendable {
  public let report: Report
  public let lifecycle: LifecycleInspection
  public let ownershipConflict: String?
  let plan: LifecycleInvocation
  let apply: @Sendable ((any RuntimeBindingProvider)?) -> UpdateCompletion<PackageResult>
  let confirmation = LifecycleConfirmation<LifecycleInvocationResult<PackageResult>>()
}

public struct LifecycleTestReview: Sendable {
  public let inspection: LifecycleInspection
  let plan: LifecycleInvocation
  let confirmation = LifecycleConfirmation<[LifecycleActionResult]>()
}

extension LifecycleActionResult {
  static func withheld(
    _ action: LifecycleActionSummary, reason: LifecycleWithholding,
    diagnostics: [LifecycleDiagnostic] = []
  ) -> Self {
    .init(
      action: action, disposition: .withheld, dispatched: false, withholding: reason,
      exitStatus: nil, signal: nil, httpStatus: nil, stdoutBytes: 0, stderrBytes: 0,
      processGroupCleanedUp: nil, diagnostics: diagnostics)
  }
}
