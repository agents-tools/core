import Darwin
import Foundation
import Testing

func finishProcesses(_ processes: [Process], resuming pause: GitTransactionPause? = nil) throws {
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

func terminateProcess(_ process: Process) {
  if process.isRunning {
    Darwin.kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }
}

/// FIFO messages establish ordering; the timeout only bounds a failed handshake.
final class ProcessSignal {
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

final class GitTransactionPause {
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
