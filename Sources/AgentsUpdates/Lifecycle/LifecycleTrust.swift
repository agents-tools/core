import AgentsCore
import AgentsManifest
import Foundation

public struct LifecycleTrustRecord: Codable, Equatable, Sendable {
  public let project: LifecycleProjectIdentity
  public let revision: UInt64
  /// Nil records a revocation with its own revision.
  public let digest: String?
}

public struct LifecycleEnablement: Sendable {
  public let project: LifecycleProjectIdentity
  /// The complete authored lifecycle subtree for the local review UI.
  public let declaration: DeclarationValue
  public let digest: String
  public let expectedRevision: UInt64
  public var shellAccessNotice: String {
    "Shell actions run with your access and may invoke mutable checkout files outside the reviewed digest."
  }

}

public struct LifecycleEnableReview: Sendable {
  public let enablement: LifecycleEnablement
  let context: LifecycleContext
  let confirmation = LifecycleConfirmation<Result<LifecycleTrustRecord, any Error>>()
}

public struct LifecycleDeclarationReview: Sendable {
  public let destination: URL
  public let documentChange: DocumentChange
  /// The complete proposed lifecycle subtree for the local review UI.
  public let declaration: DeclarationValue?
  public let enablement: LifecycleEnablement?

  let context: LifecycleContext
  let root: ExistingProjectRoot?
  let confirmation = LifecycleConfirmation<Result<LifecycleSaveResult, any Error>>()
}

public enum LifecycleSaveResult: Sendable {
  case saved
  case savedAndEnabled(LifecycleTrustRecord)
  case savedEnablementIncomplete
}

extension LifecycleOperations {
  enum Checkpoint: Sendable {
    case confirmationClaimed
    case beforeReceiptPublication
    case receiptPublished
    case declarationSaved
    case beforeHandoff
    case handedOff
  }

  @TaskLocal static var checkpoint: (@Sendable (Checkpoint) -> Void)?
  @TaskLocal package static var transactionCheckpointForTesting:
    (@Sendable (String) throws -> Void)?

