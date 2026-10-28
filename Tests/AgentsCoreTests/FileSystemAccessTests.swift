import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite(
  "Filesystem access policy",
  .enabled(if: geteuid() != 0, "Permission-denial checks require an unprivileged user"),
  .timeLimit(.minutes(1)))
struct FileSystemAccessTests {
  @Test func firstAndRepeatedLockAcquisitionsReportInheritedDenial() throws {
    let fixture = try AccessPolicyFixture(directories: false)
    let lock = fixture.directory.appendingPathComponent("writer.lock")
    var identity: ino_t?
    for _ in 0..<3 {
      expectAccessDenied(at: lock) {
        try FileLock.withLock(at: lock) { _ = Issue.record("Denied lock must not enter its body") }
      }
      var info = stat()
      try #require(lstat(lock.path, &info) == 0)
      if let identity { #expect(info.st_ino == identity) }
      identity = info.st_ino
      #expect(platform_access(AT_FDCWD, lock.path, R_OK | W_OK) == -1)
      try fixture.expectUnchanged()
    }
    #expect(try fixture.names() == ["user.txt", "writer.lock"])
  }

  @Test(arguments: ["locks", "one/two/locks"])
  func missingLockAncestorsRemainDenied(_ path: String) throws {
    let fixture = try AccessPolicyFixture(directories: true)
    let directory = fixture.directory.appendingPathComponent(path)
    for _ in 0..<3 {
      expectAccessDenied(at: directory) {
        try FileLock.withLock(at: directory.appendingPathComponent("writer.lock")) {
          _ = Issue.record("Denied directory must not reach the operation")
        }
      }
      try fixture.expectUnchanged()
    }
    #expect(try fixture.names() == [path.components(separatedBy: "/")[0], "user.txt"].sorted())
  }

  @Test func sharedDirectoryCreationReportsFirstAndRepeatedDenial() throws {
    let fixture = try AccessPolicyFixture(directories: true)
    let target = fixture.directory.appendingPathComponent("workspace")
    for _ in 0..<3 {
      expectAccessDenied(at: target) { try FileSystem.createDirectory(at: target) }
      try fixture.expectUnchanged()
    }
    #expect(try fixture.names() == ["user.txt", "workspace"])
  }

  @Test func scopeOperationsStopBeforeChangingUserContent() throws {
    let fixture = try AccessPolicyFixture(directories: true)
    let store = StateStore(
      scope: .project, environment: RuntimeEnvironment(projectDirectory: fixture.directory))
    for _ in 0..<3 {
      expectAccessDenied(at: store.directory) {
        try store.withLock { try Data("changed".utf8).write(to: fixture.userFile) }
      }
      try fixture.expectUnchanged()
    }
  }

  @Test(arguments: ["directory", "file", "copied-directory", "copied-file"])
  func entryCreationReportsFirstAndRepeatedDenial(_ kind: String) throws {
    let fixture = try AccessPolicyFixture(directories: true)
    let source = fixture.root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("source".utf8).write(to: source.appendingPathComponent("content"))
    let sourceHash = try FileHash.folderHash(source)
    let directory = try DirectoryHandle(at: fixture.directory)
    let target = fixture.directory.appendingPathComponent("entry")
    for _ in 0..<3 {
      expectAccessDenied(at: target) {
        switch kind {
        case "directory": try directory.makeDirectory("entry")
        case "file": try directory.write("entry", data: Data("new bytes".utf8))
        case "copied-directory":
          try directory.copy("entry", from: DirectoryHandle(at: fixture.root), named: "source")
        default:
          try directory.copy("entry", from: DirectoryHandle(at: source), named: "content")
        }
      }
      try fixture.expectUnchanged()
      #expect(try FileHash.folderHash(source) == sourceHash)
    }
    #expect(try fixture.names() == ["entry", "user.txt"])
  }

  @Test func deniedParentReportsDirectoryFileAndLinkCreationErrors() throws {
    let fixture = try AccessPolicyFixture(directories: false)
    let directory = try DirectoryHandle(at: fixture.directory)
    try #require(chmod(fixture.directory.path, 0o500) == 0)
    for _ in 0..<2 {
      expectAccessDenied(at: fixture.directory.appendingPathComponent("child")) {
        try directory.makeDirectory("child")
      }
      expectAccessDenied(at: fixture.directory.appendingPathComponent("file")) {
        try directory.write("file", data: Data())
      }
      expectAccessDenied(at: fixture.directory.appendingPathComponent("link")) {
        try directory.link("link", destination: "user.txt")
      }
      #expect(try fixture.names() == ["user.txt"])
      #expect(try Data(contentsOf: fixture.userFile) == fixture.bytes)
      #expect(try fixtureMetadata(fixture.userFile) == fixture.userMetadata)
    }
  }

  @Test func foundationPermissionErrorsKeepUserFilesUnchanged() throws {
    let fixture = try AccessPolicyFixture(directories: false)
    try #require(chmod(fixture.directory.path, 0o500) == 0)
    let destination = fixture.directory.appendingPathComponent("copy")
    for _ in 0..<2 {
      expectAccessDenied(at: destination) {
        try FileSystem.withAccessErrors(at: destination) {
          try FileSystem.read(at: fixture.userFile).write(to: destination)
        }
      }
      #expect(try Data(contentsOf: fixture.userFile) == fixture.bytes)
      #expect(try fixtureMetadata(fixture.userFile) == fixture.userMetadata)
      #expect(try fixture.names() == ["user.txt"])
    }
  }

  @Test func unreadableCachedArtifactReportsItsPathOnEveryAttempt() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    let cache = SourceCache(store: store)
    let bytes = Data("cached artifact".utf8)
    let digest = "sha256:" + FileHash.sha256Hex(data: bytes)
    let cached = try store.withLock { try cache.storeArtifact(bytes, digest: digest) }
    var original = stat()
    try #require(lstat(cached.path, &original) == 0)
    try #require(chmod(cached.path, 0) == 0)
    defer { chmod(cached.path, original.st_mode & 0o777) }
    for _ in 0..<2 {
      expectAccessDenied(at: cached) {
        _ = try store.withLock { try cache.storeArtifact(bytes, digest: digest) }
      }
      expectAccessDenied(at: cached) { _ = try FileHash.sha256Hex(file: cached) }
      expectAccessDenied(at: cached) { _ = try FileSystem.readUnlessDenied(at: cached) }
      var current = stat()
      try #require(lstat(cached.path, &current) == 0)
      #expect(current.st_mode & 0o777 == 0 && current.st_ino == original.st_ino)
    }
    try #require(chmod(cached.path, original.st_mode & 0o777) == 0)
    #expect(try Data(contentsOf: cached) == bytes)
  }

