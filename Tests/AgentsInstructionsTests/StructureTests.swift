import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction Markdown structure")
struct InstructionStructureTests {
  @Test func preservesCodeAcrossListContainerBoundary() throws {
    let target =
      "- item\n  ```\n  example\n```\n" + beginMarker
      + "\n# Rules\nUse care.\n" + endMarker + "\n```\n"
    let original = Data(target.utf8)
    #expect(try Instructions.remove(from: original).bytes == original)
    let result = try Instructions.assemble(original, sections: [source()])
    #expect(text(result) == block("# Rules\nUse care.") + "\n" + target)
  }

  @Test func quotedLevelSixHeadingOverflowsUnderTitle() throws {
    let section = try source("# Rules\n\n> ###### Deep\n")
    #expect(throws: InstructionError.headingOverflow(sectionID: section.id, level: 6, offset: 1)) {
      try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    }
  }

  @Test func shiftsHeadingsInsideListsAndQuotes() throws {
    let content = "# Rules\n\n> ## Quoted *text*\n\n- ### Listed\n  > #### Nested\n"
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [source(content)])
    #expect(
      result.block == block("## Rules\n\n> ### Quoted *text*\n\n- #### Listed\n  > ##### Nested"))
  }

  @Test(arguments: [
    "> # Other", "- # Other", "- item\n\n  # Other", "> Title\n> =====", "- Title\n  -----",
  ])
  func rejectsH1AndSetextHeadingsInsideContainers(_ nested: String) {
    #expect(throws: InstructionError.self) { try source("# Rules\n\n" + nested + "\n") }
  }

  @Test(arguments: ["> # Rules\n", "- # Rules\n"])
  func requiresTopLevelSourceHeading(_ content: String) {
    #expect(throws: InstructionError.self) { try source(content) }
  }

  @Test func containerHeadingsAreNotTitlesOrMatches() throws {
    let target = "> # Guide\n\n- # Rules\n  Custom\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(result.headingOffset == 0)
    #expect(result.adoptedSections.isEmpty)
    #expect(result.conflicts.isEmpty)
    #expect(text(result) == block("# Rules\nUse care.") + "\n" + target)
  }

  @Test func containerHeadingsBelongToContainingSection() throws {
    let content = "# Rules\nUse care.\n\n> ## Quoted\n> Content\n\n- ## Listed\n  Content\n"
    let result = try Instructions.assemble(Data(content.utf8), sections: [source(content)])
    #expect(result.adoptedSections == ["rules:care"])
    #expect(!result.hasCustomContent)
  }

  @Test func recognizesThematicBreakAfterList() throws {
    let content = "# Rules\n\n- item\n---\nBody\n"
    let result = try Instructions.assemble(Data(), sections: [source(content)])
    #expect(result.block == block(String(content.dropLast())))
  }

  @Test func typeSevenHTMLDoesNotCreateTitle() throws {
    let target = "<span>\n# Guide\n</span>"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source("# Rules\nBody\n")])
    #expect(result.headingOffset == 0)
    #expect(text(result) == block("# Rules\nBody") + "\n" + target)
  }

  @Test func typeOneHTMLAcceptsAnyDesignatedClosingTag() throws {
    let content = "# Rules\n<pre>\n</script>\n## Detail\n"
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [source(content)])
    #expect(result.block == block("## Rules\n<pre>\n</script>\n### Detail"))
  }

  @Test(arguments: [
    "<!-- open", "<?open", "<!DECLARATION", "<![CDATA[open", "<pre>\nopen",
    "<div>\nclosed tag </div>", "<span>\n</span>", "> <!-- open", "- <pre>\n  open",
  ])
  func rejectsSourceEndingInsideHTML(_ html: String) {
    #expect(throws: InstructionError.self) { try source("# Rules\n\n" + html + "\n") }
  }

  @Test(arguments: [
    "<!-- closed -->", "<?closed ?>", "<!DECLARATION>", "<![CDATA[closed]]>", "<pre>\n</script>",
    "> <!-- closed -->", "- <pre>\n  </style>",
  ])
  func acceptsExplicitlyClosedHTMLAtEnd(_ html: String) throws {
    let section = try source("# Rules\n\n" + html + "\n")
    #expect(try Instructions.assemble(Data(), sections: [section]).block != nil)
  }

  @Test(arguments: [
    "> ```\n> body", "- item\n  ```\n  body", "- > ~~~\n  > body", ">     indented",
    "- item\n\n      indented",
  ])
  func rejectsSourceEndingInsideContainerCode(_ code: String) {
    #expect(throws: InstructionError.self) { try source("# Rules\n\n" + code + "\n") }
  }

  @Test(arguments: [
    "> ```\n> body\n> `````", "- item\n  ```\n  body\n  ```", "- > ~~~\n  > body\n  > ~~~~",
  ])
  func acceptsClosedContainerFences(_ code: String) throws {
    let section = try source("# Rules\n\n" + code + "\n")
    #expect(try Instructions.assemble(Data(), sections: [section]).block != nil)
  }

  @Test func onlyExactTopLevelSingleLineHTMLMarkersCount() throws {
    let examples = [
      "> \(beginMarker)\n> \(endMarker)\n",
      "- \(beginMarker)\n\n- \(endMarker)\n",
      "<span>\n\(beginMarker)\n\(endMarker)\n</span>\n",
      " \(beginMarker)\n \(endMarker)\n",
      "\(beginMarker) trailing\n\(endMarker) trailing\n",
    ]
    for target in examples {
      let bytes = Data(target.utf8)
      #expect(try Instructions.remove(from: bytes).bytes == bytes)
    }
    #expect(try Instructions.remove(from: Data(block("# Rules\nUse care.").utf8)).bytes.isEmpty)
  }

  @Test func setextRangeKeepsFollowingParagraphAndUnderlineTogether() throws {
    let target = "Project\nGuide\n=====\nIntroduction\n\n## Custom\nKeep\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(
      text(result) == "Project\nGuide\n=====\nIntroduction\n\n" + block("## Rules\nUse care.")
        + "\n## Custom\nKeep\n")
  }

  @Test(arguments: ["", " ", "  ", "   "])
  func preservesHeadingIndentationAndInlineSyntax(_ indentation: String) throws {
    let section = try source(indentation + "# Rüles *and* `code` ###\nBody\n")
    #expect(section.heading == "Rüles and `code`")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(result.block == block(indentation + "## Rüles *and* `code` ###\nBody"))
  }

  @Test func escapedOpeningHashIsNotHeading() throws {
    let target = "\\# Guide\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(result.headingOffset == 0)
    #expect(text(result).hasSuffix(target))
  }

  @Test(arguments: [
    "# Guide\r", "# Guide\r\nIntroduction\r", "# Guide\nIntroduction\r", "# Guide\rIntroduction\n",
  ])
  func lockedAssemblyIsIdempotentWithMixedLineEndings(_ target: String) throws {
    let options = InstructionOptions(headingOffset: 1)
    let first = try Instructions.assemble(Data(target.utf8), sections: [source()], options: options)
    let second = try Instructions.assemble(first.bytes, sections: [source()], options: options)
    #expect(second.bytes == first.bytes)
    #expect(second.blockHash == first.blockHash)
    if target == "# Guide\r" {
      #expect(text(first) == "# Guide\r\n\n" + block("## Rules\nUse care."))
    }
  }

  @Test func assembleRemoveAssemblePreservesLockedRendering() throws {
    let options = InstructionOptions(headingOffset: 1)
    let first = try Instructions.assemble(
      Data("# Guide\n".utf8), sections: [source()], options: options)
    let removed = try Instructions.remove(from: first.bytes)
    let restored = try Instructions.assemble(removed.bytes, sections: [source()], options: options)
    #expect(restored.bytes == first.bytes)
  }

  @Test(arguments: [2_000, 10_000])
  func assemblesLargeMatchingSelection(_ count: Int) throws {
    let contents = (0..<count).map { "# S\($0)\nx\n" }
    let sections = try contents.enumerated().map {
      try source($0.element, id: "source:S\($0.offset)")
    }
    let target = contents.joined(separator: "\n")
    let clock = ContinuousClock()
    let start = clock.now
    let result = try Instructions.assemble(Data(target.utf8), sections: sections)
    let elapsed = start.duration(to: clock.now)
    #expect(result.adoptedSections == sections.map(\.id))
    #expect(!result.hasCustomContent)
    #expect(text(result) == block(String(target.dropLast())))
    // A deliberately generous bound catches repeated full-document scans without benchmarking CI speed.
    #expect(elapsed < .seconds(30))
  }
}

