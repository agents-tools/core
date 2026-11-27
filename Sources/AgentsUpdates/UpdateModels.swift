import AgentsCore
import AgentsInstructions
import AgentsSkills
import Components
import Foundation

public struct CombinedUpdateReport: Codable, Sendable, Equatable {
  public let scope: InstallScope
  public let skills: [UpdateResult]
  public let instructions: InstructionUpdateReport
  public let lockMissing: Bool
  /// Includes changes to declaration bytes, normalized state and missing-lock reconstruction.
  public let hasChanges: Bool
  public let displayedFingerprint: String
  /// Exact package pin changes included in this preview, when present.
  public let marketplaceChanges: [MarketplacePackageUpdate]?
  public let marketplaceGraphChange: MarketplaceGraphUpdate?
  public let organizationPolicy: OrganizationPolicyReport?
  /// Explicit re-resolution observed different ZIP bytes for the same normalized tree.
  public let archiveRepresentationChanges: [SourceArchiveRepresentationChange]?
  /// Durable inputs and absent leaves used to invalidate this exact preview.
  public let readLocations: [URL]
  public let components: [ComponentUpdateChange]
}

public struct SourceArchiveRepresentationChange: Codable, Sendable, Equatable {
  public let source: String
  public let treeDigest: String
  public let before: String
  public let after: String

  static func between(
    _ previous: ResolvedLedger, _ next: ResolvedLedger
  ) -> [Self]? {
    let changes = next.sources.values.compactMap { source -> Self? in
      guard let archive = source.archive, let transport = source.transport,
        let old = previous.sources.values.first(where: {
          $0.transport == transport && $0.archive?.effectiveURL == archive.effectiveURL
            && $0.archive?.treeDigest == archive.treeDigest
        })?.archive, old.observedArchiveDigest != archive.observedArchiveDigest
      else { return nil }
      return .init(
        source: transport, treeDigest: archive.treeDigest,
        before: old.observedArchiveDigest, after: archive.observedArchiveDigest)
    }.sorted { ($0.source, $0.treeDigest, $0.after) < ($1.source, $1.treeDigest, $1.after) }
    return changes.isEmpty ? nil : changes
  }
}

public struct MarketplacePackageUpdate: Codable, Sendable, Equatable {
  public let before: MarketplacePin?
  public let after: MarketplacePin?

  static func between(_ previous: ResolvedLedger, _ next: ResolvedLedger) -> [Self]? {
    let before = Dictionary(
      uniqueKeysWithValues: (previous.marketplacePackages ?? []).map { ($0.dependency.name, $0) })
    let after = Dictionary(
      uniqueKeysWithValues: (next.marketplacePackages ?? []).map { ($0.dependency.name, $0) })
    let changes = Set(before.keys).union(after.keys).sorted().compactMap { name in
      before[name] == after[name] ? nil : Self(before: before[name], after: after[name])
    }
    return changes.isEmpty ? nil : changes
  }
}

public struct MarketplaceGraphUpdate: Codable, Sendable, Equatable {
  public let before: MarketplaceGraph?
  public let after: MarketplaceGraph?

  /// Roots whose intent changes or whose reachable package changes release or edges.
  public var affectedRoots: [String] {
    let oldRoots = Dictionary(
      uniqueKeysWithValues: (before?.roots ?? []).map { ($0.intent.name, $0) })
    let newRoots = Dictionary(
      uniqueKeysWithValues: (after?.roots ?? []).map { ($0.intent.name, $0) })
    let oldNodes = Dictionary(uniqueKeysWithValues: (before?.nodes ?? []).map { ($0.id, $0) })
    let newNodes = Dictionary(uniqueKeysWithValues: (after?.nodes ?? []).map { ($0.id, $0) })
    var changed = Set(oldRoots.keys).union(newRoots.keys).filter { oldRoots[$0] != newRoots[$0] }
    for id in Set(oldNodes.keys).union(newNodes.keys) {
      let old = oldNodes[id]
      let new = newNodes[id]
      if old?.coordinate != new?.coordinate || old?.archiveDigest != new?.archiveDigest
        || old?.catalogCommit != new?.catalogCommit || old?.dependencies != new?.dependencies
      {
        changed.formUnion(before?.rootsRequiring(id) ?? [])
        changed.formUnion(after?.rootsRequiring(id) ?? [])
      }
    }
    return changed.sorted()
  }

  static func between(_ previous: ResolvedLedger, _ next: ResolvedLedger) -> Self? {
    let before = previous.marketplaceGraph
    let after = next.marketplaceGraph
    return before == after ? nil : Self(before: before, after: after)
  }
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
  /// Readable selected native configuration/files with symbolic environment/secret references.
  /// Nil means the old selected value is unavailable; native sibling values are never included.
  public let symbolicBefore: String?
  /// Readable selected native configuration/files, including generated member content and targets.
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

// Public preview text uses the inspection projection, never the ledger wire representation.
extension UpdateOperations {
  static func symbolicConfigurationText(_ value: LedgerValue) throws -> String {
    try ArtifactAggregation.configurationPreview(symbolicValue(value))
  }
}
