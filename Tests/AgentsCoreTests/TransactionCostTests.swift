import Foundation
import Testing

@testable import AgentsCore

@Suite("Transaction I/O cost")
struct TransactionCostTests {
  @Test(arguments: [false, true])
  func twoSmallFiles(_ coldDevice: Bool) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let targets = ["AGENTS.md", "GEMINI.md"].map { root.appendingPathComponent($0) }
    for target in targets { try Data("before".utf8).write(to: target) }
    let count = TransactionIOCount()
    try store.withLock {
      let transaction = FileTransaction(store: store) { step in
        if step.hasPrefix("journal."), step.hasSuffix(".renamed") { count.persist() }
        if step.hasPrefix("directory.synced.") { count.ancestor() }
      }
      for target in targets {
        try transaction.replace(target, content: nil, data: Data("after".utf8))
      }
      try DirectoryHandle.$synchronizationObserver.withValue({ count.sync() }) {
        if coldDevice {
          try DirectoryHandle.$atomicRenameFailure.withValue({ _ in nil }) {
            try transaction.commit()
          }
        } else {
          try transaction.commit()
        }
      }
    }
    print(
      "TWO_SMALL_FILES cold=\(coldDevice) persists=\(count.persists) barriers=\(count.barriers) ancestry=\(count.ancestors)"
    )
    #expect(count.persists == 10)
    #expect(count.barriers - count.ancestors == (coldDevice ? 38 : 36))
    for target in targets { #expect(try Data(contentsOf: target) == Data("after".utf8)) }
  }
}

private final class TransactionIOCount: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var persists = 0
  private(set) var barriers = 0
  private(set) var ancestors = 0
  func ancestor() {
    lock.lock()
    defer { lock.unlock() }
    ancestors += 1
  }
  func persist() {
    lock.lock()
    defer { lock.unlock() }
    persists += 1
  }
  func sync() {
    lock.lock()
    defer { lock.unlock() }
    barriers += 1
  }
}