@Suite("Claude import syntax")
struct ClaudeImportSyntaxTests {
  @Test func quotedPathDoesNotForward() throws {
    #expect(
      try ClaudeForwarding.classify([.init(path: .root, bytes: Data("@\"AGENTS.md\"".utf8))])
        == .needsImport(.root))
  }

  @Test func proseImportNeedsManagedImport() throws {
    #expect(
      try ClaudeForwarding.classify([.init(path: .root, bytes: Data("See @AGENTS.md".utf8))])
        == .needsImport(.root))
  }

  @Test(arguments: [
    "See @../AGENTS.md", "@../AGENTS.md other", "- Read @.././AGENTS.md",
    "See @../Design\\ Docs/../AGENTS.md",
  ])
  func proseDirectoryRelativeTokensNeedManagedImport(_ content: String) throws {
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .directory))
  }

  @Test(arguments: [
    "`@AGENTS.md`", "See `` @AGENTS.md ``", "See `first\n@AGENTS.md`", "```\n@AGENTS.md\n```",
    "    @AGENTS.md\n", "- item\n  ```\n  @AGENTS.md\n  ```", "> ```\n> @AGENTS.md\n> ```",
    "@'AGENTS.md'", "\"@AGENTS.md\"", "contact@AGENTS.md",
  ])
  func ignoresCodeAndQuotedPaths(_ content: String) throws {
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }

  @Test func inlineImportAfterCodeSpanNeedsManagedImport() throws {
    let content = "Rüles\r\n`@wrong.md` then @AGENTS.md\r"
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
  }

  @Test func proseWithUnterminatedBacktickNeedsManagedImport() throws {
    #expect(
      try !ClaudeForwarding.containsImport(in: Data("See `literal and @AGENTS.md".utf8), at: .root))
  }
}
