import AgentsInstructions
import Foundation
import Testing

@Suite("Reference definition ownership")
struct ReferenceDefinitionOwnershipTests {
  @Test func replacementPreservesReferenceDefinitionBeforeSetextHeading() throws {
    let target = "# Guide\n\n[ref]: /keep\nRules\n-----\nCustom.\n\n## Other\nSee [ref].\n"
    let section = try source("# Rules\nManaged.\n")
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [section], options: .init(replaceConflicts: true))
    #expect(result.conflicts.first?.existing == "Rules\n-----\nCustom.")
    #expect(
      result.bytes
        == Data(
          ("# Guide\n\n[ref]: /keep\n\n" + block("## Rules\nManaged.") + "\n## Other\nSee [ref].\n")
            .utf8))
    #expect(try Instructions.assemble(result.bytes, sections: [section]).bytes == result.bytes)
    #expect(
      try Instructions.remove(from: result.bytes).bytes
        == Data("# Guide\n\n[ref]: /keep\n## Other\nSee [ref].\n".utf8))
  }

  @Test(arguments: [
    "[ref]:\n  /keep\n  \"A title\n  on two lines\"\n",
    "[a\nlabel]: /first\n[ref]: </keep>\n  'A title'\n",
    "   [ref]:\n /keep\n (A title)\n",
  ])
  func preservesMultilineReferenceDefinitions(_ definitions: String) throws {
    let target = "# Guide\n\n" + definitions + "Rules\n-----\nCustom.\n\n## Other\nSee [ref].\n"
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [source("# Rules\nManaged.\n")],
      options: .init(replaceConflicts: true))
    #expect(result.conflicts.first?.existing == "Rules\n-----\nCustom.")
    #expect(
      result.bytes
        == Data(
          ("# Guide\n\n" + definitions + "\n" + block("## Rules\nManaged.")
            + "\n## Other\nSee [ref].\n").utf8))
  }

  @Test func replacingParentSectionPreservesNestedHeadingDefinitions() throws {
    let target = "# Rules\nCustom.\n\n[ref]: /keep\nDetail\n------\nMore.\n\n# Other\nSee [ref].\n"
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [source("# Rules\nManaged.\n")],
      options: .init(headingOffset: 0, replaceConflicts: true))
    #expect(
      result.bytes
        == Data((block("# Rules\nManaged.") + "\n[ref]: /keep\n# Other\nSee [ref].\n").utf8))
    #expect(result.conflicts.first?.existing == "# Rules\nCustom.\n\nDetail\n------\nMore.")
  }

  @Test func precedingSelectedSectionDoesNotOwnDefinitions() throws {
    let target =
      "# Guide\n\n## First\nCustom.\n\n[ref]: /keep\nRules\n-----\nCustom.\n\n## Other\nSee [ref].\n"
    let sections = try [
      source("# First\nOne\n", id: "first"), source("# Rules\nTwo\n", id: "rules"),
    ]
    let result = try Instructions.assemble(
      Data(target.utf8), sections: sections, options: .init(replaceConflicts: true))
    #expect(
      result.bytes
        == Data(
          ("# Guide\n\n" + block("## First\nOne\n\n## Rules\nTwo")
            + "\n[ref]: /keep\n## Other\nSee [ref].\n").utf8))
    #expect(result.conflicts.map(\.existing) == ["## First\nCustom.", "Rules\n-----\nCustom."])
  }

  @Test func invalidReferenceLikeTextRemainsHeadingContent() throws {
    let target = "[ref]: invalid destination\nRules\n=====\nBody\n"
    let section = try source("# [ref]: invalid destination Rules\nManaged.\n")
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [section], options: .init(replaceConflicts: true))
    #expect(result.conflicts.first?.existing == String(target.dropLast()))
    #expect(!result.hasCustomContent)
  }

  @Test func ambiguousMatchesReportPhysicalContentLines() throws {
    let target = "# Guide\n\n[one]: /keep\nRules\n-----\nA\n\n[two]:\n /keep\nRules\n-----\nB\n"
    #expect(throws: InstructionError.ambiguousMatch(sectionID: "rules:care", lines: [4, 10])) {
      try Instructions.assemble(Data(target.utf8), sections: [source()])
    }
  }

  @Test func largeSetextSelectionPreservesEveryDefinition() throws {
    let count = 2_000
    let definitions = (0..<count).map { "[ref\($0)]: /keep\($0)\n" }
    let target = (0..<count).map { definitions[$0] + "S\($0)\n===\nCustom.\n\n" }.joined()
    let sections = try (0..<count).map { try source("# S\($0)\nManaged.\n", id: "section:\($0)") }
    let clock = ContinuousClock()
    let start = clock.now
    let result = try Instructions.assemble(
      Data(target.utf8), sections: sections, options: .init(replaceConflicts: true))
    #expect(start.duration(to: clock.now) < .seconds(30))
    #expect(result.conflicts.count == count)
    #expect(try Instructions.remove(from: result.bytes).bytes == Data(definitions.joined().utf8))
  }

  @Test func definitionBytesKeepMixedLineEndingsAndBOM() throws {
    let bom = Data([0xEF, 0xBB, 0xBF])
    let custom = "# Guide\r\n\r\n[ref]:\r\n  /keep\r  \"Title\"\n"
    let target = bom + Data((custom + "Rules\n-----\nCustom.\n").utf8)
    let section = try source("# Rules\nManaged.\n")
    let result = try Instructions.assemble(
      target, sections: [section], options: .init(replaceConflicts: true))
    #expect(result.bytes == bom + Data((custom + "\n" + block("## Rules\nManaged.")).utf8))
    #expect(try Instructions.assemble(result.bytes, sections: [section]).bytes == result.bytes)
  }
}

