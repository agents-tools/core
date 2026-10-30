import AgentsManifest
import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

/// Domain operations whose single journal creates the declaration with the state beside it.
/// Killing them or their recovery at any recorded point leaves either no scope state or the
/// complete new generation, with declaration, lock, watch state and targets in agreement.
@Suite("State operation publication")
struct StatePublicationTests {
  @Test(arguments: StateOperationMatrix.publications)
  func killedOperationRecoversOneGeneration(_ fault: StateOperationFault) throws {
    try fault.checkSetup()
    let fixture = try StateOperationFixture(fault.operation)
    terminateProcess(try fixture.pause(fault.operation.command, at: fault.point))
    try fixture.recover()
    try fixture.check(committed: fault.committed)
  }

  @Test(arguments: StateOperationMatrix.recoveries)
  func recoveryCanBeKilledAtEachStageAndRepeated(_ fault: StateOperationFault) throws {
    try fault.checkSetup()
    let fixture = try StateOperationFixture(fault.operation)
    terminateProcess(try fixture.pause(fault.operation.command, at: fault.seed!))
    terminateProcess(try fixture.pause("publication-recover", at: fault.point))
    try fixture.recover()
    try fixture.check(committed: fault.committed)
  }

  /// A writer waiting for the scope lock prepares from the generation the holder committed, so
  /// neither declaration change is lost.
  @Test func serializedWritersKeepBothDeclarationChanges() throws {
    let fixture = try StateOperationFixture(.watchAdd)
    let watch = try fixture.pause("watch-add", at: "watch.mirror.fetched")
    defer { terminateProcess(watch) }
    let skill = try fixture.launch("skill-add", at: "never")
    defer { terminateProcess(skill) }
    Thread.sleep(forTimeInterval: 0.2)
    #expect(skill.isRunning)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ready"))
    kill(watch.processIdentifier, SIGCONT)
    for child in [watch, skill] {
      try ProcessWait.exit(child, root: fixture.root)
      #expect(child.terminationStatus == 0)
    }
    let declaration = try fixture.store.loadDeclaration()
    #expect(declaration.sources.keys.sorted() == ["source"])
    #expect(declaration.watch == ["source"])
    #expect(declaration.skills?["source"]?.select == .names(["demo"]))
    #expect(try fixture.store.loadResolved().skills.keys.sorted() == ["demo"])
    #expect(try fixture.store.loadWatch().sources.count == 1)
  }
}

enum StateOperation: String, CaseIterable, Sendable {
  /// A first skill add creates the declaration, the lock and an installation target.
  case freshSkillAdd
  /// A first watch subscription creates the declaration and watch state.
  case watchAdd

  var command: String { self == .freshSkillAdd ? "skill-add" : "watch-add" }

  /// Journal entries in request order; the declaration is created by entry `declaration`.
  var entries: Int { self == .freshSkillAdd ? 3 : 2 }
  var declaration: Int { self == .freshSkillAdd ? 1 : 0 }

  /// Recovery starts from sealed staging, a published declaration, every applied entry, the
  /// committed marker and terminal disposal.
  var recoverySeeds: [RecoverySeed] {
    [
      RecoverySeed(point: TransactionCheckpoint.progress(entries - 1, .ready).name),
      RecoverySeed(
        point: TransactionCheckpoint.publication(declaration, .created).name, renamed: true),
      RecoverySeed(
        point: TransactionCheckpoint.progress(entries - 1, .applied).name, renamed: true),
      RecoverySeed(
        point: TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name,
        committed: true),
      RecoverySeed(point: TransactionCheckpoint.disposalIntent.name, committed: true),
    ]
  }

  func requiredRecoveryPoints(from seed: RecoverySeed) -> Set<String> {
    var points = [
      TransactionCheckpoint.journalSynced.name, TransactionCheckpoint.journalRemoved.name,
    ]
    if !seed.committed {
      points.append(TransactionCheckpoint.persisted(.rolledBack, .terminal, .renamed).name)
    }
    if seed.renamed {
      points.append(TransactionCheckpoint.restoration(declaration, .withdrawn).name)
    }
    return Set(points)
  }
}

