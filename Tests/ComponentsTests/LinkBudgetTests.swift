import AgentsCore
import Components
import Foundation
import Testing

@Suite("Observable component bounds", .serialized)
struct LinkBudgetTests {
  @Test func repeatedExportsShareExpandedManifestValueLimits() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("expanded-values")
    try fixture.initialize(producer)
    let prompt = String(repeating: "p", count: 100_000)
    try fixture.manifest(
      """
      let agents = Agents(exports: ["g"], groups: [.group(name: "g", components: [
        .command(name: "review", description: "Review", prompt: "\(prompt)")])])
      """, at: producer)
    try fixture.commit(producer)
    func expression(_ count: Int) -> String {
      let uses = Array(repeating: ".group(name: \"g\", source: \"p\")", count: count)
        .joined(separator: ",")
      return
        "let agents = Agents(sources: [.source(name: \"p\", path: \"\(producer.path)\")], uses: [\(uses)])"
    }
    #expect(try fixture.link(expression(100)).components.count == 100)
    do {
      _ = try fixture.link(expression(200))
      Issue.record("expected aggregate expanded-value limit")
    } catch LinkError.budget(let name) {
      #expect(name == "expanded manifest values")
    }
  }

  @Test func repeatedContributionsReachLimitAndRejectOverflow() throws {
    let fixture = try LinkFixture()
    try fixture.instruction("rules", at: fixture.project)
    func expression(overflow: Bool) -> String {
      let sections = Array(repeating: "\"rules\"", count: 10_000).joined(separator: ",")
      let extra = overflow ? ", .instructions(sections: [\"rules\"])" : ""
      return
        "let agents = Agents(components: [.instructions(sections: [\(sections)])\(extra)])"
    }
    #expect(try fixture.link(expression(overflow: false)).components.count == 10_000)
    do {
      _ = try fixture.link(expression(overflow: true))
      Issue.record("expected occurrence limit")
    } catch LinkError.budget(let name) {
      #expect(name == "contribution occurrences")
    }
  }

  @Test func oversizedProducerManifestFailsBeforeParsing() throws {
    let fixture = try LinkFixture()
    let producer = fixture.root.appendingPathComponent("producer")
    try fixture.write(
      String(repeating: " ", count: 2_097_153), to: ".agent/Agents.swift", base: producer)
    do {
      _ = try fixture.link(
        "let agents = Agents(sources: [.source(name: \"p\", path: \"\(producer.path)\")], uses: [.group(name: \"g\", source: \"p\")])"
      )
      Issue.record("expected input limit")
    } catch LinkError.budget(let name) { #expect(name == "manifest input bytes") }
  }
}

