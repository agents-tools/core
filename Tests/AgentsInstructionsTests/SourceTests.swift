import AgentsInstructions
import Foundation
import Testing

let beginMarker =
  "<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->"
let endMarker = "<!-- END managed by agents -->"

func source(_ text: String = "# Rules\nUse care.\n", id: String = "rules:care") throws
  -> InstructionSection
{
  try Instructions.validateSource(Data(text.utf8), id: id)
}

func text(_ result: InstructionAssembly) -> String {
  String(decoding: result.bytes, as: UTF8.self)
}

func block(_ content: String) -> String {
  beginMarker + "\n" + content + "\n" + endMarker + "\n"
}

@Suite("Instruction sources")
struct InstructionSourceTests {
  @Test func validatesATXSource() throws {
    let section = try source("# Rules  ###\nBody\n\n## Detail\nMore\n")
    #expect(section.id == "rules:care")
    #expect(section.heading == "Rules")
    #expect(section.hash.hasPrefix("sha256:"))
    #expect(section.hash.count == 71)
  }

  @Test(arguments: [
    "", "Body\n", "Body\n# Rules\n", "## Detail\n# Rules\n", "# One\n# Two\n",
    "Title\n===\n", "# Title\n\nDetail\n---\n", "#No space\n", "####### Too deep\n",
  ])
  func rejectsInvalidSourceStructure(_ input: String) {
    #expect(throws: InstructionError.self) { try source(input) }
  }

  @Test(arguments: ["```", "~~~~ swift", "   ```swift", "    code", "\tcode"])
  func rejectsSourceEndingInCode(_ opening: String) {
    #expect(throws: InstructionError.self) { try source("# Rules\n\n" + opening + "\n\n") }
  }

  @Test(arguments: [
    "```\n# Hidden\n```", "~~~~\n# Hidden\n~~~\n~~~~", "    # Hidden\n    text", "\t# Hidden",
  ])
  func ignoresCodeHeadings(_ code: String) throws {
    let section = try source("# Rules\n\n" + code + "\n\nEnd.\n")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(text(result).contains("## Rules\n"))
    #expect(text(result).contains(code))
    #expect(!text(result).contains("## Hidden"))
  }

  @Test func ignoresMarkersInsideCode() throws {
    let code =
      "```html\n\(beginMarker)\n\(endMarker)\n```\n\n    \(beginMarker)\n    \(endMarker)\n\nEnd."
    let section = try source("# Rules\n\n" + code)
    let result = try Instructions.assemble(Data(), sections: [section])
    #expect(text(result).contains(code))
    #expect(try Instructions.assemble(result.bytes, sections: [section]).bytes == result.bytes)
  }

  @Test func rejectsStructuralSourceMarker() {
    #expect(throws: InstructionError.self) { try source("# Rules\n\(beginMarker)\n") }
  }

  @Test func rejectsInvalidUTF8() {
    #expect(throws: InstructionError.invalidUTF8) {
      try Instructions.validateSource(Data([0xFF]), id: "invalid")
    }
    #expect(throws: InstructionError.invalidUTF8) {
      try Instructions.assemble(Data([0xFF]), sections: [source()])
    }
  }

  @Test func normalizesLineEndingsAndTrailingBlanks() throws {
    let section = try source("# Rules\r\nBody\r\n\r\n \t\r\n")
    let result = try Instructions.assemble(Data(), sections: [section])
    #expect(text(result) == block("# Rules\nBody"))
    #expect(try section.hash != source("# Rules\nBody\n").hash)
  }

  @Test func shiftsOnlyStructuralATXHeadings() throws {
    let section = try source("# Rules\n\n## Detail ##\n\n```\n###### Example\n```\n")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(result.block == block("## Rules\n\n### Detail ##\n\n```\n###### Example\n```"))
  }

  @Test func rejectsFalseFenceCloser() {
    #expect(throws: InstructionError.self) { try source("# Rules\n```swift\nx\n``` trailing\n") }
    #expect(throws: InstructionError.self) { try source("# Rules\n````\nx\n```\n") }
  }

  @Test func backtickInfoCannotContainBackticks() throws {
    let section = try source("# Rules\n\n```not`a`fence\n\n## Detail\n")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(text(result).contains("### Detail\n"))
  }
  @Test func ignoresFencedCodeOpenedInList() throws {
    let code = "- ```\n  # Hidden\n  \(beginMarker)\n  ```"
    let section = try source("# Rules\n\n" + code + "\n\nEnd.\n")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(text(result).contains(code))
  }

  @Test func ignoresHeadingsAndMarkersInsideHTML() throws {
    let html = "<!--\n# Hidden\n\(beginMarker)\n-->\n\n<pre>\n# Hidden\n\(endMarker)\n</pre>"
    let section = try source("# Rules\n\n" + html + "\n\nEnd.\n")
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    #expect(text(result).contains(html))
  }

  @Test func recognizesMultilineSetextTitle() throws {
    let result = try Instructions.assemble(
      Data("Project\nGuide\n====\n".utf8), sections: [source()])
    #expect(result.headingOffset == 1)
    #expect(text(result).hasPrefix("Project\nGuide\n====\n\n"))
  }

  @Test func thematicBreakDoesNotBecomeHeading() throws {
    let section = try source("# Rules\n\n---\n\nBody\n")
    #expect(
      try Instructions.assemble(Data(), sections: [section]).block
        == block("# Rules\n\n---\n\nBody"))
  }

}
