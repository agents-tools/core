// Generated from Scripts/ManifestVocabulary.json. Run Scripts/generate-manifest-vocabulary.py.

package enum Vocabulary {
  package static let typeNames: Set<String> = [
    "String", "Int", "Bool", "Version", "NativeConfiguration", "Agent", "Scope", "Platform",
    "InstallMode", "RuntimeValue", "ConfigurationValue", "HookEvent", "PermissionOperation",
    "IgnorePurpose", "PluginMode", "ComponentKind", "ComponentReference", "Condition", "Agents",
    "Source", "ComponentGroup", "GroupReference", "SkillSelection", "SkillOverride",
    "SectionReference", "ChatGPTPrompt", "Resource", "PromptContent", "ExecutableInvocation",
    "MCPTransport", "PromptParameter", "PermissionRule", "Component",
  ]
  package static let signatures: [ConstructionSignature] = [
    ConstructionSignature(
      type: "Condition", member: "when",
      parameters: [
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "scopes", name: "scopes", type: .optional(.array(.named("Scope"))),
          defaultValue: (nil as [Scope]?).constructionValue),
        ConstructionParameter(
          label: "platforms", name: "platforms", type: .optional(.array(.named("Platform"))),
          defaultValue: (nil as [Platform]?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Agents", member: "Agents",
      parameters: [
        ConstructionParameter(
          label: "defaultAgents", name: "defaultAgents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "exports", name: "exports", type: .array(.named("String")),
          defaultValue: ([] as [String]).constructionValue),
        ConstructionParameter(
          label: "sources", name: "sources", type: .array(.named("Source")),
          defaultValue: ([] as [Source]).constructionValue),
        ConstructionParameter(
          label: "components", name: "components", type: .array(.named("Component")),
          defaultValue: ([] as [Component]).constructionValue),
        ConstructionParameter(
          label: "groups", name: "groups", type: .array(.named("ComponentGroup")),
          defaultValue: ([] as [ComponentGroup]).constructionValue),
        ConstructionParameter(
          label: "uses", name: "uses", type: .array(.named("GroupReference")),
          defaultValue: ([] as [GroupReference]).constructionValue),
        ConstructionParameter(
          label: "watch", name: "watch", type: .array(.named("String")),
          defaultValue: ([] as [String]).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "from", name: "from", type: .named("Version"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "exact", name: "exact", type: .named("Version"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "branch", name: "branch", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "revision", name: "revision", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "_", name: "range", type: .named("VersionRange"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "from", name: "from", type: .named("Version"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "exact", name: "exact", type: .named("Version"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "branch", name: "branch", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "revision", name: "revision", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "_", name: "range", type: .named("VersionRange"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Source", member: "source",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "index", name: "index", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "subpath", name: "subpath", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "ComponentGroup", member: "group",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "components", name: "components", type: .array(.named("Component")),
          defaultValue: ([] as [Component]).constructionValue),
        ConstructionParameter(
          label: "uses", name: "uses", type: .array(.named("GroupReference")),
          defaultValue: ([] as [GroupReference]).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "GroupReference", member: "group",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "GroupReference", member: "group",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "source", name: "source", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
      ], callable: true),
    ConstructionSignature(type: "SkillSelection", member: "all", parameters: [], callable: false),
    ConstructionSignature(
      type: "SkillOverride", member: "skill",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "mode", name: "mode", type: .optional(.named("InstallMode")),
          defaultValue: (nil as InstallMode?).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "SectionReference", member: "section",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "source", name: "source", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "ChatGPTPrompt", member: "prompt",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "sections", name: "sections", type: .array(.named("SectionReference")),
          defaultValue: nil),
        ConstructionParameter(
          label: "append", name: "append", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Resource", member: "path",
      parameters: [
        ConstructionParameter(label: "_", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "source", name: "source", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "PromptContent", member: "file",
      parameters: [
        ConstructionParameter(label: "_", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "source", name: "source", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "ExecutableInvocation", member: "executable",
      parameters: [
        ConstructionParameter(
          label: "_", name: "executable", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "arguments", name: "arguments", type: .array(.named("String")),
          defaultValue: ([] as [String]).constructionValue),
        ConstructionParameter(
          label: "environment", name: "environment", type: .dictionary(.named("RuntimeValue")),
          defaultValue: ([:] as [String: RuntimeValue]).constructionValue),
        ConstructionParameter(
          label: "workingDirectory", name: "workingDirectory", type: .optional(.named("Resource")),
          defaultValue: (nil as Resource?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "MCPTransport", member: "stdio",
      parameters: [
        ConstructionParameter(
          label: "_", name: "executable", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "arguments", name: "arguments", type: .array(.named("String")),
          defaultValue: ([] as [String]).constructionValue),
        ConstructionParameter(
          label: "environment", name: "environment", type: .dictionary(.named("RuntimeValue")),
          defaultValue: ([:] as [String: RuntimeValue]).constructionValue),
        ConstructionParameter(
          label: "workingDirectory", name: "workingDirectory", type: .optional(.named("Resource")),
          defaultValue: (nil as Resource?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "MCPTransport", member: "streamableHTTP",
      parameters: [
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "headers", name: "headers", type: .dictionary(.named("RuntimeValue")),
          defaultValue: ([:] as [String: RuntimeValue]).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "MCPTransport", member: "sse",
      parameters: [
        ConstructionParameter(label: "url", name: "url", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "headers", name: "headers", type: .dictionary(.named("RuntimeValue")),
          defaultValue: ([:] as [String: RuntimeValue]).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "PromptParameter", member: "parameter",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "description", name: "description", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "defaultValue", name: "defaultValue", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "PermissionRule", member: "allow",
      parameters: [
        ConstructionParameter(
          label: "_", name: "operation", type: .named("PermissionOperation"), defaultValue: nil),
        ConstructionParameter(
          label: "_", name: "pattern", type: .named("String"), defaultValue: nil),
      ], callable: true),
    ConstructionSignature(
      type: "PermissionRule", member: "ask",
      parameters: [
        ConstructionParameter(
          label: "_", name: "operation", type: .named("PermissionOperation"), defaultValue: nil),
        ConstructionParameter(
          label: "_", name: "pattern", type: .named("String"), defaultValue: nil),
      ], callable: true),
    ConstructionSignature(
      type: "PermissionRule", member: "deny",
      parameters: [
        ConstructionParameter(
          label: "_", name: "operation", type: .named("PermissionOperation"), defaultValue: nil),
        ConstructionParameter(
          label: "_", name: "pattern", type: .named("String"), defaultValue: nil),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "skills",
      parameters: [
        ConstructionParameter(
          label: "source", name: "source", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "select", name: "select", type: .named("SkillSelection"),
          defaultValue: (.all as SkillSelection).constructionValue),
        ConstructionParameter(
          label: "exclude", name: "exclude", type: .array(.named("String")),
          defaultValue: ([] as [String]).constructionValue),
        ConstructionParameter(
          label: "mode", name: "mode", type: .optional(.named("InstallMode")),
          defaultValue: (nil as InstallMode?).constructionValue),
        ConstructionParameter(
          label: "overrides", name: "overrides", type: .array(.named("SkillOverride")),
          defaultValue: ([] as [SkillOverride]).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "instructions",
      parameters: [
        ConstructionParameter(
          label: "sections", name: "sections", type: .array(.named("SectionReference")),
          defaultValue: ([] as [SectionReference]).constructionValue),
        ConstructionParameter(
          label: "chatGPT", name: "chatGPT", type: .array(.named("ChatGPTPrompt")),
          defaultValue: ([] as [ChatGPTPrompt]).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "mcpServer",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "transport", name: "transport", type: .named("MCPTransport"), defaultValue: nil),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "hook",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "event", name: "event", type: .named("HookEvent"), defaultValue: nil),
        ConstructionParameter(
          label: "run", name: "run", type: .named("ExecutableInvocation"), defaultValue: nil),
        ConstructionParameter(
          label: "matcher", name: "matcher", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
        ConstructionParameter(
          label: "timeoutSeconds", name: "timeoutSeconds", type: .optional(.named("Int")),
          defaultValue: (nil as Int?).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "subagent",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "description", name: "description", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "prompt", name: "prompt", type: .named("PromptContent"), defaultValue: nil),
        ConstructionParameter(
          label: "model", name: "model", type: .optional(.named("String")),
          defaultValue: (nil as String?).constructionValue),
        ConstructionParameter(
          label: "tools", name: "tools", type: .optional(.array(.named("String"))),
          defaultValue: (nil as [String]?).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "command",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "description", name: "description", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "prompt", name: "prompt", type: .named("PromptContent"), defaultValue: nil),
        ConstructionParameter(
          label: "parameters", name: "parameters", type: .array(.named("PromptParameter")),
          defaultValue: ([] as [PromptParameter]).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "lspServer",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "run", name: "run", type: .named("ExecutableInvocation"), defaultValue: nil),
        ConstructionParameter(
          label: "languages", name: "languages", type: .dictionary(.named("String")),
          defaultValue: nil),
        ConstructionParameter(
          label: "initializationOptions", name: "initializationOptions",
          type: .dictionary(.named("ConfigurationValue")),
          defaultValue: ([:] as [String: ConfigurationValue]).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "permissions",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "rules", name: "rules", type: .array(.named("PermissionRule")), defaultValue: nil),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "ignore",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "patterns", name: "patterns", type: .array(.named("String")), defaultValue: nil),
        ConstructionParameter(
          label: "purpose", name: "purpose", type: .named("IgnorePurpose"),
          defaultValue: (.context as IgnorePurpose).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(
      type: "Component", member: "plugin",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "path", name: "path", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "source", name: "source", type: .named("String"), defaultValue: nil),
        ConstructionParameter(
          label: "mode", name: "mode", type: .named("PluginMode"),
          defaultValue: (.components as PluginMode).constructionValue),
        ConstructionParameter(
          label: "select", name: "select", type: .optional(.array(.named("ComponentKind"))),
          defaultValue: (nil as [ComponentKind]?).constructionValue),
        ConstructionParameter(
          label: "exclude", name: "exclude", type: .array(.named("ComponentReference")),
          defaultValue: ([] as [ComponentReference]).constructionValue),
        ConstructionParameter(
          label: "agents", name: "agents", type: .optional(.array(.named("Agent"))),
          defaultValue: (nil as [Agent]?).constructionValue),
        ConstructionParameter(
          label: "condition", name: "condition", type: .optional(.named("Condition")),
          defaultValue: (nil as Condition?).constructionValue),
        ConstructionParameter(
          label: "native", name: "native",
          type: .dictionary(.dictionary(.named("ConfigurationValue"))),
          defaultValue: ([:] as NativeConfiguration).constructionValue),
      ], callable: true),
    ConstructionSignature(type: "Agent", member: "claudeCode", parameters: [], callable: false),
    ConstructionSignature(type: "Agent", member: "codex", parameters: [], callable: false),
    ConstructionSignature(type: "Agent", member: "cursor", parameters: [], callable: false),
    ConstructionSignature(type: "Agent", member: "geminiCLI", parameters: [], callable: false),
    ConstructionSignature(type: "Agent", member: "openCode", parameters: [], callable: false),
    ConstructionSignature(type: "Scope", member: "project", parameters: [], callable: false),
    ConstructionSignature(type: "Scope", member: "user", parameters: [], callable: false),
    ConstructionSignature(type: "Platform", member: "macOS", parameters: [], callable: false),
    ConstructionSignature(type: "Platform", member: "linux", parameters: [], callable: false),
    ConstructionSignature(type: "InstallMode", member: "link", parameters: [], callable: false),
    ConstructionSignature(type: "InstallMode", member: "copy", parameters: [], callable: false),
    ConstructionSignature(type: "InstallMode", member: "edit", parameters: [], callable: false),
    ConstructionSignature(
      type: "RuntimeValue", member: "literal",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "RuntimeValue", member: "environment",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "RuntimeValue", member: "secret",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "string",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "integer",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("Int"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "decimal",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "boolean",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("Bool"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "null", parameters: [], callable: false),
    ConstructionSignature(
      type: "ConfigurationValue", member: "array",
      parameters: [
        ConstructionParameter(
          label: "_", name: "value", type: .array(.named("ConfigurationValue")), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ConfigurationValue", member: "object",
      parameters: [
        ConstructionParameter(
          label: "_", name: "value", type: .dictionary(.named("ConfigurationValue")),
          defaultValue: nil)
      ], callable: true),
    ConstructionSignature(type: "HookEvent", member: "beforeTool", parameters: [], callable: false),
    ConstructionSignature(type: "HookEvent", member: "afterTool", parameters: [], callable: false),
    ConstructionSignature(
      type: "HookEvent", member: "sessionStart", parameters: [], callable: false),
    ConstructionSignature(type: "HookEvent", member: "sessionEnd", parameters: [], callable: false),
    ConstructionSignature(
      type: "HookEvent", member: "native",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "PermissionOperation", member: "read", parameters: [], callable: false),
    ConstructionSignature(
      type: "PermissionOperation", member: "write", parameters: [], callable: false),
    ConstructionSignature(
      type: "PermissionOperation", member: "execute", parameters: [], callable: false),
    ConstructionSignature(
      type: "PermissionOperation", member: "tool",
      parameters: [
        ConstructionParameter(label: "_", name: "value", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "IgnorePurpose", member: "context", parameters: [], callable: false),
    ConstructionSignature(
      type: "IgnorePurpose", member: "indexing", parameters: [], callable: false),
    ConstructionSignature(type: "PluginMode", member: "native", parameters: [], callable: false),
    ConstructionSignature(
      type: "PluginMode", member: "components", parameters: [], callable: false),
    ConstructionSignature(type: "ComponentKind", member: "skills", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "instructions", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "mcpServer", parameters: [], callable: false),
    ConstructionSignature(type: "ComponentKind", member: "hook", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "subagent", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "command", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "lspServer", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentKind", member: "permissions", parameters: [], callable: false),
    ConstructionSignature(type: "ComponentKind", member: "ignore", parameters: [], callable: false),
    ConstructionSignature(type: "ComponentKind", member: "plugin", parameters: [], callable: false),
    ConstructionSignature(
      type: "ComponentReference", member: "skill",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "instruction",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "mcpServer",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "hook",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "subagent",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "command",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "lspServer",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "permissions",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "ignore",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "ComponentReference", member: "plugin",
      parameters: [
        ConstructionParameter(
          label: "name", name: "name", type: .named("String"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "VersionRange", member: "upToNextMajor",
      parameters: [
        ConstructionParameter(
          label: "from", name: "from", type: .named("Version"), defaultValue: nil)
      ], callable: true),
    ConstructionSignature(
      type: "VersionRange", member: "upToNextMinor",
      parameters: [
        ConstructionParameter(
          label: "from", name: "from", type: .named("Version"), defaultValue: nil)
      ], callable: true),
  ]
  package static let literalTypes: [String: Set<LiteralKind>] = [
    "SectionReference": [.string],
    "GroupReference": [.string],
    "PromptContent": [.string],
    "RuntimeValue": [.string],
    "SkillSelection": [.array],
    "ConfigurationValue": [.string, .integer, .boolean, .nilLiteral, .array, .dictionary],
    "Version": [.string],
  ]
  package static let literalConstructions: [String: [LiteralKind: LiteralConstruction]] = [
    "SectionReference": [
      .string: LiteralConstruction(
        member: "section", payload: "name", payloadType: .named("String"),
        defaults: ["source": .none, "condition": .none])
    ],
    "GroupReference": [
      .string: LiteralConstruction(
        member: "group", payload: "name", payloadType: .named("String"),
        defaults: ["source": .none, "condition": .none])
    ],
    "PromptContent": [
      .string: LiteralConstruction(
        member: "literal", payload: "value", payloadType: .named("String"), defaults: [:])
    ],
    "RuntimeValue": [
      .string: LiteralConstruction(
        member: "literal", payload: "value", payloadType: .named("String"), defaults: [:])
    ],
    "SkillSelection": [
      .array: LiteralConstruction(
        member: "names", payload: "names", payloadType: .array(.named("String")), defaults: [:])
    ],
    "ConfigurationValue": [
      .string: LiteralConstruction(
        member: "string", payload: "value", payloadType: .named("String"), defaults: [:]),
      .integer: LiteralConstruction(
        member: "integer", payload: "value", payloadType: .named("Int"), defaults: [:]),
      .boolean: LiteralConstruction(
        member: "boolean", payload: "value", payloadType: .named("Bool"), defaults: [:]),
      .nilLiteral: LiteralConstruction(
        member: "null", payload: nil, payloadType: nil, defaults: [:]),
      .array: LiteralConstruction(
        member: "array", payload: "value", payloadType: .array(.named("ConfigurationValue")),
        defaults: [:]),
      .dictionary: LiteralConstruction(
        member: "object", payload: "value", payloadType: .dictionary(.named("ConfigurationValue")),
        defaults: [:]),
    ],
  ]
  package static let scalarValues: [String: [String: String]] = [
    "Agent": [
      "claudeCode": "claude-code", "codex": "codex", "cursor": "cursor", "geminiCLI": "gemini-cli",
      "openCode": "opencode",
    ],
    "Scope": ["project": "project", "user": "user"],
    "Platform": ["macOS": "macos", "linux": "linux"],
    "InstallMode": ["link": "link", "copy": "copy", "edit": "edit"],
    "IgnorePurpose": ["context": "context", "indexing": "indexing"],
    "PluginMode": ["native": "native", "components": "components"],
    "ComponentKind": [
      "skills": "skills", "instructions": "instructions", "mcpServer": "mcpServer", "hook": "hook",
      "subagent": "subagent", "command": "command", "lspServer": "lspServer",
      "permissions": "permissions", "ignore": "ignore", "plugin": "plugin",
    ],
  ]
  package static let taggedRecordTypes: Set<String> = [
    "Source", "Component", "MCPTransport", "ExecutableInvocation", "GroupReference",
    "PromptContent", "RuntimeValue", "ConfigurationValue", "HookEvent", "PermissionOperation",
    "ComponentReference", "PermissionRule",
  ]
  package static let aliasTypes: [String: ConstructionType] = [
    "NativeConfiguration": .dictionary(.dictionary(.named("ConfigurationValue")))
  ]
}
