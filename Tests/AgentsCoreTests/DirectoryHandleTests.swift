import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite("Portable filesystem contracts")
struct DirectoryHandleTests {
  @Test func enumeratesHiddenUnicodeAndLongNamesAcrossRepeatedReads() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let names = [".hidden", "目录-🌍", String(repeating: "a", count: 255)]
    for name in names { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
    let directory = try DirectoryHandle(at: root)
    #expect(try directory.names() == names.sorted())
    #expect(try directory.names() == names.sorted())
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == names.sorted())
  }

  @Test func copiesModesAndDanglingLinksWithoutFollowingThem() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let content = Data(repeating: 0xa5, count: 200_000)
    let file = source.appendingPathComponent("executable")
    try content.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("dangling").path, withDestinationPath: "missing")
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("reference").path, withDestinationPath: "executable")
    let directory = try DirectoryHandle(at: root)
    try directory.copy("copy", from: directory, named: "source")
    let copy = try directory.child("copy")
    #expect(try copy.read("executable") == content)
    let executableInfo = try #require(try copy.info("executable"))
    #expect(executableInfo.st_mode & 0o7777 == 0o751)
    #expect(try copy.readLink("dangling") == "missing")
    #expect(try copy.readLink("reference") == "executable")
    #expect(
      try FileHash.folderHash(root.appendingPathComponent("copy")) == FileHash.folderHash(source))
    let dangling = root.appendingPathComponent("copy/dangling")
    #expect(!FileManager.default.fileExists(atPath: dangling.path))
    #expect(
      try FileManager.default.attributesOfItem(atPath: dangling.path)[.type] as? FileAttributeType
        == .typeSymbolicLink)
    #expect(
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        == 0o751)
  }

  @Test func atomicallyExchangesNonemptyDirectories() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    for name in ["first", "second"] {
      let child = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      try Data(name.utf8).write(to: child.appendingPathComponent("content"))
    }
    let directory = try DirectoryHandle(at: root)
    try directory.rename("first", to: "second", swap: true)
    #expect(try directory.child("first").read("content") == Data("second".utf8))
    #expect(try directory.child("second").read("content") == Data("first".utf8))
  }

  @Test(arguments: ["file", "directory", "link"])
  func exclusiveRenamePreservesConcurrentObjects(_ kind: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let directory = try DirectoryHandle(at: root)
    for name in ["staged", "external"] {
      if kind == "directory" {
        try directory.makeDirectory(name)
        try directory.child(name).write("content", data: Data(name.utf8))
      } else if kind == "link" {
        try directory.link(name, destination: name + "-destination")
      } else {
        try directory.write(name, data: Data(name.utf8))
      }
    }
    let staged = try FileSnapshot.read("staged", from: directory)
    let external = try FileSnapshot.read("external", from: directory)
    #expect(throws: CoreError.self) { try directory.renameExclusive("staged", to: "external") }
    #expect(try FileSnapshot.read("staged", from: directory) == staged)
    #expect(try FileSnapshot.read("external", from: directory) == external)
    try directory.renameExclusive("staged", to: "published")
    #expect(try FileSnapshot.read("published", from: directory) == staged)
    #expect(try directory.info("staged") == nil)
  }

  @Test func directoryAndRegularFileReadsRejectLinks() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: source.appendingPathComponent("file"))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: CoreError.self) { try DirectoryHandle(at: link) }
    let directory = try DirectoryHandle(at: root)
    #expect(throws: CoreError.self) { try directory.read("link") }
    let linkInfo = try #require(try directory.info("link"))
    #expect(linkInfo.st_mode & S_IFMT == S_IFLNK)
  }
}
