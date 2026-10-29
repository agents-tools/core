import AgentsCore
import CPlatform
import Foundation
import StateTestSupport
import Testing

@Suite("Watch state")
struct WatchStateTests {
  @Test(arguments: [InstallScope.project, .user])
  func storesSortedBaselinesAndPreservesWatchWhenSavingOtherState(_ scope: InstallScope) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let store = StateStore(scope: scope, environment: environment)
    let revision = String(repeating: "a", count: 40)
    let digest = "sha256:" + String(repeating: "b", count: 64)
    let watch = WatchState(sources: [
      "local:/source": WatchSourceState(seen: .revision(revision)),
      "https://example.test": WatchSourceState(
        seen: .artifacts(["zebra": digest, "alpha": digest])),
    ])
    let declaration = Declaration(
      sources: [
        "git": SourceDeclaration(kind: .local, location: "/source"),
        "web": SourceDeclaration(kind: .wellKnown, location: "https://example.test"),
      ], watch: ["web", "git"])
    try store.save(declaration: declaration, resolved: ResolvedState(), watch: watch)
    let bytes = try Data(contentsOf: store.watchURL)
    #expect(try store.loadWatch() == watch)
    #expect(bytes.last == 10)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(
      try #require(text.range(of: "alpha")).lowerBound
        < #require(text.range(of: "zebra")).lowerBound)
    #expect(!text.contains("timestamp"))
    try store.save(declaration: declaration, resolved: ResolvedState())
    #expect(try Data(contentsOf: store.watchURL) == bytes)
    try store.save(declaration: declaration, resolved: ResolvedState(), watch: watch)
    #expect(try Data(contentsOf: store.watchURL) == bytes)
    #expect(try store.loadDeclaration().watch == ["git", "web"])
  }

  @Test func rejectsMalformedAndNonUTF8WatchDocumentsWithoutOverwritingThem() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    try store.save(declaration: Declaration(), resolved: ResolvedState(), watch: WatchState())
    let declaration = try Data(contentsOf: store.declarationURL)
    let resolved = try Data(contentsOf: store.resolvedURL)
    let valid = #"{"version":1,"sources":{}}"#
    let malformed = [
      #"{"version":2,"sources":{}}"#,
      #"{"version":1,"sources":{},"extra":true}"#,
      #"{"version":1,"sources":{},"sources":{}}"#,
      #"{"version":1,"sources":{"local:/source":{"seen":"a"}}}"#,
      #"{"version":1,"sources":{"local:/source":{"seen":{}}}}"#,
      #"{"version":1,"sources":{"https://example.test":{"seen":{"demo":"bad"}}}}"#,
      #"{"version":1,"sources":{"https://example.test":{"seen":{"demo":"a","demo":"b"}}}}"#,
      valid + " {}", "{", "[]",
    ].map { Data($0.utf8) }
    let encodings = [
      Data([0xEF, 0xBB, 0xBF]) + Data(valid.utf8), Data([0xFF]),
      valid.data(using: .utf16)!, valid.data(using: .utf16LittleEndian)!,
      valid.data(using: .utf16BigEndian)!,
      valid.data(using: .utf32)!, valid.data(using: .utf32LittleEndian)!,
      valid.data(using: .utf32BigEndian)!,
    ]
    for data in malformed + encodings {
      try data.write(to: store.watchURL)
      #expect(throws: (any Error).self) { try store.loadWatch() }
      #expect(throws: (any Error).self) {
        try store.save(declaration: Declaration(), resolved: ResolvedState(), watch: WatchState())
      }
      #expect(try Data(contentsOf: store.watchURL) == data)
      #expect(try Data(contentsOf: store.declarationURL) == declaration)
      #expect(try Data(contentsOf: store.resolvedURL) == resolved)
    }
  }

  @Test func corruptWatchWithoutLockDoesNotCreateAnyStateFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("invalid".utf8).write(to: store.watchURL)
    let before = try FileHash.folderHash(root)
    #expect(throws: (any Error).self) {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    }
    #expect(try FileHash.folderHash(root) == before)
  }

  @Test func rejectsDuplicateSubscriptions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let declaration = Declaration(
      sources: ["source": SourceDeclaration(kind: .local, location: root.path)],
      watch: ["source", "source"])
    #expect(throws: CoreError.self) { try declaration.validate(environment: environment) }
  }

  @Test(arguments: [
    "publish.0.exchanged", "publish.1.exchanged", "journal.committed", "cleanup.0.removed",
  ])
  func interruptedWatchAndDeclarationRecoverTogether(_ checkpoint: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:]
      ))
    let declaration = Declaration(sources: [
      "source": SourceDeclaration(kind: .local, location: "/source")
    ])
    try store.save(declaration: declaration, resolved: ResolvedState(), watch: WatchState())
    let lockBytes = try Data(contentsOf: store.resolvedURL)
    let child = try stateTestProcess(root: root, arguments: ["watch-crash", checkpoint])
    defer {
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    let marker = root.appendingPathComponent("ready")
    try ProcessWait.marker(marker, child: child, root: root)
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    #expect(throws: CoreError.transactionRecovered(store.directory.path)) { try store.loadWatch() }
    let committed = checkpoint == "journal.committed" || checkpoint == "cleanup.0.removed"
    #expect(try store.loadDeclaration().watch == (committed ? ["source"] : nil))
    #expect(try store.loadWatch().sources.isEmpty == !committed)
    #expect(try Data(contentsOf: store.resolvedURL) == lockBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent("transaction.json").path))
  }
}
