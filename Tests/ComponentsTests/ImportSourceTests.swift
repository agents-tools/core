import AgentsCore
import Components
import Foundation
import Testing

struct ImportSourceTests {
  @Test func rulesyncGitPinAndCanonicalSkillPreserveResourceCoordinates() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{"acme/repo":{"requestedRef":"main",
        "resolvedRef":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","skillsPath":"exports/skills",
        "skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}},
        "rulesPath":"rules","rules":{"overview":{"integrity":"sha256-\(String(repeating: "c", count: 64))"}},
        "skillSelection":["*"],"future":true}}}
      """)
    var input = fixture.input(.rulesyncSourcesV1)
    input.sourceDeclarations = [
      "acme/repo": .init(kind: .git, location: "https://gitlab.com/acme/repo")
    ]
    let before = try FileHash.folderHash(fixture.root)
    let proposal = try SourceImport.preview(input)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(proposal.profile.producerRevision == "fbe4fe58334cab4e84b87f20d730d6450a35e0f7")
    #expect(proposal.sources.first?.pin.commit == String(repeating: "a", count: 40))
    #expect(proposal.sources.first?.requestedRef == "main")
    #expect(proposal.sources.last?.declaration?.location == "https://gitlab.com/acme/repo")
    #expect(proposal.sources.last?.declaration?.path == "exports/skills/review")
    #expect(
      proposal.components.map(\.declaration) == [
        .skills(source: "import-source-0-skill-0", .init(select: .names(["review"])))
      ])
    #expect(proposal.resources.map(\.path) == ["exports/skills/review", "rules/overview.md"])
    #expect(proposal.resources.allSatisfy { $0.requiresStandaloneSource })
    #expect(proposal.diagnostics.filter { $0.code == .unconverted }.count == 3)
    #expect(proposal.diagnostics.allSatisfy { $0.location.document == "input.json" })
  }

  @Test func normalizedRulesyncKeyNeverGuessesProviderOrPinsRequestedRef() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{"org/repo#path=skills&ref=main":{
      "requestedRef":"\(String(repeating: "a", count: 40))","resolvedRef":"main",
      "skillsPath":"skills","skills":{"review":{"integrity":""}}}}}
      """)
    let proposal = try SourceImport.preview(fixture.input(.rulesyncSourcesV1))
    #expect(proposal.components.isEmpty)
    #expect(proposal.sources.first?.declaration == nil)
    #expect(proposal.sources.first?.pin.commit == nil)
    #expect(proposal.diagnostics.contains { $0.code == .ambiguousSource })
    #expect(proposal.diagnostics.filter { $0.code == .incompletePin }.count == 2)
  }

  @Test func rulesyncRootFallbackDoesNotInventMemberDirectory() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{"org/repo":{"resolvedRef":"\(String(repeating: "a", count: 40))",
      "skillsPath":"exports","skillSelection":["review"],
      "skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}}}}}
      """)
    var input = fixture.input(.rulesyncSourcesV1)
    input.sourceDeclarations = [
      "org/repo": .init(kind: .git, location: "https://github.com/org/repo")
    ]
    let proposal = try SourceImport.preview(input)
    #expect(proposal.components.isEmpty)
    #expect(proposal.resources.first?.producerName == "review")
    #expect(proposal.resources.first?.path == nil)
    #expect(
      proposal.resources.first?.producerIntegrity?.value == "sha256-"
        + String(repeating: "b", count: 64))
    #expect(proposal.diagnostics.contains { $0.message.contains("root fallback") })
  }

  @Test func npmProfileKeepsTarballAndResourceIntegritySeparate() throws {
    let fixture = try ImportSourceFixture()
    let sri = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{
      "@acme/with-integrity":{"resolvedVersion":"1.2.3","requestedVersion":"latest","integrity":"\(sri)",
        "skillsPath":"skills","skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}}},
      "@acme/without-integrity":{"resolvedVersion":"1.2.3","skillsPath":"skills","skills":{}}}}
      """)
    let proposal = try SourceImport.preview(fixture.input(.rulesyncNpmV1))
    #expect(proposal.sources.count == 2)
    #expect(proposal.sources[0].pin.integrity == .init(kind: .npmSRI, value: sri))
    #expect(proposal.sources[0].pin.version == "1.2.3")
    #expect(proposal.sources[0].pin.commit == nil)
    #expect(proposal.resources.first?.producerIntegrity?.kind == .rulesyncSHA256)
    #expect(proposal.diagnostics.filter { $0.code == .incompletePin }.count == 1)
    #expect(proposal.components.isEmpty)
  }

  @Test(arguments: ["latest", "^1.2.3", "1.2.3-01", "1.2.3+.."])
  func npmResolvedVersionMustBeExact(_ version: String) throws {
    let fixture = try ImportSourceFixture()
    let sri = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{"@acme/package":{"resolvedVersion":"\(version)",
      "integrity":"\(sri)","skillsPath":"skills","skills":{}}}}
      """)
    let proposal = try SourceImport.preview(fixture.input(.rulesyncNpmV1))
    #expect(proposal.sources.first?.pin.version == nil)
    #expect(proposal.sources.first?.pin.integrity?.kind == .npmSRI)
    #expect(proposal.diagnostics.contains { $0.code == .incompletePin })
  }

  @Test func vercelProjectCapturesActualContentWithoutInventingGitCommit() throws {
    let fixture = try ImportSourceFixture()
    try fixture.skill()
    try fixture.write("first\r\nsecond\r\n", at: "installed/review/guide.txt")
    try Data([0, 13, 10]).write(to: fixture.root.appendingPathComponent("installed/review/binary"))
    try fixture.write("{}", at: "installed/review/metadata.json/ignored.txt")
    try fixture.write(
      """
      {"version":2,"skills":{"review":{"source":"acme/repo","sourceType":"github","ref":"main",
      "skillPath":"skills/review/SKILL.md","computedHash":"8ab07122fdd17957fa92a18c05f175744b26f661c87f3f479ad6279e200713e3"}}}
      """)
    var input = fixture.input(.vercelProjectV2)
    input.installedSkills = ["review": "installed/review"]
    let before = try FileHash.folderHash(fixture.root)
    let proposal = try SourceImport.preview(input)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(proposal.sources.first?.pin.commit == nil)
    #expect(proposal.sources.first?.pin.integrity?.kind == .vercelInstalledSHA256)
    #expect(proposal.sources.first?.declaration?.path == "skills/review")
    #expect(proposal.sources.last?.declaration?.kind == .local)
    #expect(proposal.sources.last?.declaration?.location == "installed/review")
    #expect(
      proposal.resources.first?.observedHash == "sha256:"
        + (try FileHash.folderHash(fixture.root.appendingPathComponent("installed/review"))))
    #expect(proposal.resources.first?.requiresStandaloneSource == true)
    #expect(proposal.resources.first?.path == ".")
    #expect(proposal.components.count == 1)
    #expect(proposal.diagnostics.map(\.code) == [.incompletePin])
  }

  @Test func vercelChangedContentCannotBePresentedAsLockedContent() throws {
    let fixture = try ImportSourceFixture()
    try fixture.skill()
    try fixture.write(
      """
      {"version":2,"skills":{"review":{"source":"acme/repo","sourceType":"github",
      "computedHash":"\(String(repeating: "a", count: 64))"}}}
      """)
    var input = fixture.input(.vercelProjectV2)
    input.installedSkills = ["review": "installed/review"]
    let proposal = try SourceImport.preview(input)
    #expect(proposal.components.isEmpty)
    #expect(proposal.resources.isEmpty)
    #expect(proposal.diagnostics.contains { $0.code == .integrityMismatch })
  }

  @Test func vercelUserTreeHashAndLastSelectionAreNotCommitOrTargeting() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"version":3,"lastSelectedAgents":["codex"],"skills":{"review":{
      "source":"acme/repo","sourceType":"github","sourceUrl":"https://github.com/acme/repo",
      "skillFolderHash":"\(String(repeating: "a", count: 40))","ref":"main",
      "installedAt":"2026-11-10T00:00:00Z","updatedAt":"2026-11-10T00:00:00Z",
      "future":{"token":"SECRET_LITERAL"}}}}
      """)
    let proposal = try SourceImport.preview(fixture.input(.vercelUserV3))
    #expect(proposal.sources.first?.pin.commit == nil)
    #expect(proposal.sources.first?.pin.integrity?.kind == .githubTree)
    guard case .skills(_, let skill) = proposal.components.first?.declaration else {
      Issue.record("Expected skill proposal")
      return
    }
    #expect(skill.agents == nil)
    #expect(
      proposal.diagnostics.contains {
        $0.code == .unconverted && $0.location.pointer == "/lastSelectedAgents"
      })
    #expect(
      proposal.diagnostics.contains {
        $0.code == .unconverted && $0.location.pointer.hasSuffix("/member[0]/member[0]")
      })
    #expect(!proposal.bindings.isEmpty)
    #expect(!String(describing: proposal).contains("SECRET_LITERAL"))
  }

  @Test func credentialSourceDoesNotEscapeThroughProvenanceOrDiagnostics() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"version":2,"skills":{"review":{"source":"https://SECRET_LITERAL@github.com/acme/repo",
      "sourceType":"github","sourceUrl":"https://github.com/acme/repo?token=SECRET_LITERAL","computedHash":""}}}
      """)
    let before = try FileHash.folderHash(fixture.root)
    let proposal = try SourceImport.preview(fixture.input(.vercelProjectV2))
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(proposal.sources.isEmpty)
    #expect(proposal.bindings.count == 1)
    #expect(proposal.diagnostics.map(\.code) == [.credentialBinding])
    #expect(!String(describing: proposal).contains("SECRET_LITERAL"))
  }

  @Test func vercelUserCapturePinsActualContentAndKeepsProducerTreeUnverified() throws {
    let fixture = try ImportSourceFixture()
    try fixture.skill()
    try fixture.write(
      """
      {"version":3,"skills":{"review":{"source":"acme/repo","sourceType":"github",
      "sourceUrl":"https://github.com/acme/repo","skillFolderHash":"\(String(repeating: "a", count: 40))",
      "installedAt":"2026-11-10T00:00:00Z","updatedAt":"2026-11-10T00:00:00Z"}}}
      """)
    var input = fixture.input(.vercelUserV3)
    input.installedSkills = ["review": "installed/review"]
    let before = try FileHash.folderHash(fixture.root)
    let proposal = try SourceImport.preview(input)
    #expect(try FileHash.folderHash(fixture.root) == before)
    #expect(proposal.sources.allSatisfy { $0.pin.commit == nil })
    #expect(proposal.sources.last?.declaration?.kind == .local)
    #expect(proposal.components.count == 1)
    #expect(proposal.resources.first?.observedHash?.hasPrefix("sha256:") == true)
    #expect(proposal.resources.first?.producerIntegrity?.kind == .githubTree)
    #expect(proposal.diagnostics.contains { $0.message.contains("not verified") })
  }

  @Test(arguments: [
    "{\"version\":2,\"version\":2,\"skills\":{}}",
    "{\"version\":2,\"skills\":{},\"sk\\u0069lls\":{}}",
    "{\"version\":2,\"skills\":{}} trailing",
    "[]",
    "{\"version\":2,\"skills\":{},}",
  ]) func malformedOrAmbiguousJSONIsRejected(_ text: String) throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(text)
    let proposal = try SourceImport.preview(fixture.input(.vercelProjectV2))
    #expect(proposal.components.isEmpty)
    #expect(proposal.diagnostics.map(\.code) == [.invalidInput])
  }

  @Test(arguments: ["true", "1", "3", "null", "\"2\""])
  func unsupportedVersionDoesNotPartiallyImport(_ version: String) throws {
    let fixture = try ImportSourceFixture()
    try fixture.write("{\"version\":\(version),\"skills\":{}}")
    let proposal = try SourceImport.preview(fixture.input(.vercelProjectV2))
    #expect(proposal.sources.isEmpty)
    #expect(proposal.diagnostics.map(\.code) == [.unsupportedVersion])
  }

  @Test func selectionIsExplicitAndMissingSelectionIsDiagnosed() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write("{\"version\":2,\"skills\":{\"unselected\":{\"bad\":true}}}")
    var input = fixture.input(.vercelProjectV2)
    input.selection = []
    #expect(try SourceImport.preview(input).diagnostics.isEmpty)
    input.selection = ["absent"]
    #expect(try SourceImport.preview(input).diagnostics.map(\.code) == [.invalidInput])
  }

  @Test func unknownPayloadAndWrongOptionalTypeAreNeverSilentlyAccepted() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"version":2,"contentObjects":{"unknown":"SECRET_LITERAL"},"skills":{"review":{
      "source":"acme/repo","sourceType":"github","computedHash":"","skillPath":17}}}
      """)
    let proposal = try SourceImport.preview(fixture.input(.vercelProjectV2))
    #expect(proposal.sources.isEmpty)
    #expect(proposal.diagnostics.contains { $0.code == .unconverted })
    #expect(proposal.diagnostics.contains { $0.code == .invalidInput })
    #expect(proposal.diagnostics.last?.location.pointer == "/skills/member[0]/skillPath")
    #expect(!String(describing: proposal).contains("SECRET_LITERAL"))
  }

  @Test func rulesyncCredentialKeyIsRedactedAndLockProfilesAreDistinct() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"lockfileVersion":1,"sources":{"https://SECRET_LITERAL@github.com/org/repo":{
      "resolvedRef":"\(String(repeating: "a", count: 40))","skillsPath":"skills","skills":{}}}}
      """)
    let git = try SourceImport.preview(fixture.input(.rulesyncSourcesV1))
    #expect(git.sources.isEmpty)
    #expect(git.bindings.count == 1)
    #expect(!String(describing: git).contains("SECRET_LITERAL"))
    let npm = try SourceImport.preview(fixture.input(.rulesyncNpmV1))
    #expect(npm.sources.isEmpty)
    #expect(npm.diagnostics.contains { $0.code == .invalidInput })
    #expect(!String(describing: npm).contains("SECRET_LITERAL"))
  }

  @Test func resourceLinksAndDocumentLimitsLeaveInputsUntouched() throws {
    let fixture = try ImportSourceFixture()
    try fixture.skill()
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root.appendingPathComponent("installed/review/secret").path,
      withDestinationPath: "/etc/hosts")
    try fixture.write(
      """
      {"version":2,"skills":{"review":{"source":"acme/repo","sourceType":"github",
      "computedHash":"\(String(repeating: "a", count: 64))"}}}
      """)
    var input = fixture.input(.vercelProjectV2)
    input.installedSkills = ["review": "installed/review"]
    let before = try FileHash.folderHash(fixture.root)
    let proposal = try SourceImport.preview(input)
    #expect(proposal.components.isEmpty)
    #expect(proposal.diagnostics.contains { $0.code == .unsafePath })
    var limits = SourceImportLimits()
    limits.documentBytes = 8
    #expect(
      try SourceImport.preview(input, limits: limits).diagnostics.map(\.code) == [.invalidInput])
    #expect(try FileHash.folderHash(fixture.root) == before)
  }

  @Test func pathTraversalAndExternalSymlinksNeverBecomeResources() throws {
    let fixture = try ImportSourceFixture()
    try fixture.write(
      """
      {"version":2,"skills":{"review":{"source":"acme/repo","sourceType":"github",
      "skillPath":"../outside/SKILL.md","computedHash":""}}}
      """)
    #expect(
      try SourceImport.preview(fixture.input(.vercelProjectV2)).diagnostics.map(\.code) == [
        .unsafePath
      ])
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root.appendingPathComponent("external.json").path,
      withDestinationPath: "/etc/hosts")
    var input = fixture.input(.vercelProjectV2)
    input = .init(profile: input.profile, root: input.root, document: "external.json")
    #expect(try SourceImport.preview(input).diagnostics.map(\.code) == [.unsafePath])
  }
}

private final class ImportSourceFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "import-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }
  func write(_ text: String, at path: String = "input.json") throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }
  func input(_ profile: SourceImportProfile) -> SourceImportInput {
    .init(profile: profile, root: root, document: "input.json")
  }
  func skill() throws {
    try write(
      "---\nname: review\ndescription: Review changes\n---\n# Review\n",
      at: "installed/review/SKILL.md")
  }
}
