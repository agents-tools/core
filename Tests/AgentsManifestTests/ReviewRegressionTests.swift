import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Manifest review regressions")
struct ReviewRegressionTests {
  @Test func oversizedExplicitInsertionIsRejectedBeforeRendering() throws {
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try probe(
      "oversized-direct-insert",
      Array((manifestHeader + "let agents = Agents(components: [])").utf8),
      extraArguments: ["--edit-oversized"], in: directory)
    #expect(result.report.status == "manifest.limit")
    #expect(result.report.stage == "editing")
    #expect(result.report.peakMemoryBytes < 67_108_864)
  }

  @Test func inferredConstantsRetainContextDuringReplacement() throws {
    let doc = try document(
      "let recipient = Agent.codex\nlet agents = Agents(defaultAgents: [recipient])")
    let change = try edited(
      doc,
      [
        .replaceConstant(
          doc.constant(named: "recipient")!, with: .agent(.cursor),
          acceptingUses: doc.uses(ofConstant: "recipient"))
      ])
    #expect(change.declaration.defaultAgents == ["cursor"])
    let array = try document(
      "let recipients = [Agent.codex]\nlet agents = Agents(defaultAgents: recipients)")
    let changed = try edited(
      array,
      [
        .replaceConstant(
          array.constant(named: "recipients")!, with: .array([.agent(.cursor)]),
          acceptingUses: array.uses(ofConstant: "recipients"))
      ])
    #expect(changed.declaration.defaultAgents == ["cursor"])
    let unused = try document("let recipient = Agent.codex\nlet agents = Agents()")
    let unusedChange = try unused.preparing([
      .replaceConstant(
        unused.constant(named: "recipient")!, with: .agent(.cursor), acceptingUses: [])
    ])
    #expect(unusedChange.delta.changedPointers.isEmpty)
    #expect(!unusedChange.patches.isEmpty)
    let changedDefault = try doc.preparing([
      .replaceConstant(
        doc.constant(named: "recipient")!, with: .agent(.cursor),
        acceptingUses: doc.uses(ofConstant: "recipient"))
    ])
    #expect(changedDefault.delta.changedPointers == ["/defaultAgents/0"])
  }

  @Test func consistentFourSpaceIndentationIsInheritedAndConflictsAreRejected() throws {
    let doc = try document(
      """
      let agents = Agents(
          components: [
              .ignore(name: "first", patterns: []),
          ]
      )
      """)
    let change = try edited(doc, [.insertComponent(.instructions(), into: .root, at: .last)])
    #expect(String(decoding: change.bytes, as: UTF8.self).contains("\n        .instructions(),"))
    let replacement = try edited(
      doc,
      [.replaceComponent(doc.node(at: "/components/0")!, with: .ignore(name: "new", patterns: []))])
    #expect(
      String(decoding: replacement.bytes, as: UTF8.self).contains("\n            name: \"new\","))
    let withoutComma = try document(
      """
      let agents = Agents(
          components: [
              .ignore(name: "first", patterns: [])
          ]
      )
      """)
    let longPattern = String(repeating: "x", count: 80)
    let replaced = try edited(
      withoutComma,
      [
        .replaceComponent(
          withoutComma.node(at: "/components/0")!,
          with: .ignore(name: "new", patterns: [longPattern]))
      ])
    #expect(String(decoding: replaced.bytes, as: UTF8.self).contains("\"\(longPattern)\"\n"))
    let multiline = try document(
      """
      let agents = Agents(
          components: [
              .ignore(
                  name: "first",
                  patterns: [
                      "first",
                  ]
              ),
          ]
      )
      """)
    let withComma = try edited(
      multiline,
      [
        .replaceComponent(
          multiline.node(at: "/components/0")!,
          with: .ignore(name: "new", patterns: [longPattern]))
      ])
    #expect(String(decoding: withComma.bytes, as: UTF8.self).contains("\"\(longPattern)\",\n"))
    let mixed = try document(
      """
      let agents = Agents(
        components: [
          .ignore(name: "first", patterns: []),
           .ignore(name: "second", patterns: []),
        ]
      )
      """)
    #expect(throws: ManifestFailure.self) {
      try mixed.preparing([.insertComponent(.instructions(), into: .root, at: .last)])
    }
  }

  @Test func normalizedRequirementParentsKeepTheCompleteReferenceOriginChain() throws {
    let doc = try document(
      """
      let minimum: Version = "1.2.0"
      let alias: Version = minimum
      let agents = Agents(sources: [.source(name: "s", path: "s", from: alias)])
      """)
    for pointer in ["/sources/0/requirement", "/sources/0/requirement/from"] {
      let location = try #require(doc.sourceMap.locations(at: pointer).first)
      #expect(
        String(decoding: doc.bytes[location.span.start..<location.span.end], as: UTF8.self)
          == "alias")
      #expect(
        location.origins.map {
          String(decoding: doc.bytes[$0.start..<$0.end], as: UTF8.self)
        } == ["minimum", "\"1.2.0\""])
    }
  }
}
