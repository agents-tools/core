import AgentsInstructions
import Foundation
import Testing

func unit(_ text: String, id: String = "rules:care") throws -> InstructionSection {
  try Instructions.validateSource(Data(text.utf8), id: id)
}

@Suite("Instructions file format")
struct UnitFormatTests {
  @Test func readsFrontMatterAndKeepsTheBodyAsWritten() throws {
    let section = try unit(
      "---\ndescription: Flag unsupported claims.\n---\n\n## Code Review Rules\n\n### Claims\n\n- Flag claims.\n\n\n"
    )
    #expect(section.description == "Flag unsupported claims.")
    #expect(section.level == 2)
    #expect(section.heading == "Code Review Rules")
    #expect(section.paths.isEmpty)
    #expect(section.directory.isEmpty)
    #expect(
      try Instructions.render([section])
        == generated(["## Code Review Rules\n\n### Claims\n\n- Flag claims."]))
  }

  @Test func scopesPathsAfterTheFirstHeading() throws {
    let section = try unit(
      "---\ndescription: Rendering.\npaths:\n  - \"Sources/Render/**/*.swift\"\n  - Sources/Render/Shaders/**\n---\n# Rendering\nKeep frames stable.\n"
    )
    #expect(section.paths == ["Sources/Render/**/*.swift", "Sources/Render/Shaders/**"])
    #expect(section.directory == "Sources/Render")
    #expect(
      try Instructions.render([section])
        == generated([
          "# Rendering\n\nApplies when working on files matching `Sources/Render/**/*.swift`, `Sources/Render/Shaders/**`.\n\nKeep frames stable."
        ]))
    let headingOnly = try unit(
      "---\ndescription: d\npaths: [\"Docs/**\"]\n---\n# Docs\n")
    #expect(
      try Instructions.render([headingOnly])
        == generated(["# Docs\n\nApplies when working on files matching `Docs/**`."]))
  }

  @Test(arguments: [
    (["Sources/**/*.swift"], "Sources"), (["Sources/A/**", "Sources/B/**"], "Sources"),
    (["**/*.swift"], ""), (["Docs/guide.md"], "Docs"), (["a/b/c.md", "a/b/d/**"], "a/b"),
    (["a/b/**", "c/**"], ""), (["a?/b/**"], ""),
  ])
  func placesSectionsInTheSharedLiteralDirectory(_ paths: [String], _ directory: String) {
    #expect(Instructions.directory(for: paths) == directory)
  }

  @Test(arguments: [
    "description: \"Quoted: value\"\n", "description: 'It''s quoted'\n",
    "# comment\ndescription: Plain text\n\n",
  ])
  func acceptsTheDocumentedScalarForms(_ front: String) throws {
    let section = try unit("---\n" + front + "---\n# Rules\n")
    #expect(!section.description.isEmpty)
    #expect(!section.description.hasPrefix("\"") && !section.description.hasPrefix("'"))
  }

  @Test(arguments: [
    "# Rules\n", "---\ndescription: d\n# Rules\n", "---\n---\n# Rules\n",
    "---\ndescription:\n---\n# Rules\n", "---\ndescription: d\ntitle: t\n---\n# Rules\n",
    "---\ndescription: d\ndescription: e\n---\n# Rules\n", "---\ndescription: a: b\n---\n# Rules\n",
    "---\ndescription: [d]\n---\n# Rules\n", "---\ndescription: d\npaths: []\n---\n# Rules\n",
    "---\ndescription: d\npaths: ['a/**']\n---\n# Rules\n",
    "---\ndescription: d\npaths:\n---\n# Rules\n", "---\n description: d\n---\n# Rules\n",
  ])
  func rejectsInvalidFrontMatter(_ text: String) {
    #expect(throws: InstructionError.self) { try unit(text) }
  }

  @Test(arguments: ["../outside/**", "/absolute/**", "a//b", "a/./b", "a/**b/c", "a/[x]", "a/{b}"])
  func rejectsInvalidPathPatterns(_ pattern: String) {
    #expect(throws: InstructionError.self) {
      try unit("---\ndescription: d\npaths: [\"\(pattern)\"]\n---\n# Rules\n")
    }
  }

  @Test(arguments: [
    "Text first.\n# Rules\n", "Rules\n=====\n", "## Rules\n# Higher\n", "## Rules\n## Same\n",
    "# Rules\n\n> Quoted\n> ---\n", "# Rules\n```\nopen\n", "# Rules\n<div>\nopen\n", "",
  ])
  func rejectsBodiesWithoutOneLeadingHeading(_ body: String) {
    #expect(throws: InstructionError.self) { try unit("---\ndescription: d\n---\n" + body) }
  }

  @Test func acceptsByteOrderMarkAndCRLFAndHashesOriginalBytes() throws {
    let plain = Data("---\ndescription: d\n---\n# Rules\nBody\n".utf8)
    let crlf =
      Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ndescription: d\r\n---\r\n# Rules\r\nBody\r\n".utf8)
    let first = try Instructions.validateSource(plain, id: "a")
    let second = try Instructions.validateSource(crlf, id: "a")
    #expect(try Instructions.render([first]) == Instructions.render([second]))
    #expect(first.hash != second.hash)
  }

  @Test func rejectsInvalidUTF8() {
    #expect(throws: InstructionError.invalidUTF8) {
      try Instructions.validateSource(Data([0xFF]), id: "bad")
    }
  }
}
