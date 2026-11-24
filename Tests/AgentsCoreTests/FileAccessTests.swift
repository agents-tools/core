import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Descriptor access and private creation")
struct FileAccessTests {
  @Test func verifiesEmptyPrivateObjectsBeforeFirstPayloadWrite() throws {
    let fixture = try AccessFixture()
    let directory = try fixture.handle.createPrivateDirectory("private")
    let file = try directory.createPrivateFile("payload")
    var info = stat()
    try #require(fstat(file.descriptor, &info) == 0)
    #expect(info.st_size == 0)
    #expect(info.st_mode & 0o7777 == 0o600)
    #expect(info.st_uid == geteuid())
    #expect(file.evidence.group == info.st_gid)
    #expect(try FileAccessEvidence.requirePrivate(descriptor: directory.descriptor).mode == 0o700)
    let encoded = try JSONEncoder().encode(file.evidence)
    #expect(try JSONDecoder().decode(FileAccessEvidence.self, from: encoded) == file.evidence)
    let bytes = Data("private payload".utf8)
    try file.write(bytes)
    #expect(try directory.read("payload") == bytes)
    #expect(try directory.accessEvidence("payload") == file.evidence)
  }

  @Test(arguments: ["mode", "acl", "parent", "replacement"])
  func refusesChangedAccessBeforeAnyPayload(_ change: String) throws {
    let fixture = try AccessFixture()
    let file = try fixture.handle.createPrivateFile("payload")
    switch change {
    case "mode": try #require(fchmod(file.descriptor, 0o644) == 0)
    case "acl": try grantRead(fixture.root.appendingPathComponent("payload"))
    case "parent": try #require(fchmod(fixture.handle.descriptor, 0o777) == 0)
    default:
      try #require(
        renameat(fixture.handle.descriptor, "payload", fixture.handle.descriptor, "old") == 0)
      try fixture.handle.write("payload", data: Data("unrelated".utf8))
    }
    #expect(throws: CoreError.self) { try file.write(Data("private payload".utf8)) }
    var info = stat()
    try #require(fstat(file.descriptor, &info) == 0)
    #expect(info.st_size == 0)
    if change == "replacement" {
      #expect(try fixture.handle.read("payload") == Data("unrelated".utf8))
    }
  }

  @Test func accessEvidenceDetectsACLChangesWithoutModeChanges() throws {
    let fixture = try AccessFixture()
    let file = try fixture.handle.createPrivateFile("payload")
    let before = try FileAccessEvidence.capture(descriptor: file.descriptor)
    #if os(macOS)
      try addACL("everyone allow readsecurity", at: fixture.root.appendingPathComponent("payload"))
    #else
      try installPOSIXACL(
        descriptor: file.descriptor, owner: 6, named: 4, mask: 0, defaultACL: false)
    #endif
    let after = try FileAccessEvidence.capture(descriptor: file.descriptor)
    #expect(before.mode == after.mode)
    #expect(before.identity == after.identity)
    #expect(before.acl != after.acl)
    #expect(throws: CoreError.self) { try before.validate(descriptor: file.descriptor) }
    #expect(try FileAccessEvidence.requirePrivate(descriptor: file.descriptor) == after)
  }

  @Test func effectiveACLGrantsAndOwnerDenialsAreEvaluated() throws {
    let fixture = try AccessFixture()
    let file = try fixture.handle.createPrivateFile("payload")
    let url = fixture.root.appendingPathComponent("payload")
    try grantRead(url)
    #expect(throws: CoreError.self) {
      try FileAccessEvidence.requirePrivate(descriptor: file.descriptor)
    }
    #if os(macOS)
      var info = stat()
      try #require(fstat(file.descriptor, &info) == 0)
      #expect(info.st_mode & 0o777 == 0o600)
      try addACL("everyone deny read", at: url)
    #else
      // A named read grant with a zero mask is not effective access.
      try installPOSIXACL(
        descriptor: file.descriptor, owner: 6, named: 4, mask: 0, defaultACL: false)
      _ = try FileAccessEvidence.requirePrivate(descriptor: file.descriptor)
      // Mask bits alone grant nothing when every masked entry is empty.
      try installPOSIXACL(
        descriptor: file.descriptor, owner: 6, named: 0, mask: 4, defaultACL: false)
      _ = try FileAccessEvidence.requirePrivate(descriptor: file.descriptor)
      try installPOSIXACL(
        descriptor: file.descriptor, owner: 0, named: 4, mask: 0, defaultACL: false)
    #endif
    #expect(throws: CoreError.self) {
      try FileAccessEvidence.requirePrivate(descriptor: file.descriptor)
    }
    // Exercise the actual kernel's current-owner open denial, not just ACL bytes.
    try #require(geteuid() != 0)
    let denied = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    let code = errno
    if denied >= 0 { close(denied) }
    #expect(denied == -1 && (code == EACCES || code == EPERM))
  }

  @Test func inheritanceIsCheckedOnTheCreatedInode() throws {
    let fixture = try AccessFixture()
    #if os(macOS)
      try addACL("everyone allow read,file_inherit,only_inherit", at: fixture.root)
      // Inherit-only grants do not grant access to this directory itself.
      _ = try FileAccessEvidence.requirePrivate(descriptor: fixture.handle.descriptor)
      #expect(throws: CoreError.self) { try fixture.handle.createPrivateFile("payload") }
      #expect(try fixture.handle.info("payload") == nil)
    #else
      try installPOSIXACL(
        descriptor: fixture.handle.descriptor, owner: 7, named: 4, mask: 4, defaultACL: true)
      let before = try fixture.handle.accessEvidence()
      #expect(!before.defaultACL.isEmpty)
      let file = try fixture.handle.createPrivateFile("payload")
      #expect(!file.evidence.acl.isEmpty)
      _ = try FileAccessEvidence.requirePrivate(descriptor: file.descriptor)
      try file.write(Data("private payload".utf8))
      // The create mode masks named access; an owner-denying default is still fatal.
      try installPOSIXACL(
        descriptor: fixture.handle.descriptor, owner: 0, named: 4, mask: 4, defaultACL: true)
      #expect(throws: CoreError.self) { try fixture.handle.createPrivateFile("denied") }
      #expect(try fixture.handle.info("denied") == nil)
      #expect(throws: CoreError.self) { try before.validate(descriptor: fixture.handle.descriptor) }
    #endif
  }

  @Test func inheritedOwnerDenialDoesNotWriteOrRepairPolicy() throws {
    let fixture = try AccessFixture()
    try setRestrictiveInheritedDirectoryACL(fixture.root)
    let before = try fixture.handle.accessEvidence()
    #expect(throws: CoreError.self) { try fixture.handle.createPrivateDirectory("denied") }
    #expect(try fixture.handle.info("denied") == nil)
    #expect(try fixture.handle.accessEvidence() == before)
    try setRestrictiveInheritedFileACL(fixture.root)
    let filePolicy = try fixture.handle.accessEvidence()
    #expect(throws: CoreError.self) { try fixture.handle.createPrivateFile("denied-file") }
    // Some kernels create the empty inode before refusing the creating open.
    // Without a returned descriptor, disposal belongs to the caller's recorded intent.
    #expect(try fixture.handle.info("denied-file").map { $0.st_size == 0 } ?? true)
    #expect(try fixture.handle.accessEvidence() == filePolicy)
  }

  @Test func traversableAncestorsAndStickyOwnershipHaveDistinctReplacementRules() throws {
    let fixture = try AccessFixture()
    try #require(fchmod(fixture.handle.descriptor, 0o755) == 0)
    _ = try FileAccessEvidence.requireNonReplaceableDirectory(
      descriptor: fixture.handle.descriptor, protectingOwner: geteuid())
    let file = try fixture.handle.createPrivateFile("payload")
    try file.write(Data("private payload".utf8))
    try #require(fchmod(fixture.handle.descriptor, 0o777) == 0)
    #expect(throws: CoreError.self) {
      try FileAccessEvidence.requireNonReplaceableDirectory(
        descriptor: fixture.handle.descriptor, protectingOwner: geteuid())
    }
    try #require(fchmod(fixture.handle.descriptor, 0o1777) == 0)
    _ = try FileAccessEvidence.requireNonReplaceableDirectory(
      descriptor: fixture.handle.descriptor, protectingOwner: geteuid())
    #expect(throws: CoreError.self) {
      try FileAccessEvidence.requireNonReplaceableDirectory(
        descriptor: fixture.handle.descriptor, protectingOwner: geteuid() + 1)
    }
  }

  @Test func namespaceEvidenceDetectsAncestorExchangeAndRefusesSymlinks() throws {
    let fixture = try AccessFixture()
    let ancestor = try fixture.handle.createPrivateDirectory("ancestor")
    let before = try #require(try fixture.handle.accessEvidence("ancestor"))
    try #require(
      renameat(fixture.handle.descriptor, "ancestor", fixture.handle.descriptor, "old") == 0)
    _ = try fixture.handle.createPrivateDirectory("ancestor")
    #expect(try fixture.handle.accessEvidence("ancestor") != before)
    // The old descriptor remains valid; callers must compare every namespace edge.
    try before.validate(descriptor: ancestor.descriptor)
    try fixture.handle.link("link", destination: "ancestor")
    #expect(throws: CoreError.self) { try fixture.handle.accessEvidence("link") }
    #expect(throws: CoreError.self) { try fixture.handle.createPrivateFile("link") }
    #expect(throws: CoreError.self) { try fixture.handle.createPrivateFile("../escape") }
    #expect(throws: CoreError.self) { try fixture.handle.createPrivateDirectory("nested/path") }
    #expect(try fixture.handle.child("ancestor").names().isEmpty)
  }
}

