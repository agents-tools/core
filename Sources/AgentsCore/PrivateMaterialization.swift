import CPlatform
import Foundation

/// Runtime data supplied by the application. Source declarations never supply commands.
package protocol RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data
}

/// Ephemeral values have no encoding or diagnostic representation.
package struct RuntimeBindingValues: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  package var description: String { "<runtime bindings>" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
  private let values: [String: Data]

  init(_ values: [String: Data]) { self.values = values }

  package func value(for binding: String) throws -> Data {
    guard let value = values[binding] else {
      throw CoreError.invalidState("required runtime binding is unavailable")
    }
    return value
  }
}

/// A physical file admitted by Core's existing, scope-owned path registrations.
package struct MaterializationTarget {
  package let url: URL
  package let path: String
  let scope: URL
}

/// The before-access and intended owner-only replacement are available for a prepared report.
package struct PrivateAccessChange {
  package let before: FileAccessEvidence
  package let owner: UInt32
  package let mode: UInt32
}

/// A local receipt view has no payload digest or serializable binding data.
package struct MaterializationReceipt {
  package let generation: UUID
  package let access: FileAccessEvidence
}

package struct PreparedPrivateMaterialization {
  package let owner: UInt32
  package let receiptGeneration: UUID?
  package let accessChange: PrivateAccessChange?
  package let target: MaterializationTarget
  let evidence: TargetPrecondition
  let receiptEvidence: TargetPrecondition
  var ancestry: DirectoryAccessEvidence { evidence.access!.ancestry }
  var beforeAccess: FileAccessEvidence? { evidence.access?.target }

  /// A non-secret access segment for the enclosing candidate's displayed fingerprint.
  package func accessFingerprint() throws -> String {
    let input = PrivateAccessFingerprint(
      target: target.path, owner: owner, before: beforeAccess, ancestry: ancestry,
      permissionChange: accessChange != nil, receiptGeneration: receiptGeneration)
    return "sha256:" + FileHash.sha256Hex(data: try StateStore.encode(input))
  }
}

private struct PrivateAccessFingerprint: Encodable {
  let version = 1
  let target: String
  let owner: UInt32
  let before: FileAccessEvidence?
  let ancestry: DirectoryAccessEvidence
  let permissionChange: Bool
  let receiptGeneration: UUID?
}

extension StateStore {
  /// Native routes must extend the owning static registration after route verification.
  /// This seam cannot authorize arbitrary external roots or source-authoring files.
  package func materializationTarget(at url: URL) throws -> MaterializationTarget {
    let paths = TransactionPaths(store: self)
    let path = try paths.path(for: url)
    let root = try paths.components(path).root
    guard root.hasPrefix("instructions-"), root != "instructions-authoring" else {
      throw CoreError.unsafePath("private materialization requires a registered file target")
    }
    return MaterializationTarget(url: url.standardizedFileURL, path: path, scope: directory)
  }

  /// Inspects the last local generation under the caller's scope lock, without exposing bytes.
  package func materializationReceipt(for target: MaterializationTarget) throws
    -> MaterializationReceipt?
  {
    guard target.scope == directory,
      try TransactionPaths(store: self).path(for: target.url) == target.path
    else { throw CoreError.invalidState("materialization target belongs to another scope") }
    guard let record = try materializationReceipts().records.targets[target.path] else {
      return nil
    }
    _ = try preparePrivateMaterialization(target, expecting: record.generation)
    return MaterializationReceipt(generation: record.generation, access: record.access)
  }

