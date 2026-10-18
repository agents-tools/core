import Darwin
import Foundation
import Testing

@testable import AgentsCore

@Suite("Transaction metadata")
struct TransactionMetadataTests {
  @Test(arguments: ["journal.applying", "replace.0", "replace.2"])
  func rollbackPreservesPermissionsACLsAndExtendedAttributes(_ point: String) throws {
    let fixture = try TransactionFixture()
    let target = fixture.root.appendingPathComponent(".agents/skills/target")
    let file = target.appendingPathComponent("SKILL.md")
    let nested = target.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let link = target.appendingPathComponent("ref")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "SKILL.md")
    let urls = [target, file, nested, link]
    for (url, mode) in zip(urls, [0o750, 0o666, 0o775, 0o751]) {
      #expect(lchmod(url.path, mode_t(mode)) == 0)
      let value = Data("metadata:\(url.lastPathComponent)".utf8)
      let result = value.withUnsafeBytes {
        setxattr(url.path, "org.agents.tests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
      }
      #expect(result == 0)
      if url != link {
        try ProcessRunner.run(
          "/bin/chmod",
          arguments: ["+a", "everyone allow readattr,readextattr,readsecurity", url.path])
      }
    }
    let before = try urls.map(metadata)
    let bytes = try FileHash.folderHash(target)
    #expect(throws: CoreError.self) {
      try fixture.commit { step in
        if step == point { throw CoreError.invalidState("injected failure") }
      }
    }
    #expect(try urls.map(metadata) == before)
    #expect(try FileHash.folderHash(target) == bytes)
    try fixture.check(committed: false)
  }

  private struct Metadata: Equatable {
    var mode: mode_t
    var acl: String
    var attribute: Data
  }

  private func metadata(_ url: URL) throws -> Metadata {
    var info = stat()
    try #require(lstat(url.path, &info) == 0)
    let size = getxattr(url.path, "org.agents.tests", nil, 0, 0, XATTR_NOFOLLOW)
    try #require(size >= 0)
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes {
      getxattr(url.path, "org.agents.tests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    try #require(count == size)
    var text = ""
    if info.st_mode & S_IFMT != S_IFLNK {
      let acl = try #require(acl_get_file(url.path, ACL_TYPE_EXTENDED))
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      if let value = acl_to_text(acl, nil) {
        text = String(cString: value)
        acl_free(value)
      }
    }
    return Metadata(mode: info.st_mode, acl: text, attribute: data)
  }
}
