import AgentsCore
import Foundation
import NativeDocuments
import Testing

@testable import Components

@Suite("Parsed native component semantics")
struct NativeComponentFieldsTests {
  private func budget(_ nodes: Int = 10000) -> NativeDocumentBudget {
    .init(
      limits: .init(
        storage: 1_000_000, work: 1_000_000, nodes: nodes, depth: 64, uninterruptedBytes: 1_000_000)
    )
  }

  @Test func parsedFrontmatterKeepsNativeFieldsAndRejectsIgnoredIntent() throws {
    let fields: [String: NativeValue] = [
      "name": .string("auditor"), "description": .string("Inspect source."),
      "permissionMode": .string("plan"), "maxTurns": .integer(3),
      "tools": .array([.string("Read")]), "disallowedTools": .array([.string("Write")]),
    ]
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .subagent, name: "auditor",
        fields: fields, inPlugin: false,
        budget: budget())
        == fields)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .subagent, name: "auditor",
        fields: fields,
        inPlugin: true, budget: budget())
    }
    var commaTools = fields
    commaTools["tools"] = .string("Read, Grep")
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .subagent, name: "auditor",
        fields: commaTools, inPlugin: false,
        budget: budget()) == commaTools)
    var unknown = fields
    unknown["permissionmode"] = .string("value-canary")
    do {
      _ = try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .subagent, name: "auditor",
        fields: unknown, inPlugin: false,
        budget: budget())
      Issue.record("silently ignored unknown native field")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.reason == .unverified)
      #expect(!issue.detail.contains("value-canary"))
    }
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .command, name: "review",
        fields: ["background": .boolean(true)], inPlugin: false, budget: budget())
    }
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "source.json", kind: .command, name: "team/review",
        fields: [:],
        inPlugin: false, budget: budget()
      ).isEmpty)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, document: "source.json", kind: .command, name: "team/review",
        fields: [:],
        inPlugin: false, budget: budget())
    }
    let cursor: [String: NativeValue] = [
      "readonly": .boolean(true), "is_background": .boolean(true),
    ]
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, document: "source.json", kind: .subagent, name: "auditor",
        fields: cursor, inPlugin: false,
        budget: budget())
        == cursor)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, document: "source.json", kind: .subagent, name: "auditor",
        fields: ["tools": .array([.string("Read")])], inPlugin: false, budget: budget())
    }
  }

  @Test func parsedLSPPreservesArbitraryInitializationAndRejectsUnknownFields() throws {
    let fields: [String: NativeValue] = [
      "command": .string("source-lsp"),
      "extensionToLanguage": .object([".source": .string("source")]),
      "transport": .string("socket"), "requestTimeout": .integer(100),
      "initializationOptions": .object([
        "deep": .array([.null, .boolean(true), .string("${kept}\0data")])
      ]),
    ]
    #expect(
      try NativeComponentFieldsV1.lsp(
        surface: .claudeCode, document: "source.json", fields: fields, budget: budget())
        == fields)
    var unknown = fields
    unknown["cwd"] = .string("value-canary")
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(
        surface: .claudeCode, document: "source.json", fields: unknown, budget: budget())
    }
    var invalid = fields
    invalid["requestTimeout"] = .integer(0)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(
        surface: .claudeCode, document: "source.json", fields: invalid, budget: budget())
    }
  }

  @Test func parsedOpenCodeLSPRetainsNativeEntrySemantics() throws {
    let fields: [String: NativeValue] = [
      "command": .array([.string("source-lsp"), .string("--stdio")]),
      "extensions": .array([.string(".source")]),
      "env": .object(["SOURCE": .string("{env:SOURCE}")]),
      "initialization": .object(["any": .array([.null, .integer(7)])]),
    ]
    #expect(
      try NativeComponentFieldsV1.lsp(
        surface: .openCodeCLI, document: "source.json", fields: fields, budget: budget()) == fields)
    let disabled: [String: NativeValue] = ["disabled": .boolean(true)]
    #expect(
      try NativeComponentFieldsV1.lsp(
        surface: .openCodeCLI, document: "source.json", fields: disabled, budget: budget())
        == disabled)
    var invalid = fields
    invalid["env"] = .object(["SOURCE": .integer(7)])
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(
        surface: .openCodeCLI, document: "source.json", fields: invalid, budget: budget())
    }
  }

  @Test func parsedPluginUsesProducerRootAndMergeDefaults() throws {
    let claudeDefaults = try NativeComponentFieldsV1.pluginDefaults(
      surface: .claudeCode, document: "source.json",
      explicitFields: ["commands", "agents", "skills", "hooks"])
    #expect(claudeDefaults["commands"] == nil && claudeDefaults["agents"] == nil)
    #expect(claudeDefaults["skills"] == "skills" && claudeDefaults["hooks"] == "hooks/hooks.json")
    let cursorDefaults = try NativeComponentFieldsV1.pluginDefaults(
      surface: .cursorEditor, document: "source.json",
      explicitFields: ["commands", "skills", "hooks"])
    #expect(cursorDefaults["commands"] == nil && cursorDefaults["skills"] == nil)
    #expect(cursorDefaults["hooks"] == nil && cursorDefaults["mcpServers"] == "mcp.json")
    let entries: [LedgerEntry] = [
      .init(path: ".", kind: .directory, executable: false),
      .init(path: "commands/review.md", kind: .file, executable: false),
      .init(path: "hooks/hooks.json", kind: .file, executable: false),
    ]
    let valid: [String: NativeValue] = [
      "name": .string("fixture"), "commands": .string("./commands/review.md"),
      "hooks": .object([:]),
    ]
    let badDefault: NativeValue = .object(["hooks": .object(["invented": .array([])])])
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: "source.json", fields: valid,
        entries: entries, documents: ["hooks/hooks.json": badDefault], budget: budget())
    }
    let emptyHooks: NativeValue = .object(["hooks": .object([:])])
    #expect(
      try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: "source.json", fields: valid,
        entries: entries, documents: ["hooks/hooks.json": emptyHooks], budget: budget()) == valid)
    // Cursor explicit hooks replace its default; an absent explicit file still fails.
    let cursor: [String: NativeValue] = [
      "name": .string("fixture"), "hooks": .string("chosen.json"),
    ]
    let cursorEntries = entries + [.init(path: "chosen.json", kind: .file, executable: false)]
    #expect(
      try NativeComponentFieldsV1.plugin(
        surface: .cursorEditor, document: "source.json", fields: cursor,
        entries: cursorEntries,
        documents: ["chosen.json": .object(["version": .integer(1), "hooks": .object([:])])],
        budget: budget()) == cursor)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.plugin(
        surface: .cursorEditor, document: "source.json", fields: cursor,
        entries: entries, documents: [:], budget: budget())
    }
    #expect(throws: (any Error).self) {
      try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: "source.json", fields: valid,
        entries: entries, documents: ["hooks/hooks.json": emptyHooks], budget: budget(1))
    }
  }
  @Test func referencedConfigurationFailuresKeepTheirExactDocumentAndField() throws {
    let manifest = ".claude-plugin/plugin.json"
    let entries: [LedgerEntry] = [
      .init(path: "first.json", kind: .file, executable: false),
      .init(path: "second.json", kind: .file, executable: false),
      .init(path: ".lsp.json", kind: .file, executable: false),
      .init(path: "hooks/hooks.json", kind: .file, executable: false),
    ]
    let first: NativeValue = .object([
      "mcpServers": .object(["same": .object(["command": .integer(17)])])
    ])
    let second: NativeValue = .object([
      "mcpServers": .object(["same": .object(["command": .string("valid")])])
    ])
    let fields: [String: NativeValue] = [
      "name": .string("fixture"),
      "mcpServers": .array([.string("./first.json"), .string("./second.json")]),
    ]
    do {
      _ = try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: manifest, fields: fields, entries: entries,
        documents: ["first.json": first, "second.json": second], budget: budget())
      Issue.record("invalid overwritten source was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == "first.json")
      #expect(issue.field == ["mcpServers", "same", "command"])
      #expect(!issue.detail.contains("17"))
    }
    do {
      _ = try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: manifest,
        fields: ["name": .string("fixture")], entries: entries,
        documents: [
          "hooks/hooks.json": .object(["hooks": .object([:])]),
          ".lsp.json": .object([
            "same": .object([
              "command": .integer(17), "extensionToLanguage": .object([".x": .string("x")]),
            ])
          ]),
        ], budget: budget())
      Issue.record("invalid default source was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == ".lsp.json")
      #expect(issue.field == ["same", "command"])
    }
    do {
      _ = try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: manifest,
        fields: [
          "name": .string("fixture"),
          "hooks": .array([
            .object([:]),
            .object([
              "SessionStart": .array([
                .object([
                  "hooks": .array([.object(["type": .string("command"), "command": .integer(17)])])
                ])
              ])
            ]),
          ]),
        ], entries: [], documents: [:], budget: budget())
      Issue.record("invalid inline source was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == manifest)
      #expect(issue.field == ["hooks", "1", "SessionStart", "0", "hooks", "0", "command"])
    }
    do {
      _ = try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, document: manifest,
        fields: [
          "name": .string("fixture"),
          "mcpServers": .array([
            .object([:]), .string("./missing.json"),
          ]),
        ], entries: [], documents: [:], budget: budget())
      Issue.record("missing referenced file was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == manifest)
      #expect(issue.field == ["mcpServers", "1"])
    }
  }

  @Test func externalHookCoordinatesIncludeHandlerIndicesAndRootMetadata() throws {
    let file = "hooks/chosen.json"
    let entries: [LedgerEntry] = [.init(path: file, kind: .file, executable: false)]
    let fields: [String: NativeValue] = ["name": .string("fixture"), "hooks": .string(file)]
    for invalidMetadata in [false, true] {
      let config: NativeValue = .object([
        "version": invalidMetadata ? .integer(2) : .integer(1),
        "hooks": .object([
          "stop": .array([
            .object(["command": .string("keep")]), .object(["command": .integer(17)]),
          ])
        ]),
      ])
      do {
        _ = try NativeComponentFieldsV1.plugin(
          surface: .cursorEditor, document: ".cursor-plugin/plugin.json", fields: fields,
          entries: entries, documents: [file: config], budget: budget())
        Issue.record("invalid external hooks were accepted")
      } catch let issue as NativeComponentFieldIssue {
        #expect(issue.document == file)
        #expect(issue.field == (invalidMetadata ? ["version"] : ["hooks", "stop", "1", "command"]))
      }
    }
  }

  @Test func directParsedFailuresRetainCallerDocumentAndFieldPrefix() throws {
    do {
      _ = try NativeComponentFieldsV1.lsp(
        surface: .claudeCode, document: "settings.json", fieldPrefix: ["lsp", "same"],
        fields: ["command": .integer(17), "extensionToLanguage": .object([".x": .string("x")])],
        budget: budget())
      Issue.record("invalid LSP command was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == "settings.json")
      #expect(issue.field == ["lsp", "same", "command"])
    }
    do {
      _ = try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, document: "commands/review.md", kind: .command, name: "review",
        fields: ["model": .integer(17)], inPlugin: true, budget: budget())
      Issue.record("invalid Markdown field was accepted")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.document == "commands/review.md")
      #expect(issue.field == ["model"])
    }
  }

}
