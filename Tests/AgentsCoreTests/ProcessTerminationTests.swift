import CPlatform
import Foundation
import StateTestSupport
import Testing

/// A SIGKILL racing a child's own SIGSTOP was observed to be lost on Darwin, leaving the child
/// running or stopped. That interleaving cannot be produced on demand, so these tests pin its
/// handling: a stop is observed before signals that depend on it, and lost SIGKILLs are resent
/// within a bounded deadline.
@Suite("Test process termination")
struct ProcessTerminationTests {
  @Test func pausedChildIsObservedStoppedBeforeResuming() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let child = try stateTestProcess(root: root, arguments: ["pause", "paused"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: child, root: root)
    try ProcessWait.stopped(child, root: root)
    kill(child.processIdentifier, SIGCONT)
    try ProcessWait.exit(child, root: root)
    #expect(child.terminationStatus == 0)
  }

  @Test func stoppedChildIsTerminatedWhenTheFirstKillIsLost() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let child = try stateTestProcess(root: root, arguments: ["pause", "paused"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: child, root: root)
    try ProcessWait.stopped(child, root: root)
    var sends = 0
    try ProcessWait.terminate(child, timeout: 10) { processIdentifier in
      sends += 1
      if sends > 1 { kill(processIdentifier, SIGKILL) }
    }
    #expect(sends >= 2)
    #expect(child.terminationReason == .uncaughtSignal)
  }

  @Test func markedChildThatNeverStopsIsTerminatedWithinTheDeadline() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let child = try stateTestProcess(root: root, arguments: ["unstopped-marker"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: child, root: root)
    #expect(throws: (any Error).self) { try ProcessWait.stopped(child, root: root, timeout: 0.5) }
    let start = Date()
    try ProcessWait.terminate(child, timeout: 10)
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(child.terminationReason == .uncaughtSignal)
  }

  @Test func terminationLoopIsBoundedWhenSignalsNeverArrive() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let child = try stateTestProcess(root: root, arguments: ["unstopped-marker"])
    defer { terminateProcess(child) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: child, root: root)
    let start = Date()
    #expect(throws: (any Error).self) {
      try ProcessWait.terminate(child, timeout: 0.5, send: { _ in })
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed >= 0.5 && elapsed < 2)
    #expect(child.isRunning)
  }
}
