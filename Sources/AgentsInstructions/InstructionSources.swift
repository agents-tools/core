import AgentsCore
import Foundation

final class InstructionSources {
  /// The lock's source for a project's own instructions, which are read live and never pinned.
  static let own = "."
  /// The project's own instructions container, relative to the project root.
  static let ownContainer = ".agent/instructions"
  static let containers = ["instructions", ".agents/instructions"]

  let store: StateStore
  let cache: SourceCache
  let resolutions: SourceResolutionSession?
  private var discovered: [String: [InstructionUnit]] = [:]
  private var restored: [String: InstructionSection] = [:]
  private var ownUnits: [InstructionUnit]?

  init(store: StateStore, resolutions: SourceResolutionSession? = nil) {
    self.resolutions = resolutions
    self.store = store
    cache = SourceCache(store: store)
  }

  func lockedSource(_ source: SourceDeclaration) -> LockedSource {
    LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
  }

  func discover(_ source: SourceDeclaration, cacheSource: Bool = true) throws -> [InstructionUnit] {
    let id = try source.identity(environment: store.environment)
    if let units = discovered[id] { return units }
    guard source.kind != .wellKnown else {
      throw CoreError.unsupported("instructions require a Git source")
    }
    if source.kind == .local {
      let directory = source.localURL(environment: store.environment)
      let root = try ProcessRunner.git(
        ["-C", directory.path, "rev-parse", "--show-toplevel"],
        operation: .findRepositoryRoot, source: source.location
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        URL(fileURLWithPath: root).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath()
      else { throw CoreError.invalidSource("use the local Git root and a search path") }
    }
    func read(_ pin: SourceRevision, _ tree: URL) throws -> [InstructionUnit] {
      let root = try PathSafety.resolvedChild(base: tree, subpath: source.path ?? ".")
      var units: [InstructionUnit] = []
      for container in Self.containers {
        let directory = root.appendingPathComponent(container)
        for (name, file) in try Self.files(in: directory, tree: tree) {
          let section = try Instructions.validateSource(Data(contentsOf: file), id: id + ":" + name)
          units.append(
            InstructionUnit(
              record: LockedSection(
                name: name, source: id, revision: pin.revision, version: pin.version,
                path: PathSafety.relativePath(file.path, to: tree.path), hash: section.hash),
              section: section))
        }
      }
      return try Self.unique(units)
    }
    let units =
      try resolutions.map { try $0.withSnapshot(source, read) }
      ?? cache.withResolvedSnapshot(source, cacheSource: cacheSource, read)
    discovered[id] = units
    return units
  }

  /// The project's own instructions, read from the working tree as it is.
  func own() throws -> [InstructionUnit] {
    if let ownUnits { return ownUnits }
    guard store.scope == .project else {
      throw CoreError.invalidState("own instructions exist only in project scope")
    }
    let project = store.environment.projectDirectory.resolvingSymlinksInPath()
    let directory = project.appendingPathComponent(Self.ownContainer)
    let units = try Self.unique(
      Self.files(in: directory, tree: project).map { name, file in
        let section = try Instructions.validateSource(Data(contentsOf: file), id: name)
        return InstructionUnit(
          record: LockedSection(
            name: name, source: Self.own,
            path: PathSafety.relativePath(file.path, to: project.path), hash: section.hash),
          section: section)
      })
    ownUnits = units
    return units
  }

  func resolve(
    references: [String], declaration: Declaration, lock: inout ResolvedState
  ) throws -> [InstructionUnit] {
    try references.map { reference in
      guard let (alias, name) = Self.split(reference) else {
        guard let unit = try own().first(where: { $0.record.name == reference }) else {
          throw CoreError.notFound("own instructions file: \(reference)")
        }
        return unit
      }
      guard let source = declaration.sources[alias] else {
        throw CoreError.invalidState("invalid instruction reference: \(reference)")
      }
      guard let unit = try discover(source).first(where: { $0.record.name == name }) else {
        throw CoreError.notFound("instruction section: \(reference)")
      }
      lock.sources[unit.record.source] = lockedSource(source)
      return unit
    }
  }

  func restore(
    _ records: [LockedSection], sources: [String: LockedSource], cachedOnly: Bool = false
  ) throws
    -> [InstructionUnit]
  {
    try records.map { record in
      if record.source == Self.own {
        guard let unit = try own().first(where: { $0.record.path == record.path }),
          unit.record.hash == record.hash
        else {
          throw CoreError.invalidState(
            "own instructions file changed since the lock: \(record.name); run 'agents update'")
        }
        return unit
      }
      guard let source = sources[record.source], let revision = record.revision,
        source.kind != .wellKnown
      else { throw CoreError.invalidState("instruction section requires a locked Git revision") }
      let key = record.source + "\n" + revision + "\n" + record.path
      let section: InstructionSection
      if let existing = restored[key] {
        section = existing
      } else {
        let materialized = cache.materializedURL(sourceID: record.source, revision: revision)
        try cache.validatePath(materialized)
        func read(_ root: URL) throws -> InstructionSection {
          let file = try PathSafety.resolvedChild(base: root, subpath: record.path)
          try Self.contained(file, in: root)
          return try Instructions.validateSource(Data(contentsOf: file), id: Self.identity(record))
        }
        if FileManager.default.fileExists(atPath: materialized.path) {
          section = try read(materialized)
        } else {
          guard !cachedOnly else {
            throw CoreError.notFound("locked instruction cache: \(record.name)")
          }
          section = try cache.withSnapshot(
            sourceID: record.source, source: source, revision: revision, read)
        }
        restored[key] = section
      }
      guard section.hash == record.hash else {
        throw CoreError.invalidState("locked instruction digest mismatch: \(record.name)")
      }
      return InstructionUnit(record: record, section: section)
    }
  }

  func retain(_ lock: ResolvedState) throws {
    let records = lock.instructions.sections + lock.instructions.chatgpt.values.flatMap(\.sections)
    for record in records where record.source != Self.own {
      guard let source = lock.sources[record.source], let revision = record.revision else {
        throw CoreError.invalidState("missing instruction pin")
      }
      let root = try cache.materialize(sourceID: record.source, source: source, revision: revision)
      let file = try PathSafety.resolvedChild(base: root, subpath: record.path)
      try Self.contained(file, in: root)
      guard Instructions.hash(try Data(contentsOf: file)) == record.hash else {
        throw CoreError.invalidState("cached instruction digest mismatch: \(record.name)")
      }
    }
  }

  /// `alias:name` for a declared source, or nil for a bare name of the project's own instructions.
  static func split(_ reference: String) -> (alias: String, name: String)? {
    guard let colon = reference.firstIndex(of: ":") else { return nil }
    return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
  }

  static func identity(_ record: LockedSection) -> String { record.source + ":" + record.name }

  static func contained(_ file: URL, in root: URL) throws {
    guard PathSafety.isContained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath())
    else {
      throw CoreError.unsafePath("instruction path escapes its root")
    }
  }

