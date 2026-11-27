import AgentsCore
import CPlatform
import Foundation
import StateTestSupport
import Testing

@Suite("Inherited file locks")
struct FileLockProcessTests {
  @Test func lockedChildClosesUnrelatedDescriptors() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let file = open(root.appendingPathComponent("private").path, O_CREAT | O_RDWR, 0o600)
    try #require(file >= 0)
    defer { close(file) }
    let unrelated = fcntl(file, F_DUPFD, 64)
    try #require(unrelated >= 64)
    defer { close(unrelated) }
    try FileLock.withDescriptor(at: root.appendingPathComponent("writer.lock")) { descriptor in
      let output = try ProcessRunner.run(
        "/bin/sh", arguments: ["-c", "test ! -e /dev/fd/$1", "sh", String(unrelated)],
        inheritingLock: descriptor)
      #expect(output.exitCode == 0)
    }
  }

  @Test func lockedChildPropagatesLaunchErrors() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try FileLock.withDescriptor(at: root.appendingPathComponent("writer.lock")) { descriptor in
      let error =
        try #require(throws: (any Error).self) {
          try ProcessRunner.run(
            root.appendingPathComponent("missing").path, arguments: [], inheritingLock: descriptor)
        } as NSError
      #expect(error.domain == NSPOSIXErrorDomain)
      #expect(error.code == Int(ENOENT))
    }
  }

  @Test func childKeepsLockAfterParentClosesItsDescriptor() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appendingPathComponent("writer.lock")
    let ready = root.appendingPathComponent("child-ready")
    var child: Int32?
    defer { if let child { CPlatform.kill(child, SIGKILL) } }
    try FileLock.withDescriptor(at: lock) { descriptor in
      let script = """
        defined(my $child = fork) or die $!;
        if (!$child) {
          close STDOUT; close STDERR;
          open my $ready, '>', "$ARGV[0].new" or die $!;
          print $ready "$$"; close $ready;
          rename "$ARGV[0].new", $ARGV[0] or die $!;
          kill 'STOP', $$;
          exit 0;
        }
        print $child;
        """
      let output = try ProcessRunner.run(
        "/usr/bin/perl", arguments: ["-e", script, ready.path], inheritingLock: descriptor)
      let identifier = Int32(output.stdout)
      let pid: Int32 = try #require(identifier)
      child = pid
      try ProcessWait.condition(
        processIdentifier: pid, root: root, description: "grandchild readiness",
        isRunning: { CPlatform.kill(pid, 0) == 0 }
      ) {
        FileManager.default.fileExists(atPath: ready.path)
      }
      #expect(try String(contentsOf: ready, encoding: .utf8) == String(pid))
      #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }
    let contender = open(lock.path, O_RDWR | O_CLOEXEC)
    try #require(contender >= 0)
    defer { close(contender) }
    #expect(platform_flock(contender, LOCK_EX | LOCK_NB) == -1)
    #expect(errno == EWOULDBLOCK)
    let pid = try #require(child)
    try ProcessWait.condition(
      processIdentifier: pid, root: root, description: "grandchild lock release",
      isRunning: { CPlatform.kill(pid, 0) == 0 },
      ready: {
        CPlatform.kill(pid, SIGCONT)
        return platform_flock(contender, LOCK_EX | LOCK_NB) == 0
      })
    child = nil
  }

  @Test func lockedChildPreservesStreamsDirectoryAndEnvironment() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appendingPathComponent("writer.lock")
    try Data("directory".utf8).write(to: root.appendingPathComponent("marker"))
    try FileLock.withDescriptor(at: lock) { descriptor in
      let script = """
        alarm 10;
        open my $lock, '+<', $ARGV[0] or die $!;
        flock($lock, 2 | 4) and die 'lock not inherited';
        open my $marker, '<', 'marker' or die $!;
        print scalar(<$marker>), "\\n", $ENV{HOME}, "\\n";
        for (1..1024) { print STDOUT 'o' x 1024; print STDERR 'e' x 1024; }
        """
      let output = try ProcessRunner.run(
        "/usr/bin/perl", arguments: ["-e", script, lock.path],
        workingDirectory: root, inheritingLock: descriptor)
      #expect(
        output.stdout == "directory\n\(ProcessInfo.processInfo.environment["HOME"] ?? "")\n"
          + String(repeating: "o", count: 1024 * 1024))
      #expect(output.stderr == String(repeating: "e", count: 1024 * 1024))
    }
  }

  @Test(arguments: [0, 1], [false, true])
  func parentDeathWithClosedStreamsKeepsGitLock(_ depth: Int, _ closeInput: Bool) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let repository = root.appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline".utf8).write(to: repository.appendingPathComponent("file"))
    try initGitRepo(repository)
    let revision = try gitHead(repository)
    let reference = "refs/agents-watch/" + revision
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repository.path, "update-ref", reference, revision])
    let pause = try GitTransactionPause(
      root: root, hooks: repository.appendingPathComponent(".git/hooks"),
      condition: "[ \"$ref\" = \"\(reference)\" ]")
    defer { pause.terminate() }
    // Adjacent directory depths make FileLock's ancestry traversal alternate its
    // lowest available descriptor, covering locks allocated at both stdout and stderr.
    let relativeLock = depth == 0 ? "locks/mirror.lock" : "locks/nested/mirror.lock"
    let parent = try stateTestProcess(
      root: root,
      arguments: ["locked-git", relativeLock, closeInput ? "all" : "outputs", revision])
    defer { terminateProcess(parent) }
    try pause.wait()
    let descriptor = try String(
      contentsOf: root.appendingPathComponent("lock-descriptor"), encoding: .utf8)
    let allocated = try #require(Int32(descriptor))
    let components =
      root.appendingPathComponent(relativeLock).deletingLastPathComponent()
      .standardizedFileURL.pathComponents.count - 1
    let lowest: Int32 = closeInput ? STDIN_FILENO : STDOUT_FILENO
    #expect(allocated == lowest + (components.isMultiple(of: 2) ? 1 : 0))
    let gitLock = repository.appendingPathComponent(".git/\(reference).lock")
    try #require(FileManager.default.fileExists(atPath: gitLock.path))

    terminateProcess(parent)
    try #require(kill(pause.git, 0) == 0)
    try #require(kill(pause.hook, 0) == 0)
    let contention = try ProcessSignal(at: root.appendingPathComponent("writer-contended"))
    let contender = try stateTestProcess(root: root, arguments: ["lock-contender", relativeLock])
    defer { terminateProcess(contender) }
    #expect(try contention.receive() == "contended")
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-acquired").path))
    #expect(FileManager.default.fileExists(atPath: gitLock.path))

    try finishProcesses([contender], root: root, resuming: pause)
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-acquired").path))
    #expect(!FileManager.default.fileExists(atPath: gitLock.path))
    let refs = try ProcessRunner.run(
      "/usr/bin/env", arguments: ["git", "-C", repository.path, "for-each-ref", reference])
    #expect(refs.stdout.isEmpty)
  }

  @Test(arguments: Array(1...7))
  func lockedChildHandlesClosedStandardStreams(_ mask: Int) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let parent = try stateTestProcess(root: root, arguments: ["closed-streams", String(mask)])
    defer { terminateProcess(parent) }
    try finishProcesses([parent], root: root)
    #expect(try String(contentsOf: root.appendingPathComponent("stdout"), encoding: .utf8) == "out")
    #expect(try String(contentsOf: root.appendingPathComponent("stderr"), encoding: .utf8) == "err")
  }

  @Test(arguments: [1, 42, 127])
  func lockedChildReportsFailure(_ code: Int) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileLock.withDescriptor(at: root.appendingPathComponent("writer.lock")) { descriptor in
      let arguments = ["-c", "printf 'failure' >&2; exit \(code)"]
      #expect(
        throws: CoreError.commandFailed(
          (["/bin/sh"] + arguments).joined(separator: " ") + "\nfailure")
      ) {
        try ProcessRunner.run("/bin/sh", arguments: arguments, inheritingLock: descriptor)
      }
    }
  }
}
