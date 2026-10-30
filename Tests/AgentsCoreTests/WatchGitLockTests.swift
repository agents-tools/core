import AgentsCore
import CPlatform
import Foundation
import StateTestSupport
import Testing

@Suite("Watch Git lock recovery")
struct WatchGitLockTests {
  @Test(arguments: [false, true], [false, true])
  func interruptedGitDeletionRecoversWithoutRemovingLiveLocks(_ packed: Bool, _ removing: Bool)
    throws
  {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    let replacement = try fixture.head()
    _ = try fixture.watch.status(environment: fixture.environment)
    if packed { try fixture.mirrorGit(["pack-refs", "--all"]) }
    let hook = fixture.mirror.appendingPathComponent("hooks/reference-transaction")
    // Git's prepared hook runs with the actual ref and packed-refs locks held.
    // Stop only deletion of the old watch ref, leaving fetch and new-ref creation alone.
    let script = """
      #!/bin/sh
      if [ "$1" = prepared ]; then
        while read -r old new ref; do
          if [ "$ref" = "refs/agents-watch/\(first)" ] && [ "$new" = "\(String(repeating: "0", count: first.count))" ]; then
            printf '%s %s\\n' "$PPID" "$$" > git-deletion-ready.new
            mv git-deletion-ready.new git-deletion-ready
            kill -STOP "$$"
          fi
        done
      fi
      """
    try Data(script.utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let ready = fixture.mirror.appendingPathComponent("git-deletion-ready")
    let writer = try stateTestProcess(
      root: fixture.root, arguments: [removing ? "watch-remove" : "watch-seen", ""])
    defer {
      // Freeze the scope owner before killing its Git children, so error handling
      // cannot race the assertions about abandoned locks.
      if writer.isRunning { CPlatform.kill(writer.processIdentifier, SIGSTOP) }
      if let text = try? String(contentsOf: ready, encoding: .utf8) {
        for pid in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
          CPlatform.kill(pid, SIGKILL)
        }
      }
      terminateProcess(writer)
    }
    try waitFor(ready, process: writer)
    var locks = [
      fixture.mirror.appendingPathComponent("refs/agents-watch/\(first).lock"),
      fixture.mirror.appendingPathComponent("packed-refs.lock"),
    ]
    if packed { locks.append(fixture.mirror.appendingPathComponent("packed-refs.new")) }
    for lock in locks { try #require(FileManager.default.fileExists(atPath: lock.path)) }
    let reader = try stateTestProcess(root: fixture.root, arguments: ["read", ""])
    defer { terminateProcess(reader) }
    try waitFor(fixture.root.appendingPathComponent("reader-started"), process: reader)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("reader-finished").path))
    for lock in locks { #expect(FileManager.default.fileExists(atPath: lock.path)) }
    terminateProcess(reader)
    CPlatform.kill(writer.processIdentifier, SIGSTOP)
    let pids = try String(contentsOf: ready, encoding: .utf8)
      .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    try #require(pids.count == 2)
    for pid in pids { CPlatform.kill(pid, SIGKILL) }
    terminateProcess(writer)
    try FileManager.default.removeItem(at: ready)
    try FileManager.default.removeItem(at: hook)
    for lock in locks { #expect(FileManager.default.fileExists(atPath: lock.path)) }
    // Pruning the disappeared upstream branch would need the abandoned packed-refs lock.
    try fixture.rewrite("later")
    let before = try FileHash.folderHash(fixture.store.directory)
    let pending = CoreError.invalidState("transaction recovery is required before inspection")
    #expect(throws: pending) { try fixture.watch.status(environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
    #expect(throws: pending) { try fixture.watch.diff("source", environment: fixture.environment) }
    #expect(try FileHash.folderHash(fixture.store.directory) == before)
    let committed = try fixture.stateBytes()

    let additional = ["config.lock", "objects/pack/abandoned.lock"].map {
      fixture.mirror.appendingPathComponent($0)
    }
    for lock in additional { try Data("abandoned".utf8).write(to: lock) }
    let recovery = try stateTestProcess(
      root: fixture.root, arguments: ["watch-recover", "watch.git-lock.0.0.unlinked"])
    try fixture.kill(recovery, at: "watch.git-lock.0.0.unlinked")
    #expect(
      try fixture.recoveredWatch().sources[fixture.id]?.seen
        == (removing ? nil : .revision(replacement)))
    #expect(try fixture.stateBytes() == committed)
    #expect(try fixture.watchRefs() == (removing ? [] : [replacement]))
    for lock in locks + additional { #expect(!FileManager.default.fileExists(atPath: lock.path)) }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path))
    try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
    try fixture.mirrorGit(["gc", "--prune=now"])
    #expect(throws: (any Error).self) { try fixture.mirrorGit(["cat-file", "-e", first]) }
    if !removing { #expect(try fixture.cachedInstruction(replacement).contains("replacement")) }
    _ = try fixture.watch.status(environment: fixture.environment)
  }

  @Test(arguments: ["symlink", "directory", "fifo"], ["packed-refs.lock", "packed-refs.new"])
  func rejectsUnsafeLockEntriesBeforeRemovingAnyLock(_ kind: String, _ name: String) throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    let external = fixture.root.appendingPathComponent("external-lock")
    let original = Data("external".utf8)
    try original.write(to: external)
    let safe = fixture.mirror.appendingPathComponent("HEAD.lock")
    try original.write(to: safe)
    let unsafe = fixture.mirror.appendingPathComponent(name)
    switch kind {
    case "symlink":
      try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: external)
    case "directory":
      try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
    default:
      try #require(mkfifo(unsafe.path, 0o600) == 0)
    }
    let before = try fixture.stateBytes()
    #expect(throws: CoreError.self) { try fixture.store.loadWatch() }
    #expect(try fixture.stateBytes() == before)
    #expect(try Data(contentsOf: safe) == original)
    #expect(try Data(contentsOf: external) == original)
    #expect(FileManager.default.fileExists(atPath: unsafe.path))
  }

  @Test func recoversUnmarkedLocksWithoutFollowingDirectorySymlinks() throws {
    let fixture = try WatchGitFixture()
    try fixture.watch.add("source", environment: fixture.environment)
    let external = fixture.root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let outsideLock = external.appendingPathComponent("outside.lock")
    let original = Data("external".utf8)
    try original.write(to: outsideLock)
    try FileManager.default.createSymbolicLink(
      at: fixture.mirror.appendingPathComponent("external"), withDestinationURL: external)
    let abandoned = fixture.mirror.appendingPathComponent("HEAD.lock")
    try original.write(to: abandoned)
    let before = try fixture.stateBytes()
    #expect(try fixture.recoveredWatch().sources[fixture.id]?.seen == .revision(fixture.head()))
    #expect(try fixture.stateBytes() == before)
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(try Data(contentsOf: outsideLock) == original)
  }

  private func waitFor(_ marker: URL, process: Process) throws {
    try ProcessWait.marker(marker, child: process, root: marker.deletingLastPathComponent())
  }
}
