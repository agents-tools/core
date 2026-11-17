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

  package init(_ values: [String: Data]) { self.values = values }

  package func value(for binding: String) throws -> Data {
    guard let value = values[binding] else {
      throw CoreError.invalidState("required runtime binding is unavailable")
    }
    return value
  }
}

/// A file or complete named container admitted by Core's scope-owned path registrations.
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

package struct PrivateTreeAccessChange {
  package let path: String
  package let before: FileAccessEvidence
  package let owner: UInt32
  package let mode: UInt32
}

/// A local receipt view has no payload digest or serializable binding data.
package struct MaterializationReceipt {
  package let generation: UUID
  package let access: FileAccessEvidence
  package let treeAccess: [TreeMemberAccess]?
}

package struct PreparedPrivateMaterialization {
  package let owner: UInt32
  package let receiptGeneration: UUID?
  package let accessChange: PrivateAccessChange?
  package let target: MaterializationTarget
  let evidence: TargetPrecondition
  let receiptEvidence: TargetPrecondition?
  package let memberAccessChanges: [PrivateTreeAccessChange]
  let preimageTreeAccess: [TreeMemberAccess]?
  var ancestry: DirectoryAccessEvidence { evidence.access!.ancestry }
  var beforeAccess: FileAccessEvidence? { evidence.access?.target }

  /// A non-secret access segment for the enclosing candidate's displayed fingerprint.
  package func accessFingerprint() throws -> String {
    let input = PrivateAccessFingerprint(
      target: target.path, owner: owner,
      publicationAccess: try evidence.displayEvidence(includeContent: false),
      permissionChange: accessChange != nil, receiptGeneration: receiptGeneration,
      members: preimageTreeAccess)
    return "sha256:" + FileHash.sha256Hex(data: try StateStore.encode(input))
  }
}

private struct PrivateAccessFingerprint: Encodable {
  let version = 1
  let target: String
  let owner: UInt32
  let publicationAccess: String
  let permissionChange: Bool
  let receiptGeneration: UUID?
  let members: [TreeMemberAccess]?
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
    return MaterializationReceipt(
      generation: record.generation, access: record.access, treeAccess: record.treeAccess)
  }

  /// Under the caller's scope lock, preparation never calls a provider or renderer.
  package func preparePrivateMaterialization(
    _ target: MaterializationTarget, changingAccess: Bool = false,
    requiringReceiptForExistingTarget: Bool = false, expecting generation: UUID? = nil
  ) throws -> PreparedPrivateMaterialization {
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
        evidence: evidence, receiptEvidence: nil, memberAccessChanges: [], preimageTreeAccess: nil)
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
    guard
      evidence.snapshot == nil || evidence.snapshot?.isRegular == true
        || evidence.snapshot?.identity.isDirectory == true
    else {
      throw CoreError.unsafePath(
        "private materialization requires a regular file or registered container")
    }
    let parentURL = evidence.physicalURL.deletingLastPathComponent()
    let ancestry = try DirectoryAccessEvidence.capture(at: parentURL)
    var beforeAccess: FileAccessEvidence?
    var change: PrivateAccessChange?
    var tree: [TreeMemberAccess]?
    var memberChanges: [PrivateTreeAccessChange] = []
    let privateMode: mode_t = evidence.snapshot?.identity.isDirectory == true ? 0o700 : 0o600
    if evidence.snapshot != nil {
      let parent = try DirectoryHandle(at: parentURL)
      beforeAccess = try parent.accessEvidence(target.url.lastPathComponent)
      if let snapshot = evidence.snapshot {
        tree = try TreeMemberAccess.capture(
          target.url.lastPathComponent, in: parent, snapshot: snapshot)
      }
      for member in tree ?? [] {
        let parts = member.path.split(separator: "/").map(String.init)
        var directory = try parent.child(target.url.lastPathComponent)
        for name in parts.dropLast() { directory = try directory.child(name) }
        let mode: UInt32 =
          member.access.identity.isDirectory || member.access.mode & 0o100 != 0 ? 0o700 : 0o600
        var changes = UInt32(member.access.mode) != mode
        do { _ = try directory.requirePrivateAccess(parts.last!, matching: member.access) } catch {
          changes = true
        }
        if changes {
          memberChanges.append(
            .init(path: member.path, before: member.access, owner: UInt32(geteuid()), mode: mode))
        }
      }
      var changesAccess = beforeAccess?.mode != privateMode || !memberChanges.isEmpty
      if let snapshot = evidence.snapshot {
        do {
          try TreeMemberAccess.verify(
            tree, snapshot: snapshot, named: target.url.lastPathComponent,
            in: parent, requirePrivate: true)
        } catch { changesAccess = true }
      }
      do { _ = try parent.requirePrivateAccess(target.url.lastPathComponent) } catch {
        changesAccess = true
      }
      if changesAccess {
        guard changingAccess, let beforeAccess else {
          throw CoreError.invalidState("private materialization requires an explicit access change")
        }
        change = PrivateAccessChange(
          before: beforeAccess, owner: UInt32(geteuid()), mode: UInt32(privateMode))
      }
    }
    if let record = receipt.records.targets[target.path] {
      let paths = TransactionPaths(store: self)
      let key = try paths.components(target.path).root
      guard try materializationRootIdentity(key) == record.rootIdentity else {
        throw CoreError.invalidState("materialization receipt root changed")
      }
      if evidence.snapshot != nil {
        guard evidence.snapshot?.digest == record.digest, beforeAccess == record.access,
          tree == record.treeAccess
        else {
          throw CoreError.invalidState("materialized preimage differs from its receipt")
        }
        _ = try DirectoryHandle(at: parentURL).requirePrivateAccess(
          target.url.lastPathComponent, matching: record.access)
        try TreeMemberAccess.verify(
          record.treeAccess, snapshot: evidence.snapshot!, named: target.url.lastPathComponent,
          in: DirectoryHandle(at: parentURL), requirePrivate: true)
      }
    }
    try evidence.validate()
    try ancestry.validate(at: parentURL)
    return PreparedPrivateMaterialization(
      owner: UInt32(geteuid()), receiptGeneration: record?.generation, accessChange: change,
      target: target,
      evidence: evidence, receiptEvidence: receipt.evidence, memberAccessChanges: memberChanges,
      preimageTreeAccess: tree)
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
    var treeAccess: [TreeMemberAccess]? = nil
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
        [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(record.access.identity.kind),
        record.access.identity.isDirectory == (record.treeAccess != nil),
        record.access.identity.isDirectory
          == (NativeTargetRoute.targetRoute(path)?.isContainer == true),
        !record.rootIdentity.isEmpty
      else { throw CoreError.invalidState("invalid materialization receipt target") }
      if let members = record.treeAccess { try TreeMemberAccess.validateStructure(members) }
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
      let bytes = try directory.read(
        url.lastPathComponent, maximumBytes: LedgerLimits.standard.encodedBytes)
      try LedgerAdmission.check(bytes, limits: .standard)
      var records = try Self.decode(bytes, as: MaterializationReceipts.self)
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