  @Test func unreadableCopySourceReportsSourceInsteadOfDestination() throws {
    let fixture = try AccessPolicyFixture(directories: false)
    let source = fixture.userFile
    let destination = fixture.root.appendingPathComponent("copy")
    var original = stat()
    try #require(lstat(source.path, &original) == 0)
    try #require(chmod(source.path, 0) == 0)
    defer { chmod(source.path, original.st_mode & 0o777) }
    for _ in 0..<2 {
      expectAccessDenied(at: source) {
        try FileSystem.withAccessErrors(at: destination) {
          try FileManager.default.copyItem(at: source, to: destination)
        }
      }
      var current = stat()
      try #require(lstat(source.path, &current) == 0)
      #expect(current.st_mode & 0o777 == 0 && current.st_ino == original.st_ino)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
    }
    try #require(chmod(source.path, original.st_mode & 0o777) == 0)
    try fixture.expectUnchanged()
  }
}

@Suite("Filesystem diagnostics")
struct FileSystemErrorTests {
  @Test(arguments: [NSFilePathErrorKey, NSURLErrorKey], [false, true])
  func preservesFoundationPaths(_ key: String, nested: Bool) throws {
    let operation = URL(fileURLWithPath: "/fixture/destination")
    let source = URL(fileURLWithPath: "/fixture/source/file")
    let value: Any = key == NSFilePathErrorKey ? source.path : source
    let permission = NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
      userInfo: [
        key: value,
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
      ])
    let error =
      nested
      ? NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSFilePathErrorKey: operation.path, NSUnderlyingErrorKey: permission])
      : permission
    expectAccessDenied(at: source) {
      try FileSystem.withAccessErrors(at: operation) { throw error }
    }
  }

  @Test func optionalReadsTolerateEverythingButPermissionDenial() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    #expect(try FileSystem.readUnlessDenied(at: root.appendingPathComponent("missing")) == nil)
    #expect(try FileSystem.readUnlessDenied(at: root) == nil)
  }

  @Test(arguments: [EACCES, EPERM])
  func mapsPOSIXAndUnderlyingFoundationPermissionErrors(_ code: Int32) throws {
    let path = URL(fileURLWithPath: "/fixture/entry")
    let original = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    expectAccessDenied(at: path) {
      throw FileSystem.posixError(code, at: path, otherwise: .invalidState("original"))
    }
    for error in [
      original,
      NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: original]),
    ] {
      expectAccessDenied(at: path) {
        try FileSystem.withAccessErrors(at: path) { throw error }
      }
    }
  }

  @Test func preservesGitAndUnrelatedFailures() throws {
    let path = URL(fileURLWithPath: "/fixture/entry")
    let git = GitError(
      operation: .clone, source: "source", stderr: "Permission denied",
      command: ["git", "clone"], exitCode: 128)
    #expect(throws: git) { try FileSystem.withAccessErrors(at: path) { throw git } }
    let other = CoreError.invalidState("unrelated")
    #expect(throws: other) { try FileSystem.withAccessErrors(at: path) { throw other } }
    #expect(FileSystem.posixError(ENOSPC, at: path, otherwise: other) == other)
  }

  @Test func existingLockRetainsContentIdentityAndMetadata() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let lock = root.appendingPathComponent("writer.lock")
    let bytes = Data("existing lock".utf8)
    try bytes.write(to: lock)
    try setFixtureMetadata(lock, mode: 0o640, value: Data("owner metadata".utf8))
    let before = try fixtureMetadata(lock)
    var original = stat()
    try #require(lstat(lock.path, &original) == 0)
    for _ in 0..<2 {
      try FileLock.withDescriptor(at: lock) { descriptor in
        var current = stat()
        try #require(fstat(descriptor, &current) == 0)
        #expect(current.st_ino == original.st_ino && current.st_dev == original.st_dev)
      }
      #expect(try Data(contentsOf: lock) == bytes)
      #expect(try fixtureMetadata(lock) == before)
    }
  }
}

