import AgentsSkills
import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore
@testable import AgentsUpdates

@Suite("Combined update transactions")
struct UpdateTransactionTests {
  @Test func failedRecoveryKeepsBackupsUntilTheRootIsRestored() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    let before = try fixture.snapshot()
    try fixture.advance()
    let root = fixture.target().deletingLastPathComponent()
    let moved = fixture.root.appendingPathComponent("displaced-skills")
    do {
      _ = try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { step in
          if step == TransactionCheckpoint.progress(0, .applied).name {
            // Exchange a journal-bound root so every automatic recovery attempt must stop.
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            throw CoreError.invalidState("interrupted with displaced root")
          }
        },
        { try $0.apply() })
      Issue.record("failure checkpoint was not reached")
    } catch let error as UpdateApplyError {
      #expect(error.disposition == .recoveryRequired)
    }
    let journal = fixture.store.directory.appendingPathComponent("transaction.json")
    #expect(FileManager.default.fileExists(atPath: journal.path))
    let retained = try FileManager.default.contentsOfDirectory(atPath: moved.path)
    #expect(retained.contains { $0.hasPrefix(".agents-") })
    #expect(throws: CoreError.invalidState("transaction root identity changed")) {
      try fixture.store.loadResolved()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == retained)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: moved, to: root)
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.apply()
    }
    #expect(try fixture.snapshot() == before)
    _ = try fixture.apply()
    #expect(try !fixture.preview().hasChanges)
  }

  @Test(arguments: [
    "between-kinds", TransactionCheckpoint.phase(.preparing).name,
    TransactionCheckpoint.persisted(.applying, .entry(0, .publishing), .renamed).name,
    TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name,
    TransactionCheckpoint.phase(.committed).name, TransactionCheckpoint.containerRemoved(0).name,
    TransactionCheckpoint.journalRemoved.name,
  ])
  func failuresReportTheRecoveredGeneration(_ failure: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    let before = try fixture.snapshot()
    let oldLock = try fixture.store.loadResolved()
    let old = oldLock.skills["demo"]!
    let oldCache = SourceCache(store: fixture.store).materializedURL(
      sourceID: old.source, revision: old.revision!)
    try fixture.advance()
    var lastSkill: Int?
    var failed = false
    do {
      _ = try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { step in
          if step == TransactionCheckpoint.phase(.preparing).name {
            lastSkill = try lastSkillIndex(fixture.store)
          }
          if step == failure
            || (failure == "between-kinds"
              && step == lastSkill.map { TransactionCheckpoint.progress($0, .applied).name })
          {
            failed = true
            throw CoreError.invalidState("injected update failure")
          }
        },
        { try $0.apply() })
      Issue.record("failure checkpoint was not reached")
    } catch let error as UpdateApplyError {
      let committed = committedPoints.contains(failure)
      #expect(error.disposition == (committed ? .committed : .unchanged))
      #expect(error.underlyingError as? CoreError == .invalidState("injected update failure"))
      if committed {
        #expect(try !fixture.preview().hasChanges)
      } else {
        #expect(try fixture.snapshot() == before)
        #expect(FileManager.default.fileExists(atPath: oldCache.path))
      }
    }
    #expect(failed)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.store.directory.appendingPathComponent("transaction.json").path))
  }

  @Test(arguments: [
    "between-kinds", TransactionCheckpoint.phase(.preparing).name,
    TransactionCheckpoint.persisted(.applying, .entry(0, .publishing), .renamed).name,
    TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name,
    TransactionCheckpoint.containerRemoved(0).name,
  ])
  func killedCombinedWriterRecoversThenPreparesTheWholeUpdate(_ checkpoint: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    let before = try fixture.snapshot()
    try fixture.advance()
    let child = try launch(fixture, command: "combined-crash", argument: checkpoint)
    defer { terminate(child) }
    try waitFor("ready", fixture: fixture, child: child)
    terminate(child)
    #expect(throws: CoreError.invalidState("transaction recovery is required before inspection")) {
      try fixture.preview()
    }
    #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
      try fixture.apply()
    }
    let committed = committedPoints.contains(checkpoint)
    if !committed { #expect(try fixture.snapshot() == before) }
    var displayed = 0
    _ = try UpdateOperations.withPreparedUpdate(environment: fixture.environment) { update in
      displayed += 1
      #expect(update.report.hasChanges == !committed)
      return try update.apply()
    }
    #expect(displayed == 1)
    #expect(try !fixture.preview().hasChanges)
  }

  @Test(arguments: ["skills", "instructions", "watch", "state", "preview"])
  func preparedSessionKeepsOtherScopeUsersBlocked(_ operation: String) throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    if operation == "watch" {
      try SkillOperations.watchOperations().add("fixture", environment: fixture.environment)
    }
    let prepared = try launch(fixture, command: "combined-crash", argument: "prepared")
    defer { terminate(prepared) }
    try waitFor("ready", fixture: fixture, child: prepared)
    let contender = try launch(fixture, command: "combined-contender", argument: operation)
    defer { terminate(contender) }
    try waitFor("contender-started", fixture: fixture, child: contender)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("contender-finished").path))
    try ProcessWait.stopped(prepared, root: fixture.root)
    kill(prepared.processIdentifier, SIGCONT)
    try ProcessWait.exit(prepared, root: fixture.root)
    #expect(prepared.terminationStatus == 0)
    try waitFor("contender-finished", fixture: fixture, child: contender)
    try ProcessWait.exit(contender, root: fixture.root)
    #expect(contender.terminationStatus == 0)
  }

  @Test func watchCleanupFailureReportsCommitted() throws {
    let fixture = try UpdateFixture()
    try fixture.install()
    try fixture.advance()
    do {
      _ = try UpdateOperations.withPreparedUpdate(
        environment: fixture.environment,
        checkpoint: { step in
          if step == "watch.references.cleared" { throw CoreError.invalidState("cleanup failed") }
        },
        { try $0.apply() })
      Issue.record("watch cleanup checkpoint not reached")
    } catch let error as UpdateApplyError {
      #expect(error.disposition == .committed)
    }
    // The next writer finishes pending cleanup before a fresh plan is allowed.
    if FileManager.default.fileExists(
      atPath: fixture.store.directory.appendingPathComponent("watch-refs.pending").path)
    {
      #expect(throws: CoreError.transactionRecovered(fixture.store.directory.path)) {
        try fixture.apply()
      }
    }
    #expect(try !fixture.preview().hasChanges)
  }
}

