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
  /// without replacing an existing entry or creating a declaration or lock.
  @discardableResult
  public static func initializeInstructions(
    named name: String, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> URL {
    guard Declaration.isInstructionName(name), !name.contains("/") else {
      throw CoreError.invalidSource(
        "instruction names use lowercase letters, digits and hyphens: \(name)")
    }
    let store = StateStore(scope: .project, environment: environment)
    return try store.withLock {
      _ = try store.declarationBytes()
      let file = environment.projectDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(InstructionSources.ownContainer)
        .appendingPathComponent(name + ".md")
      guard try InstructionTargets.read(file) == nil else {
        throw CoreError.invalidSource("instruction file already exists: \(file.path)")
      }
      let bytes = Data(
        "---\ndescription: Describe what these instructions make the agent do.\n---\n# \(name)\n\nWrite the instructions here.\n"
          .utf8)
      _ = try Instructions.validateSource(bytes, id: name)
      let transaction = FileTransaction(store: store)
      try transaction.replace(file, with: .data(bytes))
      try transaction.commit()
      return file
    }
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
    try SourceResolutionSession.withTemporaryRead(store: store) { session in
      guard source.kind != .wellKnown else {
        throw CoreError.unsupported("instructions require source files")
      }
      if try session.isGitSource(source) {
        return try InstructionSources(store: store, resolutions: session).discover(
          source, cacheSource: false)
      }
      let view = try session.localSnapshot(source)
      return try InstructionSnapshotReader.read(view).map { unit in
        InstructionUnit(
          record: LockedSection(
            name: unit.name, source: view.snapshot.source,
            revision: view.pin?.revision, version: view.pin?.version,
            path: unit.path, hash: unit.section.hash), section: unit.section)
      }
    }
  }
}
