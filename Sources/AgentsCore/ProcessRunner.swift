import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package struct ProcessOutput: Equatable, Sendable {
  package var stdout: String
  package var stderr: String
  package var exitCode: Int32
}

package enum ProcessRunner {
  @discardableResult
  package static func run(
    _ executable: String, arguments: [String], workingDirectory: URL? = nil,
    inheritingLock descriptor: Int32? = nil
  ) throws -> ProcessOutput {
    let output: ProcessOutput
    if let descriptor {
      output = try spawn(
        executable, arguments: arguments, workingDirectory: workingDirectory, lock: descriptor)
    } else {
      output = try runProcess(executable, arguments: arguments, workingDirectory: workingDirectory)
    }
    guard output.exitCode == 0 else {
      throw CoreError.commandFailed(
        ([executable] + arguments).joined(separator: " ") + "\n" + output.stderr)
    }
    return output
  }

  private static func runProcess(
    _ executable: String, arguments: [String], workingDirectory: URL?
  ) throws -> ProcessOutput {
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

    return ProcessOutput(
      stdout: String(data: stdoutReader.waitForOutput(), encoding: .utf8) ?? "",
      stderr: String(data: stderrReader.waitForOutput(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )

  }

  /// Spawn actions inherit only this lock and standard streams, without clearing
  /// CLOEXEC in the parent where another thread could concurrently launch a child.
  private static func spawn(
    _ executable: String, arguments: [String], workingDirectory: URL?, lock: Int32
  ) throws -> ProcessOutput {
    func check(_ error: Int32) throws {
      if error != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    }
    func duplicate(_ descriptor: Int32) throws -> Int32 {
      let result = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
      if result < 0 { try check(errno) }
      return result
    }
    // Capture stdin before pipes can reuse a closed standard descriptor. A lock
    // occupying stdin is internal state, not input for the child.
    let inputIsOpen = lock != STDIN_FILENO && fcntl(STDIN_FILENO, F_GETFD) >= 0
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
    if inputIsOpen {
      try check(posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO))
    } else {
      try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    }
    if let workingDirectory {
      try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
    }
    let stdout = Pipe()
    let stderr = Pipe()
    defer {
      stdout.fileHandleForWriting.closeFile()
      stderr.fileHandleForWriting.closeFile()
    }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let environment =
      ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv + environment { free(pointer) }
    }
    var pid: pid_t = 0
    try {
      // Standard-stream actions must not overwrite the lock or another pipe's
      // source, even when open/pipe allocated descriptors 0, 1 or 2 in the host.
      let inheritedLock = try duplicate(lock)
      defer { close(inheritedLock) }
      let output = try duplicate(stdout.fileHandleForWriting.fileDescriptor)
      defer { close(output) }
      let error = try duplicate(stderr.fileHandleForWriting.fileDescriptor)
      defer { close(error) }
      try check(posix_spawn_file_actions_addinherit_np(&actions, inheritedLock))
      try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
      try check(posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO))
      try check(posix_spawn(&pid, executable, &actions, &attributes, argv, environment))
    }()
    stdout.fileHandleForWriting.closeFile()
    stderr.fileHandleForWriting.closeFile()
    let stdoutReader = PipeReader(stdout.fileHandleForReading)
    let stderrReader = PipeReader(stderr.fileHandleForReading)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
      if errno != EINTR { try check(errno) }
    }
    let signal = status & 0x7f
    return ProcessOutput(
      stdout: String(data: stdoutReader.waitForOutput(), encoding: .utf8) ?? "",
      stderr: String(data: stderrReader.waitForOutput(), encoding: .utf8) ?? "",
      exitCode: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
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
