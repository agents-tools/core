import AgentsCore
import Darwin
import Foundation
import Testing

@Suite("Inherited file locks")
struct FileLockProcessTests {
  @Test func childKeepsLockAfterParentClosesItsDescriptor() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appendingPathComponent("writer.lock")
    let ready = root.appendingPathComponent("child-ready")
    var child: Int32?
    defer { if let child { Darwin.kill(child, SIGKILL) } }
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
      let deadline = Date().addingTimeInterval(10)
      while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      #expect(try String(contentsOf: ready, encoding: .utf8) == String(pid))
      #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }
    let contender = open(lock.path, O_RDWR | O_CLOEXEC)
    try #require(contender >= 0)
    defer { close(contender) }
    #expect(flock(contender, LOCK_EX | LOCK_NB) == -1)
    #expect(errno == EWOULDBLOCK)
    Darwin.kill(try #require(child), SIGCONT)
    let deadline = Date().addingTimeInterval(10)
    var acquired = false
    repeat {
      if let child { Darwin.kill(child, SIGCONT) }
      acquired = flock(contender, LOCK_EX | LOCK_NB) == 0
      if !acquired { Thread.sleep(forTimeInterval: 0.01) }
    } while !acquired && Date() < deadline
    #expect(acquired)
    if acquired { child = nil }
  }

  @Test func lockedChildPreservesStreamsDirectoryAndEnvironment() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appendingPathComponent("writer.lock")
    try Data("directory".utf8).write(to: root.appendingPathComponent("marker"))
    try FileLock.withDescriptor(at: lock) { descriptor in
      let script = """
        alarm 10;
        open my $lock, '<&=', $ARGV[0] or die $!;
        open my $marker, '<', 'marker' or die $!;
        print scalar(<$marker>), "\\n", $ENV{HOME}, "\\n";
        for (1..1024) { print STDOUT 'o' x 1024; print STDERR 'e' x 1024; }
        """
      let output = try ProcessRunner.run(
        "/usr/bin/perl", arguments: ["-e", script, String(descriptor)],
        workingDirectory: root, inheritingLock: descriptor)
      #expect(
        output.stdout == "directory\n\(ProcessInfo.processInfo.environment["HOME"] ?? "")\n"
          + String(repeating: "o", count: 1024 * 1024))
      #expect(output.stderr == String(repeating: "e", count: 1024 * 1024))
    }
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
