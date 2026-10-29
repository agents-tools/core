import Foundation
import Testing

@testable import AgentsCore

@Suite("Prepared state evidence")
struct PreparationEvidenceTests {
  @Test func dataSealingRejectsAnUnexpectedExecutableMode() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let transaction = FileTransaction(store: fixture.store) { point in
      if point == "stage.0.constructed" {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .first(where: { $0.hasPrefix(".agents-") }))
        let staged = fixture.root.appendingPathComponent(name).appendingPathComponent(
          "entry.0.staged")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
      }
    }
    try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
    #expect(throws: CoreError.invalidState("staged content permissions mismatch")) {
      try transaction.commit()
    }
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  @Test func replacedContainerIsNotAdoptedBeforeIdentityPersistence() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let saved = fixture.root.appendingPathComponent("saved-empty-container")
    var external: FileSnapshot?
    var original: FileSnapshot?
    var location: URL?
    let transaction = FileTransaction(store: fixture.store) { point in
      if point == "container.0.created" {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .first(where: { $0.hasPrefix(".agents-") }))
        let container = fixture.root.appendingPathComponent(name)
        try FileManager.default.moveItem(at: container, to: saved)
        original = try FileSnapshot.read(at: saved)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        try Data("external container".utf8).write(to: container.appendingPathComponent("keep"))
        external = try FileSnapshot.read(at: container)
        location = container
      }
    }
    try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
    #expect { try transaction.commit() } throws: { error in
      guard case CoreError.invalidState(let reason) = error else { return false }
      return reason.contains("private container changed before its identity was durable")
    }
    try fixture.expectUnresolved(containing: "unidentified private container is not empty")
    #expect(try FileSnapshot.read(at: #require(location)) == external)
    #expect(try FileSnapshot.read(at: saved) == original)
    #expect(try FileSnapshot.read(at: fixture.target) == fixture.beforeTarget)
  }

  @Test(arguments: [PublicationOperation.fileCreate, .directoryDelete])
  func reservedScratchIsRejectedBeforeSealingAndDiscarded(_ operation: PublicationOperation) throws
  {
    let fixture = try PublicationFixture(operation)
    let transaction = FileTransaction(store: fixture.store) { point in
      if point == "stage.0.constructed" {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .first(where: { $0.hasPrefix(".agents-") }))
        let slot = operation == .directoryDelete ? "staged" : "preimage"
        try Data("private injection".utf8).write(
          to: fixture.root.appendingPathComponent(name).appendingPathComponent("entry.0." + slot))
      }
    }
    try transaction.replace(
      fixture.target, content: nil, data: operation == .fileCreate ? Data("postimage".utf8) : nil)
    #expect(throws: CoreError.invalidState("unexpected private recovery slot before sealing")) {
      try transaction.commit()
    }
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  @Test func equalDigestDoesNotTurnDataIntoASymbolicLink() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let transaction = FileTransaction(store: fixture.store) { point in
      if point == "stage.0.constructed" {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .first(where: { $0.hasPrefix(".agents-") }))
        let staged = fixture.root.appendingPathComponent(name).appendingPathComponent(
          "entry.0.staged")
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(
          atPath: staged.path, withDestinationPath: "postimage")
      }
    }
    try transaction.replace(fixture.target, content: nil, data: Data("postimage".utf8))
    #expect(throws: CoreError.invalidState("staged content type mismatch")) {
      try transaction.commit()
    }
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  @Test(arguments: [false, true])
  func constructionMustMatchTheRequestedCopyOrLink(_ link: Bool) throws {
    let fixture = try PublicationFixture(.fileCreate)
    let transaction = FileTransaction(store: fixture.store) { point in
      if point == "stage.0.constructed" {
        let name = try #require(
          try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .first(where: { $0.hasPrefix(".agents-") }))
        let staged = fixture.root.appendingPathComponent(name).appendingPathComponent(
          "entry.0.staged")
        if link {
          try FileManager.default.removeItem(at: staged)
          try FileManager.default.createSymbolicLink(
            atPath: staged.path, withDestinationPath: "external")
        } else {
          try Data("injected".utf8).write(to: staged.appendingPathComponent("injected"))
        }
      }
    }
    try transaction.replace(
      fixture.target, content: fixture.root.appendingPathComponent("new"), link: link)
    #expect(
      throws: CoreError.invalidState(
        link ? "staged symbolic link destination mismatch" : "staged content digest mismatch")
    ) { try transaction.commit() }
    try fixture.check(committed: false, journal: nil)
    try fixture.expectClean()
  }

  @Test func copyProtocolAlsoAcceptsARegularFile() throws {
    let fixture = try PublicationFixture(.fileCreate)
    let source = fixture.root.appendingPathComponent("new/nested/file")
    let transaction = FileTransaction(store: fixture.store)
    try transaction.replace(fixture.target, content: source)
    try transaction.commit()
    #expect(try Data(contentsOf: fixture.target) == Data(contentsOf: source))
    #expect(
      try FileSnapshot.read(at: fixture.target)?.identity.kind
        == FileSnapshot.read(at: source)?.identity.kind)
    try fixture.expectClean()
  }

  @Test func parsedBytesAndJournalPreimageUseThePreparedGeneration() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    try store.withLock {
      let prepared = try StatePrecondition(store: store)
      let original = try #require(try prepared.bytes(for: store.declarationURL))
      let declaration = try store.readDeclaration(prepared: prepared)
      try (original + Data("\n".utf8)).write(to: store.declarationURL, options: .atomic)
      let external = try FileSnapshot.read(at: store.declarationURL)
      #expect(try store.readDeclaration(prepared: prepared) == declaration)
      #expect(try prepared.bytes(for: store.declarationURL) == original)
      let transaction = FileTransaction(store: store)
      try transaction.replace(
        store.declarationURL, content: nil, data: original,
        expecting: prepared.evidence(for: store.declarationURL))
      #expect {
        try transaction.commit()
      } throws: { error in
        guard case CoreError.invalidState(let reason) = error else { return false }
        return reason.contains("path changed during preparation")
      }
      #expect(try FileSnapshot.read(at: store.declarationURL) == external)
      #expect(try store.openDirectoryIfPresent()?.info("transaction.json") == nil)
    }
  }
}