  /// The `.md` files below a container, by name. Symbolic links and invalid names are errors.
  private static func files(in directory: URL, tree: URL) throws -> [(String, URL)] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    try contained(directory, in: tree)
    var result: [(String, URL)] = []
    func walk(_ directory: URL, prefix: String) throws {
      let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
      for entry in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys
      ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try entry.resourceValues(forKeys: Set(keys))
        let component = entry.lastPathComponent
        if values.isSymbolicLink == true {
          throw CoreError.invalidSource(
            "instructions containers hold no symbolic links: \(prefix + component)")
        }
        if values.isDirectory == true {
          try walk(entry, prefix: prefix + component + "/")
        } else if values.isRegularFile == true, entry.pathExtension == "md" {
          let name = prefix + entry.deletingPathExtension().lastPathComponent
          guard Declaration.isInstructionName(name) else {
            throw CoreError.invalidSource(
              "instruction names use lowercase letters, digits and hyphens: \(name)")
          }
          result.append((name, entry))
        }
      }
    }
    try walk(directory, prefix: "")
    return result
  }

  private static func unique(_ units: [InstructionUnit]) throws -> [InstructionUnit] {
    var names = Set<String>()
    for unit in units where !names.insert(unit.record.name).inserted {
      throw CoreError.invalidSource("duplicate instruction name: \(unit.record.name)")
    }
    return units.sorted { $0.record.name < $1.record.name }
  }
}
