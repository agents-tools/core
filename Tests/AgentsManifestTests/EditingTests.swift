import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

func edited(_ doc: DeclarationDocument, _ edits: [ManifestEdit]) throws -> DeclarationDocument {
  let change = try doc.preparing(edits)
  #expect(change.originalDigest == doc.digest)
  var applied = doc.bytes
  for patch in change.patches.reversed() {
    applied.replaceSubrange(patch.range, with: patch.replacement)
  }
  #expect(applied == change.bytes)
  for pair in zip(change.patches, change.patches.dropFirst()) {
    #expect(pair.0.range.upperBound <= pair.1.range.lowerBound)
  }
  let result = try DeclarationDocument(bytes: change.bytes, identity: DocumentIdentity("manifest"))
  #expect(result.declaration == change.expectedDeclaration)
  return result
}

@Suite("Manifest document editing")
struct EditingTests {
  @Test func rootArgumentsUseSignatureOrderAndCanonicalSourceRequirements() throws {
    let initial = try document("let agents = Agents()")
    let result = try edited(
      initial,
      [
        .setWatch(["rules"]), .setExports(["review"]),
        .upsertGroup(.group(name: "review")),
        .upsertSource(.source(name: "rules", url: "intranet/team.git", "1.2.0"..<"1.3.0")),
        .setDefaultAgents([.codex]),
      ])
    let source = String(decoding: result.bytes, as: UTF8.self)
    let order = ["defaultAgents:", "exports:", "sources:", "groups:", "watch:"].map {
      source.range(of: $0)!.lowerBound
    }
    #expect(zip(order, order.dropFirst()).allSatisfy { $0 < $1 })
    #expect(source.contains("https://intranet/team.git"))
    #expect(source.contains(".upToNextMinor(from: \"1.2.0\")"))
    #expect(result.declaration.defaultAgents == ["codex"])
    let major = try edited(
      result,
      [.upsertSource(.source(name: "rules", url: "https://intranet/team.git", "1.2.0"..<"2.0.0"))])
    #expect(String(decoding: major.bytes, as: UTF8.self).contains("from: \"1.2.0\""))
    let range = try edited(
      major,
      [.upsertSource(.source(name: "rules", url: "https://intranet/team.git", "1.2.0"..<"1.8.0"))])
    #expect(String(decoding: range.bytes, as: UTF8.self).contains("\"1.2.0\"..<\"1.8.0\""))
  }