extension LinkBudgetTests {
  @Test func distinctLiveSnapshotLimitCountsReusedViewsOnce() throws {
    let fixture = try LinkFixture()
    var sources: [String] = []
    var selections: [String] = []
    for index in 0..<257 {
      let source = fixture.root.appendingPathComponent("live\(index)")
      try fixture.skill("s\(index)", at: source)
      sources.append(".source(name: \"s\(index)\", path: \"\(source.path)\")")
      selections.append(".skills(source: \"s\(index)\", select: [\"s\(index)\"], mode: .edit)")
    }
    func expression(_ count: Int, repeated: Bool = false) -> String {
      let selected = Array(selections.prefix(count))
      let components = repeated ? selected + selected : selected
      return
        "let agents = Agents(sources: [\(sources.prefix(count).joined(separator: ","))], components: [\(components.joined(separator: ","))])"
    }
    #expect(try fixture.link(expression(256)).sourceSnapshots.count == 256)
    #expect(try fixture.link(expression(256, repeated: true)).components.count == 512)
    do {
      _ = try fixture.link(expression(257))
      Issue.record("expected live snapshot limit")
    } catch LinkError.budget(let name) { #expect(name == "distinct snapshots") }
  }

  @Test func distinctSnapshotLimitUsesSourceContent() throws {
    let fixture = try LinkFixture()
    var sources: [String] = []
    var uses: [String] = []
    for index in 0..<257 {
      let producer = fixture.root.appendingPathComponent("p\(index)")
      try fixture.manifest(
        "let agents = Agents(exports: [\"g\"], groups: [.group(name: \"g\")])", at: producer)
      sources.append(".source(name: \"p\(index)\", path: \"\(producer.path)\")")
      uses.append(".group(name: \"g\", source: \"p\(index)\")")
    }
    func expression(_ count: Int) -> String {
      "let agents = Agents(sources: [\(sources.prefix(count).joined(separator: ","))], uses: [\(uses.prefix(count).joined(separator: ","))])"
    }
    #expect(try fixture.link(expression(256)).references.count == 256)
    do {
      _ = try fixture.link(expression(257))
      Issue.record("expected snapshot limit")
    } catch LinkError.budget(let name) { #expect(name == "distinct snapshots") }
  }

  @Test func containedLiveSnapshotsShareTheDistinctViewBudget() throws {
    let fixture = try LinkFixture()
    var sources: [String] = []
    var uses: [String] = []
    for index in 0..<129 {
      let producer = fixture.root.appendingPathComponent("producer\(index)")
      try fixture.skill("s\(index)", at: producer)
      try fixture.manifest(
        "let agents = Agents(exports: [\"g\"], groups: [.group(name: \"g\", components: [.skills(source: \".\", select: [\"s\(index)\"], mode: .edit)])])",
        at: producer)
      sources.append(".source(name: \"p\(index)\", path: \"\(producer.path)\")")
      uses.append(".group(name: \"g\", source: \"p\(index)\")")
    }
    func expression(_ count: Int, repeated: Bool = false) -> String {
      let selected = Array(uses.prefix(count))
      let references = repeated ? selected + selected : selected
      return
        "let agents = Agents(sources: [\(sources.prefix(count).joined(separator: ","))], uses: [\(references.joined(separator: ","))])"
    }
    #expect(try fixture.link(expression(128)).sourceSnapshots.count == 256)
    #expect(try fixture.link(expression(128, repeated: true)).components.count == 256)
    do {
      _ = try fixture.link(expression(129))
      Issue.record("expected immutable and live views to share the snapshot limit")
    } catch LinkError.budget(let name) { #expect(name == "distinct snapshots") }
  }

  @Test func qualifiedReferenceDepthIsBounded() throws {
    let fixture = try LinkFixture()
    for count in [64, 65] {
      let producer = fixture.root.appendingPathComponent("depth\(count)")
      var directory = producer
      for index in 0..<count {
        let expression =
          index == count - 1
          ? "let agents = Agents(exports: [\"g\"], groups: [.group(name: \"g\", components: [.mcpServer(name: \"leaf\", transport: .stdio(\"never-run\"))])])"
          : "let agents = Agents(exports: [\"g\"], sources: [.source(name: \"child\", path: \"child\")], groups: [.group(name: \"g\", uses: [.group(name: \"g\", source: \"child\")])])"
        try fixture.manifest(expression, at: directory)
        directory.appendPathComponent("child")
      }
      let expression =
        "let agents = Agents(sources: [.source(name: \"p\", path: \"\(producer.path)\")], uses: [.group(name: \"g\", source: \"p\")])"
      if count == 64 {
        #expect(try fixture.link(expression).components.map(\.key.name) == ["leaf"])
      } else {
        do {
          _ = try fixture.link(expression)
          Issue.record("expected active-reference limit")
        } catch LinkError.budget(let name) { #expect(name == "active references") }
      }
    }
  }

  @Test func aggregateManifestBytesAreBoundedAcrossNamespaces() throws {
    let fixture = try LinkFixture()
    var sources: [String] = []
    var uses: [String] = []
    for index in 0..<9 {
      let producer = fixture.root.appendingPathComponent("p\(index)")
      let text = LinkFixture.text(
        "let agents = Agents(exports: [\"g\"], groups: [.group(name: \"g\")])")
      try fixture.write(
        text + "//" + String(repeating: "x", count: 1_900_000 - text.utf8.count - 2),
        to: ".agent/Agents.swift", base: producer)
      sources.append(".source(name: \"p\(index)\", path: \"\(producer.path)\")")
      uses.append(".group(name: \"g\", source: \"p\(index)\")")
    }
    func expression(_ count: Int) -> String {
      "let agents = Agents(sources: [\(sources.prefix(count).joined(separator: ","))], uses: [\(uses.prefix(count).joined(separator: ","))])"
    }
    #expect(try fixture.link(expression(8)).references.count == 8)
    do {
      _ = try fixture.link(expression(9))
      Issue.record("expected aggregate manifest limit")
    } catch LinkError.budget(let name) { #expect(name == "aggregate manifest bytes") }
  }
}

extension LinkBudgetTests {
  @Test func repeatedReferenceProvenanceConsumesTotalWorkBudget() throws {
    let fixture = try LinkFixture()
    let groups = (0..<40).map { index in
      index == 39
        ? ".group(name: \"g39\")"
        : ".group(name: \"g\(index)\", uses: [\"g\(index + 1)\"])"
    }.joined(separator: ",")
    let uses = Array(repeating: "\"g0\"", count: 1500).joined(separator: ",")
    do {
      _ = try fixture.link("let agents = Agents(groups: [\(groups)], uses: [\(uses)])")
      Issue.record("expected total-work bound for repeated provenance")
    } catch LinkError.budget(let name) { #expect(name == "resolution/evaluation steps") }
  }
}
