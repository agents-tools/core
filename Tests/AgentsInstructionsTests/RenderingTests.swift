import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction rendering and drift")
struct InstructionRenderingTests {
  @Test func detectsCleanDriftAndMissingBlock() throws {
    let result = try Instructions.assemble(Data(), sections: [source()])
    let hash = try #require(result.blockHash)
    #expect(try Instructions.detectDrift(in: result.bytes, lockedBlockHash: hash) == .clean)
    let changed = Data(text(result).replacingOccurrences(of: "Use care.", with: "Changed.").utf8)
    let drift = try Instructions.detectDrift(
      in: changed, lockedBlockHash: hash, lockedBlock: result.block)
    guard case .drifted(let actual, let difference) = drift else {
      Issue.record("Expected block drift")
      return
    }
    #expect(actual == block("# Rules\nChanged."))
    #expect(difference?.contains("-Use care.\n+Changed.") == true)
    #expect(
      try Instructions.detectDrift(in: Data("Custom\n".utf8), lockedBlockHash: hash)
        == .missingBlock)
  }

  @Test func hashOnlyDriftDoesNotInventBaselineText() throws {
    let result = try Instructions.assemble(Data(), sections: [source()])
    let drift = try Instructions.detectDrift(in: result.bytes, lockedBlockHash: "sha256:different")
    #expect(drift == .drifted(actualBlock: try #require(result.block), difference: nil))
  }

  @Test func driftIgnoresCustomChangesAndNormalizesBlockLineEndings() throws {
    let result = try Instructions.assemble(Data(), sections: [source()])
    let target =
      "Custom\r\n\r\n" + text(result).replacingOccurrences(of: "\n", with: "\r\n")
      + "\r\nChanged custom\r\n"
    #expect(
      try Instructions.detectDrift(
        in: Data(target.utf8), lockedBlockHash: #require(result.blockHash)) == .clean)
  }

  @Test func rejectsIncorrectLockedBaseline() throws {
    let result = try Instructions.assemble(Data(), sections: [source()])
    #expect(throws: InstructionError.invalidLockedBlock) {
      try Instructions.detectDrift(
        in: result.bytes, lockedBlockHash: #require(result.blockHash), lockedBlock: block("# Wrong")
      )
    }
  }

  @Test func driftRejectsMalformedTargetMarkers() {
    #expect(throws: InstructionError.unpairedMarker(line: 1)) {
      try Instructions.detectDrift(in: Data(beginMarker.utf8), lockedBlockHash: "any")
    }
  }

  @Test func blockHashIncludesMarkersAndSourceHashIncludesOriginalBytes() throws {
    let first = try Instructions.assemble(Data(), sections: [source()])
    let shifted = try Instructions.assemble(
      Data(), sections: [source()], options: .init(headingOffset: 1))
    #expect(first.blockHash != shifted.blockHash)
    #expect(try first.blockHash != source().hash)
    let paddedContent = text(first).replacingOccurrences(of: "Use care.", with: "Use care. ")
    guard
      case .drifted = try Instructions.detectDrift(
        in: Data(paddedContent.utf8), lockedBlockHash: #require(first.blockHash))
    else {
      Issue.record("Content whitespace is block drift")
      return
    }
  }

  @Test func restoresDriftedBlockWithLockedOffset() throws {
    let original = try Instructions.assemble(
      Data(), sections: [source()], options: .init(headingOffset: 1))
    let changed = Data(text(original).replacingOccurrences(of: "Use care.", with: "Drift").utf8)
    let restored = try Instructions.assemble(
      changed, sections: [source()], options: .init(headingOffset: 1))
    #expect(restored.bytes == original.bytes)
    #expect(restored.blockDifference?.contains("-Drift") == true)
  }

  @Test func chatGPTKeepsSourceHeadingsAndOrder() throws {
    let rendered = try Instructions.renderChatGPT(sections: [
      source("# One\n\n## Child\nA\n"), source("# Two\nB\n", id: "two"),
    ])
    #expect(String(decoding: rendered, as: UTF8.self) == "# One\n\n## Child\nA\n\n# Two\nB\n")
  }

  @Test func chatGPTAppendsCustomBytes() throws {
    let rendered = try Instructions.renderChatGPT(
      sections: [source()], customContent: Data("Custom\r\nExact  ".utf8))
    #expect(String(decoding: rendered, as: UTF8.self) == "# Rules\nUse care.\n\nCustom\r\nExact  ")
    #expect(
      try Instructions.renderChatGPT(sections: [source()], customContent: Data())
        == Instructions.renderChatGPT(sections: [source()]))
  }

  @Test func chatGPTRejectsEmptySelectionAndInvalidCustomEncoding() {
    #expect(throws: InstructionError.emptyPrompt) {
      try Instructions.renderChatGPT(sections: [], customContent: Data("Only custom".utf8))
    }
    #expect(throws: InstructionError.invalidUTF8) {
      try Instructions.renderChatGPT(sections: [source()], customContent: Data([0xFF]))
    }
  }

  @Test func chatGPTRejectsDuplicateHeadings() {
    #expect(throws: InstructionError.self) {
      try Instructions.renderChatGPT(sections: [source(), source(id: "different")])
    }
  }
  @Test func missingFinalNewlineIsBlockDrift() throws {
    let result = try Instructions.assemble(Data(), sections: [source()])
    let changed = Data(text(result).dropLast().utf8)
    let drift = try Instructions.detectDrift(
      in: changed, lockedBlockHash: #require(result.blockHash), lockedBlock: result.block)
    guard case .drifted(_, let difference) = drift else {
      Issue.record("Expected final newline drift")
      return
    }
    #expect(difference?.contains("No newline at end of proposed text") == true)
  }

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

  @Test(arguments: ["@AGENTS.md", "@./AGENTS.md", "@rules/../AGENTS.md", "See @AGENTS.md"])
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
