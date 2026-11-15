import AgentsCore
import AgentsManifest
import AgentsSkills
import Components
import Foundation
import Testing

@Suite("Exact component snapshots", .serialized)
struct SnapshotTests {
  @Test func frozenCatalogAndScopedLifetime() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    let first = try fixture.commit(repository, tag: "1.0.0")
    let source = SourceDeclaration(kind: .local, location: repository.path)
    var borrowed: URL?
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      let candidates = try session.candidates(for: source, requirements: [nil])
      #expect(candidates.first?.revision == first)
      try fixture.skill("two", at: repository)
      try fixture.commit(repository, tag: "1.1.0")
      #expect(try session.candidates(for: source, requirements: [nil]) == candidates)
      let snapshot = try session.snapshot(source, at: candidates[0])
      var otherHome = source
      otherHome.environment = SourceEnvironment(
        projectDirectory: fixture.project,
        homeDirectory: fixture.root.appendingPathComponent("other-home"))
      let otherView = try session.snapshot(otherHome, at: candidates[0])
      #expect(otherView.localEnvironment?.homeDirectory == otherHome.environment?.homeDirectory)
      #expect(otherView.localEnvironment?.projectDirectory.path == repository.path)
      borrowed = snapshot.root
      #expect(try SkillSnapshotReader.read(snapshot).map(\.name) == ["one"])
      #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
    }
    #expect(!FileManager.default.fileExists(atPath: try #require(borrowed).path))
  }

  @Test func cachedExactPinAndErrorCleanup() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    let pin = try fixture.commit(repository)
    let source = SourceDeclaration(
      kind: .local, location: repository.path, requirement: .revision(pin))
    let cache = SourceCache(store: fixture.store)
    _ = try cache.resolve(source)
    let before = try FileHash.folderHash(fixture.store.cacheDirectory)
    try FileManager.default.removeItem(at: repository)
    var borrowed: URL?
    enum Stop: Error { case reading }
    #expect(throws: Stop.self) {
      try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
        #expect(
          try session.candidates(for: source, requirements: [source.requirement]).first?.revision
            == pin)
        let snapshot = try session.snapshot(source, at: SourceRevision(revision: pin))
        #expect(snapshot.localEnvironment?.projectDirectory.path == repository.path)
        #expect(snapshot.liveRoot == nil)
        borrowed = snapshot.root
        #expect(try SkillSnapshotReader.read(snapshot).first?.name == "one")
        throw Stop.reading
      }
    }
    #expect(!FileManager.default.fileExists(atPath: try #require(borrowed).path))
    #expect(try FileHash.folderHash(fixture.store.cacheDirectory) == before)
  }

  @Test func remoteContainedSkillsRejectEditAndEscapingLinks() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    try fixture.manifest(
      """
      version: 1
      exports: ["tools"]
      groups: {"tools": {"components": [{"kind": "skills", "source": ".", "mode": "edit"}]}}
      """, at: repository)
    try fixture.commit(repository)
    do {
      _ = try fixture.link(
        """
        version: 1
        sources: {"p": {"url": "file://localhost\(repository.path)"}}
        uses: [{"source": "p", "group": "tools"}]
        """)
      Issue.record("expected immutable edit rejection")
    } catch LinkError.invalid(_, let positions) {
      #expect(!positions.isEmpty)
    }
    let outside = fixture.root.appendingPathComponent("outside")
    try fixture.write("outside", to: "outside")
    try FileManager.default.createSymbolicLink(
      at: repository.appendingPathComponent("escape"), withDestinationURL: outside)
    try fixture.commit(repository)
    #expect(throws: (any Error).self) {
      try fixture.link(
        """
        version: 1
        sources: {"p": {"url": "file://localhost\(repository.path)"}}
        uses: [{"source": "p", "group": "tools"}]
        """)
    }
  }

  @Test func remoteProducerLocalAliasesRemainImmutableAndContained() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("remote")
    try fixture.initialize(repository)
    try fixture.manifest(
      "version: 1\nexports: [\"leaf\"]\ngroups: {\"leaf\": {\"components\": [{\"kind\": \"mcpServer\", \"name\": \"leaf\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"never-run\"}}]}}\n",
      at: repository.appendingPathComponent("child"))
    func producer(path: String, requirement: String = "") throws {
      try fixture.manifest(
        """
        version: 1
        exports: [g]
        sources: {child: {path: "\(path)"\(requirement)}}
        groups: {g: {uses: [{group: leaf, source: child}]}}
        """, at: repository)
      try fixture.commit(repository)
    }
    let expression =
      "version: 1\nsources: {\"p\": {\"url\": \"file://localhost\(repository.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"g\"}]\n"
    try producer(path: "child")
    let graph = try fixture.link(expression)
    #expect(graph.components.first?.key.name == "leaf")
    #expect(graph.components.first?.snapshot.source.contains(":contained:") == true)
    #expect(graph.references[0].snapshot.revision == graph.references[1].snapshot.revision)
    for path in ["../outside", fixture.project.path, "~/outside"] {
      try producer(path: path)
      #expect(throws: (any Error).self) { try fixture.link(expression) }
    }
    try producer(path: "child", requirement: ", requirement: {exact: \"1.0.0\"}")
    #expect(throws: LinkError.self) { try fixture.link(expression) }
    try FileManager.default.createSymbolicLink(
      at: repository.appendingPathComponent("escape"), withDestinationURL: fixture.project)
    try producer(path: "escape")
    #expect(throws: (any Error).self) { try fixture.link(expression) }
  }
}

