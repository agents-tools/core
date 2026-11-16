import CPlatform
import Foundation

package struct DuplexProcessConfiguration: Sendable {
  package var executable: String
  package var arguments: [String]
  package var directory: URL
  package var environment: [String: String]

  package init(
    executable: String, arguments: [String], directory: URL, environment: [String: String]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.directory = directory
    self.environment = environment
  }
}

package enum DuplexProcessError: Error, Sendable {
  case invalidInput
  case launchFailed
  case ioFailed
}

package enum DuplexRead: Sendable {
  case bytes(Data)
  case wouldBlock
  case end
}

/// Owns the child's wait status exclusively until group cleanup and reap finish.
/// The unreaped leader reserves its PID/PGID; no group signal is sent after reap
/// or ECHILD. Every descriptor access is locked and every I/O syscall nonblocking.
package final class OwnedDuplexProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptors: [Int32]
  private var owned = true
  private var reaped = false
  package let identifier: Int32
  package let resolvedExecutable: String

  package init(_ configuration: DuplexProcessConfiguration) throws {
    func valid(_ value: String) -> Bool { !value.utf8.contains(0) }
    guard valid(configuration.executable), !configuration.executable.isEmpty,
      valid(configuration.directory.path), configuration.arguments.allSatisfy(valid),
      configuration.environment.allSatisfy({
        !$0.key.isEmpty && !$0.key.contains("=") && valid($0.key) && valid($0.value)
      })
    else { throw DuplexProcessError.invalidInput }
    var isDirectory: ObjCBool = false
    guard configuration.directory.isFileURL,
      FileManager.default.fileExists(
        atPath: configuration.directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw DuplexProcessError.invalidInput }
    let executable: String
    if configuration.executable.contains("/") {
      executable =
        configuration.executable.hasPrefix("/")
        ? configuration.executable
        : configuration.directory.appendingPathComponent(configuration.executable).path
    } else {
      guard let path = configuration.environment["PATH"] else {
        throw DuplexProcessError.invalidInput
      }
      guard configuration.executable.utf8.count <= Int(NAME_MAX) else {
        throw DuplexProcessError.invalidInput
      }
      let candidates = path.split(separator: ":", omittingEmptySubsequences: false).lazy.map {
        entry in
        let path = String(entry)
        let base =
          path.hasPrefix("/")
          ? URL(fileURLWithPath: path, isDirectory: true)
          : configuration.directory.appendingPathComponent(path, isDirectory: true)
        return base.appendingPathComponent(configuration.executable).standardizedFileURL.path
      }
      guard
        let found = candidates.first(where: {
          var directory: ObjCBool = false
          return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
            && !directory.boolValue && access($0, X_OK) == 0
        })
      else {
        throw DuplexProcessError.launchFailed
      }
      executable = found
    }
    guard executable.utf8.count <= Int(PATH_MAX) else { throw DuplexProcessError.invalidInput }
    resolvedExecutable = executable
    let arguments = ([executable] + configuration.arguments).map { strdup($0) } + [nil]
    let environment =
      configuration.environment.sorted(by: { $0.key < $1.key }).map {
        strdup($0.key + "=" + $0.value)
      } + [nil]
    defer { for pointer in arguments + environment { free(pointer) } }
    var pid: pid_t = 0
    var fds: [Int32] = [-1, -1, -1]
    let result = platform_duplex_spawn(
      &pid, executable, arguments, environment, configuration.directory.path, &fds)
    guard result == 0 else { throw DuplexProcessError.launchFailed }
    identifier = pid
    descriptors = fds
  }

  package func readStandardOutput() throws -> DuplexRead { try read(1) }
  package func readStandardError() throws -> DuplexRead { try read(2) }

  private func read(_ index: Int) throws -> DuplexRead {
    try lock.withLock {
      let fd = descriptors[index]
      guard fd >= 0 else { return .end }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = bytes.withUnsafeMutableBytes { buffer in
        CPlatform.read(fd, buffer.baseAddress, buffer.count)
      }
      if count > 0 { return .bytes(Data(bytes.prefix(count))) }
      if count == 0 {
        close(fd)
        descriptors[index] = -1
        return .end
      }
      if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .wouldBlock }
      throw DuplexProcessError.ioFailed
    }
  }

  package func write(_ bytes: Data, offset: Int) throws -> Int {
    try lock.withLock {
      guard offset >= 0 && offset <= bytes.count else { throw DuplexProcessError.invalidInput }
      if offset == bytes.count { return 0 }
      guard descriptors[0] >= 0 else { throw DuplexProcessError.ioFailed }
      let count = bytes.withUnsafeBytes { buffer in
        platform_duplex_write(
          descriptors[0], buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if count >= 0 { return count }
      if errno == EAGAIN || errno == EWOULDBLOCK { return 0 }
      throw DuplexProcessError.ioFailed
    }
  }

  package func closeInput() {
    lock.withLock {
      if descriptors[0] >= 0 {
        close(descriptors[0])
        descriptors[0] = -1
      }
    }
  }

  package func closeOutput() {
    lock.withLock {
      for index in 1...2 where descriptors[index] >= 0 {
        close(descriptors[index])
        descriptors[index] = -1
      }
    }
  }

  private func signalGroup(_ signal: Int32) -> Bool {
    lock.withLock {
      guard owned && !reaped else { return false }
      var exited = false
      guard platform_duplex_observe(identifier, &exited) == 0 else {
        owned = false
        return false
      }
      return platform_duplex_signal(identifier, signal) == 0
    }
  }

  private func reapIfExited() -> Bool {
    lock.withLock {
      if reaped { return true }
      guard owned else { return false }
      var exited = false
      guard platform_duplex_observe(identifier, &exited) == 0 else {
        owned = false
        return false
      }
      guard exited else { return false }
      var status: Int32 = 0
      let result = waitpid(identifier, &status, WNOHANG)
      if result == identifier {
        reaped = true
        owned = false
        return true
      }
      if result < 0 && errno != EINTR { owned = false }
      return false
    }
  }

  /// Cleanup has its own finite grace/TERM/KILL budgets in addition to the
  /// protocol deadline. The leader is not reaped until group signals finish,
  /// including descendants that closed their inherited pipes. False means the
  /// kernel did not confirm cleanup; callers must not report complete success.
  package func finish(grace: Duration, terminate: Duration, killWait: Duration) async -> Bool {
    closeInput()
    try? await Task.sleep(for: grace)
    let term = signalGroup(SIGTERM)
    try? await Task.sleep(for: terminate)
    let killed = signalGroup(SIGKILL)
    closeOutput()
    let deadline = ContinuousClock.now + killWait
    repeat {
      if reapIfExited() { return term && killed }
      try? await Task.sleep(for: .milliseconds(2))
    } while ContinuousClock.now < deadline
    return false
  }

  deinit {
    // Exceptional abandoned ownership must never turn into an unbounded wait.
    for fd in descriptors where fd >= 0 { close(fd) }
    if owned && !reaped {
      var exited = false
      if platform_duplex_observe(identifier, &exited) == 0 {
        _ = platform_duplex_signal(identifier, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(identifier, &status, WNOHANG)
      }
    }
  }
}
