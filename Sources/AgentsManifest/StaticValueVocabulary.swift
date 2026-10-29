// Generated from Scripts/ManifestVocabulary.json. Run Scripts/generate-manifest-vocabulary.py.

import AgentsDescription

extension StaticValue {
  public static func configuration(_ value: AgentsDescription.ConfigurationValue) -> Self {
    Self.checked(value.constructionValue, type: .named("ConfigurationValue"))
  }
  public static func component(_ value: AgentsDescription.Component) -> Self {
    Self.checked(value.constructionValue, type: .named("Component"))
  }
  public static func source(_ value: AgentsDescription.Source) -> Self {
    Self.checked(value.constructionValue, type: .named("Source"))
  }
  public static func section(_ value: AgentsDescription.SectionReference) -> Self {
    Self.checked(value.constructionValue, type: .named("SectionReference"))
  }
  public static func groupReference(_ value: AgentsDescription.GroupReference) -> Self {
    Self.checked(value.constructionValue, type: .named("GroupReference"))
  }
  public static func version(_ value: AgentsDescription.Version) -> Self {
    Self.checked(value.constructionValue, type: .named("Version"))
  }
  public static func runtime(_ value: AgentsDescription.RuntimeValue) -> Self {
    Self.checked(value.constructionValue, type: .named("RuntimeValue"))
  }
  public static func condition(_ value: AgentsDescription.Condition) -> Self {
    Self.checked(value.constructionValue, type: .named("Condition"))
  }
  public static func selection(_ value: AgentsDescription.SkillSelection) -> Self {
    Self.checked(value.constructionValue, type: .named("SkillSelection"))
  }
  public static func skillOverride(_ value: AgentsDescription.SkillOverride) -> Self {
    Self.checked(value.constructionValue, type: .named("SkillOverride"))
  }
  public static func prompt(_ value: AgentsDescription.ChatGPTPrompt) -> Self {
    Self.checked(value.constructionValue, type: .named("ChatGPTPrompt"))
  }
  public static func resource(_ value: AgentsDescription.Resource) -> Self {
    Self.checked(value.constructionValue, type: .named("Resource"))
  }
  public static func promptContent(_ value: AgentsDescription.PromptContent) -> Self {
    Self.checked(value.constructionValue, type: .named("PromptContent"))
  }
  public static func executable(_ value: AgentsDescription.ExecutableInvocation) -> Self {
    Self.checked(value.constructionValue, type: .named("ExecutableInvocation"))
  }
  public static func transport(_ value: AgentsDescription.MCPTransport) -> Self {
    Self.checked(value.constructionValue, type: .named("MCPTransport"))
  }
  public static func parameter(_ value: AgentsDescription.PromptParameter) -> Self {
    Self.checked(value.constructionValue, type: .named("PromptParameter"))
  }
  public static func permissionRule(_ value: AgentsDescription.PermissionRule) -> Self {
    Self.checked(value.constructionValue, type: .named("PermissionRule"))
  }
  public static func agent(_ value: AgentsDescription.Agent) -> Self {
    Self.checked(value.constructionValue, type: .named("Agent"))
  }
  public static func scope(_ value: AgentsDescription.Scope) -> Self {
    Self.checked(value.constructionValue, type: .named("Scope"))
  }
  public static func platform(_ value: AgentsDescription.Platform) -> Self {
    Self.checked(value.constructionValue, type: .named("Platform"))
  }
  public static func installMode(_ value: AgentsDescription.InstallMode) -> Self {
    Self.checked(value.constructionValue, type: .named("InstallMode"))
  }
  public static func hookEvent(_ value: AgentsDescription.HookEvent) -> Self {
    Self.checked(value.constructionValue, type: .named("HookEvent"))
  }
  public static func permissionOperation(_ value: AgentsDescription.PermissionOperation) -> Self {
    Self.checked(value.constructionValue, type: .named("PermissionOperation"))
  }
  public static func ignorePurpose(_ value: AgentsDescription.IgnorePurpose) -> Self {
    Self.checked(value.constructionValue, type: .named("IgnorePurpose"))
  }
  public static func pluginMode(_ value: AgentsDescription.PluginMode) -> Self {
    Self.checked(value.constructionValue, type: .named("PluginMode"))
  }
  public static func componentKind(_ value: AgentsDescription.ComponentKind) -> Self {
    Self.checked(value.constructionValue, type: .named("ComponentKind"))
  }
  public static func componentReference(_ value: AgentsDescription.ComponentReference) -> Self {
    Self.checked(value.constructionValue, type: .named("ComponentReference"))
  }
  public static func group(_ value: AgentsDescription.ComponentGroup) -> Self {
    Self.checked(value.constructionValue, type: .named("ComponentGroup"))
  }
  public static func agents(_ value: AgentsDescription.Agents) -> Self {
    Self.checked(value.constructionValue, type: .named("Agents"))
  }
}
