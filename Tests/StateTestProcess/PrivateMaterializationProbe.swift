import AgentsCore
import AgentsInstructions
import AgentsSkills
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

func sharedMaterializationProbe(
  _ command: String, store: StateStore, checkpoint: @escaping (String) throws -> Void
) throws {
  if command == "shared-admission-wait" {
    do {
      try store.withLock(checkpoint: checkpoint) {
        try Data().write(
          to: store.environment.projectDirectory.appendingPathComponent("admission-body"))
        _ = try ProbeBindings(root: store.environment.projectDirectory).value(
          for: "value", environment: store.environment)
      }
    } catch CoreError.transactionRecovered {
      try Data().write(
        to: store.environment.projectDirectory.appendingPathComponent("admission-recovered"))
    }
    return
  }
  if command == "shared-hold-lock" {
    guard let index = CommandLine.arguments.firstIndex(of: "--lock-path"),
      CommandLine.arguments.indices.contains(index + 1)
    else { throw CoreError.invalidState("missing test lock path") }
    try FileLock.withLock(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) {
      try checkpoint("shared.rawLocked")
    }
    return
  }
  if command == "shared-skill-recover" {
    do {
      _ = try SkillOperations.remove(skillNames: ["absent"], environment: store.environment)
    } catch CoreError.transactionRecovered {}
    return
  }
  if command == "shared-watch-recover" {
    do {
      _ = try SkillOperations.watchOperations().remove("absent", environment: store.environment)
    } catch CoreError.transactionRecovered {}
    return
  }
  if command == "shared-instruction-recover" {
    do {
      _ = try InstructionOperations.remove(names: ["absent"], environment: store.environment)
    } catch CoreError.transactionRecovered {}
    return
  }
  if command == "shared-recover" {
    do { try store.withLock(checkpoint: checkpoint, {}) } catch CoreError.transactionRecovered {}
    return
  }
  try store.withLock(checkpoint: checkpoint, footprint: [.claudeMCPLocal]) {
    if command == "shared-lock" {
      try checkpoint("shared.locked")
      return
    }
    if command == "shared-readmission-writer" { try checkpoint("shared.beforeJournal") }
    let target = try store.nativeTarget(for: .claudeMCPLocal)
    let transaction = FileTransaction(store: store, checkpoint: checkpoint)
    if command == "shared-delete" {
      try transaction.delete(target.url)
    } else if command == "shared-install" {
      let prepared = try store.preparePrivateMaterialization(target, changingAccess: true)
      try transaction.replacePrivate(
        prepared, bindings: ["value"],
        provider: ProbeBindings(root: store.environment.projectDirectory)
      ) {
        try $0.value(for: "value")
      }
    } else {
      try transaction.replace(target.url, with: .data(Data("secret sibling; edited region".utf8)))
    }
    try transaction.replace(
      store.environment.projectDirectory.appendingPathComponent("old-data/AGENTS.md"),
      with: .data(Data("ordinary after".utf8)))
    try transaction.commit()
  }
}
