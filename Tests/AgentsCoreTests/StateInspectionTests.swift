import AgentsCore
import Foundation
import Testing

@Suite("State inspection concurrency")
struct StateInspectionTests {
  @Test(arguments: [false, true], [false, true])
  func firstWatchAddInvalidatesAnUnlockedRead(_ cached: Bool, _ bodyThrows: Bool) throws {
    let fixture = try WatchGitFixture()
    let head = try fixture.head()
    try FileManager.default.removeItem(at: fixture.store.directory)
    if cached {
      _ = try SourceCache(store: fixture.store).resolve(
        SourceDeclaration(kind: .local, location: fixture.repo.path))
    }
    try #require(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent(".agents.lock").path))
    var reads = 0
    var interruptedState: String?
    let pending = CoreError.invalidState("transaction recovery is required before inspection")

    #expect(throws: pending) {
      try fixture.store.withReadLock {
        reads += 1
        let child = try stateTestProcess(
          root: fixture.root, arguments: ["watch-add", "replace.1.renamed"])
        try fixture.kill(child, at: "replace.1.renamed")
        let declaration = try fixture.store.readDeclaration()
        let watch = try fixture.store.readWatch()
        try #require(declaration.watch == ["source"])
        try #require(watch.sources[fixture.id]?.seen == .revision(head))
        interruptedState = try FileHash.folderHash(fixture.store.directory)
        if bodyThrows { throw CoreError.invalidState("inconsistent inspection") }
        return watch
      }
    }
    #expect(reads == 1)
    #expect(try FileHash.folderHash(fixture.store.directory) == interruptedState)
    #expect(try fixture.recoveredWatch().sources.isEmpty)
    #expect(try fixture.store.loadDeclaration().watch == nil)
  }
}
