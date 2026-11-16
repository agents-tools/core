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
          let section = try Instructions.validateSource(
            FileSystem.read(at: file), id: id + ":" + name)
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
        let section = try Instructions.validateSource(FileSystem.read(at: file), id: name)
        return InstructionUnit(
          record: LockedSection(
            name: name, source: Self.own,
            path: PathSafety.relativePath(file.path, to: project.path), hash: section.hash),
          section: section)
      })
    ownUnits = units
    return units
  }

  /// One of the project's own instructions, read from the working tree as it is. Other files in
  /// the container are not read, so an unfinished draft affects only operations that list them.
  func own(named name: String) throws -> InstructionUnit {
    guard store.scope == .project else {
      throw CoreError.invalidState("own instructions exist only in project scope")
    }
    let project = store.environment.projectDirectory.resolvingSymlinksInPath()
    let path = Self.ownContainer + "/" + name + ".md"
    let file = project.appendingPathComponent(path)
    guard Declaration.isInstructionName(name), FileManager.default.fileExists(atPath: file.path)
    else { throw CoreError.notFound("own instructions file: \(name)") }
    try Self.requireNoLinks(file, below: project)
    let section = try Instructions.validateSource(FileSystem.read(at: file), id: name)
    return InstructionUnit(
      record: LockedSection(name: name, source: Self.own, path: path, hash: section.hash),
      section: section)
  }

  func restore(
    _ records: [LockedSection], sources: [String: LockedSource], cachedOnly: Bool = false
  ) throws
    -> [InstructionUnit]
  {
    try records.map { record in
      let ledger = try store.readLedger()
      for component in ledger.components.values
      where component.kind == "instructions" && component.name == record.name {
        guard let id = component.resources.first, let resource = ledger.resources[id],
          resource.path == record.path,
          component.revision == record.revision,
          try
            (record.source == Self.own
            || ledger.sourceIdentity(component.source, roots: store.ledgerRoots) == record.source)
        else { continue }
        let bytes: Data?
        if let object = resource.entries.first(where: { $0.path == "." && $0.kind == .file })?
          .object
        {
          bytes = ledger.contentObjects[object]
        } else {
          let file = store.cacheDirectory.appendingPathComponent(
            "artifact-content/" + String(id.dropFirst(7)) + "/payload")
          bytes = try? FileSystem.read(at: file)
        }
        if let bytes {
          let section = try Instructions.validateSource(
            bytes, id: Self.identity(record), allowRestrictions: true)
          guard section.hash == record.hash else {
            throw CoreError.invalidState("locked instruction digest mismatch")
          }
          return InstructionUnit(record: record, section: section)
        }
      }
      if record.source == Self.own {
        guard let unit = try? own(named: record.name), unit.record.path == record.path,
          unit.record.hash == record.hash
        else { throw InstructionError.ownChanged(name: record.name) }
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
          return try Instructions.validateSource(
            FileSystem.read(at: file), id: Self.identity(record))
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

  /// Rejects a symbolic link at `url` or at any directory between `tree` and it.
  static func requireNoLinks(_ url: URL, below tree: URL) throws {
    var cursor = tree
    for component in PathSafety.relativePath(url.path, to: tree.path).split(separator: "/") {
      cursor.appendPathComponent(String(component))
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
        throw CoreError.invalidSource(
          "instructions containers hold no symbolic links: \(PathSafety.relativePath(cursor.path, to: tree.path))"
        )
      }
    }
  }

  /// The `.md` files below a container, by name, except the target names `AGENTS.md` and
  /// `GEMINI.md`, which a project may generate there. Symbolic links and invalid names are errors.
  static func files(in directory: URL, tree: URL) throws -> [(String, URL)] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    try contained(directory, in: tree)
    try requireNoLinks(directory, below: tree)
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
        } else if values.isRegularFile == true, entry.pathExtension == "md",
          !["AGENTS.md", "GEMINI.md"].contains(component)
        {
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
