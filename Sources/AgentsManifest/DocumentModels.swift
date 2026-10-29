import AgentsCore
import AgentsDescription

/// An occurrence in one immutable document snapshot, never a persistent component identity.
public struct NodeID: Sendable, Hashable {
  package let digest: String
  package let pointer: String
  package let syntax: Int
}

public enum ContainerID: Sendable {
  case root
  case group(NodeID)
}

public enum InsertionPosition: Sendable {
  case first
  case last
  case before(NodeID)
  case after(NodeID)
}

public enum Editability: Sendable, Equatable {
  case direct
  case sharedConstant(uses: [NodeID])
  case readOnly(reason: String)
}

/// Checked values are constructed from the vocabulary or literal algebra, never source text.
public struct StaticValue: Sendable {
  package let value: ConstructionValue
  package let type: ConstructionType
  package let literal: Bool
  private init(_ value: ConstructionValue, _ type: ConstructionType, literal: Bool = false) {
    self.value = value
    self.type = type
    self.literal = literal
  }
  package static func checked(_ value: ConstructionValue, type: ConstructionType) -> Self {
    Self(value, type)
  }

  public static var null: Self { Self(.none, .untyped, literal: true) }

  public static func string(_ value: String) -> Self {
    Self(.text(value), .named("String"), literal: true)
  }
  public static func integer(_ value: Int) -> Self {
    Self(.integer(value), .named("Int"), literal: true)
  }
  public static func boolean(_ value: Bool) -> Self {
    Self(.boolean(value), .named("Bool"), literal: true)
  }
  public static func array(_ values: [StaticValue]) -> Self {
    Self(.array(values.map(\.value)), .array(values.first?.type ?? .named("String")), literal: true)
  }
  public static func dictionary(_ values: [String: StaticValue]) -> Self {
    Self(
      .object(values.mapValues(\.value)),
      .dictionary(values.values.first?.type ?? .named("String")), literal: true
    )
  }
}

public enum ManifestEdit: Sendable {
  case setDefaultAgents([Agent]?)
  case upsertSource(Source)
  case removeSource(alias: String)
  case insertComponent(Component, into: ContainerID, at: InsertionPosition)
  case replaceComponent(NodeID, with: Component)
  case removeComponent(NodeID)
  case moveComponent(NodeID, into: ContainerID, at: InsertionPosition)
  case setSkillSelection(NodeID, AgentsDescription.SkillSelection)
  case upsertSkillOverride(NodeID, AgentsDescription.SkillOverride)
  case removeSkillOverride(NodeID, name: String)
  case insertSection(SectionReference, into: NodeID, at: InsertionPosition)
  case removeSection(NodeID)
  case moveSection(NodeID, at: InsertionPosition)
  case upsertPrompt(NodeID, ChatGPTPrompt)
  case removePrompt(NodeID, name: String)
  case upsertGroup(ComponentGroup)
  case removeGroup(name: String)
  case insertGroupReference(GroupReference, into: ContainerID, at: InsertionPosition)
  case removeGroupReference(NodeID)
  case setExports([String])
  case setWatch([String])
  case setDictionaryEntry(NodeID, key: String, value: StaticValue)
  case removeDictionaryEntry(NodeID, key: String)
  case replaceConstant(NodeID, with: StaticValue, acceptingUses: [NodeID])
}

public struct SemanticDelta: Sendable, Equatable {
  public let changedPointers: [String]
}

public struct DocumentChange: Sendable {
  public let originalDigest: String
  public let patches: [SourcePatch]
  public let bytes: [UInt8]
  public let digest: String
  public let expectedDeclaration: DeclarationIR
  public let impactedReferences: [NodeID]
  public let diagnostics: [ManifestDiagnostic]
  public let delta: SemanticDelta
  package init(
    originalDigest: String, patches: [SourcePatch], bytes: [UInt8], digest: String,
    expectedDeclaration: DeclarationIR, impactedReferences: [NodeID],
    diagnostics: [ManifestDiagnostic], delta: SemanticDelta
  ) {
    self.originalDigest = originalDigest
    self.patches = patches
    self.bytes = bytes
    self.digest = digest
    self.expectedDeclaration = expectedDeclaration
    self.impactedReferences = impactedReferences
    self.diagnostics = diagnostics
    self.delta = delta
  }
}