struct StateOperationFault: Sendable, CustomTestStringConvertible {
  let operation: StateOperation
  let point: String
  var committed = false
  var seed: String?
  var setupFailure: String?
  var testDescription: String {
    "\(operation.rawValue), \(seed.map { "from \($0), " } ?? "")\(point)"
  }
  func checkSetup() throws {
    if let setupFailure {
      throw CoreError.invalidState("checkpoint recording failed: " + setupFailure)
    }
  }
}

/// Kill points recorded from real traces. By default each operation is killed at
/// representative points, and its recovery at durable steps from each seeded interruption;
/// `AGENTS_PUBLICATION_MATRIX=full` kills at every recorded point.
enum StateOperationMatrix {
  static let complete = ProcessInfo.processInfo.environment["AGENTS_PUBLICATION_MATRIX"] == "full"
  static let publications = record(recovery: false)
  static let recoveries = record(recovery: true)

  /// Every recovery seed, the first durable intent, the last synced publication, container
  /// removal, and for watch subscriptions the acknowledged fetch and the ref reconciliation
  /// that follows the commit.
  private static func representativePublication(_ operation: StateOperation) -> Set<String> {
    var points =
      operation.recoverySeeds.map(\.point) + [
        TransactionCheckpoint.progress(0, .publishing).name,
        TransactionCheckpoint.publication(operation.entries - 1, .synced).name,
        TransactionCheckpoint.phase(.committed).name,
        TransactionCheckpoint.containerRemoved(0).name,
      ]
    if operation == .watchAdd {
      points += ["watch.mirror.fetched", "watch.references.pending", "watch.references.0.synced"]
    }
    return Set(points)
  }

  /// The observed-journal barrier, each durable recovery write, each creation's withdrawal and
  /// its barrier, disposal and the ref reconciliation that follows recovery.
  private static func representativeRecovery(_ operation: StateOperation) -> Set<String> {
    var points: [TransactionCheckpoint] = [.journalSynced, .containerRemoved(0), .journalRemoved]
    for phase in [TransactionJournal.Phase.applying, .committed, .rolledBack] {
      points += [.persisted(phase, .terminal, .renamed), .persisted(phase, .disposing, .renamed)]
      for index in 0..<operation.entries {
        for progress in [TransactionJournal.Progress.restoring, .restored, .cancelled] {
          points.append(.persisted(phase, .entry(index, progress), .renamed))
        }
      }
    }
    for index in 0..<operation.entries {
      points += [.restoration(index, .withdrawn), .restoration(index, .synced)]
    }
    return Set(points.map(\.name) + ["watch.references.0.synced", "watch.references.cleared"])
  }

  private static func record(recovery: Bool) -> [StateOperationFault] {
    var cases: [StateOperationFault] = []
    let commitMarker = TransactionCheckpoint.persisted(.committed, .terminal, .renamed).name
    for operation in StateOperation.allCases {
      let selected =
        recovery ? representativeRecovery(operation) : representativePublication(operation)
      let seeds: [RecoverySeed?] = recovery ? operation.recoverySeeds.map { $0 } : [nil]
      for seed in seeds {
        do {
          let fixture = try StateOperationFixture(operation)
          if let seed { terminateProcess(try fixture.pause(operation.command, at: seed.point)) }
          let command = recovery ? "publication-recover" : operation.command
          let child = try fixture.launch(command, at: "never")
          defer { terminateProcess(child) }
          try ProcessWait.exit(child, root: fixture.root)
          guard child.terminationStatus == 0 else {
            throw CoreError.invalidState("checkpoint recorder exited \(child.terminationStatus)")
          }
          let trace = try fixture.trace(child)
          guard !trace.isEmpty, Set(trace).count == trace.count else {
            throw CoreError.invalidState("checkpoint names are empty or repeated")
          }
          let required =
            seed.map(operation.requiredRecoveryPoints(from:))
            ?? representativePublication(operation)
          if !required.isSubset(of: trace) {
            throw CoreError.invalidState(
              "representative points were not recorded: \(required.subtracting(trace).sorted())")
          }
          var committed = seed?.committed ?? false
          for point in trace {
            if point == commitMarker { committed = true }
            guard complete || selected.contains(point) else { continue }
            cases.append(
              StateOperationFault(
                operation: operation, point: point, committed: committed, seed: seed?.point))
          }
        } catch {
          cases.append(
            StateOperationFault(
              operation: operation, point: "recording", seed: seed?.point,
              setupFailure: String(describing: error)))
        }
      }
    }
    return cases
  }
}

