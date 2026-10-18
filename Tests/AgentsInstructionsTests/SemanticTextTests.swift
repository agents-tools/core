import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction semantic text and physical lines")
struct InstructionSemanticTextTests {
  @Test func referenceDefinitionDoesNotChangeHeadingIdentity() throws {
    let target = "[ref]: /url\nRules\n=====\nKeep this custom content.\n"
    let section = try source("# [ref]\nManaged.\n")
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [section], options: .init(replaceConflicts: true))
    #expect(result.headingOffset == 1)
    #expect(result.conflicts.isEmpty)
    #expect(result.hasCustomContent)
    #expect(result.bytes == Data((target + "\n" + block("## [ref]\nManaged.")).utf8))
    #expect(try Instructions.assemble(result.bytes, sections: [section]).bytes == result.bytes)
  }

  @Test func referenceDefinitionKeepsSetextUnderlineBeforeNextHeading() throws {
    let target = "[ref]: /url\nRules\n=====\n## Custom\nKeep.\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source("# Other\nBody\n")])
    #expect(
      result.bytes
        == Data(
          ("[ref]: /url\nRules\n=====\n\n" + block("## Other\nBody") + "\n## Custom\nKeep.\n").utf8)
    )
  }

  @Test func tabIndentedSetextContinuationUsesSemanticUnicodeText() throws {
    let target = "Guide\n\t规则\n===\nBody\n"
    let section = try source("# Guide 规则\nBody\n")
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [section], options: .init(replaceConflicts: true))
    #expect(result.headingOffset == 0)
    #expect(result.conflicts.count == 1)
    #expect(result.conflicts.first?.existing == String(target.dropLast()))
    #expect(result.bytes == Data(block("# Guide 规则\nBody").utf8))
    #expect(!result.hasCustomContent)
  }

  @Test(arguments: ["#Rules\n=====\n", "##Rules\n=====\n", "# Rules\n\n> ##Detail\n> ---\n"])
  func rejectsSetextWithHashPrefix(_ content: String) {
    #expect(throws: InstructionError.self) { try source(content) }
  }

  @Test(arguments: [
    ("#\tRules\n", "##\tRules"), ("#\n", "##"),
    ("# Rules\n\n-\t## Detail\n", "## Rules\n\n-\t### Detail"),
    ("# Rules\n\n> 2. ## Detail\n", "## Rules\n\n> 2. ### Detail"),
    ("# Rules\n\n- item\n  > ## Detail\n", "## Rules\n\n- item\n  > ### Detail"),
  ])
  func shiftsVerifiedATXOpenings(_ content: String, _ shifted: String) throws {
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [source(content)])
    #expect(result.block == block(shifted))
  }

  @Test func headingIdentityUsesSemanticInlineText() throws {
    let section = try source("# **Rules** &amp; [care](https://example.com) `now`\nBody\n")
    #expect(section.heading == "Rules & care `now`")
    let target = "# Rules & care `now`\nCustom\n"
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [section], options: .init(replaceConflicts: true))
    #expect(result.headingOffset == 0)
    #expect(result.conflicts.first?.existing == "# Rules & care `now`\nCustom")
    #expect(result.block == block("# **Rules** &amp; [care](https://example.com) `now`\nBody"))
  }

  @Test func semanticHeadingsRejectDuplicateSelections() throws {
    let sections = try [source("# *Rules*\nA\n", id: "one"), source("# Rules\nB\n", id: "two")]
    #expect(
      throws: InstructionError.duplicateHeading(heading: "Rules", sectionIDs: ["one", "two"])
    ) {
      try Instructions.assemble(Data(), sections: sections)
    }
  }

  @Test func semanticHeadingsRejectAmbiguousMatches() throws {
    let target = "# *Rules*\nA\n\n# **Rules**\nB\n"
    #expect(throws: InstructionError.ambiguousMatch(sectionID: "rules:care", lines: [1, 4])) {
      try Instructions.assemble(Data(target.utf8), sections: [source()])
    }
  }

  @Test(arguments: ["=", "  === \t", "   =====", "===\t"])
  func verifiesPhysicalSetextUnderline(_ underline: String) throws {
    let target = "Guide\n" + underline + "\n## Custom\nKeep\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(
      result.bytes
        == Data(
          ("Guide\n" + underline + "\n\n" + block("## Rules\nUse care.") + "\n## Custom\nKeep\n")
            .utf8))
  }
}

