import AgentsCore
import AgentsManifest
import Foundation

public enum UpdateOperation: Sendable {
  case update
  case restore
  case edit([ManifestEdit])
  case declaration(Declaration)
  case remove
}

/// Selection constrains application and protects the recorded semantics of every other domain.
public struct UpdateRequest: Sendable {
  package var marketplaceChange: MarketplaceChange?
  var marketplaceGraphChange: MarketplaceGraphChange?
  var marketplaceFrozenProducers: [String: URL] = [:]
  var deployPendingMarketplace = false
  package var catalogPreparation: CatalogPreparation?
  package var capturedAddition: CapturedAddition?
  package var importPreparation: ImportPreparation?
  var bundleInstallation: BundleInstallation?
  package var expectedDiscoveryFingerprint: String?
  package var automaticSkill: (source: String, name: String)?
  var instructionAddition: InstructionAddition?
  package var selectedIdentities: Set<String>?
  private(set) var declarationYAML: [UInt8]?
  public var selections: [ComponentSelection]
  public var operation: UpdateOperation {
    didSet { declarationYAML = nil }
  }
  public var kinds: Set<DeclaredComponentKind>?
  public var names: [String]
  /// Recipient removal for skills and native components; replacement recipients for instruction removal.
  public var agents: [AgentID]?
  public var replace: Bool
  public var expectedDeclarationDigest: String?
  public var changingAccess: Bool
  /// Restricts restore to existing scope state, local producers, and admitted exact acquisitions.
  public var offline: Bool

  var restoresOffline: Bool {
    if case .restore = operation { return offline || deployPendingMarketplace }
    return false
  }

  public init(
    operation: UpdateOperation = .update, kinds: Set<DeclaredComponentKind>? = nil,
    names: [String] = [], selections: [ComponentSelection] = [], agents: [AgentID]? = nil,
    replace: Bool = false,
    changingAccess: Bool = false, expectedDeclarationDigest: String? = nil, offline: Bool = false
  ) {
    self.selections = selections
    self.operation = operation
    self.kinds = kinds
    self.names = names
    self.agents = agents
    self.replace = replace
    self.changingAccess = changingAccess
    self.offline = offline
    self.expectedDeclarationDigest = expectedDeclarationDigest
  }

  /// Previews and applies the complete UTF-8 declaration, preserving its exact bytes.
  /// Supply the digest of the loaded document, or `"absent"` when the scope has no declaration.
  /// Preview and preparation validate the YAML and its sources before publication.
  public init(declarationYAML: Data, expectedDeclarationDigest: String) {
    self.init(operation: .edit([]), expectedDeclarationDigest: expectedDeclarationDigest)
    self.declarationYAML = Array(declarationYAML.prefix(ManifestLimits.Input.bytes + 1))
  }
}
