import AgentsCore
import AgentsManifest
import Components
import Foundation

/// The immutable input to which a patch applies.
public enum ProducerPatchBase: Hashable, Sendable, Encodable {
  case git(commit: String)
  case release(version: String, contentDigest: String)
}

public struct ProducerPatchProducer: Hashable, Sendable, Encodable {
  /// Canonical repository or catalog identity, without transport credentials.
  public let source: String
  public let package: String?
  /// Repository-relative package root, or "." for the entire repository or release.
  public let root: String
  public let base: ProducerPatchBase
}

public struct ProducerPatchFile: Sendable, Encodable {
  public let filename: String
  public let producer: ProducerPatchProducer
  public let selectors: [String]
  public let paths: [String]
  /// The exact UTF-8 content used by export.
  public let content: String
}

public struct ProducerPatchSkip: Equatable, Sendable, Encodable {
  public enum Reason: String, Sendable, Encodable {
    case locallyOwned, linkedDeployment, transformed, missingProducerIdentity
    case missingPathAttribution, ambiguousProducer
    case deleted, nonRegular, binary, uncleanSource, modeChanged, conflictingEdits
  }

  public let path: URL
  public let reason: Reason
}

/// Captures a reviewable generation. Use a fresh preview after a stale export.
public struct ProducerPatchPreview: Sendable, Encodable, CustomReflectable {
  public let patches: [ProducerPatchFile]
  public let skipped: [ProducerPatchSkip]
  fileprivate let store: StateStore
  fileprivate let generation: ProducerPatchGeneration

  private enum CodingKeys: String, CodingKey { case patches, skipped }

  public var customMirror: Mirror {
    Mirror(self, children: ["patches": patches, "skipped": skipped], displayStyle: .struct)
  }
}

public enum ProducerPatchError: Error, Equatable, Sendable, LocalizedError {
  case missingLock
  case lockedInputUnavailable
  case stale
  case unsafeDestination(URL)

  public var errorDescription: String? {
    switch self {
    case .missingLock: "Producer patches require a deployed agents.resolved lock."
    case .lockedInputUnavailable:
      "A required locked producer input is missing or failed verification."
    case .stale: "Producer patch inputs changed. Preview the edits again before exporting."
    case .unsafeDestination(let url): "Unsafe producer patch destination: " + url.path
    }
  }
}

public struct ProducerPatchExport: Sendable, Encodable {
  public struct Failure: Sendable, Encodable {
    public enum Reason: String, Sendable, Encodable {
      case occupied, destinationChanged, publicationFailed, cancelled
    }

    public let file: URL
    public let reason: Reason
  }

  /// The common destination for every producer, nil for an empty preview.
  public let directory: URL?
  public let written: [URL]
  public let reused: [URL]
  public let failures: [Failure]
}

