import CPlatform
import Foundation

package struct ProcessOutput: Equatable, Sendable {
  package var stdout: String
  package var stderr: String
  package var exitCode: Int32
}

package enum ProcessRunner {
  /// Runs Git plumbing with literal arguments and without inherited Git overrides.
  package static func isolatedGit(
    _ arguments: [String], in directory: URL, inheritingLock descriptor: Int32? = nil
  ) throws -> ProcessOutput {
    let environment = [
      "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
      "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_ATTR_NOSYSTEM": "1", "GIT_NO_REPLACE_OBJECTS": "1",
      "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0",
      "GIT_CEILING_DIRECTORIES": directory.deletingLastPathComponent().path,
    ]
    return try execute(
      "/usr/bin/env",
      arguments: [
        "git", "-c", "core.attributesFile=/dev/null", "-c", "core.hooksPath=/dev/null",
      ] + arguments, workingDirectory: directory, environment: environment, lock: descriptor)
  }

  @discardableResult
  package static func run(
    _ executable: String, arguments: [String], workingDirectory: URL? = nil,
    inheritingLock descriptor: Int32? = nil
  ) throws -> ProcessOutput {
    let output = try execute(
      executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: ProcessInfo.processInfo.environment, lock: descriptor)
    guard output.exitCode == 0 else {
      throw CoreError.commandFailed(
        ([executable] + arguments).joined(separator: " ") + "\n" + output.stderr)
    }
    return output
  }

  @discardableResult
  package static func git(
    _ arguments: [String], operation: GitError.Operation, source: String,
    replacingPaths paths: [URL] = [], inheritingLock descriptor: Int32? = nil,
    offline: Bool = false, managed: ManagedSourceGit? = nil, managedMirror: URL? = nil
  ) throws -> ProcessOutput {
    if let managed { return try managed.command(arguments, lock: descriptor, in: managedMirror) }
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GCM_INTERACTIVE"] = "never"
    if offline {
      environment["GIT_NO_LAZY_FETCH"] = "1"
      environment["GIT_ALLOW_PROTOCOL"] = ""
      environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    }
    let arguments = ["git"] + arguments
    let output = try execute(
      "/usr/bin/env", arguments: arguments, workingDirectory: nil,
      environment: environment, lock: descriptor)
    guard output.exitCode == 0 else {
      throw GitError(
        operation: operation, source: source, stderr: output.stderr,
        command: ["/usr/bin/env"] + arguments, exitCode: output.exitCode, replacingPaths: paths)
    }
    return output
  }

  /// Runs the system Git from a clean workspace with an allowlisted child environment.
  static func isolatedGit(
    _ arguments: [String], in workspace: URL, operation: GitError.Operation, source: String,
    network: Bool = false, certificateAuthority: URL? = nil
  ) throws -> String {
    let executable = "/usr/bin/git"
    let environment = isolatedGitEnvironment(in: workspace, network: network)
    var options = isolatedGitOptions
    if let certificateAuthority {
      options += ["-c", "http.sslCAInfo=" + certificateAuthority.path]
    }
    let args = options + arguments
    let output = try execute(
      executable, arguments: args, workingDirectory: workspace, environment: environment, lock: nil)
    guard output.exitCode == 0 else {
      throw GitError(
        operation: operation, source: source, stderr: output.stderr,
        command: [executable] + args, exitCode: output.exitCode, replacingPaths: [workspace])
    }
    return output.stdout.trimmingCharacters(in: .newlines)
  }

  static func isolatedGitEnvironment(in workspace: URL, network: Bool) -> [String: String] {
    [
      "PATH": "/usr/bin:/bin",
      "HOME": workspace.path,
      "XDG_CONFIG_HOME": workspace.path,
      "CURL_HOME": workspace.path,
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_NO_REPLACE_OBJECTS": "1",
      "GIT_NO_LAZY_FETCH": "1",
      "GIT_ALLOW_PROTOCOL": network ? "https" : "",
      "LC_ALL": "C",
    ]
  }

  static let isolatedGitOptions = [
    "-c", "core.hooksPath=/dev/null",
    "-c", "credential.helper=",
    "-c", "http.extraHeader=",
    "-c", "http.proxy=",
    "-c", "http.followRedirects=false",
    "-c", "http.sslVerify=true",
    "-c", "http.lowSpeedLimit=1",
    "-c", "http.lowSpeedTime=30",
    "-c", "fetch.fsckObjects=true",
    "-c", "transfer.fsckObjects=true",
    "-c", "gc.auto=0",
    "-c", "maintenance.auto=false",
    "-c", "core.fsync=objects,reference,pack-metadata",
    "-c", "core.fsyncMethod=fsync",
  ]

  static func unpackGitArchive(_ archive: URL, into directory: URL) throws {
    let output = try execute(
      "/usr/bin/tar", arguments: ["-xf", archive.path, "-C", directory.path],
      workingDirectory: directory, environment: ["PATH": "/usr/bin:/bin"], lock: nil)
    guard output.exitCode == 0 else {
      throw CoreError.invalidSource("could not extract Git archive")
    }
  }

  static func execute(
    _ executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], lock: Int32?
  ) throws -> ProcessOutput {
    if let lock {
      return try spawn(
        executable, arguments: arguments, workingDirectory: workingDirectory,
        environment: environment, lock: lock)
    }
    return try runProcess(
      executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment
    )
  }

  private static func runProcess(
    _ executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String]
  ) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = environment

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
    _ executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], lock: Int32
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
    let stdout = Pipe()
    let stderr = Pipe()
    defer {
      stdout.fileHandleForWriting.closeFile()
      stderr.fileHandleForWriting.closeFile()
    }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let environment =
      environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
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
      func launch(_ directory: UnsafePointer<CChar>?) throws {
        try check(
          platform_spawn(
            &pid, executable, argv, environment, directory, inheritedLock, inputIsOpen, output,
            error))
      }
      if let workingDirectory {
        try workingDirectory.path.withCString { try launch($0) }
      } else {
        try launch(nil)
      }
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