  @Test func everyComponentSectionPromptAndOverrideOperation() throws {
    var doc = try document(
      "let agents = Agents(sources: [.source(name: \"s\", path: \"s\")], components: [.skills(source: \"s\"), .instructions(sections: [\"guide\", \"second\"])], groups: [.group(name: \"g\")])"
    )
    doc = try edited(
      doc, [.insertComponent(.ignore(name: "ignore", patterns: []), into: .root, at: .first)])
    doc = try edited(
      doc,
      [
        .replaceComponent(
          doc.node(at: "/components/0")!, with: .ignore(name: "replacement", patterns: [".build/"]))
      ])
    doc = try edited(doc, [.setSkillSelection(doc.node(at: "/components/1")!, ["a", "b"])])
    doc = try edited(
      doc, [.upsertSkillOverride(doc.node(at: "/components/1")!, .skill(name: "a", mode: .copy))])
    doc = try edited(doc, [.removeSkillOverride(doc.node(at: "/components/1")!, name: "a")])
    doc = try edited(
      doc, [.insertSection("third", into: doc.node(at: "/components/2")!, at: .last)])
    doc = try edited(doc, [.moveSection(doc.node(at: "/components/2/sections/2")!, at: .first)])
    #expect(
      doc.declaration.components[2]["sections"]?.elements?.first?.record?["name"]
        == .string("third"))
    doc = try edited(doc, [.removeSection(doc.node(at: "/components/2/sections/1")!)])
    doc = try edited(
      doc,
      [.upsertPrompt(doc.node(at: "/components/2")!, .prompt(name: "weekly", sections: ["guide"]))])
    doc = try edited(doc, [.removePrompt(doc.node(at: "/components/2")!, name: "weekly")])
    doc = try edited(
      doc,
      [
        .moveComponent(
          doc.node(at: "/components/0")!, into: .group(doc.node(at: "/groups/0")!), at: .last)
      ])
    #expect(doc.declaration.components.count == 2)
    #expect(doc.declaration.groups[0]["components"]?.elements?.count == 1)
    doc = try edited(doc, [.insertGroupReference("g", into: .root, at: .first)])
    doc = try edited(doc, [.removeGroupReference(doc.node(at: "/uses/0")!)])
    doc = try edited(doc, [.removeComponent(doc.node(at: "/groups/0/components/0")!)])
    doc = try edited(doc, [.removeGroup(name: "g")])
    doc = try edited(
      doc, [.removeComponent(doc.node(at: "/components/0")!), .removeSource(alias: "s")])
    #expect(doc.declaration.sources.isEmpty)
  }

  @Test func dictionaryEntryEditsPreserveUnrelatedBytesAndHandleNegativeBoundaries() throws {
    var doc = try document(
      "let agents = Agents(components: [.lspServer(name: \"s\", run: .executable(\"tool\"), languages: [\".swift\": \"swift\"], initializationOptions: [\"x\":/* note */0, \"other\": true])])"
    )
    let original = String(decoding: doc.bytes, as: UTF8.self)
    doc = try edited(
      doc,
      [
        .setDictionaryEntry(
          doc.node(at: "/components/0/initializationOptions")!, key: "x", value: .configuration(-1))
      ])
    let replaced = String(decoding: doc.bytes, as: UTF8.self)
    #expect(replaced == original.replacingOccurrences(of: "/* note */0", with: "/* note */ -1"))
    doc = try edited(
      doc,
      [
        .setDictionaryEntry(
          doc.node(at: "/components/0/initializationOptions")!, key: "added",
          value: .configuration(["nested": nil]))
      ])
    doc = try edited(
      doc,
      [.removeDictionaryEntry(doc.node(at: "/components/0/initializationOptions")!, key: "added")])
    #expect(String(decoding: doc.bytes, as: UTF8.self).contains("\"other\": true"))
    #expect(throws: ManifestFailure.self) {
      try doc.preparing([
        .setDictionaryEntry(
          doc.node(at: "/components/0/languages")!, key: ".js", value: .integer(3))
      ])
    }
  }

  @Test func wholeDefinitionReplacementAcceptsAllTransitiveUses() throws {
    let doc = try document(
      "let base: [String] = [\"one\"]\nlet alias = base\nlet agents = Agents(components: [.ignore(name: \"a\", patterns: base), .ignore(name: \"b\", patterns: alias)])"
    )
    let handle = doc.constant(named: "base")!
    let uses = doc.uses(ofConstant: "base")
    #expect(uses.count == 3)
    #expect(throws: ManifestFailure.self) {
      try doc.preparing([
        .replaceConstant(handle, with: .array([.string("two")]), acceptingUses: [])
      ])
    }
    let changed = try doc.preparing([
      .replaceConstant(handle, with: .array([.string("two")]), acceptingUses: uses)
    ])
    #expect(changed.impactedReferences.count == 3)
    let result = try DeclarationDocument(
      bytes: changed.bytes, identity: DocumentIdentity("manifest"))
    #expect(result.declaration.components[0]["patterns"] == .array([.string("two")]))
    #expect(result.declaration.components[1]["patterns"] == .array([.string("two")]))
  }

  @Test func commentsBOMCRLFFinalNewlineAndUnchangedRangesSurvive() throws {
    let text =
      "\u{feff}"
      + (manifestHeader
      + "// file\nlet agents = Agents(\n  components: [\n    // first owner\n    .ignore(name: \"first\", patterns: []), // trailing owner\n\n    // second owner\n    .ignore(name: \"second\", patterns: [])\n  ]\n)")
      .replacingOccurrences(of: "\n", with: "\r\n")
    let doc = try DeclarationDocument(
      bytes: Array(text.utf8), identity: DocumentIdentity("manifest"))
    let result = try edited(doc, [.removeComponent(doc.node(at: "/components/0")!)])
    let source = String(decoding: result.bytes, as: UTF8.self)
    #expect(source.hasPrefix("\u{feff}// agents-tools-version: 1.0\r\n"))
    #expect(!source.hasSuffix("\n"))
    #expect(!source.contains("first owner"))
    #expect(!source.contains("trailing owner"))
    #expect(source.contains("// second owner\r\n    .ignore(name: \"second\""))
    #expect(source.contains("// file\r\n"))
  }

  @Test func noOpsKeepOriginalBytesAndUnsafeEditsPublishNothing() throws {
    let doc = try document(
      "let agents = Agents(defaultAgents: nil, sources: [.source(name: \"s\", url: \"https://example.org/s.git\", \"1.2.0\" ..< \"2.0.0\")], components: [/*container*/])"
    )
    let noOp = try doc.preparing([
      .setDefaultAgents(nil),
      .upsertSource(.source(name: "s", url: "https://example.org/s.git", from: "1.2.0")),
    ])
    #expect(noOp.bytes == doc.bytes)
    #expect(noOp.patches.isEmpty)
    #expect(throws: ManifestFailure.self) {
      try doc.preparing([.insertComponent(.instructions(), into: .root, at: .first)])
    }
    let unrelated = try document("let agents = Agents()")
    #expect(throws: ManifestFailure.self) {
      try unrelated.preparing([.removeComponent(doc.node(at: "/sources/0")!)])
    }
    #expect(doc.bytes == noOp.bytes)
  }

  @Test func symbolicReferencesNeedCompleteRepairBatch() throws {
    let doc = try document(
      "let agents = Agents(exports: [\"g\"], sources: [.source(name: \"s\", path: \"s\")], groups: [.group(name: \"g\", components: [.skills(source: \"s\")])], uses: [\"g\"], watch: [\"s\"])"
    )
    #expect(throws: ManifestFailure.self) { try doc.preparing([.removeSource(alias: "s")]) }
    #expect(throws: ManifestFailure.self) { try doc.preparing([.removeGroup(name: "g")]) }
    let repaired = try edited(
      doc,
      [
        .removeSource(alias: "s"), .removeGroup(name: "g"),
        .removeGroupReference(doc.node(at: "/uses/0")!), .setExports([]), .setWatch([]),
      ])
    #expect(repaired.declaration.sources.isEmpty)
    #expect(repaired.declaration.groups.isEmpty)
  }

  @Test func replacementKeepsVersionSlotAndNegativeConstantBoundariesValid() throws {
    let doc = try document(
      "let number: [Int] = [/*keep*/0]\nlet minimum: Version = \"1.2.0\"\nlet agents = Agents(sources: [.source(name: \"s\", path: \"s\", from: minimum)])"
    )
    let changed = try edited(
      doc,
      [
        .replaceConstant(
          doc.constant(named: "minimum")!, with: .version("1.3.0"),
          acceptingUses: doc.uses(ofConstant: "minimum"))
      ])
    #expect(
      changed.declaration.sources[0]["requirement"] == .requirement(.upToNextMajor(from: "1.3.0")))
    let n = try document("let number: [Int] = [/*keep*/0]\nlet agents = Agents()")
    let scalar = try document("let number = 0\nlet agents = Agents()")
    let negative = try edited(
      scalar,
      [.replaceConstant(scalar.constant(named: "number")!, with: .integer(-1), acceptingUses: [])])
    #expect(String(decoding: negative.bytes, as: UTF8.self).contains("let number = -1"))
    #expect(throws: ManifestFailure.self) {
      try n.preparing([
        .replaceConstant(
          n.constant(named: "number")!, with: .array([.integer(-1)]), acceptingUses: [])
      ])
    }
  }
  @Test func movesCarryLeadingAndTrailingCommentsAndDictionaryEntriesOwnTheirTrivia() throws {
    let doc = try document(
      """
      let agents = Agents(
        components: [
          // follows first
          .ignore(name: "first", patterns: []), // inline owner
          .ignore(name: "second", patterns: [])
        ],
        groups: [.group(name: "g")]
      )
      """)
    let moved = try edited(
      doc,
      [
        .moveComponent(
          doc.node(at: "/components/0")!, into: .group(doc.node(at: "/groups/0")!), at: .last)
      ])
    let text = String(decoding: moved.bytes, as: UTF8.self)
    #expect(text.range(of: "// follows first")!.lowerBound > text.range(of: "groups:")!.lowerBound)
    #expect(text.contains("// inline owner"))
    let dictionary = try document(
      """
      let agents = Agents(components: [.lspServer(
        name: "s", run: .executable("tool"), languages: [".swift": "swift"],
        initializationOptions: [
          // remove with x
          "x": /* inside x */ 1, // after x

          // keep with y
          "y": true
        ]
      )])
      """)
    let removed = try edited(
      dictionary,
      [
        .removeDictionaryEntry(
          dictionary.node(at: "/components/0/initializationOptions")!, key: "x")
      ])
    let result = String(decoding: removed.bytes, as: UTF8.self)
    #expect(!result.contains("remove with x"))
    #expect(!result.contains("inside x"))
    #expect(!result.contains("after x"))
    #expect(result.contains("keep with y"))
  }

}
