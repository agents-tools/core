import AgentsCore
import Darwin
import Foundation
import Testing

@Suite("Watch mirror exclusion")
struct WatchMirrorConcurrencyTests {
  @Test(arguments: [false, true])
  func parentDeathKeepsGitDeletionExclusive(_ packed: Bool) throws {
    let fixture = try WatchGitFixture()
    let first = try fixture.head()
    try fixture.watch.add("source", environment: fixture.environment)
    try fixture.rewrite("replacement")
    _ = try fixture.watch.status(environment: fixture.environment)
    if packed { try fixture.mirrorGit(["pack-refs", "--all"]) }
    let pause = try GitTransactionPause(
      root: fixture.root, hooks: fixture.mirror.appendingPathComponent("hooks"),
      condition:
        "[ \"$ref\" = \"refs/agents-watch/\(first)\" ] && [ \"$new\" = \"\(String(repeating: "0", count: first.count))\" ]"
    )
    defer { pause.terminate() }
    let parent = try stateTestProcess(root: fixture.root, arguments: ["watch-seen", ""])
    defer { terminate(parent) }
    try pause.wait(for: parent)
    let locks = try gitLocks(fixture)
    try #require(!locks.isEmpty)
    let committed = try fixture.stateBytes()

    // Kill only Swift. Git and its prepared hook remain alive with the real deletion locks.
    terminate(parent)
    try #require(kill(pause.git, 0) == 0)
    try #require(kill(pause.hook, 0) == 0)
    let acknowledger = try stateTestProcess(
      root: fixture.root, arguments: ["watch-acknowledge", first])
    defer { terminate(acknowledger) }
    try waitFor(fixture.root.appendingPathComponent("writer-waiting"), process: acknowledger)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(acknowledger.isRunning)
    #expect(!exists(fixture.root.appendingPathComponent("writer-finished")))
    #expect(try fixture.stateBytes() == committed)
    let currentLocks = try gitLocks(fixture)
    #expect(currentLocks == locks)

    // Recovery and re-acknowledgment must follow the surviving Git child's completion.
    try finish([acknowledger], resuming: pause)
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(first))
    #expect(try fixture.watchRefs() == [first])
    #expect(try gitLocks(fixture).isEmpty)
    try fixture.mirrorGit(["reflog", "expire", "--expire=now", "--all"])
    try fixture.mirrorGit(["gc", "--prune=now"])
    #expect(try fixture.cachedInstruction(first).contains("initial"))
  }

  @Test(arguments: [false, true])
  func listingAndFirstWatchMutationShareMirrorLock(_ existingMirror: Bool) throws {
    let fixture = try WatchGitFixture()
    try FileManager.default.removeItem(at: fixture.store.directory)
    let scopeLock = fixture.store.directory.appendingPathComponent(".agents.lock")
    let template = fixture.root.appendingPathComponent("template")
    if existingMirror {
      let listing = try stateTestProcess(root: fixture.root, arguments: ["instruction-list", ""])
      defer { terminate(listing) }
      try finish([listing])
      try #require(exists(fixture.mirror))
      try #require(!exists(scopeLock))
      try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("listing-finished"))
      try Data("# Rule\nupdated\n".utf8).write(
        to: fixture.repo.appendingPathComponent("instructions/rule.md"))
      try fixture.git(["commit", "-am", "update"])
    }
    let pause = try GitTransactionPause(
      root: fixture.root,
      hooks: (existingMirror ? fixture.mirror : template).appendingPathComponent("hooks"),
      condition: "[ \"${ref#refs/heads/}\" != \"$ref\" ]")
    defer { pause.terminate() }
    let listing = try stateTestProcess(
      root: fixture.root, arguments: ["instruction-list", ""],
      environment: existingMirror ? [:] : ["GIT_TEMPLATE_DIR": template.path])
    defer { terminate(listing) }
    try pause.wait(for: listing)
    try #require(!exists(scopeLock))
    let mirrorLock = fixture.store.cacheDirectory.appendingPathComponent("locks")
      .appendingPathComponent(fixture.mirror.deletingPathExtension().lastPathComponent + ".lock")
    try #require(exists(mirrorLock))
    let locks = try gitLocks(fixture)
    try #require(!locks.isEmpty)

    let writer = try stateTestProcess(root: fixture.root, arguments: ["watch-subscribe", ""])
    defer { terminate(writer) }
    try waitFor(fixture.root.appendingPathComponent("writer-waiting"), process: writer)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(exists(scopeLock))
    #expect(writer.isRunning)
    #expect(!exists(fixture.store.watchURL))
    #expect(!exists(fixture.root.appendingPathComponent("writer-finished")))
    #expect(try gitLocks(fixture) == locks)

    try finish([listing, writer], resuming: pause)
    #expect(
      try String(
        contentsOf: fixture.root.appendingPathComponent("listing-finished"), encoding: .utf8)
        == "rule")
    #expect(try fixture.store.loadWatch().sources[fixture.id]?.seen == .revision(fixture.head()))
    #expect(try fixture.watchRefs() == [fixture.head()])
    #expect(try gitLocks(fixture).isEmpty)
  }

  private func gitLocks(_ fixture: WatchGitFixture) throws -> [String: Data] {
    let directory = fixture.store.cacheDirectory.appendingPathComponent("mirrors")
    let entries = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    var result: [String: Data] = [:]
    for case let entry as URL in entries where entry.lastPathComponent.hasSuffix(".lock") {
      result[entry.path] = try Data(contentsOf: entry)
    }
    return result
  }

  private func finish(_ processes: [Process], resuming pause: GitTransactionPause? = nil) throws {
    let deadline = Date().addingTimeInterval(30)
    while processes.contains(where: \.isRunning), Date() < deadline {
      pause?.resume()
      Thread.sleep(forTimeInterval: 0.01)
    }
    for process in processes {
      try #require(!process.isRunning)
      #expect(process.terminationStatus == 0)
    }
    pause?.completed()
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  private func waitFor(_ marker: URL, process: Process) throws {
    let deadline = Date().addingTimeInterval(30)
    while !exists(marker), process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(exists(marker))
  }

  private func terminate(_ process: Process) {
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }
}

