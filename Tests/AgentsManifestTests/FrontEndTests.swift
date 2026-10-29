import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

let manifestHeader = "// agents-tools-version: 1.0\nimport AgentsDescription\n\n"

func document(_ body: String) throws -> DeclarationDocument {
  try DeclarationDocument(
    bytes: Array((manifestHeader + body).utf8), identity: DocumentIdentity("manifest"))
}

@Suite("Manifest front end")
struct FrontEndTests {
  @Test func completeExamplesCompileAndAgreeUnderValueEquality() throws {
    let baselineURL = Bundle.module.resourceURL!.appendingPathComponent(
      "Fixtures/ParserBaseline.json")
    let baseline =
      try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as! [String: Any]
    let baselineFixtures = baseline["fixtures"] as! [String: [String: Int]]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let resolved =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("Package.resolved"))) as! [String: Any]
    let pins = resolved["pins"] as! [[String: Any]]
    let syntaxPin = pins.first { $0["identity"] as? String == "swift-syntax" }!
    #expect(
      (syntaxPin["state"] as! [String: String])["version"] == baseline["swiftSyntax"] as? String)
    let fixtureDirectory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    let sourceNames = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
      .filter { $0.hasSuffix(".swift.txt") }.sorted()
    #expect(compiledFixtures().map(\.name).sorted() == sourceNames)
    #expect(baselineFixtures.keys.sorted() == sourceNames)
    for fixture in compiledFixtures() {
      let name = fixture.name
      let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
      let doc = try DeclarationDocument(
        bytes: Array(Data(contentsOf: url)), identity: DocumentIdentity("manifest"))
      #expect(fixture.agents == Agents(value: doc.evaluation.root.value), "\(name)")
      #expect(fixture.constants.keys.sorted() == doc.evaluation.constants.keys.sorted())
      for (constant, compiled) in fixture.constants {
        #expect(compiled == doc.evaluation.constants[constant]?.value, "\(name): \(constant)")
      }
      #expect(doc.metrics.parserCalls == 1)
      #expect(doc.metrics.syntaxNodes <= doc.metrics.syntaxReservation)
      #expect(doc.metrics.syntaxDepth <= 128)
      #expect(!doc.sourceMap.entries.isEmpty)
      if let expected = baselineFixtures[name] {
        #expect(doc.metrics.tokens == expected["tokens"])
        #expect(doc.metrics.syntaxReservation == expected["syntaxReservation"])
        #expect(doc.metrics.syntaxNodes == expected["syntaxNodes"])
        #expect(doc.metrics.syntaxDepth == expected["syntaxDepth"])
      } else {
        Issue.record("fixture is missing from parser baseline: \(name)")
      }
    }
  }

  @Test func closedLiteralTyping() throws {
    let bodies = [
      "let text = \"x\"\nlet value: SectionReference = text",
      "let text = \"x\"\nlet value: PromptContent = text",
      "let text = \"x\"\nlet value: RuntimeValue = text",
      "let text = \"1.2.0\"\nlet value: Version = text",
      "let text = \"review\"\nlet value: GroupReference = text",
      "let names = [\"x\"]\nlet value: SkillSelection = names",
      "let text = \"x\"\nlet value: ConfigurationValue = text",
      "let value = .copy", "let value = []", "let value = [:]", "let value = nil",
      "let value = \"a\" + \"b\"", "let value: SkillSelection = [\"a\"] + [\"b\"]",
      "let value: ConfigurationValue = [1] + [2]", "let value = Version(\"1.2.0\")",
      "let value = String(stringLiteral: \"x\")", "let value = future\nlet future = 1",
    ]
    for body in bodies {
      #expect(throws: ManifestFailure.self) { try document(body + "\nlet agents = Agents()") }
    }
  }

  @Test func domainValidationIsOfflineAndIncludesUnusedValues() throws {
    let bad = [
      "let bad: Condition = .when(agents: [.codex, .codex])\nlet agents = Agents()",
      "let agents = Agents(sources: [.source(name: \".\", path: \"a\")])",
      "let agents = Agents(sources: [.source(name: \"a\", url: \"https://EXAMPLE.org/r.git\"), .source(name: \"b\", url: \"https://example.org/r/\")])",
      "let agents = Agents(components: [.hook(name: \"h\", event: .native(\"x\"), run: .executable(\"tool\"))])",
      "let agents = Agents(components: [.hook(name: \"h\", event: .beforeTool, run: .executable(\"tool\"), timeoutSeconds: 0)])",
      "let agents = Agents(components: [.subagent(name: \"../bad\", description: \"x\", prompt: \"x\")])",
      "let agents = Agents(components: [.mcpServer(name: \"x\", transport: .sse(url: \"https://user:pw@example.org/mcp\"))])",
      "let agents = Agents(components: [.command(name: \"x\", description: \"x\", prompt: \"${input:missing}\")])",
      "let value: ConfigurationValue = .decimal(\"1e99999\")\nlet agents = Agents()",
      "let value: Resource = .path(\"../escape\")\nlet agents = Agents()",
      "let value: PermissionRule = .allow(.read, \"/private/**\")\nlet agents = Agents()",
      "let value: PermissionRule = .deny(.write, \"../**\")\nlet agents = Agents()",
      "let agents = Agents(groups: [.group(name: \"a\", uses: [\"b\"]), .group(name: \"b\", uses: [\"a\"])])",
      "let agents = Agents(groups: [.group(name: \"unused\", uses: [\"missing\"])])",
    ]
    for input in bad { #expect(throws: ManifestFailure.self) { try document(input) } }
    let doc = try document(
      "let agents = Agents(sources: [.source(name: \"r\", url: \"intranet/team\")])")
    #expect(doc.diagnostics.first?.code == "manifest.domain")
    #expect(doc.diagnostics.first?.severity == .warning)
    #expect(
      String(decoding: doc.diagnostics.first!.fixIt!.replacement, as: UTF8.self)
        == "\"https://intranet/team\"")
    _ = try document(
      "let root: Resource = .path(\"\")\nlet notes: Resource = .path(\"~notes\")\nlet rule: PermissionRule = .allow(.read, \"src/**\")\nlet agents = Agents(components: [.mcpServer(name: \"s\", transport: .streamableHTTP(url: \"HTTPS://example.org/mcp\"))])"
    )
  }

  @Test func duplicateKeysUseDecodedSwiftStringEqualityAndLocatedRelatedSpans() throws {
    for key in ["\\u{61}", "a"] {
      do {
        _ = try document(
          "let value: [String: Int] = [\"a\": 1, \"\(key)\": 2]\nlet agents = Agents()")
        Issue.record("duplicate accepted")
      } catch let error as ManifestFailure {
        #expect(error.diagnostics[0].code == "manifest.dictionary.duplicateKey")
        #expect(error.diagnostics[0].related.count == 1)
        #expect(error.diagnostics[0].span.start > error.diagnostics[0].related[0].start)
      }
    }
    #expect(throws: ManifestFailure.self) {
      try document(
        "let value: ConfigurationValue = [\"é\": 1, \"e\\u{301}\": 2]\nlet agents = Agents()")
    }
  }

  @Test func defaultsOrderConditionsAndProvenanceRemainSymbolic() throws {
    let doc = try document(
      "let sections: [SectionReference] = [\"guide\", \"guide\"]\nlet agents = Agents(defaultAgents: [], components: [.instructions(sections: sections, condition: .when(agents: []))], groups: [.group(name: \"inert\")])"
    )
    #expect(doc.declaration.defaultAgents == [])
    #expect(doc.declaration.components[0]["agents"] == .null)
    #expect(doc.declaration.components[0]["sections"]?.elements?.count == 2)
    #expect(doc.declaration.groups.count == 1)
    #expect(doc.sourceMap.locations(at: "/components/0/agents").first?.defaulted == true)
    #expect(doc.sourceMap.locations(at: "/components/0/sections/0").first?.origins.isEmpty == false)
  }
  @Test func unusedSkillValuesReceiveTheirOwnDomainChecks() throws {
    for body in [
      "let selection: SkillSelection = [\"duplicate\", \"duplicate\"]",
      "let selection: SkillSelection = [\"../escape\"]",
      "let override: SkillOverride = .skill(name: \"../escape\")",
    ] {
      expectManifestFailure("manifest.domain") { try document(body + "\nlet agents = Agents()") }
    }
    _ = try document(
      "let selection: SkillSelection = [\"one\", \"two\"]\nlet override: SkillOverride = .skill(name: \"one\")\nlet agents = Agents()"
    )
  }

  @Test func inspectionAndDocumentConstructionUseTheSameObservedPhases() throws {
    let bytes = Array((manifestHeader + "let agents = Agents()").utf8)
    var documentStages: [FrontEndStage] = []
    let doc = try DeclarationDocument(
      bytes: bytes, identity: DocumentIdentity("manifest"), validateDomain: true
    ) { stage, _ in documentStages.append(stage) }
    var inspectionStages: [FrontEndStage] = []
    let metrics = try DeclarationDocument.inspect(
      bytes: bytes, identity: DocumentIdentity("manifest"), checking: .declaration
    ) { stage, _ in inspectionStages.append(stage) }
    #expect(documentStages == [.admission, .parser, .evaluation, .domain, .lowering, .sourceMap])
    #expect(inspectionStages == documentStages + [.teardown, .complete])
    #expect(metrics.parserCalls == doc.metrics.parserCalls)
    #expect(metrics.syntaxNodes == doc.metrics.syntaxNodes)
    #expect(metrics.evaluationSteps == doc.metrics.evaluationSteps)
    #expect(metrics.expandedNodes == doc.metrics.expandedNodes)
  }

}
