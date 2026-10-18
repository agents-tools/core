import AgentsCore
import AgentsInstructions
import Darwin
import Foundation

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[1])
let scope: InstallScope = arguments.count > 4 && arguments[4] == "user" ? .user : .project
let store = StateStore(
  scope: scope,
  environment: RuntimeEnvironment(
    projectDirectory: root,
    homeDirectory: root.appendingPathComponent("home"),
    environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path]))
func stop(_ step: String, marker: String = "ready") throws {
  if step == arguments[3] {
    try Data(step.utf8).write(to: root.appendingPathComponent(marker), options: .atomic)
    raise(SIGSTOP)
  }
}
if arguments[2] == "instruction-list" {
  let units = try InstructionOperations.list(
    source: SourceDeclaration(kind: .local, location: root.appendingPathComponent("source").path),
    environment: store.environment)
  try Data(units.map(\.record.name).joined(separator: "\n").utf8).write(
    to: root.appendingPathComponent("listing-finished"))
} else if ["watch-subscribe", "watch-acknowledge"].contains(arguments[2]) {
  let watch = WatchOperations(
    discoverSkills: { _ in [] },
    fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") },
    checkpoint: { step in
      if step == "mirror.lock.waiting" {
        try Data().write(to: root.appendingPathComponent("writer-waiting"))
      }
    })
  func acknowledge() throws {
    if arguments[2] == "watch-subscribe" {
      try watch.add(
        root.appendingPathComponent("source").path, alias: "source", environment: store.environment)
    } else {
      try watch.seen("source", revision: arguments[3], environment: store.environment)
    }
  }
  do { try acknowledge() } catch CoreError.transactionRecovered { try acknowledge() }
  try Data().write(to: root.appendingPathComponent("writer-finished"))
} else if ["watch-add", "watch-seen", "watch-remove"].contains(arguments[2]) {
  let watch = WatchOperations(
    discoverSkills: { _ in [] },
    fetchArtifacts: { _ in throw CoreError.unsupported("Git fixture") },
    checkpoint: { try stop($0) })
  if arguments[2] == "watch-add" {
    try watch.add(
      root.appendingPathComponent("source").path, alias: "source", environment: store.environment)
  } else if arguments[2] == "watch-seen" {
    try watch.seen("source", environment: store.environment)
  } else {
    try watch.remove("source", environment: store.environment)
  }
} else if arguments[2] == "watch-recover" {
  try store.withLock(checkpoint: { try stop($0) }, {})
} else if arguments[2] == "recover" {
  try FileLock.withLock(at: store.directory.appendingPathComponent(".agents.lock")) {
    _ = try FileTransaction.recover(store: store) { try stop($0, marker: "recovery-ready") }
  }
} else if arguments[2] == "read" {
  try Data().write(to: root.appendingPathComponent("reader-started"))
  do { _ = try store.loadResolved() } catch CoreError.transactionRecovered {
    _ = try store.loadResolved()
  }
  try Data().write(to: root.appendingPathComponent("reader-finished"))
} else if arguments[2] == "create-scope" {
  try FileLock.withLock(
    at: store.directory.appendingPathComponent(".agents.lock"), checkpoint: { try stop($0) },
    {
      try Data().write(to: root.appendingPathComponent("lock-acquired"))
    })
} else {
  try store.withLock {
    if arguments[2] == "cache-content" || arguments[2] == "cache-git"
      || arguments[2] == "cache-bytes"
    {
      let cache = SourceCache(store: store) { try stop($0) }
      let lock = try store.readResolved()
      guard let skill = lock.skills["demo"], let hash = skill.hash else {
        throw CoreError.invalidState("missing fixture skill")
      }
      if arguments[2] == "cache-content", let artifact = skill.artifact {
        _ = try cache.materializeArtifact(
          root.appendingPathComponent("new"), digest: artifact.digest, hash: hash)
      } else if arguments[2] == "cache-bytes", let artifact = skill.artifact {
        _ = try cache.storeArtifact(
          Data(contentsOf: root.appendingPathComponent("payload")), digest: artifact.digest)
      } else if let revision = skill.revision, let source = lock.sources[skill.source] {
        _ = try cache.materialize(sourceID: skill.source, source: source, revision: revision)
      } else {
        throw CoreError.invalidState("missing fixture pin")
      }
    } else if arguments[2] == "watch-crash" {
      var declaration = try store.readDeclaration()
      declaration.watch = ["source"]
      let watch = WatchState(sources: [
        "local:/source": WatchSourceState(seen: .revision(String(repeating: "b", count: 40)))
      ])
      let transaction = FileTransaction(store: store) { try stop($0) }
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(declaration))
      try transaction.replace(store.watchURL, content: nil, data: StateStore.encode(watch))
      try transaction.commit()
    } else if arguments[2] == "writer" {
      for index in 0..<5 {
        var declaration = try store.readDeclaration()
        declaration.sources["\(arguments[3])-\(index)"] = SourceDeclaration(
          kind: .local, location: root.appendingPathComponent("\(arguments[3])-\(index)").path)
        usleep(10_000)
        let transaction = FileTransaction(store: store)
        try transaction.replace(
          store.declarationURL, content: nil, data: StateStore.encode(declaration))
        try transaction.commit()
      }
    } else {
      let transaction = FileTransaction(store: store) { step in
        try stop(step)
      }
      try transaction.replace(
        AgentRegistry.installSkillsDirectory(
          for: .codex, scope: scope, environment: store.environment
        )
        .appendingPathComponent("target"),
        content: root.appendingPathComponent("new"))
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
      try transaction.replace(
        store.resolvedURL, content: nil,
        data: StateStore.encode(ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
      try transaction.replace(
        store.cacheDirectory.appendingPathComponent("artifact-content/pruned"), content: nil)
      try transaction.replace(
        AgentRegistry.installSkillsDirectory(
          for: .claudeCode, scope: scope, environment: store.environment
        ).appendingPathComponent("created"),
        content: root.appendingPathComponent("new"),
        link: true)
      try transaction.commit()
    }
  }

}
