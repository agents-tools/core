import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Transaction I/O cost")
struct TransactionCostTests {
  @Test func containersOnOneDeviceShareOneProbe() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    var steps: [String] = []
    try store.withLock {
      let transaction = FileTransaction(store: store) { steps.append($0) }
      try transaction.replace(
        root.appendingPathComponent("AGENTS.md"), with: .data(Data("after".utf8)))
      try transaction.replace(
        store.declarationURL, with: .data(manifestText("defaultAgents: [\"codex\"]\n")))
      try transaction.commit()
    }
    #expect(steps.contains(TransactionCheckpoint.containerCreated(1).name))
    #expect(steps.contains(TransactionCheckpoint.probe(0, .verified).name))
    #expect(!steps.contains(TransactionCheckpoint.probe(1, .firstCreated).name))
  }
}
