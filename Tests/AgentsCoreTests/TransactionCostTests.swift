import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Transaction I/O cost")
struct TransactionCostTests {
  /// Every commit probes its device once; existing ancestry costs one barrier per component.
  @Test func twoSmallFiles() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let targets = ["AGENTS.md", "GEMINI.md"].map { root.appendingPathComponent($0) }
    for target in targets { try Data("before".utf8).write(to: target) }
    let ancestry = root.resolvingSymlinksInPath().pathComponents.count - 1
    for _ in 0..<2 {
      let count = TransactionIOCount()
      try store.withLock {
        let transaction = FileTransaction(store: store) { step in
          if TransactionCheckpoint.isJournalPublished(step) { count.persist() }
          if step == TransactionCheckpoint.probe(0, .verified).name { count.probe() }
        }
        for target in targets {
          try transaction.replace(target, with: .data(Data("after".utf8)))
        }
        try DirectoryHandle.$synchronizationObserver.withValue({ count.sync() }) {
          try transaction.commit()
        }
      }
      #expect(count.persists == 10)
      #expect(count.probes == 1)
      #expect(count.barriers - ancestry == 38)
      for target in targets { #expect(try Data(contentsOf: target) == Data("after".utf8)) }
    }
  }

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
        store.declarationURL, with: .data(manifestText("defaultAgents: [.codex]")))
      try transaction.commit()
    }
    #expect(steps.contains(TransactionCheckpoint.containerCreated(1).name))
    #expect(steps.contains(TransactionCheckpoint.probe(0, .verified).name))
    #expect(!steps.contains(TransactionCheckpoint.probe(1, .firstCreated).name))
  }
}

private final class TransactionIOCount: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var persists = 0
  private(set) var barriers = 0
  private(set) var probes = 0
  func persist() {
    lock.lock()
    defer { lock.unlock() }
    persists += 1
  }
  func probe() {
    lock.lock()
    defer { lock.unlock() }
    probes += 1
  }
  func sync() {
    lock.lock()
    defer { lock.unlock() }
    barriers += 1
  }
}
