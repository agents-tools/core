import Foundation

/// Every wait on a test child is bounded. Marker, stop and exit waits share one deadline and a
/// diagnostic naming the child's last checkpoint; termination has its own shorter deadline.
package enum ProcessWait {
  package static func marker(_ file: URL, child: Process, root: URL, timeout: TimeInterval = 120)
    throws
  {
    try until(child, root: root, timeout: timeout, description: file.lastPathComponent) {
      FileManager.default.fileExists(atPath: file.path)
    }
  }

  package static func exit(_ child: Process, root: URL, timeout: TimeInterval = 120) throws {
    try until(child, root: root, timeout: timeout, description: "process exit") { !child.isRunning }
    child.waitUntilExit()
  }

  /// A checkpoint writes its marker before raising SIGSTOP. Signals sent before the stop takes
  /// effect can be lost, so a paused child is resumed or killed only after this returns.
  package static func stopped(_ child: Process, root: URL, timeout: TimeInterval = 120) throws {
    try until(child, root: root, timeout: timeout, description: "process stop") {
      isStopped(child.processIdentifier)
    }
  }

  /// `WNOWAIT` leaves the stop reportable; Foundation reaps only exits.
  private static func isStopped(_ processIdentifier: Int32) -> Bool {
    var info = siginfo_t()
    guard waitid(P_PID, id_t(processIdentifier), &info, WSTOPPED | WNOHANG | WNOWAIT) == 0 else {
      return false
    }
    return info.si_signo == SIGCHLD && info.si_code == Int32(CLD_STOPPED)
  }

  /// SIGKILL can be lost while a child is stopping itself, so it is resent until the exit is
  /// observed. The deadline bounds the whole termination.
  package static func terminate(
    _ child: Process, timeout: TimeInterval = 30, retry: TimeInterval = 0.2,
    send: (Int32) -> Void = { _ = kill($0, SIGKILL) }
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while child.isRunning {
      guard Date() < deadline else {
        throw WaitFailure(
          message:
            "Process \(child.processIdentifier) survived SIGKILL for \(timeout) seconds")
      }
      send(child.processIdentifier)
      let resend = min(deadline, Date().addingTimeInterval(retry))
      while child.isRunning, Date() < resend { Thread.sleep(forTimeInterval: 0.005) }
    }
    child.waitUntilExit()
  }

  package static func condition(_ child: Process, root: URL, description: String, ready: () -> Bool)
    throws
  {
    try until(child, root: root, timeout: 120, description: description, ready: ready)
  }

  /// A grandchild has no waitable exit status in this process; its parent owns that status.
  package static func condition(
    processIdentifier: Int32, root: URL, description: String,
    isRunning: () -> Bool, ready: () -> Bool
  ) throws {
    try until(
      processIdentifier: processIdentifier, root: root, timeout: 120, description: description,
      isRunning: isRunning, status: { "unavailable: not a direct child" }, ready: ready)
  }

  private static func until(
    _ child: Process, root: URL, timeout: TimeInterval,
    description: String, ready: () -> Bool
  ) throws {
    try until(
      processIdentifier: child.processIdentifier, root: root, timeout: timeout,
      description: description, isRunning: { child.isRunning },
      status: {
        child.isRunning
          ? "unavailable while running" : "\(child.terminationStatus) (\(child.terminationReason))"
      }, ready: ready)
  }

  private static func until(
    processIdentifier: Int32, root: URL, timeout: TimeInterval, description: String,
    isRunning: () -> Bool, status: () -> String, ready: () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready(), isRunning(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard ready() else {
      let trace = root.appendingPathComponent("checkpoint-\(processIdentifier).log")
      let last =
        (try? String(contentsOf: trace, encoding: .utf8))?.split(separator: "\n").last.map(
          String.init) ?? "none"
      throw WaitFailure(
        message:
          "Timed out or exited before \(description); alive=\(isRunning()), exit=\(status()), last checkpoint=\(last)"
      )
    }
  }

  private struct WaitFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
}