extension UpdateOperations {
  /// Previews edits to qualifying copies using only deployed state and offline producer evidence.
  public static func previewProducerPatches(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ProducerPatchPreview {
    let store = StateStore(scope: scope, environment: environment)
    return try withProducerPatchInputs(store: store) { inputs, plan, workspace in
      let patches = try ProducerPatchDiff.files(for: plan.edits, in: workspace)
      try inputs.validateState()
      try plan.native.validate()
      return ProducerPatchPreview(
        patches: patches, skipped: plan.skipped, store: store,
        generation: inputs.generation(native: plan.native))
    } finish: { _, preview in
      preview
    }
  }

  /// Exports the reviewed bytes to one directory, defaulting to the project's patches directory.
  /// The selected URL is used synchronously, including its security scope on macOS.
  public static func exportProducerPatches(
    _ preview: ProducerPatchPreview, to directory: URL? = nil
  ) throws -> ProducerPatchExport {
    let store = preview.store
    let output = directory ?? store.environment.projectDirectory.appendingPathComponent("patches")
    #if os(macOS)
      let accessing = output.startAccessingSecurityScopedResource()
      defer { if accessing { output.stopAccessingSecurityScopedResource() } }
    #endif
    var published: ProducerPatchExport?
    do {
      return try withProducerPatchInputs(store: store, expecting: preview.generation) {
        inputs, plan, _ in
        guard inputs.generation(native: plan.native) == preview.generation,
          plan.skipped == preview.skipped
        else { throw ProducerPatchError.stale }
        return plan.native
      } finish: { inputs, native in
        if let published { return published }
        func validate() throws {
          do {
            try inputs.validateState()
            try native.validate()
            if !preview.patches.isEmpty { try store.validateHeldScope() }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw ProducerPatchError.stale
          }
        }
        try validate()
        guard !preview.patches.isEmpty else {
          return .init(directory: nil, written: [], reused: [], failures: [])
        }
        let destination = try ProducerPatchDestination(
          output, excluding: inputs.protectedLocations())
        let result = try destination.publish(preview.patches, validate: validate)
        published = result
        return result
      }
    } catch {
      if let published { return published }
      if error is ProducerPatchError || error is SourcePolicyFailure
        || error is OrganizationPolicyFailure || error is CancellationError
      {
        throw error
      }
      throw ProducerPatchError.stale
    }
  }

  private static func withProducerPatchInputs<Prepared, Result>(
    store: StateStore, expecting generation: ProducerPatchGeneration? = nil,
    prepare: (ProducerPatchInputs, ProducerPatchPlan, URL?) throws -> Prepared,
    finish: (ProducerPatchInputs, Prepared) throws -> Result
  ) throws -> Result {
    try withReadPlan(store: store) { admitted, installations in
      let inputs: ProducerPatchInputs
      do {
        inputs = try ProducerPatchInputs(store: store)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as SourcePolicyFailure {
        throw error
      } catch let error as OrganizationPolicyFailure {
        throw error
      } catch {
        if generation != nil { throw ProducerPatchError.stale }
        throw error
      }
      if let generation, inputs.fingerprint != generation.fingerprint {
        throw ProducerPatchError.stale
      }

      let projections = try ProducerPatchRoutes(inputs: inputs)
      let additional = projections.routes.subtracting(admitted)
      let targets = projections.installations.filter { installations[$0.key] == nil }
      guard additional.isEmpty, targets.isEmpty else {
        throw RequiredRoutes(routes: additional, installations: targets)
      }
      let prepared = try projections.withPlan(inputs: inputs, revalidating: generation != nil) {
        plan, workspace in
        try prepare(inputs, plan, workspace)
      }
      return try finish(inputs, prepared)
    }
  }
}

struct ProducerPatchGeneration: Equatable, Sendable {
  let fingerprint: String
  let scopeDirectory: FileObjectIdentity
  let native: ProducerPatchNativeInputs
}

struct ProducerPatchInputs {
  static let limits = LedgerLimits.standard

  let store: StateStore
  let ledger: ResolvedLedger
  let roots: [String: URL]
  let sourcePolicy: SourcePolicySnapshot
  let organization: OrganizationPolicySnapshot
  let fingerprint: String
  let declared: Declaration
  private let scopeDirectory: FileObjectIdentity
  private let declaration: Data
  private let ledgerDigest: String

  init(store: StateStore) throws {
    self.store = store
    guard let directory = try DirectoryHandle.readDirectoryIfPresent(at: store.directory),
      let lock = try directory.readRegularFileIfPresent(
        StateStore.resolvedFileName, maximumBytes: Self.limits.encodedBytes)
    else { throw ProducerPatchError.missingLock }
    guard
      let declaration = try directory.readRegularFileIfPresent(
        StateStore.declarationFileName, maximumBytes: Self.limits.encodedBytes)
    else { throw CoreError.missingDeclaration(store.declarationURL.path) }
    self.declaration = declaration
    scopeDirectory = try directory.objectIdentity
    var ledger = try ResolvedLedgerCodec.decode(lock, limits: Self.limits)
    ledger.pendingDeployment = nil
    self.ledger = ledger
    ledgerDigest = try ResolvedLedgerCodec.digest(ledger)
    roots = store.ledgerRoots(recordedIn: ledger)
    sourcePolicy = try SourcePolicySnapshot(store: store)
    try sourcePolicy.effective.require(ledger, store: store, roots: roots)
    organization = try OrganizationPolicySnapshot(store: store, offline: true)
    try organization.admit()
    let document = try DeclarationDocument(
      bytes: Array(declaration), identity: .init(store.declarationURL.path))
    declared = try ManifestProjection.declaration(of: document, environment: store.environment)
    var deployedDeclaration = declared
    deployedDeclaration.marketplaceRoots = ledger.marketplaceGraph?.roots.map(\.intent) ?? []
    deployedDeclaration.packages = ledger.marketplacePackages?.map(\.dependency) ?? []
    let evaluation = try OrganizationInstallEvaluation(
      policy: organization, store: store, declaration: deployedDeclaration, bytes: declaration)
    let findings = try evaluation.closure(ledger, roots: roots)
    try organization.admit(findings)
    fingerprint = try ResolvedLedgerCodec.digest([
      ledgerDigest, sourcePolicy.fingerprint, organization.fingerprint,
      ResolvedLedgerCodec.digest(findings.map { try ResolvedLedgerCodec.digest($0) }.sorted()),
    ])
  }

  func generation(native: ProducerPatchNativeInputs) -> ProducerPatchGeneration {
    .init(fingerprint: fingerprint, scopeDirectory: scopeDirectory, native: native)
  }

  func validateState() throws {
    try Task.checkCancellation()
    try sourcePolicy.validate()
    try organization.validate()
    let directory = try DirectoryHandle.readDirectory(at: store.directory)
    guard try directory.objectIdentity == scopeDirectory,
      try directory.readRegularFile(
        StateStore.declarationFileName, maximumBytes: Self.limits.encodedBytes) == declaration,
      let lock = try directory.readRegularFileIfPresent(
        StateStore.resolvedFileName, maximumBytes: Self.limits.encodedBytes)
    else { throw ProducerPatchError.stale }
    var current = try ResolvedLedgerCodec.decode(lock, limits: Self.limits)
    current.pendingDeployment = nil
    guard try ResolvedLedgerCodec.digest(current) == ledgerDigest else {
      throw ProducerPatchError.stale
    }
  }
}
