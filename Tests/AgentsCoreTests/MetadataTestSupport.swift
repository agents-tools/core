import AgentsCore
import CPlatform
import Foundation
import Testing

struct FixtureMetadata: Equatable {
  var mode: mode_t
  var acl: Data
  var attribute: Data
  var defaultACL = Data()
}

func setRestrictiveInheritedFileACL(_ directory: URL) throws {
  do {
    #if os(macOS)
      try ProcessRunner.run(
        "/bin/chmod",
        arguments: ["+a", "everyone deny read,write,file_inherit,only_inherit", directory.path])
    #else
      try setFixtureMetadata(
        directory, mode: 0o700, value: Data(), defaultOwnerPermissions: 5)
    #endif
  } catch {
    throw CoreError.invalidState(
      "Restrictive inherited ACL fixture unavailable at \(directory.path): \(error)")
  }
}

func setRestrictiveInheritedDirectoryACL(_ directory: URL) throws {
  do {
    try setFixtureMetadata(directory, mode: 0o700, value: Data(), defaultOwnerPermissions: 5)
    #if os(macOS)
      try ProcessRunner.run(
        "/bin/chmod",
        arguments: [
          "+a", "everyone deny write,append,file_inherit,directory_inherit,only_inherit",
          directory.path,
        ])
    #endif
  } catch {
    throw CoreError.invalidState(
      "Restrictive inherited directory ACL fixture unavailable at \(directory.path): \(error)")
  }
}

func setFixtureMetadata(
  _ url: URL, mode: mode_t, value: Data, defaultOwnerPermissions: UInt16 = 6
) throws {
  var info = stat()
  try #require(lstat(url.path, &info) == 0)
  #if os(macOS)
    try #require(
      value.withUnsafeBytes {
        setxattr(url.path, "org.agents.tests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
      } == 0)
    if info.st_mode & S_IFMT != S_IFLNK {
      try ProcessRunner.run(
        "/bin/chmod",
        arguments: ["+a", "everyone allow readattr,readextattr,readsecurity", url.path])
    }
    try #require(lchmod(url.path, mode) == 0)
  #else
    // Linux symlink modes are fixed at 0777 and user xattrs/ACLs cannot be set
    // on symlinks. Never chmod or set attributes through their referents.
    guard info.st_mode & S_IFMT != S_IFLNK else { return }
    try #require(
      value.withUnsafeBytes {
        lsetxattr(url.path, "user.org.agents.tests", $0.baseAddress, $0.count, 0)
      } == 0)
    // Linux's little-endian POSIX ACL xattr format: version 2, owner, named
    // nobody (uid 65534), owning group, mask and other. No libacl dependency.
    var acl = Data([2, 0, 0, 0])
    for (tag, permissions, identifier): (UInt16, UInt16, UInt32) in [
      (1, 6, .max), (2, 4, 65534), (4, 4, .max), (16, 4, .max), (32, 0, .max),
    ] {
      for field in [UInt32(tag) | (UInt32(permissions) << 16), identifier] {
        var bytes = field.littleEndian
        withUnsafeBytes(of: &bytes) { acl.append(contentsOf: $0) }
      }
    }
    try #require(
      acl.withUnsafeBytes {
        lsetxattr(url.path, "system.posix_acl_access", $0.baseAddress, $0.count, 0)
      } == 0)
    if info.st_mode & S_IFMT == S_IFDIR {
      var defaultACL = acl
      defaultACL[6] = UInt8(truncatingIfNeeded: defaultOwnerPermissions)
      defaultACL[7] = UInt8(truncatingIfNeeded: defaultOwnerPermissions >> 8)
      try #require(
        defaultACL.withUnsafeBytes {
          lsetxattr(url.path, "system.posix_acl_default", $0.baseAddress, $0.count, 0)
        } == 0)
    }
    try #require(chmod(url.path, mode) == 0)
  #endif
}

func fixtureMetadata(_ url: URL) throws -> FixtureMetadata {
  var info = stat()
  try #require(lstat(url.path, &info) == 0)
  #if os(macOS)
    let size = getxattr(url.path, "org.agents.tests", nil, 0, 0, XATTR_NOFOLLOW)
    try #require(size >= 0)
    var attribute = Data(count: size)
    try #require(
      attribute.withUnsafeMutableBytes {
        getxattr(url.path, "org.agents.tests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
      } == size)
    var text = ""
    if info.st_mode & S_IFMT != S_IFLNK {
      let acl = try #require(acl_get_file(url.path, ACL_TYPE_EXTENDED))
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      if let value = acl_to_text(acl, nil) {
        text = String(cString: value)
        acl_free(value)
      }
    }
    return FixtureMetadata(mode: info.st_mode, acl: Data(text.utf8), attribute: attribute)
  #else
    if info.st_mode & S_IFMT == S_IFLNK {
      return FixtureMetadata(mode: info.st_mode, acl: Data(), attribute: Data())
    }
    func read(_ name: String) throws -> Data {
      let size = lgetxattr(url.path, name, nil, 0)
      if size < 0 && errno == ENODATA { return Data() }
      try #require(size >= 0)
      var value = Data(count: size)
      try #require(
        value.withUnsafeMutableBytes {
          lgetxattr(url.path, name, $0.baseAddress, $0.count)
        } == size)
      return value
    }
    return FixtureMetadata(
      mode: info.st_mode, acl: try read("system.posix_acl_access"),
      attribute: try read("user.org.agents.tests"),
      defaultACL: info.st_mode & S_IFMT == S_IFDIR ? try read("system.posix_acl_default") : Data())
  #endif
}