extension SnapshotTests {
  @Test func cancellationCleansOwnedSnapshots() async throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.skill("one", at: repository)
    let store = fixture.store
    let source = SourceDeclaration(kind: .local, location: repository.path)
    let task = Task.detached { () throws -> URL in
      var path: URL?
      do {
        try SourceResolutionSession.withTemporaryRead(store: store) { session in
          path = try session.localSnapshot(source).root
          withUnsafeCurrentTask { $0?.cancel() }
        }
      } catch is CancellationError {
        return path!
      }
      throw CoreError.invalidState("expected cooperative cancellation")
    }
    let borrowed = try await task.value
    #expect(!FileManager.default.fileExists(atPath: borrowed.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.cacheDirectory.path))
  }

  @Test func namespacesShareVersionWithoutSharingMembers() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    for name in ["a", "b"] {
      let directory = repository.appendingPathComponent(name)
      try fixture.manifest(
        "version: 1\nexports: [\"tools\"]\ngroups: {\"tools\": {\"components\": [{\"kind\": \"mcpServer\", \"name\": \"\(name)\", \"transport\": {\"kind\": \"stdio\", \"executable\": \"never-run\"}}]}}\n",
        at: directory)
    }
    let commit = try fixture.commit(repository)
    var sources: [String] = []
    for name in ["a", "b"] {
      let producer = fixture.root.appendingPathComponent("producer-" + name)
      try fixture.manifest(
        """
        version: 1
        exports: ["tools"]
        sources: {"s": {"url": "file://localhost\(repository.path)", "subpath": "\(name)"}}
        groups: {"tools": {"uses": [{"source": "s", "group": "tools"}]}}
        """, at: producer)
      sources.append("\"\(name)\": {\"path\": \"\(producer.path)\"}")
    }
    let graph = try fixture.link(
      "version: 1\nsources: {\(sources.joined(separator: ","))}\nuses: [{\"source\": \"a\", \"group\": \"tools\"}, {\"source\": \"b\", \"group\": \"tools\"}]\n"
    )
    #expect(graph.components.map(\.key.name) == ["a", "b"])
    #expect(graph.components.map(\.key.root) == ["a", "b"])
    #expect(graph.components.allSatisfy { $0.snapshot.revision == commit })
    #expect(graph.selections.count == 1)
  }
}

extension SnapshotTests {
  @Test func branchRevisionAndVersionConstraintsUseOneAllowedTag() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.write("one", to: "file", base: repository)
    let first = try fixture.commit(repository)
    try fixture.git(repository, ["tag", "-a", "1.0.0+first", "-m", "tag"])
    try fixture.git(repository, ["tag", "1.0.0+second"])
    let source = SourceDeclaration(kind: .local, location: repository.path)
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      let mixed: [SourceRequirement?] = [
        .branch("main"), .revision("refs/tags/1.0.0+first"), .upToNextMajor(from: "1.0.0"),
      ]
      #expect(try session.candidates(for: source, requirements: mixed).first?.revision == first)
      #expect(
        try session.candidates(for: source, requirements: mixed).first?.version == "1.0.0+second")
      #expect(
        try session.candidates(
          for: source, requirements: [.exact("1.0.0+first"), .exact("1.0.0+second")]
        ).isEmpty)
      try fixture.write("two", to: "file", base: repository)
      try fixture.commit(repository)
      // Branch evidence remains fixed after the source advances.
      #expect(try session.candidates(for: source, requirements: mixed).first?.revision == first)
    }
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session throws -> Void in
      #expect(
        try session.candidates(
          for: source,
          requirements: [.branch("main"), .revision(first), .upToNextMajor(from: "1.0.0")]
        ).isEmpty)
    }
  }
}

