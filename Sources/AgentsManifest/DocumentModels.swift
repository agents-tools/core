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

  public static var null: Self { Self(.none, .named(""), literal: true) }

  public static func string(_ value: String) -> Self {
    Self(.text(value), .named("String"), literal: true)
  }
  public static func integer(_ value: Int) -> Self {
    Self(.integer(value), .named("Int"), literal: true)
  }
  public static func boolean(_ value: Bool) -> Self {
    Self(.boolean(value), .named("Bool"), literal: true)
  }
  public static func configuration(_ value: ConfigurationValue) -> Self {
    Self(value.constructionValue, .named("ConfigurationValue"))
  }
  public static func component(_ value: Component) -> Self {
    Self(value.constructionValue, .named("Component"))
  }
  public static func source(_ value: Source) -> Self {
    Self(value.constructionValue, .named("Source"))
  }
  public static func section(_ value: SectionReference) -> Self {
    Self(value.constructionValue, .named("SectionReference"))
  }
  public static func groupReference(_ value: GroupReference) -> Self {
    Self(value.constructionValue, .named("GroupReference"))
  }
  public static func version(_ value: Version) -> Self {
    Self(value.constructionValue, .named("Version"))
  }
  public static func runtime(_ value: RuntimeValue) -> Self {
    Self(value.constructionValue, .named("RuntimeValue"))
  }
  public static func condition(_ value: Condition) -> Self {
    Self(value.constructionValue, .named("Condition"))
  }
  public static func selection(_ value: AgentsDescription.SkillSelection) -> Self {
    Self(value.constructionValue, .named("SkillSelection"))
  }
  public static func skillOverride(_ value: AgentsDescription.SkillOverride) -> Self {
    Self(value.constructionValue, .named("SkillOverride"))
  }
  public static func prompt(_ value: ChatGPTPrompt) -> Self {
    Self(value.constructionValue, .named("ChatGPTPrompt"))
  }
  public static func resource(_ value: Resource) -> Self {
    Self(value.constructionValue, .named("Resource"))
  }
  public static func promptContent(_ value: PromptContent) -> Self {
    Self(value.constructionValue, .named("PromptContent"))
  }
  public static func executable(_ value: ExecutableInvocation) -> Self {
    Self(value.constructionValue, .named("ExecutableInvocation"))
  }
  public static func transport(_ value: MCPTransport) -> Self {
    Self(value.constructionValue, .named("MCPTransport"))
  }
  public static func parameter(_ value: PromptParameter) -> Self {
    Self(value.constructionValue, .named("PromptParameter"))
  }
  public static func permissionRule(_ value: PermissionRule) -> Self {
    Self(value.constructionValue, .named("PermissionRule"))
  }
  public static func agent(_ value: Agent) -> Self {
    Self(value.constructionValue, .named("Agent"))
  }
  public static func scope(_ value: Scope) -> Self {
    Self(value.constructionValue, .named("Scope"))
  }
  public static func platform(_ value: Platform) -> Self {
    Self(value.constructionValue, .named("Platform"))
  }
  public static func installMode(_ value: AgentsDescription.InstallMode) -> Self {
    Self(value.constructionValue, .named("InstallMode"))
  }
  public static func hookEvent(_ value: HookEvent) -> Self {
    Self(value.constructionValue, .named("HookEvent"))
  }
  public static func permissionOperation(_ value: PermissionOperation) -> Self {
    Self(value.constructionValue, .named("PermissionOperation"))
  }
  public static func ignorePurpose(_ value: IgnorePurpose) -> Self {
    Self(value.constructionValue, .named("IgnorePurpose"))
  }
  public static func pluginMode(_ value: PluginMode) -> Self {
    Self(value.constructionValue, .named("PluginMode"))
  }
  public static func componentKind(_ value: ComponentKind) -> Self {
    Self(value.constructionValue, .named("ComponentKind"))
  }
  public static func componentReference(_ value: ComponentReference) -> Self {
    Self(value.constructionValue, .named("ComponentReference"))
  }
  public static func group(_ value: ComponentGroup) -> Self {
    Self(value.constructionValue, .named("ComponentGroup"))
  }
  public static func agents(_ value: Agents) -> Self {
    Self(value.constructionValue, .named("Agents"))
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
