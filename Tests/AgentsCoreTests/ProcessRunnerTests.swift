import Foundation
import Testing

@testable import AgentsCore

@Suite("Process Runner")
struct ProcessRunnerTests {
  @Test func readsLargeStdoutPromptly() throws {
    try expectLargeOutput(stdout: String(repeating: "o", count: 1023) + "\n", stderr: "")
  }

  @Test func readsLargeStderrPromptly() throws {
    try expectLargeOutput(stdout: "", stderr: String(repeating: "e", count: 1023) + "\n")
  }

  @Test func readsLargeInterleavedOutputPromptly() throws {
    try expectLargeOutput(
      stdout: String(repeating: "o", count: 1023) + "🌍\n",
      stderr: String(repeating: "e", count: 1023) + "🌎\n")
  }

  @Test func capturesOutputAndZeroExitCode() throws {
    let output = try ProcessRunner.run(
      "/bin/sh", arguments: ["-c", "printf 'output\\n'; printf 'error\\n' >&2"])

    #expect(output == ProcessOutput(stdout: "output\n", stderr: "error\n", exitCode: 0))
  }

  @Test(arguments: [1, 42, 127])
  func mapsNonzeroExitToCommandFailed(exitCode: Int) throws {
    let arguments = ["-c", "printf 'output\\n'; printf 'error\\n' >&2; exit \(exitCode)"]
    let expected = CoreError.commandFailed(
      (["/bin/sh"] + arguments).joined(separator: " ") + "\nerror\n")

    #expect(throws: expected) {
      try ProcessRunner.run("/bin/sh", arguments: arguments)
    }
  }

  @Test func propagatesLaunchErrors() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("missing-executable")
    let process = Process()
    process.executableURL = executable
    let expected =
      try #require(throws: (any Error).self) {
        try process.run()
      } as NSError

    let actual =
      try #require(throws: (any Error).self) {
        try ProcessRunner.run(executable.path, arguments: [])
      } as NSError

    #expect(actual.domain == expected.domain)
    #expect(actual.code == expected.code)
  }

  @Test func respectsWorkingDirectory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("working directory\n".utf8).write(to: directory.appendingPathComponent("marker"))

    let output = try ProcessRunner.run(
      "/bin/cat", arguments: ["marker"], workingDirectory: directory)

    #expect(output.stdout == "working directory\n")
    #expect(output.stderr.isEmpty)
    #expect(output.exitCode == 0)
  }

  @Test func inheritsEnvironment() throws {
    let environment = ProcessInfo.processInfo.environment
    let output = try ProcessRunner.run(
      "/bin/sh", arguments: ["-c", "printf '%s\\n' \"$HOME\" \"$PATH\""])

    #expect(output.stdout == "\(environment["HOME"] ?? "")\n\(environment["PATH"] ?? "")\n")
    #expect(output.stderr.isEmpty)
    #expect(output.exitCode == 0)
  }

  @Test func preservesInvalidUTF8Fallback() throws {
    let output = try ProcessRunner.run(
      "/bin/sh", arguments: ["-c", "printf '\\377'; printf '\\377' >&2"])

    #expect(output == ProcessOutput(stdout: "", stderr: "", exitCode: 0))
  }

  private func expectLargeOutput(stdout: String, stderr: String) throws {
    // The child alarm makes a blocked pipe fail the test instead of hanging the suite.
    let script = """
      alarm 10;
      select(STDOUT); $| = 1;
      select(STDERR); $| = 1;
      for (1..1024) {
        print STDOUT $ARGV[0];
        print STDERR $ARGV[1];
      }
      """
    let start = ContinuousClock.now
    let output = try ProcessRunner.run("/usr/bin/perl", arguments: ["-e", script, stdout, stderr])

    #expect(start.duration(to: .now) < .seconds(5))
    #expect(output.stdout == String(repeating: stdout, count: 1024))
    #expect(output.stderr == String(repeating: stderr, count: 1024))
    #expect(output.exitCode == 0)
  }
}
