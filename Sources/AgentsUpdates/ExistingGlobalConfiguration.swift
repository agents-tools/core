import AgentsCore
import AgentsManifest
import Components
import Foundation

/// A read-only preview of the global configuration to apply.
public struct ExistingGlobalConfigurationPreview: Sendable {
  /// The number of declared source aliases.
  public let sourceCount: Int
  /// The number of distinct skills in the saved installation records.
  public let skillCount: Int
  /// Existing managed skill installations, counting shared physical paths once.
  public let installationCount: Int
  /// Locked instruction sections, including the sections selected by each named prompt.
  public let instructionCount: Int
  /// The YAML declaration to be created on confirmation.
  public let declarationURL: URL
  /// The resolved ledger to write on confirmation.
  public let ledgerURL: URL
  /// The new file that will contain the exact bytes of the original lock.
  public let originalLedgerURL: URL

  fileprivate let store: StateStore
  fileprivate let declaration: Data
  fileprivate let ledger: Data
  fileprivate let originalLedger: Data
  fileprivate let evidence: ConfigurationImportEvidence

  fileprivate init(
    store: StateStore, declaration: Data, ledger: Data, originalLedger: Data,
    sourceCount: Int, skillCount: Int, installationCount: Int, instructionCount: Int,
    evidence: ConfigurationImportEvidence
  ) {
    self.store = store
    self.declaration = declaration
    self.ledger = ledger
    self.originalLedger = originalLedger
    self.sourceCount = sourceCount
    self.skillCount = skillCount
    self.installationCount = installationCount
    self.instructionCount = instructionCount
    self.evidence = evidence
    declarationURL = store.declarationURL
    ledgerURL = store.resolvedURL
    originalLedgerURL = store.directory.appendingPathComponent(StateStore.originalLedgerFileName)
  }
}

public enum ExistingGlobalConfigurationError: LocalizedError, Equatable, Sendable {
  case unavailable
  case stalePreview(String)
  case conflict(String)
  case recovery(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Use Existing Configuration requires agents.json and its associated agents.resolved in a scope without agents.yaml."
    case .stalePreview(let detail):
      "The global configuration changed after the preview. Preview it again. \(detail)"
    case .conflict(let detail):
      "There is a conflict in the existing global configuration. \(detail)"
    case .recovery(let detail):
      detail
    }
  }
}

public enum ExistingGlobalConfiguration {
  /// Checks whether a global configuration is available to import using its state files.
  public static func isAvailable(environment: RuntimeEnvironment) throws -> Bool {
    let store = StateStore(scope: .user, environment: environment)
    return try withImportErrors {
      try store.withReadLock(onPendingRecovery: { throw pendingOperation(in: store) }) {
        try importableLedger(in: store) != nil
      }
    }
  }

  public static func preview(environment: RuntimeEnvironment) throws
    -> ExistingGlobalConfigurationPreview
  {
    let store = StateStore(scope: .user, environment: environment)
    return try withImportErrors {
      try store.withReadLock(onPendingRecovery: { throw pendingOperation(in: store) }) {
        guard let bytes = try importableLedger(in: store) else {
          throw ExistingGlobalConfigurationError.unavailable
        }
        let files = try configurationInputs(in: store)
        guard files.yaml.bytes == nil, files.ledger.bytes == bytes,
          let json = files.configurationJSON.bytes
        else {
          throw ExistingGlobalConfigurationError.stalePreview(
            "The configuration files changed during inspection.")
        }
        guard files.originalLedger.bytes == nil else {
          throw ExistingGlobalConfigurationError.conflict(
            "A saved ledger copy already exists at \(files.originalLedger.evidence.url.path). "
              + "Move that copy to a safe location before previewing again.")
        }
        try LedgerAdmission.check(json, limits: .standard)
        let declaration = try StateStore.decode(json, as: ExistingGlobalConfigurationJSON.self)
          .declaration(environment: environment)
        let saved = try StateStore.decode(bytes, as: ResolvedState.self)
        try saved.validate()
        _ = try store.readWatch()
        let yaml =
          try DeclarationEditPlan.bytes(
            replacing: Declaration(), with: declaration, in: nil,
            identity: DocumentIdentity(store.declarationURL.path), environment: environment)
          ?? Array("version: 1\n".utf8)
        var conversion = ImportedConfigurationLedger(
          store: store, declaration: declaration, saved: saved)
        let candidate = try conversion.convert()
        let encoded = try ResolvedLedgerCodec.encode(candidate, limits: .standard)
        let evidence = ConfigurationImportEvidence(
          yaml: files.yaml.evidence, ledger: files.ledger.evidence,
          originalLedger: files.originalLedger.evidence,
          untouched: [files.configurationJSON.evidence, files.watch.evidence]
            + conversion.evidence.values.sorted { $0.url.path < $1.url.path },
          installationAuthorities: SkillInstallationTarget.distinctAuthorities(
            conversion.installations),
          editSources: conversion.editSources.values.sorted {
            $0.directory.path < $1.directory.path
          },
          offlinePins: conversion.offlinePins, store: store)
        try evidence.validate(excludingTargets: [])
        return ExistingGlobalConfigurationPreview(
          store: store, declaration: Data(yaml), ledger: encoded, originalLedger: bytes,
          sourceCount: declaration.sourceDeclarations.count, skillCount: saved.skills.count,
          installationCount: conversion.installed.count,
          instructionCount: saved.instructions.sections.count
            + saved.instructions.chatgpt.values.reduce(0) { $0 + $1.sections.count },
          evidence: evidence)
      }
    }
  }