@Suite("Standalone Claude forwarding")
struct StandaloneClaudeForwardingTests {
  @Test(arguments: [
    "**@AGENTS.md**/backup", "\"**@AGENTS.md**\"", "**@AGENTS.md**", "See @AGENTS.md",
    "@AGENTS.md other", "\"@AGENTS.md\"", "@\"AGENTS.md\"", "> @AGENTS.md", "- @AGENTS.md",
    "@**folder**/../AGENTS.md", "@AGENTS.md/backup", "@AGENTS.md\n===\n",
    "**start\n@AGENTS.md\nend**\n", "`start\n@AGENTS.md\nend`\n",
    "<!--\n@AGENTS.md\n-->\n", "[ref]: /url \"title\n@AGENTS.md\nend\"\n",
  ])
  func requiresManagedImportForMentionsAndExamples(_ content: String) throws {
    let bytes = Data(content.utf8)
    #expect(try !ClaudeForwarding.containsImport(in: bytes, at: .root))
    #expect(
      try ClaudeForwarding.classify([.init(path: .root, bytes: bytes)]) == .needsImport(.root))
  }

  @Test(arguments: [
    "@AGENTS.md", " @AGENTS.md \t", "@./AGENTS.md", "@rules/../AGENTS.md\n",
    "@Design\\ Docs/../AGENTS.md", "P with `code`\n@AGENTS.md\n",
    "[ref]: /url\n@AGENTS.md\n", "P\r\n@AGENTS.md\r", "P\n\t@AGENTS.md\n",
    "agents-forwarding-line-0\n@AGENTS.md\n",
  ])
  func recognizesStandaloneImportLines(_ content: String) throws {
    #expect(try ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }

  @Test(arguments: ["@../AGENTS.md", "  @.././AGENTS.md \t", "@../Design\\ Docs/../AGENTS.md"])
  func recognizesStandaloneDirectoryRelativeImports(_ content: String) throws {
    #expect(try ClaudeForwarding.containsImport(in: Data(content.utf8), at: .directory))
  }

  @Test func standaloneCodeLineCannotBorrowProseImport() throws {
    let content = "See @AGENTS.md\n\n```\n@AGENTS.md\n```\n"
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }

  @Test func managedBlockForwardsAlongsideProseMentions() throws {
    let content = "**@AGENTS.md**/backup\n\n" + ClaudeForwarding.renderBlock(for: .root)
    #expect(try ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }
}
