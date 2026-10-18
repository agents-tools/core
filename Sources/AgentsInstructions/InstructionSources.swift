import AgentsCore
import Foundation

final class InstructionSources {
  let store: StateStore
  let cache: SourceCache
  private var discovered: [String: [InstructionUnit]] = [:]
  private var restored: [String: InstructionSection] = [:]

  init(store: StateStore) {
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
        operation: "find the repository root for", source: source.location
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        URL(fileURLWithPath: root).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath()
      else { throw CoreError.invalidSource("use the local Git root and a search path") }
    }
    let units = try cache.withResolvedSnapshot(source, cacheSource: cacheSource) { pin, tree in
      let root = try PathSafety.resolvedChild(base: tree, subpath: source.path ?? ".")
      var units: [InstructionUnit] = []
      var names = Set<String>()
      for container in ["instructions", ".agents/instructions"] {
        let directory = root.appendingPathComponent(container)
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        try Self.contained(directory, in: tree)
        for file in try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "md" {
          try Self.contained(file, in: tree)
          guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
          }
          let name = file.deletingPathExtension().lastPathComponent
          guard !name.isEmpty, !name.contains(":"), names.insert(name).inserted else {
            throw CoreError.invalidSource("duplicate or invalid instruction name: \(name)")
          }
          let section = try Instructions.validateSource(Data(contentsOf: file), id: id + ":" + name)
          units.append(
            InstructionUnit(
              record: LockedSection(
                name: name, source: id, revision: pin.revision, version: pin.version,
                path: PathSafety.relativePath(file.path, to: tree.path), hash: section.hash),
              section: section))
        }
      }
      return units.sorted { $0.record.name < $1.record.name }
    }
    discovered[id] = units
    return units
  }

  func resolve(
    references: [String], declaration: Declaration, lock: inout ResolvedState
  ) throws -> [InstructionUnit] {
    try references.map { reference in
      let parts = reference.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 2, let source = declaration.sources[parts[0]] else {
        throw CoreError.invalidState("invalid instruction reference: \(reference)")
      }
      let units = try discover(source)
      guard let unit = units.first(where: { $0.record.name == parts[1] }) else {
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
    for record in records {
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

  static func identity(_ record: LockedSection) -> String { record.source + ":" + record.name }

  static func contained(_ file: URL, in root: URL) throws {
    guard PathSafety.isContained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath())
    else {
      throw CoreError.unsafePath("instruction path escapes its root")
    }
  }
}