final class StateOperationFixture {
  let operation: StateOperation
  let root: URL
  let source: URL
  let store: StateStore
  let target: URL

  init(_ operation: StateOperation) throws {
    self.operation = operation
    root = try temporaryDirectory()
    source = root.appendingPathComponent("source")
    store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(
        projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
        environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path]
      ))
    target = AgentRegistry.installSkillsDirectory(
      for: .codex, scope: .project, environment: store.environment
    ).appendingPathComponent("demo")
    do {
      let skill = source.appendingPathComponent("skills/demo")
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try Data("---\nname: demo\ndescription: Fixture skill.\n---\nBody\n".utf8).write(
        to: skill.appendingPathComponent("SKILL.md"))
      try initGitRepo(source)
    } catch {
      removeTemporaryDirectory(root)
      throw error
    }
  }

  deinit { removeTemporaryDirectory(root) }

  func launch(_ command: String, at point: String) throws -> Process {
    try stateTestProcess(root: root, arguments: [command, point])
  }

  func pause(_ command: String, at point: String) throws -> Process {
    let marker = root.appendingPathComponent(
      command == "publication-recover" ? "recovery-ready" : "ready")
    try? FileManager.default.removeItem(at: marker)
    let child = try launch(command, at: point)
    do {
      try ProcessWait.marker(marker, child: child, root: root)
      try ProcessWait.stopped(child, root: root)
      return child
    } catch {
      terminateProcess(child)
      throw error
    }
  }

  func trace(_ child: Process) throws -> [String] {
    try String(
      contentsOf: root.appendingPathComponent("checkpoint-\(child.processIdentifier).log"),
      encoding: .utf8
    ).split(separator: "\n").map(String.init)
  }

  /// Recovers as the next writer would; repeating it finds nothing left to recover.
  func recover() throws {
    do { try store.withLock {} } catch CoreError.transactionRecovered {}
    try store.withLock {}
  }

  func check(committed: Bool) throws {
    #expect(try store.openDirectoryIfPresent()?.info(TransactionJournal.fileName) == nil)
    #expect(try store.openDirectoryIfPresent()?.info("watch-refs.pending") == nil)
    let declaration = try store.loadDeclaration()
    let lock = try store.loadResolved()
    let watch = try store.loadWatch()
    let present = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    guard committed else {
      for url in [store.declarationURL, store.resolvedURL, store.watchURL] {
        #expect(!present(url))
      }
      #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil)
      #expect(declaration == Declaration())
      return
    }
    let id = try SourceDeclaration(kind: .local, location: source.path).identity(
      environment: store.environment)
    #expect(declaration.sources.keys.sorted() == ["source"])
    #expect(try declaration.sources["source"]?.identity(environment: store.environment) == id)
    switch operation {
    case .freshSkillAdd:
      #expect(
        declaration.skills == [
          "source": SkillDeclaration(select: .names(["demo"]), agents: [.codex], mode: .edit)
        ])
      #expect(declaration.watch == nil)
      #expect(lock.skills["demo"]?.source == id)
      #expect(lock.skills["demo"]?.installs == ["codex": .edit])
      #expect(lock.sources[id] == LockedSource(kind: .local))
      #expect(
        target.resolvingSymlinksInPath().path
          == source.appendingPathComponent("skills/demo").resolvingSymlinksInPath().path)
      #expect(!present(store.watchURL))
    case .watchAdd:
      #expect(declaration.skills == nil)
      #expect(declaration.watch == ["source"])
      #expect(watch.sources[id]?.seen == .revision(try gitHead(source)))
      #expect(lock == ResolvedState())
      #expect(!present(store.resolvedURL))
    }
    let parents = [store.directory, target.deletingLastPathComponent()]
    for parent in parents where present(parent) {
      #expect(
        try !FileManager.default.contentsOfDirectory(atPath: parent.path).contains {
          $0.hasPrefix(".agents-")
        })
    }
  }
}
