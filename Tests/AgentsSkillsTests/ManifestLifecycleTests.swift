import AgentsManifest
import AgentsSkills
import AgentsUpdates
import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

/// Skill and watch writes through the scope's `agents.yaml` declaration document.
@Suite("Skill declaration documents")
struct ManifestLifecycleTests {
  @Test func freshAddCreatesTheCanonicalDeclarationInTheLockJournal() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let store = fixture.store()
    let entries = JournalEntries()
    _ = try SkillOperations.add(
      AddOptions(
        source: fixture.repo.path, alias: "fixture", agents: [.codex], mode: .copy, all: true,
        environment: fixture.environment),
      checkpoint: { point in
        guard point == TransactionCheckpoint.progress(0, .ready).name else { return }
        let journal = try StateStore.decode(
          Data(contentsOf: store.directory.appendingPathComponent(TransactionJournal.fileName)),
          as: TransactionJournal.self)
        entries.value = journal.entries
      })
    #expect(
      Set(["codex/demo", "state/agents.yaml", "state/agents.resolved"]).isSubset(
        of: Set(entries.value.map(\.path))))
    #expect(entries.value.allSatisfy { $0.preimage == nil })
    #expect(
      String(decoding: try Data(contentsOf: store.declarationURL), as: UTF8.self) == """
        version: 1
        sources:
          "fixture": {"path": "\(fixture.repo.path)"}
        components:
          - {"kind": "skills", "source": "fixture", "select": "all", "exclude": [], "mode": "copy", "overrides": {}, "agents": ["codex"], "native": {}}

        """)
    #expect(try store.loadResolved().skills["demo"]?.installs == ["codex": .copy])
  }

  @Test func skillAndWatchEditsKeepCommentsAndUntouchedBytes() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.skill("other", body: "B")
    try fixture.commit()
    let store = fixture.store()
    let header = """
      # Team skills, reviewed weekly.
      version: 1
      sources:
        # The fixture repository.
        fixture: {path: "\(fixture.repo.path)"}

      """
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data(
      (header
        + "components:\n  # Everything the fixture publishes.\n  - {kind: skills, source: fixture, agents: [codex]}\n")
        .utf8
    ).write(to: store.declarationURL)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try store.loadResolved().skills.keys.sorted() == ["demo", "other"])
    func text() throws -> String {
      String(decoding: try Data(contentsOf: store.declarationURL), as: UTF8.self)
    }
    func expectUntouched() throws {
      let current = try text()
      #expect(current.hasPrefix(header))
      #expect(current.contains("  # Everything the fixture publishes.\n"))
    }

    try SkillOperations.remove(skillNames: ["demo"], environment: fixture.environment)
    try expectUntouched()
    #expect(try store.loadDeclaration().skills?["fixture"]?.exclude == ["demo"])
    #expect(try store.loadResolved().skills.keys.sorted() == ["other"])

    _ = try SkillOperations.add(
      AddOptions(
        source: "fixture", agents: [.codex], skillNames: ["demo"], environment: fixture.environment)
    )
    try expectUntouched()
    #expect(try store.loadDeclaration().skills?["fixture"]?.exclude == nil)

    let watch = SkillOperations.watchOperations()
    try watch.add("fixture", environment: fixture.environment)
    try expectUntouched()
    #expect(try store.loadDeclaration().watch == ["fixture"])
    try watch.remove("fixture", environment: fixture.environment)
    try expectUntouched()
    // Only the component fields and the watch field were edited.
    let final = try text()
    #expect(
      final.hasPrefix(
        header
          + "components:\n  # Everything the fixture publishes.\n  - {kind: skills, source: fixture, agents: [codex]"
      ))
    #expect(final.hasSuffix("\"watch\": []\n"))
    let declaration = try store.loadDeclaration()
    #expect(declaration.watch == nil)
    #expect((try declaration.skills)?["fixture"]?.select == .all)
    #expect((try declaration.skills)?["fixture"]?.exclude == nil)
    #expect(try store.loadResolved().skills.keys.sorted() == ["demo", "other"])
  }

  @Test func unchangedUpdateKeepsTheDeclarationFile() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let declaration = fixture.store().declarationURL
    let before = try FileStatus(declaration)
    let results = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(results.allSatisfy { !$0.changed })
    let after = try FileStatus(declaration)
    #expect(after == before)
  }

  /// A comment-only edit during the callback changes no declared intent but still invalidates
  /// the preparation.
  @Test func commentEditBeforeApplyRejectsTheUpdate() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    try fixture.skill("demo", body: "B")
    try fixture.commit()
    let store = fixture.store()
    let lock = try Data(contentsOf: store.resolvedURL)
    let target = try fixture.body(fixture.target("demo"))
    var edited = Data()
    #expect {
      try SkillOperations.updateInstalled(
        environment: fixture.environment, apply: true,
        beforeApply: { _ in
          edited = try Data(contentsOf: store.declarationURL) + Data("# Reviewed.\n".utf8)
          try edited.write(to: store.declarationURL)
        })
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("changed during preparation")
    }
    #expect(try Data(contentsOf: store.declarationURL) == edited)
    #expect(try Data(contentsOf: store.resolvedURL) == lock)
    #expect(try fixture.body(fixture.target("demo")) == target)
  }

  /// Unsupported shared aliases stop before retaining content or touching targets.
  @Test func unsupportedSelectionStopsAnAddBeforeRetention() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.skill("other", body: "B")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let store = fixture.store()
    let declaration = Data(
      """
      version: 1
      sources: {"fixture": {"path": "\(fixture.repo.path)"}}
      components: [{"kind": "skills", "source": "fixture", "select": &picked [demo], "mode": "copy", "agents": ["codex"]}]
      """.utf8)
    try declaration.write(to: store.declarationURL)
    let before = try snapshot(fixture.environment.projectDirectory)
    #expect {
      try SkillOperations.add(
        AddOptions(
          source: "fixture", agents: [.codex], skillNames: ["other"], mode: .copy,
          environment: fixture.environment))
    } throws: { error in
      (error as? ManifestFailure)?.diagnostics.first?.code == "manifest.unsupported"
    }
    #expect(try snapshot(fixture.environment.projectDirectory) == before)
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
  }

  @Test func fullDeclarationSurvivesSkillAndWatchWrites() throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    let store = fixture.store()
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let declaration = Data(
      """
      # All declaration families remain owned by this document.
      version: 1
      sources:
        fixture: {path: "\(fixture.repo.path)"}
        unused: {path: ./not-present}
      groups:
        unused: {components: [{kind: skills, source: unused, select: [draft]}]}
      components:
        - {kind: skills, source: fixture, agents: [codex], mode: copy}
        # A valid inactive declaration needs no native target.
        - {kind: mcpServer, name: tools, agents: [], transport: {kind: stdio, executable: never-run}}

      """.utf8)
    try declaration.write(to: store.declarationURL)
    #expect(try SkillOperations.listManaged(environment: fixture.environment).isEmpty)
    _ = try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { try $0.apply() }
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    let ledger = try store.loadLedger()
    #expect(ledger.version == 2)
    #expect(ledger.components.values.contains { $0.kind == "mcpServer" && $0.recipients.isEmpty })
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
    try fixture.skill("other", body: "B")
    try fixture.commit()
    _ = try SkillOperations.add(
      AddOptions(
        source: "fixture", agents: [.codex], skillNames: ["other"], mode: .copy,
        environment: fixture.environment))
    let watch = SkillOperations.watchOperations()
    try watch.add("fixture", environment: fixture.environment)
    let lock = try Data(contentsOf: store.resolvedURL)
    let before = try snapshot(fixture.root)
    #expect(
      try SkillOperations.listManaged(environment: fixture.environment).map(\.name).sorted() == [
        "demo", "other",
      ])
    _ = try SkillOperations.doctor(environment: fixture.environment)
    _ = try watch.status(environment: fixture.environment)
    #expect(try snapshot(fixture.root) == before)
    try watch.remove("fixture", environment: fixture.environment)
    #expect(try Data(contentsOf: store.resolvedURL) == lock)
    let document = try #require(try store.loadManifest())
    #expect(document.declaration.groups.count == 1)
    #expect(document.declaration.components.contains { $0.kind == "mcpServer" })
    #expect(try store.loadDeclaration().sources["unused"]?.location == "./not-present")
    #expect(
      String(decoding: document.bytes, as: UTF8.self).contains("# A valid inactive declaration"))
  }

}

/// Checkpoint callbacks run synchronously in the calling test.
private final class JournalEntries: @unchecked Sendable {
  var value: [TransactionJournal.Entry] = []
}

/// The inode and modification time a rewrite would change.
private struct FileStatus: Equatable {
  let inode: UInt64
  let seconds: Int
  let nanoseconds: Int

  init(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CoreError.notFound(url.path) }
    inode = UInt64(info.st_ino)
    #if canImport(Darwin)
      seconds = info.st_mtimespec.tv_sec
      nanoseconds = info.st_mtimespec.tv_nsec
    #else
      seconds = info.st_mtim.tv_sec
      nanoseconds = info.st_mtim.tv_nsec
    #endif
  }
}

private func snapshot(_ directory: URL) throws -> [String: Data] {
  var result: [String: Data] = [:]
  let entries = try #require(FileManager.default.enumerator(atPath: directory.path))
  for case let path as String in entries {
    let url = directory.appendingPathComponent(path)
    if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
      result[path] = Data(("link:" + destination).utf8)
    } else if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
      result[path] = try Data(contentsOf: url)
    } else {
      result[path] = Data()
    }
  }
  return result
}
