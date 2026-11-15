import AgentsCore
import Foundation

func privateMaterializationProbe(
  _ command: String, store: StateStore, checkpoint: @escaping (String) throws -> Void
) throws {
  let root = store.environment.projectDirectory
  if command == "private-recover" {
    do { try store.withLock(checkpoint: checkpoint, {}) } catch CoreError.transactionRecovered {}
    return
  }
  try store.withLock {
    let target = try store.materializationTarget(at: root.appendingPathComponent("AGENTS.md"))
    let prepared = try store.preparePrivateMaterialization(target, changingAccess: true)
    let transaction = FileTransaction(store: store, checkpoint: checkpoint)
    try transaction.replacePrivate(
      prepared, bindings: ["value"], provider: ProbeBindings(root: root)
    ) {
      try $0.value(for: "value")
    }
    try transaction.commit()
  }
}

private struct ProbeBindings: RuntimeBindingProvider {
  let root: URL
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    try Data().write(to: root.appendingPathComponent("provider-called"))
    return Data("private-after".utf8)
  }
}
