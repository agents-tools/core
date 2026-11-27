import Foundation
import Testing

@testable import AgentsCore

@Suite("File hashes")
struct FileHashTests {
  @Test func sha256MatchesStandardVectors() {
    #expect(
      FileHash.sha256Hex(data: Data())
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(
      FileHash.sha256Hex(data: Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func arbitraryBytesCannotImpersonateTreeEntries() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try Data("same skill".utf8).write(to: root.appendingPathComponent("SKILL.md"))
    try Data("x".utf8).write(to: root.appendingPathComponent("a"))
    try Data("y".utf8).write(to: root.appendingPathComponent("b"))
    let twoFiles = try FileHash.folderHash(root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("b"))
    try Data("x\0b\0file\0y".utf8).write(to: root.appendingPathComponent("a"))
    #expect(try FileHash.folderHash(root) != twoFiles)
  }

  @Test func hashesEveryContentEntryDeterministically() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try "one".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try "two".write(
      to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)

    let first = try FileHash.folderHash(root)
    let second = try FileHash.folderHash(root)
    #expect(first == second)

    try "included".write(
      to: root.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "included".write(
      to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
    #expect(try FileHash.folderHash(root) != first)

    try "changed".write(
      to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)
    #expect(try FileHash.folderHash(root) != first)
  }

  @Test func streamedTreeUsesTheCanonicalRecordOrder() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let directory = root.appendingPathComponent("rules")
    let content = Data(repeating: 0x7e, count: 150_000)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try content.write(to: directory.appendingPathComponent("guide"))
    try Data("extra".utf8).write(to: root.appendingPathComponent("rules-extra"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("rules0").path, withDestinationPath: "rules/guide")
    let expected = FileHash.hashRecords([
      ("rules0", Data("link\0rules/guide".utf8)),
      ("rules/guide", Data("file\0".utf8) + content),
      ("rules-extra", Data("file\0extra".utf8)),
      ("rules", Data("directory".utf8)),
    ])
    #expect(try FileHash.folderHash(root) == expected)
  }

  @Test func hashesSymlinkedFolderLikeItsTarget() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try "one".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(try FileHash.folderHash(link) == FileHash.folderHash(target))
  }

}