  public static func storedTrust(
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [LifecycleTrustRecord] {
    let context = LifecycleContext(scope: .user, environment: environment)
    return try context.readTrust().entries.values.sorted {
      if $0.project.canonicalPath != $1.project.canonicalPath {
        return $0.project.canonicalPath < $1.project.canonicalPath
      }
      return $0.project.key < $1.project.key
    }
  }

  public static func reviewEnable(
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LifecycleEnableReview {
    let context = LifecycleContext(scope: .project, environment: environment)
    let discovery = try context.readProject()
    guard let project = discovery.root, let declaration = discovery.projectDeclaration,
      let digest = discovery.projectDigest
    else { throw CoreError.invalidState("A valid project lifecycle declaration is required.") }
    return try context.enableReview(project: project, declaration: declaration, digest: digest)
  }

  public static func enable(
    _ review: LifecycleEnableReview
  ) async -> LifecycleSubmission<Result<LifecycleTrustRecord, any Error>> {
    await review.confirmation.submit {
      checkpoint?(.confirmationClaimed)
      return Result { try review.context.publishEnable(review.enablement) }
    }
  }

  /// Revokes the selected stored identity even when its path no longer names that checkout.
  @discardableResult
  public static func revoke(
    _ project: LifecycleProjectIdentity, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LifecycleTrustRecord {
    let context = LifecycleContext(scope: .user, environment: environment)
    let record = try context.writeTrust(project: project, digest: nil)
    try context.withHandoff(for: project) {}
    return record
  }

  public static func previewScaffold(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    force: Bool = false
  ) throws -> LifecycleDeclarationReview {
    let starter: DeclarationValue = .dictionary([
      LifecycleEvent.preInstall.rawValue: .array([]),
      LifecycleEvent.postInstall.rawValue: .array([]),
    ])
    return try declarationReview(
      starter, scope: scope, environment: environment, requireAbsent: !force, offerEnablement: false
    )
  }

  /// Prepares a lifecycle-only edit of an existing manifest. It may be saved and enabled
  /// in one reviewed project operation.
  public static func previewDeclaration(
    _ declaration: DeclarationValue?, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LifecycleDeclarationReview {
    try declarationReview(
      declaration, scope: scope, environment: environment, requireAbsent: false,
      offerEnablement: true)
  }

  public static func save(
    _ review: LifecycleDeclarationReview, enable: Bool = false
  ) async -> LifecycleSubmission<Result<LifecycleSaveResult, any Error>> {
    await review.confirmation.submit {
      checkpoint?(.confirmationClaimed)
      return Result {
        let proposed = enable ? review.enablement : nil
        if enable && proposed == nil {
          throw CoreError.invalidState("Enablement requires a reviewed project declaration.")
        }
        try review.context.publishDeclaration(review)
        checkpoint?(.declarationSaved)
        guard let proposed else { return .saved }
        do {
          return .savedAndEnabled(try review.context.publishEnable(proposed))
        } catch {
          return .savedEnablementIncomplete
        }
      }
    }
  }

  private static func declarationReview(
    _ declaration: DeclarationValue?, scope: InstallScope, environment: RuntimeEnvironment,
    requireAbsent: Bool, offerEnablement: Bool
  ) throws -> LifecycleDeclarationReview {
    let context = LifecycleContext(scope: scope, environment: environment)
    let root = scope == .project ? try context.store.captureExistingProjectRoot() : nil
    let directory =
      try scope == .project
      ? context.openProject().lifecycleChild(".agent", authority: .project)
      : context.openHome()?.lifecycleChild(".agents", authority: .user)
    guard
      let input = try directory?.readLifecycleFile(
        StateStore.declarationFileName, authority: scope == .project ? .project : .user,
        maximumBytes: 2 * 1024 * 1024)
    else {
      throw CoreError.notFound("existing declaration at \(context.store.declarationURL.path)")
    }
    let document = try DeclarationDocument(
      bytes: Array(input.bytes), identity: DocumentIdentity(context.store.declarationURL.path))
    if requireAbsent && document.declaration.lifecycle != nil {
      throw CoreError.invalidState("A lifecycle declaration already exists. Confirm replacement.")
    }
    let change = try document.preparing([.setLifecycle(declaration)])
    let installed = change.expectedDeclaration.lifecycle
    let enablement: LifecycleEnablement?
    if offerEnablement, scope == .project, let installed,
      let project = try? LifecycleProjectIdentity(context.openProject())
    {
      try root?.validateForLifecycle()
      enablement = try? context.enablement(
        project: project, declaration: installed, digest: LifecycleDeclaration.digest(installed))
    } else {
      enablement = nil
    }
    return LifecycleDeclarationReview(
      destination: context.store.declarationURL, documentChange: change, declaration: installed,
      enablement: enablement, context: context, root: root)
  }
}

struct LifecycleReceipts: Codable {
  let version: Int
  var entries: [String: LifecycleTrustRecord]

  static let empty = Self(version: 1, entries: [:])
  static let file = "receipts.json"
  static let maximumBytes = 2 * 1024 * 1024
}

extension LifecycleContext {
  func readProject() throws -> LifecycleDiscovery {
    let root = try openProject()
    var discovery = LifecycleDiscovery()
    discovery.root = try LifecycleProjectIdentity(root)
    let source = LifecycleSource(authority: .project, file: store.declarationURL)
    if let directory = try root.lifecycleChild(".agent", authority: .project) {
      try discovery.addNative(directory: directory, source: source, authority: .project)
    }
    return discovery
  }

  func trustReceipt(_ project: LifecycleProjectIdentity?) throws -> LifecycleTrustRecord? {
    guard let project else { return nil }
    return try readTrust().entries[project.key]
  }

  func enableReview(
    project: LifecycleProjectIdentity, declaration: DeclarationValue, digest: String
  ) throws -> LifecycleEnableReview {
    try LifecycleEnableReview(
      enablement: enablement(project: project, declaration: declaration, digest: digest),
      context: self)
  }

  func enablement(
    project: LifecycleProjectIdentity, declaration: DeclarationValue, digest: String
  ) throws -> LifecycleEnablement {
    try LifecycleEnablement(
      project: project, declaration: declaration, digest: digest,
      expectedRevision: trustReceipt(project)?.revision ?? 0)
  }

  func publishEnable(_ review: LifecycleEnablement) throws -> LifecycleTrustRecord {
    try writeTrust(
      project: review.project, digest: review.digest, expectedRevision: review.expectedRevision
    ) {
      let current = try self.readProject()
      guard current.root == review.project, current.projectDigest == review.digest else {
        throw CoreError.invalidState("The reviewed project lifecycle declaration changed.")
      }
    }
  }

  func publishDeclaration(_ review: LifecycleDeclarationReview) throws {
    try Task.checkCancellation()
    if store.scope == .user { _ = try openHome()?.lifecycleChild(".agents", authority: .user) }
    try store.withLock(createIfMissing: false, existingRoot: review.root) {
      let baseline = try StatePrecondition(store: store)
      let original = try store.declarationDocument(prepared: baseline)
      guard original?.digest == review.documentChange.originalDigest else {
        throw CoreError.invalidState("The reviewed declaration changed before saving.")
      }
      if review.documentChange.patches.isEmpty { return }
      let transaction = FileTransaction(store: store)
      transaction.requireUnchanged(since: baseline)
      try store.stageDeclaration(
        DeclarationChange(bytes: Data(review.documentChange.bytes)), in: transaction,
        prepared: baseline)
      try transaction.commit()
    }
  }

  func readTrust() throws -> LifecycleReceipts {
    try readTrust(in: privateState())
  }

  func writeTrust(
    project: LifecycleProjectIdentity, digest: String?, expectedRevision: UInt64? = nil,
    validate: () throws -> Void = {}
  ) throws -> LifecycleTrustRecord {
    try Task.checkCancellation()
    guard let home = try openHome() else {
      throw CoreError.invalidState("An existing protected user home is required.")
    }
    _ = try home.createPrivateLifecycleChild(".agents", existingAuthority: .user)
    let record = try userStore.withLock(createIfMissing: false) {
      guard let directory = try privateState(create: true) else {
        throw CoreError.invalidState("Private lifecycle state is unavailable.")
      }
      var latest = try readTrust(in: directory)
      let revision = latest.entries[project.key]?.revision ?? 0
      guard expectedRevision == nil || revision == expectedRevision, revision < UInt64.max else {
        throw CoreError.invalidState("The project's lifecycle trust revision changed.")
      }
      LifecycleOperations.checkpoint?(.beforeReceiptPublication)
      try validate()
      try Task.checkCancellation()
      let record = LifecycleTrustRecord(project: project, revision: revision + 1, digest: digest)
      latest.entries[project.key] = record
      let bytes = try StateStore.encodeState(latest)
      guard bytes.count <= LifecycleReceipts.maximumBytes else {
        throw CoreError.invalidState("Lifecycle receipt storage exceeds its size limit.")
      }
      try directory.replacePrivateLifecycleFile(LifecycleReceipts.file, bytes: bytes)
      return record
    }
    LifecycleOperations.checkpoint?(.receiptPublished)
    return record
  }

  func withHandoff<T>(
    for project: LifecycleProjectIdentity, onContention: () -> Void = {},
    _ body: () throws -> T
  ) throws -> T {
    guard let directory = try privateState() else {
      throw CoreError.invalidState("Private lifecycle handoff state is unavailable.")
    }
    return try FileLock.withPrivateLock(
      in: directory, named: "handoff-" + project.key, onContention: onContention, body)
  }

  private func privateState(create: Bool = false) throws -> DirectoryHandle? {
    guard let base = try openHome()?.lifecycleChild(".agents", authority: .user) else { return nil }
    return try create
      ? base.createPrivateLifecycleChild("lifecycle")
      : base.lifecycleChild("lifecycle", authority: .privateState)
  }

  private func readTrust(in directory: DirectoryHandle?) throws -> LifecycleReceipts {
    guard
      let data = try directory?.readLifecycleFile(
        LifecycleReceipts.file, authority: .privateState,
        maximumBytes: LifecycleReceipts.maximumBytes)
    else { return .empty }
    let receipts = try StateStore.decode(data.bytes, as: LifecycleReceipts.self)
    guard receipts.version == 1,
      receipts.entries.allSatisfy({ $0.key == $0.value.project.key && $0.value.revision > 0 })
    else { throw CoreError.invalidState("Invalid lifecycle trust receipts.") }
    return receipts
  }
}
