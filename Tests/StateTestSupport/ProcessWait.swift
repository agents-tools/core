import Foundation

/// One deadline and one diagnostic format for filesystem handshakes and process completion.
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