  /// Publishes only the captured state files. Preview a changed scope again before confirming.
  public static func apply(_ preview: ExistingGlobalConfigurationPreview) throws {
    try apply(preview, checkpoint: { _ in })
  }

  package static func apply(
    _ preview: ExistingGlobalConfigurationPreview, checkpoint: @escaping (String) throws -> Void
  ) throws {
    try withImportErrors {
      let store = preview.store
      let outcome = TransactionOutcome()
      try store.withConfigurationImportLock(
        checkpoint: checkpoint,
        beforeCreatingLock: { try preview.evidence.validateFiles() }
      ) {
        try preview.evidence.validate(excludingTargets: [])
        let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
        transaction.requireUnchanged(since: preview.evidence)
        try transaction.replace(
          preview.originalLedgerURL, with: .data(preview.originalLedger),
          expecting: preview.evidence.originalLedger)
        try transaction.replace(
          preview.declarationURL, with: .data(preview.declaration),
          expecting: preview.evidence.yaml)
        try transaction.replace(
          preview.ledgerURL, with: .data(preview.ledger),
          expecting: preview.evidence.ledger)
        do {
          try transaction.commit()
        } catch {
          if outcome.recoveryPending {
            throw ExistingGlobalConfigurationError.recovery(
              FileTransaction.recoveryDiagnostic(store: store).message)
          }
          if outcome.terminal != .committed { throw error }
        }
      }
    }
  }

  private static func importableLedger(in store: StateStore) throws -> Data? {
    struct Version: Decodable { let version: Int }
    guard try !store.stateEntryExists(StateStore.declarationFileName),
      try store.stateEntryExists(StateStore.configurationJSONFileName),
      let ledger = try store.configurationInputBytes(StateStore.resolvedFileName)
    else { return nil }
    try LedgerAdmission.check(ledger, limits: .standard)
    return try JSONDecoder().decode(Version.self, from: ledger).version == 1 ? ledger : nil
  }

  private static func pendingOperation(in store: StateStore) -> ExistingGlobalConfigurationError {
    .recovery(
      "A configuration operation is pending at \(store.directory.path). "
        + "Finish it in the tool that started it, then preview again.")
  }

  private typealias StateInput = (bytes: Data?, evidence: TargetPrecondition)

  private static func configurationInputs(in store: StateStore) throws -> (
    configurationJSON: StateInput, yaml: StateInput, ledger: StateInput, originalLedger: StateInput,
    watch: StateInput
  ) {
    try (
      TargetPrecondition.readingFile(
        store.directory.appendingPathComponent(StateStore.configurationJSONFileName)),
      TargetPrecondition.readingFile(store.declarationURL),
      TargetPrecondition.readingFile(store.resolvedURL),
      TargetPrecondition.readingFile(
        store.directory.appendingPathComponent(StateStore.originalLedgerFileName)),
      TargetPrecondition.readingFile(store.watchURL)
    )
  }