@Suite("Claude semantic inline text")
struct ClaudeSemanticTextTests {
  @Test(arguments: [
    "[ref]: /url\n`@AGENTS.md`\n",
    "P\n            `@AGENTS.md`\n",
    "P\r\n            `@AGENTS.md`\r",
    "P\n\t\t\t\t\t\t\t\t\t\t\t\t`@AGENTS.md`\n",
    "P\r\n\t\t\t\t\t\t\t\t\t\t\t\t`@AGENTS.md`\r",
  ])
  func codeSpanNeverForwards(_ content: String) throws {
    let bytes = Data(content.utf8)
    #expect(try !ClaudeForwarding.containsImport(in: bytes, at: .root))
    #expect(
      try ClaudeForwarding.classify([.init(path: .root, bytes: bytes)]) == .needsImport(.root))
  }

  @Test(arguments: [
    "[ref]: /url\n`example` and @AGENTS.md\n",
    "P\n            `example` and @AGENTS.md\n",
    "P\r\n            `example` and @AGENTS.md\r",
    "**See @AGENTS.md**", "> Read @AGENTS.md", "- Read @AGENTS.md",
  ])
  func proseTextForwards(_ content: String) throws {
    #expect(try ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }

  @Test(arguments: [
    "<!-- @AGENTS.md -->", "<span>\n@AGENTS.md\n</span>\n",
    "<pre>\n@AGENTS.md\n</pre>\n", "Read <a data-import='@AGENTS.md'>example</a>",
    "[ref]: /@AGENTS.md\nReference.\n",
  ])
  func htmlAndReferenceDestinationsDoNotForward(_ content: String) throws {
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }
}

@Suite("Instruction UTF-8 byte order marks")
struct InstructionByteOrderMarkTests {
  let bom = Data([0xEF, 0xBB, 0xBF])

  @Test func preservesTargetByteOrderMarkAndTitle() throws {
    let target = bom + Data("# Guide\n".utf8)
    let section = try source("# Rules\nBody\n")
    let result = try Instructions.assemble(target, sections: [section])
    #expect(result.headingOffset == 1)
    #expect(result.bytes == bom + Data(("# Guide\n\n" + block("## Rules\nBody")).utf8))
    #expect(try Instructions.assemble(result.bytes, sections: [section]).bytes == result.bytes)
    #expect(try Instructions.remove(from: result.bytes).bytes == target)
  }

  @Test func preservesByteOrderMarkWhenPrependingBlock() throws {
    let target = bom + Data("Custom\r\nExact  \r".utf8)
    let result = try Instructions.assemble(target, sections: [source()])
    #expect(
      result.bytes == bom + Data((block("# Rules\nUse care.") + "\nCustom\r\nExact  \r").utf8))
    #expect(result.hasCustomContent)
    #expect(try Instructions.assemble(result.bytes, sections: [source()]).bytes == result.bytes)
  }

  @Test func byteOrderMarkIsMetadataForRemovalAndDrift() throws {
    let result = try Instructions.assemble(bom, sections: [source()])
    #expect(result.bytes == bom + Data(block("# Rules\nUse care.").utf8))
    #expect(!result.hasCustomContent)
    #expect(
      try Instructions.detectDrift(in: result.bytes, lockedBlockHash: #require(result.blockHash))
        == .clean)
    let removed = try Instructions.remove(from: result.bytes)
    #expect(removed.bytes == bom)
    #expect(!removed.hasCustomContent)
    let unchanged = try Instructions.remove(from: bom)
    #expect(unchanged.bytes == bom)
    #expect(!unchanged.hasCustomContent)
  }

  @Test func sourceHashIncludesByteOrderMark() throws {
    let plain = Data("# Rules\nBody\n".utf8)
    let section = try Instructions.validateSource(bom + plain, id: "rules")
    #expect(section.heading == "Rules")
    #expect(try section.hash != Instructions.validateSource(plain, id: "rules").hash)
    #expect(try Instructions.assemble(Data(), sections: [section]).block == block("# Rules\nBody"))
  }

  @Test(arguments: ["# Guide\n", "Custom\r\nExact  \r", ""])
  func chatGPTAppendsByteOrderMarkVerbatim(_ custom: String) throws {
    let bytes = bom + Data(custom.utf8)
    let result = try Instructions.renderChatGPT(sections: [source()], customContent: bytes)
    #expect(result == Data("# Rules\nUse care.\n\n".utf8) + bytes)
  }

  @Test func importParsingAcceptsByteOrderMark() throws {
    #expect(try ClaudeForwarding.containsImport(in: bom + Data("See @AGENTS.md\n".utf8), at: .root))
    #expect(try !ClaudeForwarding.containsImport(in: bom + Data("`@AGENTS.md`\n".utf8), at: .root))
  }
}
