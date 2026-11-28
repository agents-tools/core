import AgentsCore
import Components
import Foundation
import Testing

@Suite("Component linking review regressions")
struct LinkingReviewRegressionTests {
  @Test("Coalescing checks every overlapping hook and permission payload")
  func coalescingRejectsOverlapInEitherOrder() throws {
    let fixture = try LinkFixture()

    for kind in ["hook", "permissions"] {
      func component(_ payload: String, _ agent: String) -> String {
        let recipient = agent == "claudeCode" ? "claude-code" : agent
        if kind == "hook" {
          return
            "{kind: hook, name: shared, event: afterTool, run: {executable: \"\(payload)\"}, agents: [\(recipient)]}"
        }
        let rule = payload == "a" ? "allow" : "deny"
        return
          "{kind: permissions, name: shared, rules: [{effect: \(rule), operation: read, pattern: files/**}], agents: [\(recipient)]}"

      }

      let aCodex = component("a", "codex")
      let bClaude = component("b", "claudeCode")
      let aClaude = component("a", "claudeCode")
      let disjoint = try fixture.link(
        "version: 1\ncomponents: [\(aCodex), \(bClaude)]\n")
      #expect(disjoint.components.count == 2)
      let identical = try fixture.link(
        "version: 1\ncomponents: [\(aCodex), \(aClaude)]\n")
      let merged = try #require(identical.components.first)
      #expect(identical.components.count == 1)
      #expect(merged.recipients == [.codex, .claudeCode])
      #expect(merged.origins.count == 2)

      for components in [
        [aCodex, bClaude, aClaude],
        [aCodex, aClaude, bClaude],
      ] {
        do {
          _ = try fixture.link(
            "version: 1\ncomponents: [\(components.joined(separator: ", "))]\n")
          Issue.record("Expected conflicting \(kind) payloads to be rejected")
        } catch let error as LinkError {
          guard case .conflict(let key, _) = error else {
            Issue.record("Expected a \(kind) conflict, got \(error)")
            continue
          }
          #expect(key.name == "shared")
        }
      }
    }
  }

  @Test("Protected instruction order includes ordinary and named prompt sections")
  func protectedInstructionOrder() throws {
    let fixture = try LinkFixture()
    try fixture.instruction("a", at: fixture.project)
    try fixture.instruction("b", at: fixture.project)
    let drafts = fixture.root.appendingPathComponent("drafts")
    try fixture.skill("draft", at: drafts)

    for prompt in [false, true] {
      func declaration(_ sections: String, extra: Bool = false) -> String {
        let instruction =
          prompt
          ? "{kind: instructions, chatgpt: {review: {sections: [\(sections)]}}}"
          : "{kind: instructions, sections: [\(sections)], agents: [codex]}"
        let skill =
          extra
          ? "{kind: skills, source: drafts, select: [draft], mode: edit, agents: [codex]}," : ""
        let uses = extra ? "uses: [{group: empty}]" : ""
        return """
          version: 1
          sources: {drafts: {path: ../drafts}}
          components: [\(skill) \(instruction)]
          groups: {empty: {}}
          \(uses)
          watch: []
          """

      }

      let before = try fixture.link(declaration(#"{name: a}, {name: b}"#))
      let after = try fixture.link(declaration(#"{name: b}, {name: a}"#))
      let unrelated = try fixture.link(declaration(#"{name: a}, {name: b}"#, extra: true))
      let beforeSections = before.components.filter {
        $0.key.kind == .instructions && $0.chatGPT == prompt
      }
      let afterSections = after.components.filter {
        $0.key.kind == .instructions && $0.chatGPT == prompt
      }
      #expect(beforeSections.map(\.key.name) == ["a", "b"])
      #expect(afterSections.map(\.key.name) == ["b", "a"])
      #expect(!after.protectedChanges(from: before, allowing: [.skills]).isEmpty)
      #expect(unrelated.protectedChanges(from: before, allowing: [.skills]).isEmpty)
    }
  }

  @Test("Live edit sources consume the distinct snapshot budget")
  func liveEditSnapshotBudget() throws {
    let fixture = try LinkFixture()
    for index in 0..<257 {
      let directory = fixture.root.appendingPathComponent("source-\(index)")
      try fixture.skill("skill-\(index)", at: directory)
    }

    func declaration(distinct count: Int, repetitions: Int = 1) -> String {
      let sources = (0..<count).map {
        "\"source-\($0)\": {\"path\": \"../source-\($0)\"}"
      }.joined(separator: ",\n  ")
      let components = (0..<count).flatMap { index in
        Array(
          repeating:
            "{\"kind\": \"skills\", \"source\": \"source-\(index)\", \"select\": [\"skill-\(index)\"], \"mode\": \"edit\"}",
          count: repetitions)
      }.joined(separator: ",\n  ")
      return """
        version: 1
        sources: {\(sources)}
        components: [\(components)]
        """
    }

    let belowLimit = try fixture.link(declaration(distinct: 128))
    #expect(Set(belowLimit.components.map(\.key.name)).count == 128)

    let repeated = try fixture.link(declaration(distinct: 1, repetitions: 257))
    let repeatedOrigins = repeated.components
      .filter { $0.key.name == "skill-0" }
      .flatMap(\.origins)
    #expect(repeatedOrigins.count == 257)

    do {
      _ = try fixture.link(declaration(distinct: 257))
      Issue.record("Expected 257 distinct live sources to exceed the snapshot budget")
    } catch let error as LinkError {
      guard case .budget(let name) = error else {
        Issue.record("Expected a snapshot budget error, got \(error)")
        return
      }
      #expect(name.lowercased().contains("snapshot"))
    }
  }
}
