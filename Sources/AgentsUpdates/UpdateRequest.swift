import AgentsCore
import AgentsManifest

public enum UpdateOperation: Sendable {
  case update
  case restore
  case edit([ManifestEdit])
  case declaration(Declaration)
  case remove
}

/// Selection constrains application and protects the recorded semantics of every other domain.
public struct UpdateRequest: Sendable {
  package var catalogPreparation: CatalogPreparation?
  package var capturedAddition: CapturedAddition?
  package var importPreparation: ImportPreparation?
  package var expectedDiscoveryFingerprint: String?
  package var automaticSkill: (source: String, name: String)?
  package var selectedIdentities: Set<String>?
  public var selections: [ComponentSelection]
  public var operation: UpdateOperation
  public var kinds: Set<DeclaredComponentKind>?
  public var names: [String]
  /// Recipient removal for skills and native components; replacement recipients for instruction removal.
  public var agents: [AgentID]?
  public var replace: Bool
  public var expectedDeclarationDigest: String?
  public var changingAccess: Bool

  public init(
    operation: UpdateOperation = .update, kinds: Set<DeclaredComponentKind>? = nil,
    names: [String] = [], selections: [ComponentSelection] = [], agents: [AgentID]? = nil,
    replace: Bool = false,
    changingAccess: Bool = false, expectedDeclarationDigest: String? = nil
  ) {
    self.selections = selections
    self.operation = operation
    self.kinds = kinds
    self.names = names
    self.agents = agents
    self.replace = replace
    self.changingAccess = changingAccess
    self.expectedDeclarationDigest = expectedDeclarationDigest
  }
}
