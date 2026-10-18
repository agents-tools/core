import AgentsCore
import Darwin
import Foundation

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[1])
let store = StateStore(
  scope: .project,
  environment: RuntimeEnvironment(
    projectDirectory: root,
    homeDirectory: root.appendingPathComponent("home"), environment: [:]))
func stop(_ step: String, marker: String = "ready") throws {
  if step == arguments[3] {
    try Data(step.utf8).write(to: root.appendingPathComponent(marker))
    raise(SIGSTOP)
  }
}
if arguments[2] == "recover" {
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
    if arguments[2] == "writer" {
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
        root.appendingPathComponent(".agents/skills/target"),
        content: root.appendingPathComponent("new"))
      try transaction.replace(
        store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
      try transaction.replace(
        store.resolvedURL, content: nil,
        data: StateStore.encode(ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
      try transaction.replace(
        root.appendingPathComponent(".agent/cache/artifact-content/pruned"), content: nil)
      try transaction.replace(
        root.appendingPathComponent(".claude/skills/created"),
        content: root.appendingPathComponent("new"),
        link: true)
      try transaction.commit()
    }
  }

}