private final class GitTransactionPause {
  let ready: URL
  let release: URL
  private(set) var git: Int32 = 0
  private(set) var hook: Int32 = 0
  private var finished = false

  init(root: URL, hooks: URL, condition: String) throws {
    ready = root.appendingPathComponent("git-transaction-ready")
    release = root.appendingPathComponent("git-transaction-release")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let marker = "'" + ready.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let released = "'" + release.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    // A stopped orphan process group receives SIGHUP/SIGCONT when its parent dies.
    // Waiting for a file keeps the Git transaction live through a parent-only kill.
    let script = """
      #!/bin/sh
      if [ "$1" = prepared ] && [ ! -f \(marker) ]; then
        while read -r old new ref; do
          if \(condition); then
            printf '%s %s\\n' "$PPID" "$$" > \(marker).new
            mv \(marker).new \(marker)
            while [ ! -f \(released) ]; do sleep 0.01; done
            break
          fi
        done
      fi
      """
    let file = hooks.appendingPathComponent("reference-transaction")
    try Data(script.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
  }

  func wait(for parent: Process) throws {
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: ready.path), parent.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    let pids = try String(contentsOf: ready, encoding: .utf8)
      .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    try #require(pids.count == 2)
    git = pids[0]
    hook = pids[1]
  }

  func resume() { try? Data().write(to: release) }

  func completed() { finished = true }

  func terminate() {
    guard !finished else { return }
    // A failed wait may still have created the hook's marker before reporting its failure.
    let pids =
      (try? String(contentsOf: ready, encoding: .utf8))?
      .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) } ?? []
    for pid in pids { Darwin.kill(pid, SIGKILL) }
  }
}