private func expectAccessDenied(at url: URL, _ body: () throws -> Void) {
  let expected = CoreError.invalidState(
    "permission denied: \(url.path); check the directory's permissions and default ACL")
  #expect(throws: expected) { try body() }
}

private final class AccessPolicyFixture {
  let root: URL
  let directory: URL
  let userFile: URL
  let bytes = Data("user-owned content".utf8)
  let userMetadata: FixtureMetadata
  let directoryMetadata: FixtureMetadata

  init(directories: Bool) throws {
    root = try temporaryDirectory()
    directory = root.appendingPathComponent("policy")
    userFile = directory.appendingPathComponent("user.txt")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try bytes.write(to: userFile)
      try setFixtureMetadata(userFile, mode: 0o640, value: Data("user metadata".utf8))
      try setFixtureMetadata(directory, mode: 0o700, value: Data("directory metadata".utf8))
      if directories {
        try setRestrictiveInheritedDirectoryACL(directory)
      } else {
        try setRestrictiveInheritedFileACL(directory)
      }
      userMetadata = try fixtureMetadata(userFile)
      directoryMetadata = try fixtureMetadata(directory)
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }

  deinit {
    #if os(macOS)
      do { try ProcessRunner.run("/bin/chmod", arguments: ["-RN", root.path]) } catch {
        Issue.record(error)
      }
    #endif
    // The test owns these denied entries; only teardown restores access to remove them.
    chmod(directory.path, 0o700)
    if let entries = FileManager.default.enumerator(atPath: root.path) {
      for case let name as String in entries {
        chmod(root.appendingPathComponent(name).path, 0o700)
      }
    }
    removeTemporaryDirectory(root)
  }

  func names() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  func expectUnchanged() throws {
    #expect(try Data(contentsOf: userFile) == bytes)
    #expect(try fixtureMetadata(userFile) == userMetadata)
    #expect(try fixtureMetadata(directory) == directoryMetadata)
  }
}
