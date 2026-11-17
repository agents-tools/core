import AgentsCore

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
  case first, last
  case before(NodeID)
  case after(NodeID)
}
public enum Editability: Sendable, Equatable {
  case direct
  case readOnly(reason: String)
}

/// Edits carry complete domain intent. They never contain parser nodes or source programs.
public enum ManifestEdit: Sendable {
  case setDefaultAgents([AgentID]?)
  case upsertSource(NamedSourceDeclaration)
  /// Replaces one source in place and retargets its typed alias references.
  case replaceSource(NodeID, with: NamedSourceDeclaration)
  case removeSource(alias: String)
  case insertComponent(ComponentDeclaration, into: ContainerID, at: InsertionPosition)
  case replaceComponent(NodeID, with: ComponentDeclaration)
  case removeComponent(NodeID)
  case moveComponent(NodeID, into: ContainerID, at: InsertionPosition)
  case setSkillSelection(NodeID, SkillSelection)
  case upsertSkillOverride(NodeID, NamedSkillOverrideDeclaration)
  case removeSkillOverride(NodeID, name: String)
  case insertSection(SectionDeclaration, into: NodeID, at: InsertionPosition)
  case removeSection(NodeID)
  case moveSection(NodeID, at: InsertionPosition)
  case upsertPrompt(NodeID, NamedPromptDeclaration)
  case removePrompt(NodeID, name: String)
  case upsertGroup(ComponentGroupDeclaration)
  case removeGroup(name: String)
  case insertGroupReference(GroupUseDeclaration, into: ContainerID, at: InsertionPosition)
  case removeGroupReference(NodeID)
  case setExports([String])
  case setWatch([String])
  case setDictionaryEntry(NodeID, key: String, value: NativeValue)
  case removeDictionaryEntry(NodeID, key: String)
}

public struct SemanticDelta: Sendable, Equatable { public let changedPointers: [String] }
public struct DocumentChange: Sendable {
  public let originalDigest: String
  public let patches: [SourcePatch]
  public let bytes: [UInt8]
  public let digest: String
  public let expectedDeclaration: DeclarationIR
  public let diagnostics: [ManifestDiagnostic]
  public let delta: SemanticDelta
}
