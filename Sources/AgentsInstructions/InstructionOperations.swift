import AgentsCore
import AgentsManifest
import Foundation

public enum InstructionOperations {
  public static func list(
    source: SourceDeclaration, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [InstructionUnit] {
    let store = StateStore(scope: scope, environment: environment)
    return try operate(store, apply: false) { _, _ in
      try inspectSource(source, store: store)
    }
  }

  /// The project's own instructions in `.agent/instructions/`, read from the working tree.
  public static func listOwn(environment: RuntimeEnvironment = RuntimeEnvironment()) throws
    -> [InstructionUnit]
  {
    let store = StateStore(scope: .project, environment: environment)
    return try operate(store, apply: false) { _, _ in try InstructionSources(store: store).own() }
  }

  /// Includes missing targets; doctor supplies their disk status.
  public static func listManaged(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> LockedInstructions {
    try operate(StateStore(scope: scope, environment: environment), apply: false) { _, lock in
      lock.instructions
    }
  }

  /// Creates the project's own `.agent/instructions/<name>.md` with the required front matter,
  /// without replacing an existing entry or creating a declaration or resolved ledger.
  @discardableResult
  public static func initializeInstructions(
    named name: String, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> URL {
    try InstructionInitialization(named: name, environment: environment, validateState: false)
      .apply(outcome: TransactionOutcome(), checkpoint: { _ in })
  }

  static func operate<T>(
    _ store: StateStore, apply: Bool, _ body: (Declaration, ResolvedState) throws -> T
  ) throws -> T {
    if apply {
      return try store.withLock {
        try body(store.readDeclaration(), store.readResolved())
      }
    }
    return try store.withReadLock {
      try body(store.readDeclaration(), store.readResolved())
    }
  }

}

extension InstructionOperations {
  package static func inspectOwn(names: [String], environment: RuntimeEnvironment) throws
    -> [InstructionUnit]
  {
    let sources = InstructionSources(store: StateStore(scope: .project, environment: environment))
    return try names.isEmpty ? sources.own() : names.map(sources.own(named:))
  }
}

extension InstructionOperations {
  package static func inspectSource(_ source: SourceDeclaration, store: StateStore) throws
    -> [InstructionUnit]
  {
    let policy = try SourcePolicySnapshot(store: store)
    return try SourceResolutionSession.withTemporaryRead(
      store: store, sourcePolicy: policy.effective
    ) { session in
      guard source.kind != .wellKnown else {
        throw CoreError.unsupported("instructions require source files")
      }
      if try session.isGitSource(source) {
        let units = try InstructionSources(store: store, resolutions: session).discover(
          source, cacheSource: false)
        try policy.validate()
        return units
      }
      let view = try session.localSnapshot(source)
      let units = try InstructionSnapshotReader.read(view).map { unit in
        InstructionUnit(
          record: LockedSection(
            name: unit.name, source: view.snapshot.source,
            revision: view.pin?.revision, version: view.pin?.version,
            path: unit.path, hash: unit.section.hash), section: unit.section)
      }
      try policy.validate()
      return units
    }
  }
}

extension InstructionOperations {
  /// Includes the absent own container and explicitly selected leaves for file-event invalidation.
  package static func ownReadLocations(names: [String] = [], environment: RuntimeEnvironment)
    -> [URL]
  {
    let directory = environment.projectDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(InstructionSources.ownContainer)
    return [directory] + names.map { directory.appendingPathComponent($0 + ".md") }
  }
}
