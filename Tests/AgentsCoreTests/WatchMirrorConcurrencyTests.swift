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
    try pause.wait()
    let locks = try gitLocks(fixture)
    try #require(!locks.isEmpty)
    let committed = try fixture.stateBytes()

    // Kill only Swift. Git and its prepared hook remain alive with the real deletion locks.
    terminate(parent)
    try #require(kill(pause.git, 0) == 0)
    try #require(kill(pause.hook, 0) == 0)
    let contention = try ProcessSignal(at: fixture.root.appendingPathComponent("writer-contended"))
    let acknowledger = try stateTestProcess(
      root: fixture.root, arguments: ["watch-acknowledge", first])
    defer { terminate(acknowledger) }
    #expect(try contention.receive() == "contended")
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
    try pause.wait()
    try #require(!exists(scopeLock))
    let mirrorLock = fixture.store.cacheDirectory.appendingPathComponent("locks")
      .appendingPathComponent(fixture.mirror.deletingPathExtension().lastPathComponent + ".lock")
    try #require(exists(mirrorLock))
    let contention = try ProcessSignal(at: fixture.root.appendingPathComponent("writer-contended"))

    let writer = try stateTestProcess(root: fixture.root, arguments: ["watch-subscribe", ""])
    defer { terminate(writer) }
    #expect(try contention.receive() == "contended")
    #expect(exists(scopeLock))
    #expect(writer.isRunning)
    #expect(!exists(fixture.store.watchURL))
    #expect(!exists(fixture.root.appendingPathComponent("writer-finished")))

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
    try pause?.resume()
    for process in processes {
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      if process.isRunning {
        try #require(exited.wait(timeout: .now() + 60) == .success)
      }
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    pause?.completed()
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  private func terminate(_ process: Process) {
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }
}

/// FIFO messages establish ordering; the timeout only bounds a failed handshake.
private final class ProcessSignal {
  let url: URL
  private let descriptor: Int32

  init(at url: URL) throws {
    self.url = url
    try #require(mkfifo(url.path, 0o600) == 0)
    descriptor = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    try #require(descriptor >= 0)
  }

  deinit { close(descriptor) }

  func send(_ message: String) throws {
    let data = Data((message + "\n").utf8)
    let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    try #require(count == data.count)
  }

  func receive() throws -> String {
    let deadline = Date().addingTimeInterval(60)
    var bytes = [UInt8]()
    while true {
      var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let timeout = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
      let result = poll(&event, 1, timeout)
      if result < 0 && errno == EINTR { continue }
      try #require(result > 0, "Timed out waiting for \(url.lastPathComponent)")
      var byte: UInt8 = 0
      try #require(Darwin.read(descriptor, &byte, 1) == 1)
      if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
      bytes.append(byte)
    }
  }
}

private final class GitTransactionPause {
  private let ready: ProcessSignal
  private let release: ProcessSignal
  private let marker: URL
  private(set) var git: Int32 = 0
  private(set) var hook: Int32 = 0
  private var finished = false

  init(root: URL, hooks: URL, condition: String) throws {
    ready = try ProcessSignal(at: root.appendingPathComponent("git-transaction-ready"))
    release = try ProcessSignal(at: root.appendingPathComponent("git-transaction-release"))
    marker = root.appendingPathComponent("git-transaction-pids")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    func quoted(_ url: URL) -> String {
      "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    // Blocking on a pipe keeps the prepared transaction alive through a parent-only kill.
    // The marker also records the children for cleanup if the readiness handshake fails.
    let script = """
      #!/bin/sh
      if [ "$1" = prepared ] && [ ! -f \(quoted(marker)) ]; then
        while read -r old new ref; do
          if \(condition); then
            printf '%s %s\\n' "$PPID" "$$" > \(quoted(marker)).new
            mv \(quoted(marker)).new \(quoted(marker))
            printf '%s %s\\n' "$PPID" "$$" > \(quoted(ready.url))
            read -r released < \(quoted(release.url))
            break
          fi
        done
      fi
      """
    let file = hooks.appendingPathComponent("reference-transaction")
    try Data(script.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
  }

  func wait() throws {
    let pids = try ready.receive().split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    try #require(pids.count == 2)
    git = pids[0]
    hook = pids[1]
  }

  func resume() throws { try release.send("release") }

  func completed() { finished = true }

  func terminate() {
    guard !finished else { return }
    let pids =
      (try? String(contentsOf: marker, encoding: .utf8))?
      .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) } ?? []
    for pid in pids { Darwin.kill(pid, SIGKILL) }
  }
}
