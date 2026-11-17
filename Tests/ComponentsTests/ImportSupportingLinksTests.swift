import AgentsCore
import Foundation
import Testing

@testable import Components

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ImportSupportingLinksTests {
  @Test(arguments: [
    SourceImportProfile.claudePluginV1, .cursorPluginV1, .geminiExtensionV1,
  ])
  func nativeSkillPreservesContainedChainedExecutableSupport(_ profile: SourceImportProfile) throws
  {
    let f = try SupportingSkillFixture(profile)
    try f.write("bundle/shared/tool.txt", "Supporting executable\n", executable: true)
    try f.link("bundle/shared/current", "tool.txt")
    try f.link("bundle/skills/helper/reference.txt", "../../shared/current")
    try f.write(
      "bundle/shared/directory/SKILL.md", "---\nname: hidden\ndescription: Hidden\n---\nBody\n")
    try f.link("bundle/skills/helper/data", "../../shared/directory")
    let before = try FileHash.folderHash(f.root)
    let proposal = try SourceImport.preview(f.input)
    #expect(proposal.diagnostics.isEmpty)
    #expect(proposal.components.count == 1)
    let member = try #require(proposal.components.first)
    #expect(member.member?.selector == .skill(name: "helper"))
    #expect(member.member?.containerRoot == "bundle")
    #expect(member.origin.document == "bundle/skills/helper/SKILL.md")
    let preservation = try #require(proposal.resources.first { $0.kind == .skills })
    #expect(preservation.path == "skills/helper")
    #expect(preservation.requiresStandaloneSource && !preservation.requiresBindingRewrite)
    #expect(
      proposal.sources.first { $0.alias == preservation.sourceAlias }?.producerPath == "bundle")
    #expect(
      preservation.observedHash
        == "sha256:"
        + (try FileHash.folderHash(f.root.appendingPathComponent("bundle/skills/helper"))))
    #expect(
      proposal.resources.contains {
        $0.path == "shared/tool.txt" && $0.executableFlags["shared/tool.txt"] == true
      })
    let captured = try LedgerResources.capture(
      f.root.appendingPathComponent("bundle/skills/helper"), embed: true, limits: .standard,
      sourceRoot: f.root.appendingPathComponent("bundle"))
    #expect(
      captured.entries.contains { $0.path == "reference.txt" && $0.link == "../../shared/current" })
    #expect(captured.support.contains { $0.path == "shared/current" && $0.link == "tool.txt" })
    #expect(captured.support.contains { $0.path == "shared/tool.txt" && $0.executable })
    #expect(try FileHash.folderHash(f.root) == before)
  }

  @Test func linkedSkillClosureSurvivesProductionFreezeAndLedgerRoundTrip() throws {
    let f = try LinkFixture()
    try f.write(#"{"name":"bundle"}"#, to: "bundle/.claude-plugin/plugin.json", base: f.project)
    try f.write(
      "---\nname: helper\ndescription: Helper\n---\nBody\n",
      to: "bundle/skills/helper/SKILL.md", base: f.project)
    try f.write("Executable support\n", to: "bundle/shared/tool.txt", base: f.project)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: f.project.appendingPathComponent("bundle/shared/tool.txt").path)
    try FileManager.default.createSymbolicLink(
      atPath: f.project.appendingPathComponent("bundle/skills/helper/reference.txt").path,
      withDestinationPath: "../../shared/tool.txt")
    let declaration = try f.document(
      """
      version: 1
      components: [{kind: plugin, name: bundle, source: ".", path: bundle, agents: [claude-code]}]
      """)
    let ledger = try ComponentLinker.withLinkedComponents(
      document: declaration, store: f.store, platform: .macOS
    ) { graph, session in
      let locations = Dictionary(
        (graph.sourceSnapshots + graph.declaringSnapshots).filter {
          $0.source?.kind == .local && $0.container == nil
        }.map {
          (
            $0.snapshot.source,
            LedgerLocation(
              kind: .absolute, path: String($0.snapshot.source.dropFirst("local:".count)))
          )
        }, uniquingKeysWith: { first, _ in first })
      return try LedgerFreeze.freeze(
        graph, session: session, locations: .init(sources: locations), limits: .standard)
    }
    let skill = try #require(ledger.resources.values.first { $0.path.hasSuffix("skills/helper") })
    #expect(
      skill.entries.contains { $0.path == "reference.txt" && $0.link == "../../shared/tool.txt" })
    #expect(skill.support.contains { $0.path.hasSuffix("shared/tool.txt") && $0.executable })
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(encoded, limits: .standard) == ledger)
  }

  @Test func laterSupportingDocumentCredentialsBlockTheEntireSkillCapture() throws {
    let f = try SupportingSkillFixture(.claudePluginV1)
    try f.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","lspServers":"./shared/language.json"}"#)
    try f.write(
      "bundle/shared/language.json",
      #"{"review":{"command":"never-run","extensionToLanguage":{".txt":"text"},"env":{"TOKEN":"SUPPORT_LITERAL_CANARY"}}}"#
    )
    try f.link("bundle/skills/helper/reference.txt", "../../shared/language.json")
    let proposal = try SourceImport.preview(f.input)
    let skill = try #require(proposal.resources.first { $0.kind == .skills })
    #expect(skill.requiresBindingRewrite && skill.observedHash == nil)
    #expect(
      proposal.resources.filter { $0.origin == skill.origin }.allSatisfy {
        $0.requiresBindingRewrite && $0.observedHash == nil
      })
    #expect(!proposal.bindings.isEmpty)
    #expect(!String(reflecting: proposal).contains("SUPPORT_LITERAL_CANARY"))
  }

  @Test(arguments: ["absolute", "outside", "missing", "cycle", "linkThenParent", "fifo"])
  func invalidSupportingClosureCannotEmitASkill(_ kind: String) throws {
    let f = try SupportingSkillFixture(.claudePluginV1)
    try f.write("bundle/shared/tool.txt", "Support\n")
    let reference = "bundle/skills/helper/reference.txt"
    switch kind {
    case "absolute":
      try f.link(reference, f.root.appendingPathComponent("bundle/shared/tool.txt").path)
    case "outside":
      try f.write("outside.txt", "Outside container\n")
      try f.link(reference, "../../../outside.txt")
    case "missing": try f.link(reference, "../../shared/missing.txt")
    case "cycle":
      try f.link(reference, "../../shared/loop")
      try f.link("bundle/shared/loop", "../skills/helper/reference.txt")
    case "linkThenParent":
      try f.write("outside/dir/child.txt", "Child\n")
      try f.write("outside/tool.txt", "Outside container\n")
      try f.link("bundle/shared/jump", "../../outside/dir")
      try f.link(reference, "../../shared/jump/../tool.txt")
    default:
      let fifo = f.root.appendingPathComponent("bundle/shared/pipe").path
      #expect(mkfifo(fifo, 0o600) == 0)
      try f.link(reference, "../../shared/pipe")
    }
    let proposal = try SourceImport.preview(f.input)
    #expect(!proposal.diagnostics.isEmpty)
    #expect(!proposal.components.contains { $0.declaration.kind == .skills })
    #expect(!proposal.resources.contains { $0.kind == .skills })
  }

  @Test func supportingLinksCannotDiscoverMembersOrChangeOtherProducerHashAdmission() throws {
    let f = try SupportingSkillFixture(.cursorPluginV1)
    try FileManager.default.removeItem(
      at: f.root.appendingPathComponent("bundle/skills/helper/SKILL.md"))
    try f.write(
      "bundle/shared/SKILL.md", "---\nname: linked\ndescription: Linked\n---\nBody\n")
    try f.link("bundle/skills/helper/SKILL.md", "../../shared/SKILL.md")
    let proposal = try SourceImport.preview(f.input)
    #expect(proposal.components.isEmpty)
    #expect(
      proposal.diagnostics.contains {
        $0.code == .unconverted && $0.location.document.hasSuffix("SKILL.md")
      })

    let regular = try SupportingSkillFixture(.claudePluginV1)
    try regular.write("bundle/shared/tool.txt", "Support\n")
    try regular.link("bundle/skills/helper/reference.txt", "../../shared/tool.txt")
    #expect(throws: (any Error).self) {
      try ImportSkillContent.read("bundle/skills/helper", input: regular.input, limits: .init())
    }
    var producer = regular.input
    producer = .init(profile: .vercelProjectV2, root: producer.root, document: producer.document)
    #expect(throws: (any Error).self) {
      try ImportSkillContent.read(
        "bundle/skills/helper", input: producer, limits: .init(), nativeContainer: "bundle")
    }
  }

  @Test func explicitMemberPathCannotTraverseALinkedDirectory() throws {
    let f = try SupportingSkillFixture(.claudePluginV1)
    try f.write(
      "bundle/.claude-plugin/plugin.json",
      #"{"name":"bundle","skills":"./alias/nested"}"#)
    try f.write(
      "bundle/real/nested/SKILL.md", "---\nname: linked\ndescription: Linked\n---\nBody\n")
    try f.link("bundle/alias", "real")
    let proposal = try SourceImport.preview(f.input)
    #expect(!proposal.components.contains { $0.member?.selector == .skill(name: "linked") })
    #expect(proposal.components.contains { $0.member?.selector == .skill(name: "helper") })
    #expect(
      proposal.diagnostics.contains {
        $0.code == .unconverted && $0.location.document == "bundle/alias"
      })
  }

  @Test(arguments: ["entries", "bytes", "depth"])
  func supportingClosureRemainsBounded(_ budget: String) throws {
    let f = try SupportingSkillFixture(.geminiExtensionV1)
    try f.write("bundle/shared/tool.txt", String(repeating: "S", count: 256))
    try f.link("bundle/skills/helper/reference.txt", "../../shared/tool.txt")
    var limits = SourceImportLimits()
    switch budget {
    case "entries": limits.resourceEntries = 3
    case "bytes": limits.resourceBytes = 128
    default: limits.depth = 1
    }
    #expect(throws: (any Error).self) {
      try ImportSkillContent.read(
        "bundle/skills/helper", input: f.input, limits: limits, nativeContainer: "bundle")
    }
  }
}

private final class SupportingSkillFixture {
  let root: URL
  let input: SourceImportInput
  init(_ profile: SourceImportProfile) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "import-support-" + UUID().uuidString)
    let document: String
    switch profile {
    case .claudePluginV1: document = "bundle/.claude-plugin/plugin.json"
    case .cursorPluginV1: document = "bundle/.cursor-plugin/plugin.json"
    default: document = "bundle/gemini-extension.json"
    }
    input = .init(profile: profile, root: root, document: document)
    try write(document, #"{"name":"bundle","version":"1.2.3"}"#)
    try write(
      "bundle/skills/helper/SKILL.md", "---\nname: helper\ndescription: Helper\n---\nBody\n")
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func write(_ path: String, _ text: String, executable: Bool = false) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
  }
  func link(_ path: String, _ target: String) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target)
  }
}
