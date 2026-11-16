import CPlatform
import Foundation

/// Runtime data supplied by the application. Source declarations never supply commands.
/// Implementations must return bounded, noninteractive data synchronously. They must not
/// hide network requests, login flows or unbounded work inside value resolution.
public protocol RuntimeBindingProvider: Sendable {
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
  let receiptEvidence: TargetPrecondition?
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
    guard target.scope.path == directory.path,
      try TransactionPaths(store: self).path(for: target.url) == target.path
    else { throw CoreError.invalidState("materialization target belongs to another scope") }
    if let route = NativeTargetRoute.sharedRoute(target.path),
      try TransactionLockContext.current(self)?.absentRoot(for: route) != nil
    {
      return nil
    }
    guard let record = try materializationReceipts(for: target.path).records.targets[target.path]
    else {
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
    if NativeTargetRoute.targetRoute(target.path)?.isContainer == true {
      throw CoreError.invalidState("private materialization requires a registered regular file")
    }
    guard target.scope.path == directory.path,
      try TransactionPaths(store: self).path(for: target.url) == target.path
    else { throw CoreError.invalidState("materialization target belongs to another scope") }
    if let route = NativeTargetRoute.sharedRoute(target.path),
      try TransactionLockContext.current(self)?.absentRoot(for: route) != nil
    {
      guard generation == nil else {
        throw CoreError.invalidState("materialization receipt generation changed or is missing")
      }
      let evidence = try TargetPrecondition(target.url).capturingAccess()
      return PreparedPrivateMaterialization(
        owner: UInt32(geteuid()), receiptGeneration: nil, accessChange: nil, target: target,
        evidence: evidence, receiptEvidence: nil)
    }
    let receipt = try materializationReceipts(for: target.path)
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
      guard try materializationRootIdentity(key) == record.rootIdentity else {
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
      let parts: (root: String, descendants: [String])
      if let route = NativeTargetRoute.sharedRoute(path) {
        guard path.utf8.elementsEqual((route.root + "/" + route.basename).utf8) else {
          throw CoreError.invalidState("invalid physical receipt target")
        }
        parts = (route.root, [route.basename])
      } else {
        parts = try paths.components(path)
      }
      guard
        (parts.root.hasPrefix("instructions-") && parts.root != "instructions-authoring")
          || NativeTargetRoute.targetRoute(parts.root) != nil
      else {
        throw CoreError.invalidState("invalid materialization receipt target")
      }
      guard
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

  func materializationRootIdentity(_ root: String) throws -> String {
    if let route = NativeTargetRoute.sharedRoute(root) {
      guard let context = TransactionLockContext.current(self) else {
        throw CoreError.invalidState("shared receipt requires its held footprint")
      }
      return try context.resource(for: route).identity.orderingKey
    }
    return try TransactionPaths(store: self).root(root).identity
  }

  func materializationReceipts(for path: String = "") throws -> MaterializationReceiptState {
    let route = NativeTargetRoute.sharedRoute(path)
    let shared = route != nil
    let resource: SharedResource?
    if let route {
      guard let context = TransactionLockContext.current(self) else {
        throw CoreError.invalidState("shared receipt requires its held footprint")
      }
      resource = try context.resource(for: route)
    } else {
      resource = nil
    }
    let url: URL
    let receiptPath: String
    if let resource {
      let metadataURL = resource.parent.url.appendingPathComponent(SharedResource.metadataName)
        .appendingPathComponent(resource.identity.directoryName)
      url = (resource.metadata?.url ?? metadataURL).appendingPathComponent("receipt")
      receiptPath = resource.route.metadata + "/receipt"
    } else {
      url = materializationReceiptURL
      receiptPath = "state/" + MaterializationReceipts.fileName
    }
    let evidence = try TargetPrecondition(url)
    guard evidence.snapshot != nil else {
      return .init(path: receiptPath, url: url, records: .init(), evidence: evidence, access: nil)
    }
    let directory = try DirectoryHandle(at: url.deletingLastPathComponent())
    let evidenceWithAccess = try evidence.capturingAccess()
    let access = try directory.requirePrivateAccess(url.lastPathComponent)
    do {
      var records = try Self.decode(
        directory.read(url.lastPathComponent), as: MaterializationReceipts.self)
      try records.validate(store: self)
      if let resource {
        guard records.targets.count == 1, let (key, record) = records.targets.first,
          let recorded = NativeTargetRoute.sharedRoute(key),
          recorded.basename.utf8.elementsEqual(resource.identity.basename.utf8),
          record.rootIdentity.utf8.elementsEqual(resource.identity.orderingKey.utf8)
        else { throw CoreError.invalidState("shared receipt must identify its physical file") }
        records.targets = [resource.route.root + "/" + resource.identity.basename: record]
      }
      if !shared {
        var candidates = TransactionLockContext.current(self)?.requestedRoutes ?? []
        if let route = NativeTargetRoute.targetRoute(path) { candidates.insert(route) }
        for route in candidates.filter({ !$0.shared }).sorted(by: {
          $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }) {
          let target = try nativeTarget(for: route)
          let parentURL = target.url.deletingLastPathComponent()
          let ancestry = try DirectoryAccessEvidence.capture(at: parentURL)
          guard ancestry.directories.count == parentURL.pathComponents.count else { continue }
          let parent = try DirectoryHandle(at: parentURL)
          let identity = try parent.identity
          let matches = records.targets.filter { key, record in
            NativeTargetRoute.targetRoute(key)?.shared == false
              && key.split(separator: "/").last.map(String.init)?.utf8.elementsEqual(
                route.basename.utf8) == true
              && record.rootIdentity == identity
          }
          guard matches.count <= 1 else {
            throw CoreError.invalidState("ambiguous physical materialization receipts")
          }
          if let (old, record) = matches.first {
            records.targets.removeValue(forKey: old)
            records.targets[target.path] = record
          }
          try ancestry.validate(at: parentURL)
        }
      }
      for (key, record) in records.targets {
        guard shared == (NativeTargetRoute.sharedRoute(key) != nil),
          !shared
            || record.rootIdentity.utf8.elementsEqual((resource?.identity.orderingKey ?? "").utf8)
        else { throw CoreError.invalidState("receipt belongs to another physical resource") }
      }
      try evidence.validate()
      _ = try directory.requirePrivateAccess(url.lastPathComponent, matching: access)
      return .init(
        path: receiptPath, url: url, records: records, evidence: evidenceWithAccess, access: access)
    } catch { throw CoreError.invalidState("invalid private materialization receipt") }
  }
}

struct MaterializationReceiptState {
  let path: String
  let url: URL
  let records: MaterializationReceipts
  let evidence: TargetPrecondition
  let access: FileAccessEvidence?
}
