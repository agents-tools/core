import AgentsInstructions
import Foundation
import Testing

let beginMarker =
  "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->"
let endMarker = "<!-- END managed by agents -->"

func block(_ content: String) -> String {
  beginMarker + "\n" + content + "\n" + endMarker + "\n"
}

@Suite("Claude forwarding")
struct ClaudeForwardingTests {
  @Test(arguments: ClaudeInstructionPath.allCases)
  func rendersRelativeImportBlock(_ path: ClaudeInstructionPath) throws {
    let expected = path == .directory ? "@../AGENTS.md" : "@AGENTS.md"
    let rendered = ClaudeForwarding.renderBlock(for: path)
    #expect(rendered == block(expected))
    #expect(try ClaudeForwarding.containsImport(in: Data(rendered.utf8), at: path))
  }

  @Test(arguments: ["@AGENTS.md", "@./AGENTS.md", "@rules/../AGENTS.md"])
  func recognizesEquivalentImport(_ line: String) throws {
    #expect(
      try ClaudeForwarding.containsImport(in: Data(("# Guide\n\n" + line + "\n").utf8), at: .root))
  }

  @Test(arguments: ["@AGENTS.md", "@../../AGENTS.md", "@\"../AGENTS.md\"", "@../AGENTS.md/"])
  func rejectsWrongDirectoryImport(_ line: String) throws {
    #expect(try !ClaudeForwarding.containsImport(in: Data(line.utf8), at: .directory))
  }

  @Test func ignoresImportsInsideCode() throws {
    let target = "```\n@AGENTS.md\n```\n\n    @AGENTS.md\n"
    #expect(try !ClaudeForwarding.containsImport(in: Data(target.utf8), at: .root))
  }

  @Test func rootSymlinkAlreadyForwards() throws {
    let files = [ClaudeInstructionFile(path: .root, isSymbolicLinkToAgents: true)]
    #expect(try ClaudeForwarding.classify(files) == .forwarding(.root))
    #expect(try ClaudeForwarding.classify([.init(path: .root)]) == .needsImport(.root))
  }

  @Test func choosesFirstExistingClaudeFile() throws {
    #expect(
      try ClaudeForwarding.classify([
        .init(path: .local), .init(path: .directory), .init(path: .root),
      ]) == .needsImport(.root))
    #expect(
      try ClaudeForwarding.classify([.init(path: .local), .init(path: .directory)])
        == .needsImport(.directory))
    #expect(try ClaudeForwarding.classify([.init(path: .local)]) == .needsImport(.local))
    #expect(try ClaudeForwarding.classify([]) == .automatic)
  }

  @Test func existingImportInAnotherProjectFileForwards() throws {
    let files = [
      ClaudeInstructionFile(path: .root),
      ClaudeInstructionFile(path: .directory, bytes: Data("@../AGENTS.md\n".utf8)),
    ]
    #expect(try ClaudeForwarding.classify(files) == .forwarding(.directory))
  }

  @Test func rejectsMalformedForwardingMarkers() {
    #expect(throws: InstructionError.self) {
      try ClaudeForwarding.containsImport(
        in: Data((beginMarker + "\n@AGENTS.md\n").utf8), at: .root)
    }
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

@Suite("Claude import examples")
struct ClaudeImportExampleTests {
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
  func proseTextNeedsManagedImport(_ content: String) throws {
    #expect(try !ClaudeForwarding.containsImport(in: Data(content.utf8), at: .root))
    #expect(
      try ClaudeForwarding.classify([.init(path: .root, bytes: Data(content.utf8))])
        == .needsImport(.root))
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

@Suite("Claude import byte order marks")
struct ClaudeImportByteOrderMarkTests {
  let bom = Data([0xEF, 0xBB, 0xBF])

  @Test func importParsingAcceptsByteOrderMark() throws {
    #expect(try ClaudeForwarding.containsImport(in: bom + Data("@AGENTS.md\n".utf8), at: .root))
    #expect(try !ClaudeForwarding.containsImport(in: bom + Data("`@AGENTS.md`\n".utf8), at: .root))
  }
}
