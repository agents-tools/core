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
      if step == arguments[3] {
        try Data(step.utf8).write(to: root.appendingPathComponent("ready"))
        raise(SIGSTOP)
      }
    }
    try transaction.replace(
      root.appendingPathComponent("target"), content: root.appendingPathComponent("new"))
    try transaction.replace(
      store.declarationURL, content: nil, data: StateStore.encode(Declaration(agents: [.codex])))
    try transaction.replace(
      store.resolvedURL, content: nil,
      data: StateStore.encode(ResolvedState(sources: ["local:/new": LockedSource(kind: .local)])))
    try transaction.replace(root.appendingPathComponent("pruned"), content: nil)
    try transaction.replace(
      root.appendingPathComponent("created/skill"), content: root.appendingPathComponent("new"),
      link: true)
    try transaction.commit()
  }
}
