import Foundation
import Testing

@testable import AgentsCore

/// Watch writes take their journal preimages and lock baseline before the Git acknowledgment,
/// which can be slow; editors that ignore the scope lock may change state meanwhile.
@Suite("Watch preparation evidence")
struct WatchPreparationTests {
  @Test func declarationEditedDuringAcknowledgmentIsPreserved() throws {
    let fixture = try WatchGitFixture()
    let watchBefore = try FileSnapshot.read(at: fixture.store.watchURL)
    let edited = try StateStore.encodeState(
      Declaration(
        agents: [.codex],
        sources: ["source": SourceDeclaration(kind: .local, location: fixture.repo.path)]))
    let external = ExternalEdit()
    let watch = fixture.operations { [store = fixture.store] in
      try edited.write(to: store.declarationURL)
      external.snapshot = try FileSnapshot.read(at: store.declarationURL)
    }
    #expect {
      try watch.add("source", environment: fixture.environment)
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("changed during preparation")
        && reason.contains(fixture.store.declarationURL.lastPathComponent)
    }
    #expect(external.snapshot != nil)
    #expect(try FileSnapshot.read(at: fixture.store.declarationURL) == external.snapshot)
    #expect(try FileSnapshot.read(at: fixture.store.watchURL) == watchBefore)
  }

  @Test func lockEditedDuringAcknowledgmentPreventsPruning() throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    let unreferenced = fixture.store.cacheDirectory.appendingPathComponent(
      "artifact-content/" + String(repeating: "a", count: 64))
    try FileManager.default.createDirectory(at: unreferenced, withIntermediateDirectories: true)
    try Data("unreferenced".utf8).write(to: unreferenced.appendingPathComponent("SKILL.md"))
    let cached = try FileSnapshot.read(at: unreferenced)
    let declaration = try FileSnapshot.read(at: fixture.store.declarationURL)
    let watchBefore = try FileSnapshot.read(at: fixture.store.watchURL)
    let edited = try StateStore.encodeState(
      ResolvedState(sources: ["local:/edited": LockedSource(kind: .local)]))
    let external = ExternalEdit()
    let watch = fixture.operations { [store = fixture.store] in
      try edited.write(to: store.resolvedURL)
      external.snapshot = try FileSnapshot.read(at: store.resolvedURL)
    }
    #expect {
      try watch.seen("source", environment: fixture.environment)
    } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("changed during preparation")
        && reason.contains(fixture.store.resolvedURL.lastPathComponent)
    }
    #expect(external.snapshot != nil)
    #expect(try FileSnapshot.read(at: fixture.store.resolvedURL) == external.snapshot)
    #expect(try FileSnapshot.read(at: unreferenced) == cached)
    #expect(try FileSnapshot.read(at: fixture.store.declarationURL) == declaration)
    #expect(try FileSnapshot.read(at: fixture.store.watchURL) == watchBefore)
  }
}

private final class ExternalEdit: @unchecked Sendable {
  private let lock = NSLock()
  private var value: FileSnapshot?
  var snapshot: FileSnapshot? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      value = newValue
    }
  }
}

extension WatchGitFixture {
  /// Runs `edit` once, after the Git fetch and before the scope journal is written.
  fileprivate func operations(edit: @escaping @Sendable () throws -> Void) -> WatchOperations {
    WatchOperations(
      discoverSkills: { _ in [] },
      fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") },
      checkpoint: { step in
        if step == "watch.mirror.fetched" { try edit() }
      })
  }
}