  private static func withImportErrors<T>(_ operation: () throws -> T) throws -> T {
    do {
      return try operation()
    } catch let error as ExistingGlobalConfigurationError {
      throw error
    } catch let error as CoreError {
      switch error {
      case .recoveryPending(let detail):
        throw ExistingGlobalConfigurationError.recovery(detail)
      case .transactionRecovered:
        throw ExistingGlobalConfigurationError.recovery(error.description)
      default:
        throw ExistingGlobalConfigurationError.conflict(error.description)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ExistingGlobalConfigurationError.conflict(String(describing: error))
    }
  }
}

struct ConfigurationImportEvidence: PreparedEvidence, Sendable {
  let yaml: TargetPrecondition
  let ledger: TargetPrecondition
  let originalLedger: TargetPrecondition
  let untouched: [TargetPrecondition]
  let installationAuthorities: [SkillInstallationTarget]
  let editSources: [EditSourceEvidence]
  let offlinePins: [OfflinePin]
  let store: StateStore

  func validateFiles(excludingTargets targets: Set<String> = []) throws {
    for installation in installationAuthorities {
      do { try installation.validateAuthority() } catch {
        throw ExistingGlobalConfigurationError.stalePreview(installation.url.path)
      }
    }
    for file in [yaml, ledger, originalLedger] + untouched where !targets.contains(file.url.path) {
      do { try file.validate() } catch {
        throw ExistingGlobalConfigurationError.stalePreview(file.url.path)
      }
    }
    for source in editSources {
      do { try source.validate() } catch {
        throw ExistingGlobalConfigurationError.stalePreview(source.directory.path)
      }
    }
  }

  func validate(excludingTargets targets: Set<String>) throws {
    try validateFiles(excludingTargets: targets)
    // Cached resources are covered by file evidence. An exact Git object can disappear
    // independently of the scope, even though its content cannot mutate.
    for pin in offlinePins {
      do {
        try SourceCache(store: store).withOfflineSnapshot(
          sourceID: pin.identity, source: pin.source, revision: pin.revision
        ) { _, _ in () }
      } catch {
        throw ExistingGlobalConfigurationError.stalePreview(
          "Git commit \(pin.revision) for \(pin.identity).")
      }
    }
  }

  struct OfflinePin: Equatable, Sendable {
    let identity: String
    let source: LockedSource
    let revision: String
  }
}

/// A live edit source supplies preview metadata and a content digest. Its directory is
/// read in place. Transaction preimages cover the managed link and the small state files.
struct EditSourceEvidence: Sendable {
  let directory: URL
  let hash: String
  private let authoredURL: URL
  private let authoredIdentity: PathIdentity
  private let directoryIdentity: PathIdentity
  private let linkedMetadata: (url: URL, identity: PathIdentity, hash: String)?

  init(authoredURL: URL, directory: URL, metadata: URL) throws {
    self.authoredURL = authoredURL
    self.directory = directory
    authoredIdentity = try PathIdentity(authoredURL)
    directoryIdentity = try PathIdentity(directory)
    // The tree digest records a symlink's destination spelling. Metadata parsing also
    // depends on the bytes at that destination when SKILL.md is itself a link.
    if metadata.path == directory.appendingPathComponent("SKILL.md").path {
      linkedMetadata = nil
    } else {
      linkedMetadata = try (metadata, PathIdentity(metadata), FileHash.sha256Hex(file: metadata))
    }
    hash = try "sha256:" + FileHash.folderHash(directory)
    try validateIdentity()
  }

  func validate() throws {
    try validateIdentity()
    guard try "sha256:" + FileHash.folderHash(directory) == hash else {
      throw ExistingGlobalConfigurationError.stalePreview(directory.path)
    }
    if let linkedMetadata, try FileHash.sha256Hex(file: linkedMetadata.url) != linkedMetadata.hash {
      throw ExistingGlobalConfigurationError.stalePreview(linkedMetadata.url.path)
    }
    try validateIdentity()
  }

  private func validateIdentity() throws {
    try authoredIdentity.validate()
    try directoryIdentity.validate()
    guard authoredURL.resolvingSymlinksInPath() == directory else {
      throw ExistingGlobalConfigurationError.stalePreview(authoredURL.path)
    }
    if let linkedMetadata {
      try linkedMetadata.identity.validate()
      guard
        directory.appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
          == linkedMetadata.url
      else { throw ExistingGlobalConfigurationError.stalePreview(linkedMetadata.url.path) }
    }
  }
}
