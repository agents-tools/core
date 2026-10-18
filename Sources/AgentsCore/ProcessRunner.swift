import Foundation

package struct ProcessOutput: Equatable, Sendable {
  package var stdout: String
  package var stderr: String
  package var exitCode: Int32
}

package enum ProcessRunner {
  @discardableResult
  package static func run(_ executable: String, arguments: [String], workingDirectory: URL? = nil)
    throws -> ProcessOutput
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let stdoutReader = PipeReader(stdout.fileHandleForReading)
    let stderrReader = PipeReader(stderr.fileHandleForReading)
    process.waitUntilExit()

    let output = ProcessOutput(
      stdout: String(data: stdoutReader.waitForOutput(), encoding: .utf8) ?? "",
      stderr: String(data: stderrReader.waitForOutput(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )

    guard output.exitCode == 0 else {
      throw CoreError.commandFailed(
        ([executable] + arguments).joined(separator: " ") + "\n" + output.stderr)
    }
    return output
  }
}

// Each reader drains independently; its queue serializes all access to the captured data.
private final class PipeReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "ProcessRunner.PipeReader")
  private var data = Data()

  init(_ handle: FileHandle) {
    queue.async {
      self.data = handle.readDataToEndOfFile()
    }
  }

  func waitForOutput() -> Data {
    queue.sync { data }
  }
}
