import Foundation
import Testing

@testable import AgentsCore

@Suite("State transactions")
struct StateTransactionTests {
  @Test func rollsBackEarlierReplacementsWhenALaterDestinationFails() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second/file")
    try Data("old".utf8).write(to: first)
    let transaction = FileTransaction()
    try transaction.replace(first, content: nil, data: Data("new".utf8))
    try transaction.replace(second, content: nil, data: Data("new".utf8))
    try FileManager.default.removeItem(at: second.deletingLastPathComponent())
    try Data("blocking file".utf8).write(to: second.deletingLastPathComponent())
    #expect(throws: (any Error).self) { try transaction.commit() }
    #expect(try String(contentsOf: first, encoding: .utf8) == "old")
  }

  @Test func serializesWritersAcrossConcurrentOperations() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          try store.withLock {
            var declaration = try store.loadDeclaration()
            declaration.sources["source-\(index)"] = SourceDeclaration(
              kind: .git, location: "example.com/repo/\(index)")
            let transaction = FileTransaction()
            try transaction.replace(
              store.declarationURL, content: nil, data: StateStore.encode(declaration))
            try transaction.commit()
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try store.loadDeclaration().sources.count == 8)
  }
}
