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
    process.waitUntilExit()

    let output = ProcessOutput(
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        ?? "",
      exitCode: process.terminationStatus
    )

    guard output.exitCode == 0 else {
      throw CoreError.commandFailed(
        ([executable] + arguments).joined(separator: " ") + "\n" + output.stderr)
    }
    return output
  }
}
