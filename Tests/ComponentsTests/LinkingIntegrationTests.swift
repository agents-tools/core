import AgentsCore
import AgentsInstructions
import AgentsManifest
import Foundation
import Testing

@testable import Components

@Suite("Component integration boundaries", .serialized)
struct LinkingIntegrationTests {
  @Test(arguments: [SourceKind.local, .git])
  func annotatedObjectsConjoinAndFreezeAsCommits(_ kind: SourceKind) throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    try fixture.manifest(
      "version: 1\nexports: [g]\ngroups: {g: {components: [{kind: skills, source: .}]}}",
      at: repository)
    let commit = try fixture.commit(repository, tag: "1.0.0")
    try fixture.git(
      repository, ["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "release"])
    let object = try fixture.git(repository, ["rev-parse", "release"])
    let source = SourceDeclaration(
      kind: kind, location: kind == .local ? repository.path : "file://localhost" + repository.path,
      requirement: .revision(object))
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session throws -> Void in
      #expect(
        try session.candidates(for: source, requirements: [.revision(object), .revision(commit)])
          .map(\.revision) == [commit])
      #expect(
        try session.candidates(for: source, requirements: [.revision(object), .exact("1.0.0")])
          .first?.revision == commit)
      let selected = try session.snapshot(source, at: .init(revision: object))
      #expect(selected.snapshot.revision == commit)
      #expect(selected.pin?.revision == commit)
    }
    let field = kind == .local ? "path" : "url"
    let document = try fixture.document(
      "version: 1\nsources: {p: {\(field): '\(source.location)', requirement: {revision: '\(object)'}}}\nuses: [{source: p, group: g}]"
    )
    let (graph, ledger) = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      var locations = [
        "local:" + fixture.project.path: LedgerLocation(
          kind: .registered, root: "project", path: ".")
      ]
      if kind == .local {
        locations["local:" + repository.path] = .init(
          kind: .authoringRelative, root: "project", path: "../repository")
      }
      return (
        graph,
        try LedgerFreeze.freeze(
          graph, session: session, locations: .init(sources: locations), limits: .standard)
      )
    }
    let decoded = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(ledger, limits: .standard), limits: .standard)
    #expect(decoded.components.values.first?.revision == commit)
    #expect(decoded.sources.values.contains { $0.kind == kind && $0.revision == commit })
    #expect(graph.components.first?.pin?.revision == commit)
    #expect(graph.references.first?.snapshot.revision == commit)
    let cache = SourceCache(store: fixture.store)
    _ = try cache.resolve(source)
    try fixture.git(repository, ["tag", "--delete", "release"])
    try FileManager.default.removeItem(at: repository)
    let before = try FileHash.folderHash(fixture.store.cacheDirectory)
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session throws -> Void in
      #expect(
        try session.candidates(for: source, requirements: [.revision(object), .revision(commit)])
          .map(\.revision) == [commit])
      #expect(try session.snapshot(source, at: .init(revision: object)).snapshot.revision == commit)
      #expect(throws: (any Error).self) {
        try session.snapshot(source, at: .init(revision: "main"))
      }
    }
    #expect(try FileHash.folderHash(fixture.store.cacheDirectory) == before)
  }

  @Test func exactRelativeSourceKeepsItsDeclaringEnvironment() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    let commit = try fixture.commit(repository)
    let source = SourceDeclaration(
      kind: .local, location: "../repository", requirement: .revision(commit))
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      let candidate = try #require(
        try session.candidates(for: source, requirements: [.revision(commit)]).first)
      let view = try session.snapshot(source, at: candidate)
      #expect(view.snapshot.source == "local:" + repository.path)
      #expect(view.localEnvironment?.projectDirectory.path == repository.path)
      #expect(view.snapshot.revision == commit)
    }
  }

  @Test func selectedOwnSectionDoesNotReadUnrelatedDrafts() throws {
    let fixture = try LinkFixture()
    try fixture.instruction("guide", at: fixture.project, restrictions: "agents: [\"codex\"]\n")
    try fixture.write(
      "---\ndescription: [unterminated\n---\nDraft", to: ".agent/instructions/draft.md",
      base: fixture.project)
    let graph = try fixture.link(
      "version: 1\ncomponents: [{kind: instructions, sections: [{name: guide}]}]")
    #expect(graph.components.map(\.key.name) == ["guide"])
    #expect(graph.components[0].recipients == [.codex])
    let view = try SourceSnapshot(
      snapshot: .init(source: "own", revision: "live"), pin: nil, root: fixture.project)
    #expect(throws: (any Error).self) { try InstructionSnapshotReader.read(view, own: true) }
    #expect(throws: (any Error).self) {
      try fixture.link("version: 1\ncomponents: [{kind: instructions, sections: [{name: draft}]}]")
    }
    #expect(throws: (any Error).self) {
      try fixture.link(
        "version: 1\ncomponents: [{kind: instructions, sections: [{name: missing}]}]")
    }
    let guide = fixture.project.appendingPathComponent(".agent/instructions/guide.md")
    try FileManager.default.removeItem(at: guide)
    try fixture.write(
      "---\ndescription: Selected\n---\nBody", to: "other.md", base: fixture.project)
    try FileManager.default.createSymbolicLink(
      at: guide, withDestinationURL: fixture.project.appendingPathComponent("other.md"))
    #expect(throws: (any Error).self) {
      try fixture.link("version: 1\ncomponents: [{kind: instructions, sections: [{name: guide}]}]")
    }
  }

  @Test func namedReaderPreservesDiscoveryAndRejectsSelectedContainerLinks() throws {
    let fixture = try LinkFixture()
    let published = fixture.project.appendingPathComponent("published")
    try fixture.instruction("guide", at: published, restrictions: "scopes: [\"project\"]\n")
    try fixture.write(
      "---\ndescription: [broken\n---\nDraft", to: ".agent/instructions/draft.md", base: published)
    let view = try SourceSnapshot(
      snapshot: .init(source: "reader", revision: "live"), pin: nil, root: fixture.project,
      discoveryPath: "published")
    let selected = try InstructionSnapshotReader.read(view, own: "guide")
    let section = try #require(selected)
    #expect(section.path == "published/.agent/instructions/guide.md")
    #expect(section.section.condition.scopes == [.project])
    #expect(try InstructionSnapshotReader.read(view, own: "missing") == nil)
    #expect(throws: (any Error).self) { try InstructionSnapshotReader.read(view, own: "../guide") }
    #expect(throws: (any Error).self) { try InstructionSnapshotReader.read(view, own: "draft") }
    #expect(throws: (any Error).self) { try InstructionSnapshotReader.read(view, own: true) }
    let agentRoot = try SourceSnapshot(
      snapshot: view.snapshot, pin: nil, root: fixture.project, discoveryPath: "published/.agent")
    #expect(try InstructionSnapshotReader.read(agentRoot, own: "guide") == section)
    let container = published.appendingPathComponent(".agent/instructions")
    let moved = published.appendingPathComponent("actual")
    try FileManager.default.moveItem(at: container, to: moved)
    try FileManager.default.createSymbolicLink(at: container, withDestinationURL: moved)
    #expect(throws: (any Error).self) { try InstructionSnapshotReader.read(view, own: "guide") }
  }

  @Test func exactAcquisitionDoesNotRefreshFrozenExpressions() throws {
    let fixture = try LinkFixture()
    let sourceRoot = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(sourceRoot)
    try fixture.skill("one", at: sourceRoot)
    let first = try fixture.commit(sourceRoot)
    let source = SourceDeclaration(kind: .git, location: "file://localhost" + sourceRoot.path)
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      #expect(try session.candidates(for: source, requirements: [nil]).first?.revision == first)
      try fixture.skill("two", at: sourceRoot)
      let second = try fixture.commit(sourceRoot)
      try fixture.git(sourceRoot, ["-c", "tag.gpgsign=false", "tag", "-a", "later", "-m", "later"])
      let object = try fixture.git(sourceRoot, ["rev-parse", "later"])
      #expect(
        try session.candidates(for: source, requirements: [.revision(object)]).first?.revision
          == second)
      #expect(
        try session.candidates(for: source, requirements: [.revision("main")]).first?.revision
          == first)
      #expect(
        try session.candidates(for: source, requirements: [.branch("main")]).first?.revision
          == first)
      #expect(try session.snapshot(source, at: .init(revision: second)).snapshot.revision == second)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }

  @Test func allMembershipUsesOverrideViewsAndCanonicalNames() throws {
    let fixture = try LinkFixture()
    let source = fixture.root.appendingPathComponent("skills")
    try fixture.initialize(source)
    try fixture.skill("Stable Skill", at: source)
    try fixture.commit(source)
    try fixture.skill("Live Draft", at: source)
    try FileManager.default.moveItem(
      at: source.appendingPathComponent("skills/Live Draft"),
      to: source.appendingPathComponent("skills/folder"))
    try fixture.skill("unrelated", at: source)
    func expression(_ mode: String, _ override: String, named: Bool = false) -> String {
      "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: skills, source: s, mode: \(mode), \(named ? "select: [live-draft], " : "")overrides: {live-draft: {mode: \(override)}}}]"
    }
    let copy = try fixture.link(expression("copy", "edit"))
    #expect(copy.components.map(\.key.name) == ["live-draft", "stable-skill"])
    let live = try #require(copy.components.first)
    guard case .skill(let skill, .edit, _) = live.payload else {
      Issue.record("expected live override")
      return
    }
    #expect(skill.name == "Live Draft")
    #expect(skill.path == "skills/folder")
    #expect(skill.livePath == source.appendingPathComponent("skills/folder").path)
    try FileManager.default.removeItem(at: source.appendingPathComponent("skills/folder"))
    #expect(
      try fixture.link(expression("copy", "edit")).components.map(\.key.name) == ["stable-skill"])
    #expect(throws: (any Error).self) { try fixture.link(expression("copy", "edit", named: true)) }
    try fixture.skill("Live Draft", at: source)
    #expect(
      try fixture.link(expression("edit", "copy")).components.map(\.key.name) == [
        "stable-skill", "unrelated",
      ])
    #expect(throws: (any Error).self) { try fixture.link(expression("edit", "copy", named: true)) }
    try FileManager.default.removeItem(at: source.appendingPathComponent("skills/Stable Skill"))
    let inverse = try fixture.link(
      "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: skills, source: s, mode: edit, overrides: {stable-skill: {mode: copy}}}]"
    )
    #expect(inverse.components.map(\.key.name) == ["live-draft", "stable-skill", "unrelated"])
    #expect(
      try fixture.link(
        "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: skills, source: s, exclude: [stable-skill]}]"
      ).components.isEmpty)
    try fixture.write(
      "---\nname: broken\ndescription: [invalid]\n---\n", to: "skills/broken/SKILL.md", base: source
    )
    #expect(
      try fixture.link(
        "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: skills, source: s, mode: copy, exclude: [stable-skill], overrides: {stable-skill: {mode: edit}}}]"
      ).components.isEmpty)

  }

  @Test func canonicalKeysKeepAnUnselectedMembersExactPin() throws {
    let fixture = try LinkFixture()
    let source = fixture.root.appendingPathComponent("skills")
    try fixture.initialize(source)
    for name in ["First Skill", "Second Skill"] { try fixture.skill(name, at: source) }
    let first = try fixture.commit(source, tag: "1.0.0")
    let expression =
      "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: skills, source: s, mode: copy}]"
    let before = try fixture.link(expression)
    let preserved = ComponentKey(
      source: "local:" + fixture.project.path, root: ".", group: nil, kind: .skills,
      name: "second-skill")
    #expect(before.components.map(\.key.name) == ["first-skill", "second-skill"])
    try fixture.write("new", to: "skills/First Skill/new", base: source)
    try fixture.write("new", to: "skills/Second Skill/new", base: source)
    let second = try fixture.commit(source, tag: "1.1.0")
    let after = try fixture.link(expression, directPins: [preserved: .init(revision: first)])
    #expect(after.components.map(\.snapshot.revision) == [second, first])
    #expect(after.components.last?.key == preserved)
    try FileManager.default.removeItem(at: source.appendingPathComponent("skills/Second Skill"))
    let third = try fixture.commit(source, tag: "1.2.0")
    let explicit = expression.replacingOccurrences(
      of: "mode: copy}", with: "mode: copy, select: [first-skill, second-skill]}")
    let partial = try fixture.link(explicit, directPins: [preserved: .init(revision: first)])
    #expect(partial.components.map(\.snapshot.revision) == [third, first])
  }

  @Test(arguments: [InstallScope.project, .user])
  func missingConsumerAppendFreezesAsMetadata(_ scope: InstallScope) throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: scope, environment: fixture.environment)
    let source = fixture.project.appendingPathComponent("rules")
    try fixture.initialize(source)
    try fixture.instruction("guide", at: source, own: false)
    try fixture.commit(source)
    let document = try fixture.document(
      "version: 1\nsources: {s: {path: '\(source.path)'}}\ncomponents: [{kind: instructions, chatgpt: {daily: {sections: [{name: guide, source: s}], append: custom.md}}}]"
    )
    let ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: store, platform: .macOS
    ) { graph, session in
      #expect(graph.components[0].resources.count == 1)
      return try LedgerFreeze.freeze(
        graph, session: session,
        locations: .init(sources: [
          "local:" + source.path: .init(kind: .registered, root: "project", path: "rules"),
          "local:" + (scope == .project ? fixture.project : store.directory).path: .init(
            kind: .registered, root: scope == .project ? "project" : "state", path: "."),
        ]), limits: .standard)
    }
    let restored = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(ledger, limits: .standard), limits: .standard)
    let component = try #require(restored.components.values.first)
    let append = try #require(component.payload.object?["localAppend"]?.object)
    #expect(append["root"]?.text == (scope == .project ? "project" : "home"))
    #expect(append["path"]?.text == "custom.md")
    #expect(component.resources.count == 1)
    let value = try #require(component.payload.object?["localAppend"])
    let location = try LedgerLocation(ledgerValue: value)
    let roots = ["project": fixture.project, "home": fixture.home, "state": store.directory]
    #expect(throws: (any Error).self) { try location.readContainedFile(roots: roots) }
    let target = scope == .project ? fixture.project : fixture.home
    for root in [fixture.project, fixture.home, store.directory] {
      try fixture.write(root == target ? "first" : "shadow", to: "custom.md", base: root)
    }
    #expect(try location.readContainedFile(roots: roots) == Data("first".utf8))
    try fixture.write("current", to: "custom.md", base: target)
    #expect(try location.readContainedFile(roots: roots) == Data("current".utf8))
    #expect(
      try ResolvedLedgerCodec.encode(restored, limits: .standard)
        == ResolvedLedgerCodec.encode(ledger, limits: .standard))
    try FileManager.default.removeItem(at: target.appendingPathComponent("custom.md"))
    try FileManager.default.createDirectory(
      at: target.appendingPathComponent("custom.md"), withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try location.readContainedFile(roots: roots) }
    try FileManager.default.removeItem(at: target.appendingPathComponent("custom.md"))
    try fixture.write("outside", to: "outside.md")
    try FileManager.default.createSymbolicLink(
      at: target.appendingPathComponent("custom.md"),
      withDestinationURL: fixture.root.appendingPathComponent("outside.md"))
    #expect(throws: (any Error).self) { try location.readContainedFile(roots: roots) }
  }
}
