import AgentsCore
import AgentsInstructions
import AgentsSkills
import AgentsUpdates
import CPlatform
import Foundation
import Synchronization

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[1])
let scopeIndex = arguments.firstIndex(of: "--scope")
let scope: InstallScope =
  scopeIndex.flatMap { InstallScope(rawValue: arguments[$0 + 1]) } ?? .project
let store = StateStore(
  scope: scope,
  environment: RuntimeEnvironment(
    projectDirectory: root,
    homeDirectory: root.appendingPathComponent("home"),
    environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("configured-claude").path]))
let checkpointState = Mutex(
  (requested: arguments.count > 3 ? arguments[3] : "", seen: Set<String>()))
let traceURL = root.appendingPathComponent(
  "checkpoint-\(ProcessInfo.processInfo.processIdentifier).log")
FileManager.default.createFile(atPath: traceURL.path, contents: nil)
let trace = try FileHandle(forWritingTo: traceURL)
/// A repeated name would make a kill point ambiguous, so the recorder fails the run.
func stop(_ point: String, marker: String = "ready") throws {
  let (repeated, shouldStop) = checkpointState.withLock { state in
    (!state.seen.insert(point).inserted, point == state.requested)
  }
  try trace.write(contentsOf: Data((point + "\n").utf8))
  if repeated { fatalError("repeated checkpoint: \(point)") }
  if point.hasPrefix("journal."), point.hasSuffix(".renamed"),
    let bytes = try? Data(contentsOf: store.directory.appendingPathComponent("transaction.json"))
  {
    try bytes.write(to: root.appendingPathComponent("last-journal"))
  }
  if shouldStop {
    try Data(point.utf8).write(to: root.appendingPathComponent(marker), options: .atomic)
    raise(SIGSTOP)
    // A resumed handshake may select the next stop once, rather than reading on every checkpoint.
    let next =
      (try? String(contentsOf: root.appendingPathComponent("stop-at"), encoding: .utf8)) ?? ""
    checkpointState.withLock { $0.requested = next }
  }
}
func signalContention() throws {
  let signal = try FileHandle(forWritingTo: root.appendingPathComponent("writer-contended"))
  defer { try? signal.close() }
  try signal.write(contentsOf: Data("contended\n".utf8))
}
if arguments[2] == "git-environment" {
  let before = ProcessInfo.processInfo.environment
  let cache = SourceCache(store: store)
  let source = SourceDeclaration(kind: .local, location: root.appendingPathComponent("source").path)
  _ = try cache.resolve(source)
  _ = try cache.inspectRevision(source)
  _ = try cache.resolve(source)
  let helper = root.appendingPathComponent("ssh-helper")
  try Data(
    """
    #!/bin/sh
    printf 'protocol=https\\nhost=example.invalid\\n\\n' | \
      git -c credential.helper= \
      -c "credential.helper=!printf 'username=fixture\\npassword=fixture\\n'" credential fill >&2
    exit 1
    """.utf8
  ).write(to: helper)
  let quotedHelper = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  do {
    try ProcessRunner.git(
      [
        "-c", "core.sshCommand=/bin/sh " + quotedHelper, "-c", "ssh.variant=ssh",
        "ls-remote", "--", "ssh://git@example.invalid/source.git",
      ], operation: .listRemoteReferences, source: "ssh://git@example.invalid/source.git")
    preconditionFailure("SSH helper must fail after reading credentials")
  } catch let error as GitError {
    precondition(error.stderr.contains("username=fixture\npassword=fixture"), error.description)
  }
  precondition(ProcessInfo.processInfo.environment == before)
} else if arguments[2] == "locked-git" {
  close(STDOUT_FILENO)
  close(STDERR_FILENO)
  if arguments[4] == "all" { close(STDIN_FILENO) }
  try FileLock.withDescriptor(at: root.appendingPathComponent(arguments[3])) { descriptor in
    try Data(String(descriptor).utf8).write(to: root.appendingPathComponent("lock-descriptor"))
    try ProcessRunner.run(
      "/usr/bin/env",
      arguments: [
        "git", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
        "-C", root.appendingPathComponent("repository").path,
        "update-ref", "--no-deref", "-d", "refs/agents-watch/" + arguments[5], arguments[5],
      ], inheritingLock: descriptor)
  }
} else if arguments[2] == "lock-contender" {
  try FileLock.withLock(
    at: root.appendingPathComponent(arguments[3]),
    checkpoint: { if $0 == "lock.contended" { try signalContention() } },
    { try Data().write(to: root.appendingPathComponent("lock-acquired")) })
} else if arguments[2] == "closed-streams" {
  let mask = Int(arguments[3])!
  try FileLock.withDescriptor(at: root.appendingPathComponent("writer.lock")) { descriptor in
    for stream: Int32 in 0...2 where mask & (1 << stream) != 0 { close(stream) }
    let script = """
      if ($ARGV[0]) {
        my $byte;
        my $count = sysread(STDIN, $byte, 1);
        defined($count) && $count == 0 or die 'stdin must provide EOF';
      }
      print STDOUT 'out'; print STDERR 'err';
      """
    let output = try ProcessRunner.run(
      "/usr/bin/perl", arguments: ["-e", script, String(mask & 1)], inheritingLock: descriptor)
    try Data(output.stdout.utf8).write(to: root.appendingPathComponent("stdout"))
    try Data(output.stderr.utf8).write(to: root.appendingPathComponent("stderr"))
  }
} else if arguments[2] == "automatic-add" {
  let result: String
  do {
    if arguments[3] == "skill" {
      _ = try SkillOperations.add(
        AddOptions(
          source: "source", agents: [.codex], mode: .copy, environment: store.environment))
    } else {
      _ = try InstructionOperations.add(
        InstructionAddOptions(source: "source", agents: [.codex], environment: store.environment))
    }
    result = "applied"
  } catch {
    result = String(describing: error)
  }
  try Data(result.utf8).write(to: root.appendingPathComponent("add-result"))
} else if arguments[2] == "instruction-list" {
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
      if step == "mirror.lock.contended" {
        try signalContention()
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
} else if arguments[2] == "publication-recover" {
  let outcome = TransactionOutcome()
  let result: String
  do {
    try store.withLock(checkpoint: { try stop($0, marker: "recovery-ready") }, outcome: outcome, {})
    result = "clean"
  } catch CoreError.transactionRecovered { result = "recovered" } catch {
    result = "unresolved: \(error)"
  }
  try Data(result.utf8).write(to: root.appendingPathComponent("recovery-result"))
} else if arguments[2] == "publication" {
  let outcome = TransactionOutcome()
  var failure = ""
  do {
    try store.withLock(outcome: outcome) {
      let transaction = FileTransaction(store: store, outcome: outcome) {
        try Data(String(describing: outcome.disposition).utf8).write(
          to: root.appendingPathComponent("stopped-outcome"))
        try stop($0)
      }
      try transaction.replace(
        root.appendingPathComponent("GEMINI.md"), content: nil,
        data: Data("auxiliary postimage".utf8))
      let target =
        arguments[4] == "crossParentReplace"
        ? root.appendingPathComponent(".agents/skills/target")
        : root.appendingPathComponent("AGENTS.md")
      switch arguments[4] {
      case "directoryReplace":
        let source = root.appendingPathComponent("new")
        try transaction.replace(
          target, content: source, expectedHash: "sha256:" + FileHash.folderHash(source))
      case "directoryDelete": try transaction.replace(target, content: nil)
      case "symlinkCreate":
        try transaction.replace(target, content: root.appendingPathComponent("new"), link: true)
      default: try transaction.replace(target, content: nil, data: Data("postimage".utf8))
      }
      try transaction.commit()
    }
  } catch { failure = String(describing: error) }
  try Data((String(describing: outcome.disposition) + "\n" + failure).utf8).write(
    to: root.appendingPathComponent("publication-result"))
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
} else if arguments[2] == "combined-crash" {
  _ = try UpdateOperations.withPreparedUpdate(
    scope: scope, environment: store.environment,
    checkpoint: { step in
      if arguments[3] == "between-kinds", step.hasPrefix("entry.") && step.hasSuffix(".applied") {
        let journal =
          try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.directory.appendingPathComponent("transaction.json")))
          as! [String: Any]
        let entries = journal["entries"] as! [[String: Any]]
        let firstInstruction = entries.firstIndex {
          ($0["path"] as! String).hasPrefix("instructions-")
        }!
        if step == "entry.\(firstInstruction - 1).applied" { try stop("between-kinds") }
      } else {
        try stop(step)
      }
    },
    { update in
      try stop("prepared")
      return try update.apply()
    })
} else if arguments[2] == "combined-contender" {
  try Data().write(to: root.appendingPathComponent("contender-started"))
  switch arguments[3] {
  case "skills":
    _ = try SkillOperations.updateInstalled(
      scope: scope, environment: store.environment, apply: true)
  case "instructions":
    _ = try InstructionOperations.updateInstalled(
      scope: scope, environment: store.environment, apply: true)
  case "watch":
    _ = try SkillOperations.watchOperations().remove(
      "fixture", scope: scope, environment: store.environment)
  case "preview": _ = try UpdateOperations.preview(scope: scope, environment: store.environment)
  default: _ = try store.loadResolved()
  }
  try Data().write(to: root.appendingPathComponent("contender-finished"))
} else if arguments[2] == "pause" {
  try stop("paused")
} else if arguments[2] == "unstopped-marker" {
  // The marker exists but the process never stops, as when it is killed before its self-stop.
  try Data().write(to: root.appendingPathComponent("ready"), options: .atomic)
  while true { sleep(1) }
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
    } else if arguments[2] == "inspection-transaction" {
      let transaction = FileTransaction(store: store) { try stop($0) }
      try transaction.replace(
        AgentRegistry.installSkillsDirectory(
          for: .codex, scope: scope, environment: store.environment
        ).appendingPathComponent("target"), content: root.appendingPathComponent("new"))
      try transaction.replace(
        InstructionLocations.file(for: .codex, scope: scope, environment: store.environment)!,
        content: nil)
      try transaction.replace(
        InstructionLocations.file(for: .geminiCLI, scope: scope, environment: store.environment)!,
        content: nil, data: Data("New instructions\n".utf8))
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.cursor])))
      try transaction.replace(
        store.resolvedURL, content: nil, data: StateStore.encode(ResolvedState()))
      try transaction.commit()
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
      try transaction.replace(
        InstructionLocations.file(for: .codex, scope: scope, environment: store.environment)!,
        content: nil, data: Data("new instructions".utf8))
      try transaction.commit()
    }
  }

}