private final class AccessFixture {
  let root: URL
  let handle: DirectoryHandle

  init() throws {
    root = try temporaryDirectory()
    do {
      try #require(chmod(root.path, 0o700) == 0)
      handle = try DirectoryHandle(at: root)
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
    chmod(root.path, 0o700)
    removeTemporaryDirectory(root)
  }
}

private func grantRead(_ url: URL) throws {
  #if os(macOS)
    try addACL("everyone allow read", at: url)
  #else
    let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try #require(file >= 0)
    defer { close(file) }
    try installPOSIXACL(descriptor: file, owner: 6, named: 4, mask: 4, defaultACL: false)
  #endif
}

#if os(macOS)
  private func addACL(_ entry: String, at url: URL) throws {
    try ProcessRunner.run("/bin/chmod", arguments: ["+a", entry, url.path])
  }
#else
  private func installPOSIXACL(
    descriptor: Int32, owner: UInt16, named: UInt16, mask: UInt16, defaultACL: Bool
  ) throws {
    var bytes = Data([2, 0, 0, 0])
    let foreignOwner: UInt32 = geteuid() == 65_534 ? 65_533 : 65_534
    for (tag, permissions, identifier): (UInt16, UInt16, UInt32) in [
      (1, owner, .max), (2, named, foreignOwner), (4, 0, .max),
      (16, mask, .max), (32, 0, .max),
    ] {
      for field in [UInt32(tag) | (UInt32(permissions) << 16), identifier] {
        var value = field.littleEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
      }
    }
    let name = defaultACL ? "system.posix_acl_default" : "system.posix_acl_access"
    try #require(
      bytes.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0) } == 0)
  }
#endif
