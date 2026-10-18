import AgentsInstructions
import Foundation
import Testing

@Suite("Instruction assembly")
struct InstructionAssemblyTests {
  @Test func declaresSectionOrderAndKeepsSubsections() throws {
    let sections = try [
      source("# First\na\n\n## Child\nb\n"), source("# Second\nc\n", id: "other"),
    ]
    let result = try Instructions.assemble(Data(), sections: sections)
    #expect(result.block == block("# First\na\n\n## Child\nb\n\n# Second\nc"))
    #expect(!result.hasCustomContent)
  }

  @Test func sectionStopsAtSameOrHigherHeading() throws {
    let target = "# Rules\nUse care.\n\n# Other\nKeep exactly.\n"
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [source()], options: .init(headingOffset: 0))
    #expect(result.adoptedSections == ["rules:care"])
    #expect(text(result) == block("# Rules\nUse care.") + "\n# Other\nKeep exactly.\n")
  }

  @Test func lowerHeadingBelongsToMatchedSection() throws {
    let target = "# Rules\nUse care.\n\n## Custom child\nOwned by the section.\n"
    #expect(throws: InstructionError.self) {
      try Instructions.assemble(Data(target.utf8), sections: [source()])
    }
  }

  @Test func replacesExistingContiguousBlockInPlace() throws {
    let target = "Before\n\n" + block("# Old\nOld text.") + "\n# After\nKeep\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(text(result) == "Before\n\n" + block("# Rules\nUse care.") + "\n# After\nKeep\n")
    #expect(result.blockDifference?.contains("-Old text.") == true)
  }

  @Test(arguments: [
    beginMarker, endMarker, beginMarker + "\n" + beginMarker + "\n" + endMarker,
    block("# One") + block("# Two"), endMarker + "\n" + beginMarker,
  ])
  func rejectsMalformedMarkers(_ target: String) {
    #expect(throws: InstructionError.self) {
      try Instructions.assemble(Data(target.utf8), sections: [source()])
    }
    #expect(throws: InstructionError.self) { try Instructions.remove(from: Data(target.utf8)) }
  }

  @Test func markerErrorsIncludeLocations() {
    #expect(throws: InstructionError.unpairedMarker(line: 2)) {
      try Instructions.remove(from: Data("text\n\(endMarker)\n".utf8))
    }
    #expect(throws: InstructionError.nestedMarker(line: 2)) {
      try Instructions.remove(from: Data("\(beginMarker)\n\(beginMarker)\n".utf8))
    }
    #expect(throws: InstructionError.multipleBlocks) {
      try Instructions.remove(from: Data((block("a") + block("b")).utf8))
    }
  }

  @Test func targetCodeMarkersAndHeadingsAreIgnored() throws {
    let custom =
      "```\n# Fake title\n\(beginMarker)\n```\n\n    # Fake title\n    \(endMarker)\n\nEnd\n"
    let result = try Instructions.assemble(Data(custom.utf8), sections: [source()])
    #expect(result.headingOffset == 0)
    #expect(text(result) == block("# Rules\nUse care.") + "\n" + custom)
  }

  @Test func titleShiftsHeadings() throws {
    let result = try Instructions.assemble(Data("# Guide\n".utf8), sections: [source()])
    #expect(result.headingOffset == 1)
    #expect(result.block == block("## Rules\nUse care."))
  }

  @Test func selectedOnlyH1IsAdoptedWithoutOffset() throws {
    let result = try Instructions.assemble(Data("# Rules\nUse care.\n".utf8), sections: [source()])
    #expect(result.headingOffset == 0)
    #expect(result.adoptedSections == ["rules:care"])
    #expect(text(result) == block("# Rules\nUse care."))
    #expect(!result.hasCustomContent)
  }

  @Test func titleAfterBlockDoesNotShift() throws {
    let result = try Instructions.assemble(
      Data((block("# Old") + "\n# Later\n").utf8), sections: [source()])
    #expect(result.headingOffset == 0)
  }

  @Test func titleAppearanceAndDisappearanceRecomputeOffset() throws {
    let initial = try Instructions.assemble(Data(), sections: [source()])
    let withTitle = try Instructions.assemble(
      Data(("# Guide\n\n" + text(initial)).utf8), sections: [source()])
    #expect(withTitle.headingOffset == 1)
    let withoutTitle = try Instructions.assemble(
      Data(try #require(withTitle.block).utf8), sections: [source()])
    #expect(withoutTitle.headingOffset == 0)
    #expect(withoutTitle.bytes == initial.bytes)
  }

  @Test func installUsesLockedOffset() throws {
    let withTitle = try Instructions.assemble(
      Data("# Guide\n".utf8), sections: [source()], options: .init(headingOffset: 0))
    #expect(withTitle.headingOffset == 0)
    #expect(withTitle.block == block("# Rules\nUse care."))
    let withoutTitle = try Instructions.assemble(
      Data(), sections: [source()], options: .init(headingOffset: 1))
    #expect(withoutTitle.block == block("## Rules\nUse care."))
    #expect(
      try Instructions.assemble(
        withoutTitle.bytes, sections: [source()], options: .init(headingOffset: 1)
      ).bytes == withoutTitle.bytes)
  }

  @Test func levelSixIsValidWithoutShiftAndOverflowsWithTitle() throws {
    let section = try source("# Rules\n\n###### Deep\nBody\n")
    #expect(try Instructions.assemble(Data(), sections: [section]).headingOffset == 0)
    #expect(throws: InstructionError.headingOverflow(sectionID: section.id, level: 6, offset: 1)) {
      try Instructions.assemble(Data("# Guide\n".utf8), sections: [section])
    }
  }

  @Test(arguments: [-1, 2, Int.max])
  func rejectsInvalidOffset(_ offset: Int) {
    #expect(throws: InstructionError.invalidHeadingOffset(offset)) {
      try Instructions.assemble(Data(), sections: [source()], options: .init(headingOffset: offset))
    }
  }

  @Test func matchingCollapsesWhitespaceAndTrimsClosingHashes() throws {
    let result = try Instructions.assemble(
      Data("# Guide\n\n##  Be \t careful  ###\nOld\n".utf8),
      sections: [source("# Be careful\nNew\n")], options: .init(replaceConflicts: true))
    #expect(result.conflicts.count == 1)
    #expect(result.conflicts.first?.existing.hasPrefix("##  Be") == true)
    #expect(!text(result).contains("Old"))
  }

  @Test func matchingRequiresLevelAndCase() throws {
    let target = "# Guide\n\n### Rules\nKeep\n\n## rules\nKeep also\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(result.adoptedSections.isEmpty)
    #expect(result.conflicts.isEmpty)
    #expect(text(result).hasSuffix("### Rules\nKeep\n\n## rules\nKeep also\n"))
  }

  @Test func rejectsAmbiguousCustomMatches() {
    #expect(throws: InstructionError.ambiguousMatch(sectionID: "rules:care", lines: [3, 6])) {
      try Instructions.assemble(
        Data("# Guide\n\n## Rules\na\n\n## Rules\nb\n".utf8), sections: [source()])
    }
  }

  @Test func rejectsDuplicateSelectedHeadingsAcrossSources() {
    #expect(
      throws: InstructionError.duplicateHeading(
        heading: "Rules", sectionIDs: ["one:rules", "two:rules"])
    ) {
      try Instructions.assemble(
        Data(),
        sections: [source(id: "one:rules"), source("#  Rules ###\nOther\n", id: "two:rules")])
    }
  }

  @Test func placesAtEarliestMatchAndUsesDeclaredOrder() throws {
    let target = "# Guide\n\n## Second\nb\n\n## Custom\nKeep\n\n## First\na\n"
    let result = try Instructions.assemble(
      Data(target.utf8), sections: [source("# First\na\n"), source("# Second\nb\n", id: "second")])
    #expect(
      text(result) == "# Guide\n\n" + block("## First\na\n\n## Second\nb") + "\n## Custom\nKeep\n\n"
    )
    #expect(result.adoptedSections == ["rules:care", "second"])
  }

  @Test func placesAfterTitleBeforeFirstHeading() throws {
    let target = "# Guide\nIntro.\n\n## Custom\nKeep\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(
      text(result) == "# Guide\nIntro.\n\n" + block("## Rules\nUse care.") + "\n## Custom\nKeep\n")
  }

  @Test func appendsToFileWithOnlyTitle() throws {
    let result = try Instructions.assemble(Data("# Guide\nIntro.".utf8), sections: [source()])
    #expect(text(result) == "# Guide\nIntro.\n\n" + block("## Rules\nUse care."))
  }

  @Test func prependsWithoutTitle() throws {
    let target = "Preamble\n\n## Custom\nKeep"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(text(result) == block("# Rules\nUse care.") + "\n" + target)
  }

  @Test func reportsConflictsWithBothTextsAndDifference() throws {
    do {
      _ = try Instructions.assemble(Data("# Rules\nOld\n".utf8), sections: [source()])
      Issue.record("Expected a conflict")
    } catch InstructionError.conflictingSections(let conflicts) {
      let conflict = try #require(conflicts.first)
      #expect(conflict.existing == "# Rules\nOld")
      #expect(conflict.proposed == "# Rules\nUse care.")
      #expect(conflict.difference.contains("-Old\n+Use care."))
      #expect(
        InstructionError.conflictingSections(conflicts).description.contains(conflict.difference))
    }
  }

  @Test func replacementReturnsConflictsForCallerPreview() throws {
    let result = try Instructions.assemble(
      Data("# Rules\nOld\n".utf8), sections: [source()], options: .init(replaceConflicts: true))
    #expect(result.conflicts.count == 1)
    #expect(result.adoptedSections.isEmpty)
    #expect(text(result) == block("# Rules\nUse care."))
  }

  @Test func adoptsNormalizedIdenticalContent() throws {
    let result = try Instructions.assemble(
      Data("# Rules\r\nUse care.\r\n\r\n".utf8), sections: [source()])
    #expect(result.adoptedSections == ["rules:care"])
    #expect(result.conflicts.isEmpty)
    #expect(text(result) == block("# Rules\nUse care."))
  }

  @Test func preservesCustomCRLFAndNormalizesOwnedRegion() throws {
    let target =
      "# Guide\r\n\r\n" + block("## Old\nOld").replacingOccurrences(of: "\n", with: "\r\n")
      + "\r\n## Custom\r\nBytes  \r\n\r\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(
      text(result) == "# Guide\r\n\n" + block("## Rules\nUse care.")
        + "\n## Custom\r\nBytes  \r\n\r\n")
  }

  @Test func preservesExtraCustomBlankLines() throws {
    let target = "Before\r\n\r\n\r\n" + block("# Old") + "\r\n\r\nAfter\r\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(text(result) == "Before\r\n\r\n\n" + block("# Rules\nUse care.") + "\n\r\nAfter\r\n")
    #expect(try Instructions.assemble(result.bytes, sections: [source()]).bytes == result.bytes)
  }

  @Test func rejectsAssemblyWhoseMarkersAreSwallowedByCode() {
    #expect(throws: InstructionError.invalidAssembly) {
      try Instructions.assemble(Data("# Guide\n\n```\nUnclosed\n".utf8), sections: [source()])
    }
  }

  @Test(arguments: [
    "", "# Guide\n", "Custom\r\n", "# Rules\nUse care.\n", "Guide\n=====\n\n## Custom\nX\n",
  ])
  func assemblyIsIdempotent(_ target: String) throws {
    let first = try Instructions.assemble(Data(target.utf8), sections: [source()])
    let second = try Instructions.assemble(first.bytes, sections: [source()])
    #expect(second.bytes == first.bytes)
    #expect(second.blockHash == first.blockHash)
    #expect(second.blockDifference == nil)
  }

  @Test func recognizesSetextTitle() throws {
    let result = try Instructions.assemble(
      Data("Project Guide\n=============\nIntro\n\nCustom\n------\nKeep\n".utf8),
      sections: [source()])
    #expect(result.headingOffset == 1)
    #expect(
      text(result) == "Project Guide\n=============\nIntro\n\n" + block("## Rules\nUse care.")
        + "\nCustom\n------\nKeep\n")
  }

  @Test func setextSelectedHeadingIsAMatchRatherThanTitle() throws {
    let result = try Instructions.assemble(
      Data("Rules\n=====\nUse care.\n".utf8), sections: [source()],
      options: .init(replaceConflicts: true))
    #expect(result.headingOffset == 0)
    #expect(result.conflicts.count == 1)
    #expect(!result.hasCustomContent)
  }

  @Test func removesLastSectionAndSeparators() throws {
    let target = "# Guide\r\n\r\n" + block("## Rules\nUse care.") + "\r\n## Custom\r\nKeep\r\n\r\n"
    let result = try Instructions.remove(from: Data(target.utf8))
    #expect(text(result) == "# Guide\r\n## Custom\r\nKeep\n")
    #expect(result.block == nil)
    #expect(result.blockHash == nil)
    #expect(result.hasCustomContent)
    #expect(try Instructions.assemble(Data(target.utf8), sections: []).bytes == result.bytes)
  }

  @Test func removingOnlyBlockLeavesNoCustomContent() throws {
    let result = try Instructions.remove(from: Data(block("# Rules\nUse care.").utf8))
    #expect(result.bytes.isEmpty)
    #expect(!result.hasCustomContent)
  }

  @Test func removalWithoutBlockPreservesBytes() throws {
    let custom = Data("Custom\r\n\r\n".utf8)
    #expect(try Instructions.remove(from: custom).bytes == custom)
    #expect(try Instructions.remove(from: custom).hasCustomContent)
  }

  @Test func removingSomeSectionsKeepsBlock() throws {
    let initial = try Instructions.assemble(
      Data(), sections: [source(), source("# Other\nX\n", id: "other")])
    let result = try Instructions.assemble(initial.bytes, sections: [source()])
    #expect(result.block == block("# Rules\nUse care."))
    #expect(!result.hasCustomContent)
  }

  @Test func reportsOnlySharedSourceQualifiedScopeIdentities() {
    #expect(
      Instructions.sectionsInBothScopes(
        user: ["one:rules", "two:other"], project: ["two:other", "one:rules", "one:rules"]) == [
          "two:other", "one:rules",
        ])
    #expect(Instructions.sectionsInBothScopes(user: ["one:rules"], project: ["two:rules"]).isEmpty)
    #expect(Instructions.sectionsInBothScopes(user: [], project: ["one:rules"]).isEmpty)
  }
  @Test func rejectsAssemblyWhoseMarkersAreSwallowedByHTML() throws {
    #expect(throws: InstructionError.invalidAssembly) {
      try Instructions.assemble(Data("# Guide\n\n<!-- unclosed\n".utf8), sections: [source()])
    }
    let section = try source("# Rules\n<!-- unclosed\n")
    #expect(throws: InstructionError.invalidAssembly) {
      try Instructions.assemble(Data(), sections: [section])
    }
  }

  @Test func equivalentUnicodeWithDifferentBytesIsAConflict() throws {
    let result = try Instructions.assemble(
      Data("# Rules\ncaf\u{65}\u{301}\n".utf8), sections: [source("# Rules\ncaf\u{e9}\n")],
      options: .init(replaceConflicts: true))
    let conflict = try #require(result.conflicts.first)
    #expect(conflict.difference.contains("-caf\u{65}\u{301}\n+caf\u{e9}\n"))
    #expect(result.adoptedSections.isEmpty)
  }

  @Test func sectionBeforeMarkerDoesNotConsumeManagedBlockOrFollowingCustom() throws {
    let target = "# Rules\nUse care.\n\n" + block("# Old\nOld") + "\n# Other\nCustom\n"
    let result = try Instructions.assemble(Data(target.utf8), sections: [source()])
    #expect(result.adoptedSections == ["rules:care"])
    #expect(text(result) == block("# Rules\nUse care.") + "\n# Other\nCustom\n")
  }

}
