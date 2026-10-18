import Foundation

/// A durable undo journal covers targets, both state files and cache pruning.
/// The scope writer lock must be held through planning, commit and recovery.
package final class FileTransaction {
  private struct Entry: Codable {
    var path: String
    var existed: Bool
    var replacement: Bool
    var name: String { String(path.split(separator: "/").last!) }
  }
  private struct Journal: Codable {
    var id: UUID
    var scope: String
    var roots: [String: String]
    var phase: Phase
    var entries: [Entry]
  }
  private enum Phase: String, Codable { case preparing, applying, committed, rolledBack }
  private struct Content {
    var url: URL?
    var link: Bool
    var data: Data?
    var expectedHash: String?
    var prepare: ((URL) throws -> URL)?
  }
  private let store: StateStore
  private let checkpoint: (String) throws -> Void
  private var entries: [Entry] = []
  private var contents: [Content] = []

  package init(store: StateStore, checkpoint: @escaping (String) throws -> Void = { _ in }) {
    self.store = store
    self.checkpoint = checkpoint
  }

  package func replace(
    _ destination: URL, content: URL?, link: Bool = false, data: Data? = nil,
    expectedHash: String? = nil
  ) throws {
    if let expectedHash {
      try StateValidation.digest(expectedHash)
      guard !link, content != nil || data != nil else {
        throw CoreError.invalidState("verification requires copied content")
      }
    }
    let path = try TransactionPaths(store: store).path(for: destination)
    guard !entries.contains(where: { $0.path == path }) else {
      throw CoreError.invalidState("duplicate transaction destination")
    }
    entries.append(Entry(path: path, existed: false, replacement: content != nil || data != nil))
    contents.append(
      Content(url: content, link: link, data: data, expectedHash: expectedHash, prepare: nil))
  }

  /// Builds source content inside journal-owned scratch storage before verified copying.
  func prepare(_ destination: URL, content: @escaping (URL) throws -> URL) throws {
    try replace(destination, content: nil)
    entries[entries.count - 1].replacement = true
    contents[contents.count - 1].prepare = content
  }

  func remove(_ name: String, from parent: DirectoryHandle) throws {
    try replace(parent.url.appendingPathComponent(name), content: nil)
  }

  package func commit() throws {
    guard let directory = try store.openDirectoryIfPresent(),
      try directory.info("transaction.json") == nil
    else {
      throw CoreError.invalidState("transaction recovery is required")
    }
    let paths = TransactionPaths(store: store)
    var roots: [String: DirectoryHandle] = [:]
    for entry in entries {
      let key = try paths.components(entry.path).root
      if roots[key] == nil {
        roots[key] = try paths.root(key, create: true, checkpoint: checkpoint)
      }
    }
    let parents = try entries.map {
      try paths.parent(for: $0.path, roots: roots, create: true, checkpoint: checkpoint)
    }
    try Self.validateDestinations(entries, parents: parents)
    for index in entries.indices {
      entries[index].existed = try parents[index].info(entries[index].name) != nil
    }
    var journal = Journal(
      id: UUID(), scope: try directory.identity,
      roots: try roots.mapValues { try $0.identity }, phase: .preparing, entries: entries)
    do {
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("journal.preparing")
      for (index, entry) in entries.enumerated() {
        let parent = parents[index]
        let backup = Self.temporaryName(journal, index, "old")
        let staged = Self.temporaryName(journal, index, "new")
        if entry.existed { try parent.copy(backup, from: parent, named: entry.name) }
        try checkpoint("backup.\(index)")
        var content = contents[index]
        if let prepare = content.prepare {
          let work = Self.temporaryName(journal, index, "work")
          try parent.makeDirectory(work)
          try checkpoint("prepare.\(index).directory")
          let root = parent.url.appendingPathComponent(work)
          let source = try prepare(root)
          guard PathSafety.isContained(source.resolvingSymlinksInPath(), in: root) else {
            throw CoreError.unsafePath("prepared content escapes transaction staging")
          }
          content.url = source
          content.expectedHash = "sha256:" + (try FileHash.folderHash(source))
          try checkpoint("prepare.\(index).ready")
        }
        if let data = content.data {
          try parent.write(staged, data: data)
          try checkpoint("stage.\(index).written")
        } else if let source = content.url {
          if content.link {
            try parent.link(
              staged, destination: Self.linkDestination(source, parent: parent.url, store: store))
          } else {
            try Self.validateCopy(source)
            let origin = source.resolvingSymlinksInPath()
            try parent.copy(
              staged, from: DirectoryHandle(at: origin.deletingLastPathComponent()),
              named: origin.lastPathComponent,
              checkpoint: { try checkpoint("stage.\(index).copy.\($0)") })
          }
        }
        if let expectedHash = content.expectedHash {
          let hash =
            try content.data == nil
            ? FileHash.folderHash(parent.child(staged))
            : FileHash.sha256Hex(data: parent.read(staged))
          guard "sha256:" + hash == expectedHash else {
            throw CoreError.invalidState("staged content digest mismatch")
          }
          try checkpoint("stage.\(index).verified")
        }
        try checkpoint("stage.\(index)")
      }
      journal.phase = .applying
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("journal.applying")
      for (index, entry) in entries.enumerated() {
        let parent = parents[index]
        if entry.replacement {
          try parent.rename(
            Self.temporaryName(journal, index, "new"), to: entry.name, swap: entry.existed
          ) {
            try checkpoint("replace.\(index).renamed")
          }
        } else if entry.existed {
          try parent.rename(entry.name, to: Self.temporaryName(journal, index, "removed")) {
            try checkpoint("replace.\(index).renamed")
          }
        }
        try checkpoint("replace.\(index)")
      }
      journal.phase = .committed
      try Self.persist(journal, directory: directory, checkpoint: checkpoint)
      try checkpoint("journal.committed")
      try Self.cleanup(journal, directory: directory, parents: parents, checkpoint: checkpoint)
    } catch {
      _ = try Self.recover(store: store)
      throw error
    }
  }

  /// Recovers only after validating and pinning every parent in the journal.
  package static func recover(store: StateStore, checkpoint: (String) throws -> Void = { _ in })
    throws -> Bool
  {
    guard let directory = try store.openDirectoryIfPresent() else { return false }
    guard try directory.info("transaction.json") != nil else {
      guard try directory.info("transaction.new") != nil else { return false }
      _ = try directory.read("transaction.new")
      try directory.remove("transaction.new")
      return true
    }
    var journal = try StateStore.decode(directory.read("transaction.json"), as: Journal.self)
    guard journal.scope == (try directory.identity) else {
      throw CoreError.invalidState("transaction journal belongs to another scope location")
    }
    let paths = TransactionPaths(store: store)
    var roots: [String: DirectoryHandle] = [:]
    let keys = try Set(journal.entries.map { try paths.components($0.path).root })
    guard keys == Set(journal.roots.keys) else {
      throw CoreError.invalidState("invalid transaction roots")
    }
    for key in keys {
      let root = try paths.root(key)
      guard try root.identity == journal.roots[key] else {
        throw CoreError.invalidState("transaction root identity changed")
      }
      roots[key] = root
    }
    let parents = try journal.entries.map { try paths.parent(for: $0.path, roots: roots) }
    try validateDestinations(journal.entries, parents: parents)
    for (index, entry) in journal.entries.enumerated() {
      if journal.phase == .applying, entry.existed,
        try parents[index].info(temporaryName(journal, index, "old")) == nil
      {
        throw CoreError.invalidState("missing transaction backup")
      }
    }
    // Validate the journal's scratch file before any recovery mutation as well.
    if try directory.info("transaction.new") != nil { _ = try directory.read("transaction.new") }
    if journal.phase == .applying {
      for (index, entry) in journal.entries.enumerated().reversed() {
        let parent = parents[index]
        if entry.existed {
          let restore = temporaryName(journal, index, "restore")
          try parent.remove(restore)
          try parent.copy(restore, from: parent, named: temporaryName(journal, index, "old"))
          try parent.rename(restore, to: entry.name, swap: try parent.info(entry.name) != nil) {
            try checkpoint("restore.\(index).renamed")
          }
          try parent.remove(restore)
        } else {
          try parent.remove(entry.name)
        }
        try checkpoint("restore.\(index)")
      }
    }
    if journal.phase == .applying || journal.phase == .preparing {
      journal.phase = .rolledBack
      try persist(journal, directory: directory, checkpoint: checkpoint)
    }
    try cleanup(journal, directory: directory, parents: parents, checkpoint: checkpoint)
    return true
  }

  private static func validateDestinations(_ entries: [Entry], parents: [DirectoryHandle]) throws {
    var paths: [URL] = []
    for (index, entry) in entries.enumerated() {
      let path = parents[index].url.appendingPathComponent(entry.name)
      guard
        !paths.contains(where: {
          PathSafety.isContained(path, in: $0) || PathSafety.isContained($0, in: path)
        })
      else {
        throw CoreError.invalidState("overlapping transaction destinations")
      }
      paths.append(path)
    }
  }

  private static func cleanup(
    _ journal: Journal, directory: DirectoryHandle, parents: [DirectoryHandle],
    checkpoint: (String) throws -> Void
  ) throws {
    // A visible terminal phase may have been renamed but not synced by a killed
    // writer. Make that observed generation durable before deleting any backup.
    try directory.syncFile("transaction.json")
    try checkpoint("journal.terminalSynced")
    for (index, _) in journal.entries.enumerated() {
      for suffix in ["old", "new", "removed", "restore", "work"] {
        try parents[index].remove(temporaryName(journal, index, suffix))
      }
      try checkpoint("cleanup.\(index)")
    }
    try directory.remove("transaction.new")
    try directory.remove("transaction.json")
    try checkpoint("journal.removed")
  }

  private static func temporaryName(_ journal: Journal, _ index: Int, _ suffix: String) -> String {
    ".agents-\(journal.id.uuidString)-\(index).\(suffix)"
  }

  private static func persist(
    _ journal: Journal, directory: DirectoryHandle,
    checkpoint: (String) throws -> Void
  ) throws {
    try directory.remove("transaction.new")
    try directory.write("transaction.new", data: StateStore.encode(journal))
    try directory.rename("transaction.new", to: "transaction.json") {
      try checkpoint("journal.\(journal.phase.rawValue).renamed")
    }
  }

  package static func linkDestination(_ source: URL, parent: URL, store: StateStore) -> String {
    let root = (store.scope == .project ? store.environment.projectDirectory : store.directory)
      .resolvingSymlinksInPath()
    let source = source.resolvingSymlinksInPath()
    if PathSafety.isContained(source, in: root) {
      let from = parent.pathComponents
      let to = source.pathComponents
      let common = zip(from, to).prefix(while: { $0 == $1 }).count
      return (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(
        separator: "/")
    }
    return source.path
  }

  private static func validateCopy(_ source: URL) throws {
    let root = source.resolvingSymlinksInPath()
    guard
      let entries = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else { return }
    for case let entry as URL in entries {
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        entries.skipDescendants()
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        guard !destination.hasPrefix("/"),
          PathSafety.isContained(entry.resolvingSymlinksInPath(), in: root)
        else {
          throw CoreError.unsafePath("copy symlink escapes installed subtree: \(entry.path)")
        }
      }
    }
  }
}
