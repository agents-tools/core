import Foundation
import Testing

@testable import AgentsCore

@Suite("File hashes")
struct FileHashTests {
  @Test func hashesFoldersDeterministicallyIgnoringMetadata() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try "one".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try "two".write(
      to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)

    let first = try FileHash.folderHash(root)
    let second = try FileHash.folderHash(root)
    #expect(first == second)

    try "ignored".write(
      to: root.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "ignored".write(
      to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
    #expect(try FileHash.folderHash(root) == first)

    try "changed".write(
      to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)
    #expect(try FileHash.folderHash(root) != first)
  }

  @Test func hashesSymlinkedFolderLikeItsTarget() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try "one".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(try FileHash.folderHash(link) == FileHash.folderHash(target))
  }

}