extension SnapshotTests {
  @Test func missingPersistentMirrorLockIsNotRecreated() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.skill("one", at: repository)
    let pin = try fixture.commit(repository)
    let source = SourceDeclaration(
      kind: .local, location: repository.path, requirement: .revision(pin))
    let cache = SourceCache(store: fixture.store)
    _ = try cache.resolve(source)
    let locks = fixture.store.cacheDirectory.appendingPathComponent("locks")
    for lock in try FileManager.default.contentsOfDirectory(
      at: locks, includingPropertiesForKeys: nil)
    {
      try FileManager.default.removeItem(at: lock)
    }
    let before = try FileHash.folderHash(fixture.store.cacheDirectory)
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      let view = try session.snapshot(source, at: SourceRevision(revision: pin))
      #expect(try SkillSnapshotReader.read(view).map(\.name) == ["one"])
    }
    #expect(try FileHash.folderHash(fixture.store.cacheDirectory) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).isEmpty)
  }

  @Test func resourceEvidenceRemainsReadableOnlyDuringSession() throws {
    let fixture = try LinkFixture()
    let repository = fixture.root.appendingPathComponent("repository")
    try fixture.initialize(repository)
    try fixture.write("Prompt bytes", to: "prompts/review.md", base: repository)
    try fixture.manifest(
      """
      version: 1
      exports: ["tools"]
      groups: {"tools": {"components": [{"kind": "command", "name": "review", "description": "Review", "prompt": {"file": {"path": "prompts/review.md"}}}]}}
      """, at: repository)
    let pin = try fixture.commit(repository, tag: "1.0.0")
    let document = try fixture.document(
      "version: 1\nsources: {\"p\": {\"path\": \"\(repository.path)\"}}\nuses: [{\"source\": \"p\", \"group\": \"tools\"}]\n"
    )
    var borrowed: URL?
    let graph = try ComponentLinker.withLinkedComponents(
      document: document, store: fixture.store, platform: .macOS
    ) { graph, session in
      let resource = try #require(graph.components.first?.resources.first)
      let path = try session.resource(snapshot: resource.snapshot, path: resource.path)
      borrowed = path
      #expect(try String(contentsOf: path, encoding: .utf8) == "Prompt bytes")
      #expect(graph.components.first?.pin?.revision == pin)
      #expect(graph.components.first?.pin?.version == "1.0.0")
      #expect(
        graph.sourceSnapshots.contains {
          $0.snapshot == resource.snapshot && $0.source?.kind == .local
        })
      return graph
    }
    #expect(!graph.sourceSnapshots.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: try #require(borrowed).path))
  }
}

extension SnapshotTests {
  @Test func ownPackageSkillsUseCommittedContentAndLiveEdit() throws {
    let fixture = try LinkFixture()
    try fixture.initialize(fixture.project)
    try fixture.skill("one", at: fixture.project)
    let pin = try fixture.commit(fixture.project)
    try fixture.skill("two", at: fixture.project)
    let linked = try fixture.link(
      "version: 1\ncomponents: [{\"kind\": \"skills\", \"source\": \".\"}]\n")
    #expect(linked.components.map(\.key.name) == ["one"])
    #expect(linked.components[0].pin?.revision == pin)
    let edited = try fixture.link(
      "version: 1\ncomponents: [{\"kind\": \"skills\", \"source\": \".\", \"mode\": \"edit\"}]\n")
    #expect(edited.components.map(\.key.name) == ["one", "two"])
    for component in edited.components {
      guard case .skill(let skill, .edit, _) = component.payload else {
        Issue.record("expected edit")
        continue
      }
      #expect(skill.livePath?.hasPrefix(fixture.project.path) == true)
    }
  }
}
