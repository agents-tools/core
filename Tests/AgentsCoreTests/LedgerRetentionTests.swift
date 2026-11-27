import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger retention")
struct LedgerRetentionTests {
  @Test func completeClosureRetainsNonSkillPinsAndWatch() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try FileSystem.createDirectory(at: store.directory)
    let cache = SourceCache(store: store)
    let source = "github.com/example/components"
    let pin = String(repeating: "a", count: 40)
    let obsolete = String(repeating: "b", count: 40)
    let kept = cache.materializedURL(sourceID: source, revision: pin)
    let unused = cache.materializedURL(sourceID: source, revision: obsolete)
    try FileSystem.createDirectory(at: kept)
    try FileSystem.createDirectory(at: unused)
    var ledger = ResolvedLedger()
    ledger.sources["group-source"] = LedgerSource(
      kind: .git,
      transport: "https://github.com/example/components.git", revision: pin)
    ledger.groups = [
      LedgerGroup(
        id: 0, source: "group-source", root: ".", name: "empty-export",
        manifestHash: "sha256:" + String(repeating: "c", count: 64), children: [])
    ]
    var references = try RetentionReferences(ledger: ledger, roots: [:])
    #expect(references.git.count == 1)
    let tx = FileTransaction(store: store)
    try cache.prune(references: references, transaction: tx)
    #expect(FileManager.default.fileExists(atPath: unused.path))
    try tx.commit()
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    ledger.groups = []
    ledger.sources = [:]
    references = try RetentionReferences(ledger: ledger, roots: [:])
    try references.include(
      watch: WatchState(sources: [source: WatchSourceState(seen: .revision(pin))]))
    let watched = FileTransaction(store: store)
    try cache.prune(references: references, transaction: watched)
    try watched.commit()
    #expect(FileManager.default.fileExists(atPath: kept.path))
    let released = FileTransaction(store: store)
    try cache.prune(references: RetentionReferences(), transaction: released)
    try released.commit()
    #expect(!FileManager.default.fileExists(atPath: kept.path))
  }

  @Test func danglingAncestryAndReferencesReject() throws {
    var ledger = ResolvedLedger()
    ledger.sources["child"] = LedgerSource(kind: .local, revision: "x", container: "missing")
    #expect(throws: (any Error).self) { _ = try RetentionReferences(ledger: ledger, roots: [:]) }
    ledger.sources["missing"] = LedgerSource(kind: .local, revision: "x", container: "child")
    #expect(throws: (any Error).self) { try ledger.validate() }
  }
}