  /// Under the caller's scope lock, preparation never calls a provider or renderer.
  package func preparePrivateMaterialization(
    _ target: MaterializationTarget, changingAccess: Bool = false,
    requiringReceiptForExistingTarget: Bool = false, expecting generation: UUID? = nil
  ) throws -> PreparedPrivateMaterialization {
    guard target.scope == directory,
      try TransactionPaths(store: self).path(for: target.url) == target.path
    else { throw CoreError.invalidState("materialization target belongs to another scope") }
    let receipt = try materializationReceipts()
    let record = receipt.records.targets[target.path]
    if let generation, record?.generation != generation {
      throw CoreError.invalidState("materialization receipt generation changed or is missing")
    }
    let evidence = try TargetPrecondition(target.url).capturingAccess()
    guard !requiringReceiptForExistingTarget || evidence.snapshot == nil || record != nil else {
      throw CoreError.invalidState("known materialized target is missing its private receipt")
    }
    guard evidence.snapshot == nil || evidence.snapshot?.isRegular == true else {
      throw CoreError.unsafePath("private materialization requires a regular file")
    }
    let parentURL = evidence.physicalURL.deletingLastPathComponent()
    let ancestry = try DirectoryAccessEvidence.capture(at: parentURL)
    var beforeAccess: FileAccessEvidence?
    var change: PrivateAccessChange?
    if evidence.snapshot != nil {
      let parent = try DirectoryHandle(at: parentURL)
      beforeAccess = try parent.accessEvidence(target.url.lastPathComponent)
      var changesAccess = beforeAccess?.mode != 0o600
      do { _ = try parent.requirePrivateAccess(target.url.lastPathComponent) } catch {
        changesAccess = true
      }
      if changesAccess {
        guard changingAccess, let beforeAccess else {
          throw CoreError.invalidState("private materialization requires an explicit access change")
        }
        change = PrivateAccessChange(before: beforeAccess, owner: UInt32(geteuid()), mode: 0o600)
      }
    }
    if let record = receipt.records.targets[target.path] {
      let paths = TransactionPaths(store: self)
      let key = try paths.components(target.path).root
      guard try paths.root(key).identity == record.rootIdentity else {
        throw CoreError.invalidState("materialization receipt root changed")
      }
      if evidence.snapshot != nil {
        guard evidence.snapshot?.digest == record.digest, beforeAccess == record.access else {
          throw CoreError.invalidState("materialized preimage differs from its receipt")
        }
        _ = try DirectoryHandle(at: parentURL).requirePrivateAccess(
          target.url.lastPathComponent, matching: record.access)
      }
    }
    try evidence.validate()
    try ancestry.validate(at: parentURL)
    return PreparedPrivateMaterialization(
      owner: UInt32(geteuid()), receiptGeneration: record?.generation, accessChange: change,
      target: target,
      evidence: evidence, receiptEvidence: receipt.evidence)
  }
}

/// Only materialization generations and local physical evidence belong here.
struct MaterializationReceipts: Codable {
  static let fileName = "materializations.json"
  var version = 1
  var targets: [String: Record] = [:]

  struct Record: Codable {
    let generation: UUID
    let rootIdentity: String
    let digest: String
    let access: FileAccessEvidence
  }

  func validate(store: StateStore) throws {
    guard version == 1 else { throw CoreError.invalidState("unsupported materialization receipt") }
    for (path, record) in targets {
      let paths = TransactionPaths(store: store)
      let parts = try paths.components(path)
      guard parts.root.hasPrefix("instructions-"), parts.root != "instructions-authoring",
        record.access.identity.kind == S_IFREG,
        !record.rootIdentity.isEmpty
      else { throw CoreError.invalidState("invalid materialization receipt target") }
      try StateValidation.digest("sha256:" + record.digest)
    }
  }
}

extension StateStore {
  var materializationReceiptURL: URL {
    directory.appendingPathComponent(MaterializationReceipts.fileName)
  }

  func materializationReceipts() throws -> (
    records: MaterializationReceipts, evidence: TargetPrecondition, access: FileAccessEvidence?
  ) {
    let evidence = try TargetPrecondition(materializationReceiptURL)
    guard evidence.snapshot != nil else { return (.init(), evidence, nil) }
    guard let directory = try openDirectoryIfPresent() else {
      throw CoreError.invalidState("materialization receipt directory is missing")
    }
    let evidenceWithAccess = try evidence.capturingAccess()
    let access = try directory.requirePrivateAccess(MaterializationReceipts.fileName)
    do {
      let records = try Self.decode(
        directory.read(MaterializationReceipts.fileName), as: MaterializationReceipts.self)
      try records.validate(store: self)
      try evidence.validate()
      _ = try directory.requirePrivateAccess(MaterializationReceipts.fileName, matching: access)
      return (records, evidenceWithAccess, access)
    } catch { throw CoreError.invalidState("invalid private materialization receipt") }
  }
}
