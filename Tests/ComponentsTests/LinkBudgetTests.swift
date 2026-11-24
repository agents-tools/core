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
      version: 1
      exports: ["g"]
      groups: {"g": {"components": [{"kind": "command", "name": "review", "description": "Review", "prompt": "\(prompt)"}]}}
      """, at: producer)
    try fixture.commit(producer)
    func expression(_ count: Int) -> String {
      let uses = Array(repeating: "{group: g, source: p}", count: count)
        .joined(separator: ",")
      return
        "version: 1\nsources: {\"p\": {\"path\": \"\(producer.path)\"}}\nuses: [\(uses)]\n"
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
      let sections = Array(repeating: "name: rules", count: 10_000).joined(separator: ",")
      let extra = overflow ? ", {kind: instructions, sections: [{name: rules}]}" : ""
      return "version: 1\ncomponents: [{kind: instructions, sections: [\(sections)]}\(extra)]\n"

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
      String(repeating: " ", count: 2_097_153), to: ".agent/agents.yaml", base: producer)
    do {
      _ = try fixture.link(
        "version: 1\nsources: {\"p\": {\"path\": \"\(producer.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"g\"}]\n"
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
      sources.append("\"s\(index)\": {\"path\": \"\(source.path)\"}")
      selections.append(
        "{\"kind\": \"skills\", \"source\": \"s\(index)\", \"select\": [\"s\(index)\"], \"mode\": \"edit\"}"
      )
    }
    func expression(_ count: Int, repeated: Bool = false) -> String {
      let selected = Array(selections.prefix(count))
      let components = repeated ? selected + selected : selected
      return
        "version: 1\nsources: {\(sources.prefix(count).joined(separator: ","))}\ncomponents: [\(components.joined(separator: ","))]\n"
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
        "version: 1\nexports: [\"g\"]\ngroups: {\"g\": {}}\n", at: producer)
      sources.append("\"p\(index)\": {\"path\": \"\(producer.path)\"}")
      uses.append("{group: g, source: p\(index)}")
    }
    func expression(_ count: Int) -> String {
      "version: 1\nsources: {\(sources.prefix(count).joined(separator: ","))}\nuses: [\(uses.prefix(count).joined(separator: ","))]\n"
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
        "version: 1\nexports: [\"g\"]\ngroups: {\"g\": {\"components\": [{\"kind\": \"skills\", \"source\": \".\", \"select\": [\"s\(index)\"], \"mode\": \"edit\"}]}}\n",
        at: producer)
      sources.append("\"p\(index)\": {\"path\": \"\(producer.path)\"}")
      uses.append("{group: g, source: p\(index)}")
    }
    func expression(_ count: Int, repeated: Bool = false) -> String {
      let selected = Array(uses.prefix(count))
      let references = repeated ? selected + selected : selected
      return
        "version: 1\nsources: {\(sources.prefix(count).joined(separator: ","))}\nuses: [\(references.joined(separator: ","))]\n"
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
          ? "version: 1\nexports: [\"g\"]\ngroups: {\"g\": {\"components\": [{\"kind\": \"mcpServer\", \"name\": \"leaf\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"never-run\"}}]}}\n"
          : "version: 1\nexports: [\"g\"]\nsources: {\"child\": {\"path\": \"child\"}}\ngroups: {\"g\": {\"uses\": [{\"source\": \"child\", \"group\": \"g\"}]}}\n"
        try fixture.manifest(expression, at: directory)
        directory.appendPathComponent("child")
      }
      let expression =
        "version: 1\nsources: {\"p\": {\"path\": \"\(producer.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"g\"}]\n"
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
        "version: 1\nexports: [\"g\"]\ngroups: {\"g\": {}}\n")
      try fixture.write(
        text + "#" + String(repeating: "x", count: 1_900_000 - text.utf8.count - 1),
        to: ".agent/agents.yaml", base: producer)
      sources.append("\"p\(index)\": {\"path\": \"\(producer.path)\"}")
      uses.append("{group: g, source: p\(index)}")
    }
    func expression(_ count: Int) -> String {
      "version: 1\nsources: {\(sources.prefix(count).joined(separator: ","))}\nuses: [\(uses.prefix(count).joined(separator: ","))]\n"
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
        ? "\"g39\": {}"
        : "\"g\(index)\": {\"uses\": [{\"group\": \"g\(index + 1)\"}]}"
    }.joined(separator: ",")
    let uses = Array(repeating: "{group: g0}", count: 1500).joined(separator: ",")
    do {
      _ = try fixture.link("version: 1\ngroups: {\(groups)}\nuses: [\(uses)]\n")
      Issue.record("expected total-work bound for repeated provenance")
    } catch LinkError.budget(let name) { #expect(name == "resolution/evaluation steps") }
  }
}
