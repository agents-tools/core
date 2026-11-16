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
        surface: .claudeCode, kind: .subagent, name: "auditor", fields: fields, inPlugin: false,
        budget: budget())
        == fields)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, kind: .subagent, name: "auditor", fields: fields,
        inPlugin: true, budget: budget())
    }
    var commaTools = fields
    commaTools["tools"] = .string("Read, Grep")
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, kind: .subagent, name: "auditor", fields: commaTools, inPlugin: false,
        budget: budget()) == commaTools)
    var unknown = fields
    unknown["permissionmode"] = .string("value-canary")
    do {
      _ = try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, kind: .subagent, name: "auditor", fields: unknown, inPlugin: false,
        budget: budget())
      Issue.record("silently ignored unknown native field")
    } catch let issue as NativeComponentFieldIssue {
      #expect(issue.reason == .unverified)
      #expect(!issue.detail.contains("value-canary"))
    }
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, kind: .command, name: "review",
        fields: ["background": .boolean(true)], inPlugin: false, budget: budget())
    }
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .claudeCode, kind: .command, name: "team/review", fields: [:],
        inPlugin: false, budget: budget()
      ).isEmpty)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, kind: .command, name: "team/review", fields: [:],
        inPlugin: false, budget: budget())
    }
    let cursor: [String: NativeValue] = [
      "readonly": .boolean(true), "is_background": .boolean(true),
    ]
    #expect(
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, kind: .subagent, name: "auditor", fields: cursor, inPlugin: false,
        budget: budget())
        == cursor)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.markdown(
        surface: .cursorEditor, kind: .subagent, name: "auditor",
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
      try NativeComponentFieldsV1.lsp(surface: .claudeCode, fields: fields, budget: budget())
        == fields)
    var unknown = fields
    unknown["cwd"] = .string("value-canary")
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(surface: .claudeCode, fields: unknown, budget: budget())
    }
    var invalid = fields
    invalid["requestTimeout"] = .integer(0)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(surface: .claudeCode, fields: invalid, budget: budget())
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
        surface: .openCodeCLI, fields: fields, budget: budget()) == fields)
    let disabled: [String: NativeValue] = ["disabled": .boolean(true)]
    #expect(
      try NativeComponentFieldsV1.lsp(
        surface: .openCodeCLI, fields: disabled, budget: budget()) == disabled)
    var invalid = fields
    invalid["env"] = .object(["SOURCE": .integer(7)])
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.lsp(surface: .openCodeCLI, fields: invalid, budget: budget())
    }
  }

  @Test func parsedPluginUsesProducerRootAndMergeDefaults() throws {
    let claudeDefaults = try NativeComponentFieldsV1.pluginDefaults(
      surface: .claudeCode, explicitFields: ["commands", "agents", "skills", "hooks"])
    #expect(claudeDefaults["commands"] == nil && claudeDefaults["agents"] == nil)
    #expect(claudeDefaults["skills"] == "skills" && claudeDefaults["hooks"] == "hooks/hooks.json")
    let cursorDefaults = try NativeComponentFieldsV1.pluginDefaults(
      surface: .cursorEditor, explicitFields: ["commands", "skills", "hooks"])
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
        surface: .claudeCode, fields: valid,
        entries: entries, documents: ["hooks/hooks.json": badDefault], budget: budget())
    }
    let emptyHooks: NativeValue = .object(["hooks": .object([:])])
    #expect(
      try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, fields: valid,
        entries: entries, documents: ["hooks/hooks.json": emptyHooks], budget: budget()) == valid)
    // Cursor explicit hooks replace its default; an absent explicit file still fails.
    let cursor: [String: NativeValue] = [
      "name": .string("fixture"), "hooks": .string("chosen.json"),
    ]
    let cursorEntries = entries + [.init(path: "chosen.json", kind: .file, executable: false)]
    #expect(
      try NativeComponentFieldsV1.plugin(
        surface: .cursorEditor, fields: cursor,
        entries: cursorEntries,
        documents: ["chosen.json": .object(["version": .integer(1), "hooks": .object([:])])],
        budget: budget()) == cursor)
    #expect(throws: NativeComponentFieldIssue.self) {
      try NativeComponentFieldsV1.plugin(
        surface: .cursorEditor, fields: cursor,
        entries: entries, documents: [:], budget: budget())
    }
    #expect(throws: (any Error).self) {
      try NativeComponentFieldsV1.plugin(
        surface: .claudeCode, fields: valid,
        entries: entries, documents: ["hooks/hooks.json": emptyHooks], budget: budget(1))
    }
  }
}