private func lastSkillIndex(_ store: StateStore) throws -> Int {
  let journal = try #require(
    JSONSerialization.jsonObject(
      with: Data(
        contentsOf:
          store.directory.appendingPathComponent("transaction.json"))) as? [String: Any])
  let entries = try #require(journal["entries"] as? [[String: Any]])
  return try #require(
    entries.firstIndex { ($0["path"] as? String)?.hasPrefix("instructions-") == true }) - 1
}

private final class UpdateTestBundle: NSObject {}

/// Interruptions at or after the terminal commit marker.
private let committedPoints = [
  TransactionCheckpoint.persisted(.committed, .terminal, .renamed), .phase(.committed),
  .containerRemoved(0), .journalRemoved,
].map(\.name)

private func launch(_ fixture: UpdateFixture, command: String, argument: String) throws -> Process {
  var directory = Bundle(for: UpdateTestBundle.self).bundleURL
  while !FileManager.default.isExecutableFile(
    atPath: directory.appendingPathComponent("StateTestProcess").path),
    directory.path != "/"
  { directory.deleteLastPathComponent() }
  let process = Process()
  process.executableURL = directory.appendingPathComponent("StateTestProcess")
  process.arguments = [
    fixture.root.path, command, argument, "--scope", fixture.store.scope.rawValue,
  ]
  try process.run()
  return process
}

private func waitFor(_ name: String, fixture: UpdateFixture, child: Process) throws {
  let file = fixture.root.appendingPathComponent(name)
  try ProcessWait.marker(file, child: child, root: fixture.root)
}

/// A child that survives the termination deadline fails the test instead of blocking the run.
private func terminate(_ process: Process) {
  do { try ProcessWait.terminate(process) } catch { Issue.record(error) }
}
