import Foundation

/// A durable undo journal covers targets, both state files and cache pruning.
/// The scope writer lock must be held through planning, commit and recovery.
package final class FileTransaction {
  private struct Entry: Codable {
    var parent: URL
    var name: String
    var existed: Bool
    var replacement: Bool
  }
  private struct Journal: Codable {
    var id: UUID
    var phase: Phase
    var entries: [Entry]
    var directories: [URL]
  }
  private enum Phase: String, Codable { case preparing, applying, committed, rolledBack }
  private struct Content {
    var url: URL?
    var link: Bool
    var data: Data?
    var parent: DirectoryHandle?
  }
  private let store: StateStore
  private let checkpoint: (String) throws -> Void
  private var entries: [Entry] = []
  private var contents: [Content] = []

  package init(store: StateStore, checkpoint: @escaping (String) throws -> Void = { _ in }) {
    self.store = store
    self.checkpoint = checkpoint
  }

  package func replace(_ destination: URL, content: URL?, link: Bool = false, data: Data? = nil)
    throws
  {
    try plan(destination, content: content, link: link, data: data, parent: nil)
  }

  func remove(_ name: String, from parent: DirectoryHandle) throws {
    try plan(
      parent.url.appendingPathComponent(name), content: nil, link: false, data: nil, parent: parent)
  }

  private func plan(
    _ destination: URL, content: URL?, link: Bool, data: Data?, parent: DirectoryHandle?
  ) throws {
    let directory = parent?.url ?? destination.deletingLastPathComponent().resolvingSymlinksInPath()
    let name = destination.lastPathComponent
    guard !entries.contains(where: { $0.parent == directory && $0.name == name }) else {
      throw CoreError.invalidState("duplicate transaction destination: \(destination.path)")
    }
    let existed =
      (try? FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(name).path)) != nil
    entries.append(
      Entry(
        parent: directory, name: name, existed: existed, replacement: content != nil || data != nil)
    )
    contents.append(Content(url: content, link: link, data: data, parent: parent))
  }

  package func commit() throws {
    let journalURL = Self.journalURL(store)
    guard !FileManager.default.fileExists(atPath: journalURL.path) else {
      throw CoreError.invalidState("transaction recovery is required")
    }
    var missing = Set<URL>()
    for entry in entries {
      var directory = entry.parent
      while !FileManager.default.fileExists(atPath: directory.path) {
        missing.insert(directory)
        directory.deleteLastPathComponent()
      }
    }
    var journal = Journal(
      id: UUID(), phase: .preparing, entries: entries,
      directories: missing.sorted { $0.pathComponents.count < $1.pathComponents.count })
    try Self.persist(journal, store: store)
    do {
      try checkpoint("journal.preparing")
      for directory in journal.directories {
        let parent = try DirectoryHandle(at: directory.deletingLastPathComponent())
        try parent.makeDirectory(directory.lastPathComponent)
        try checkpoint("directory.\(directory.path)")
      }
      for (index, entry) in entries.enumerated() {
        let parent = try contents[index].parent ?? DirectoryHandle(at: entry.parent)
        let backup = Self.temporaryName(journal, index, "old")
        let staged = Self.temporaryName(journal, index, "new")
        if entry.existed { try parent.copy(backup, from: parent, named: entry.name) }
        try checkpoint("backup.\(index)")
        let content = contents[index]
        if let data = content.data {
          try parent.write(staged, data: data)
        } else if let source = content.url {
          if content.link {
            try parent.link(staged, destination: linkDestination(source, parent: entry.parent))
          } else {
            try Self.validateCopy(source)
            let origin = source.resolvingSymlinksInPath()
            let sourceParent = try DirectoryHandle(at: origin.deletingLastPathComponent())
            try parent.copy(staged, from: sourceParent, named: origin.lastPathComponent)
          }
        }
        try checkpoint("stage.\(index)")
      }
      journal.phase = .applying
      try Self.persist(journal, store: store)
      try checkpoint("journal.applying")
      for (index, entry) in entries.enumerated() {
        let parent = try contents[index].parent ?? DirectoryHandle(at: entry.parent)
        if entry.replacement {
          try parent.rename(
            Self.temporaryName(journal, index, "new"), to: entry.name,
            swap: entry.existed)
        } else {
          // An atomic rename keeps the removed tree available until the commit point.
          if entry.existed {
            try parent.rename(entry.name, to: Self.temporaryName(journal, index, "removed"))
          }
        }
        try checkpoint("replace.\(index)")
      }
      journal.phase = .committed
      try Self.persist(journal, store: store)
      try checkpoint("journal.committed")
      try Self.cleanup(journal, store: store, checkpoint: checkpoint)
    } catch {
      _ = try Self.recover(store: store)
      throw error
    }
  }

  /// Returns true only after an abandoned journal has been recovered completely.
  package static func recover(store: StateStore) throws -> Bool {
    let url = journalURL(store)
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return false }
    let data = try Data(contentsOf: url)
    try JSONKeys.validate(data)
    var journal = try JSONDecoder().decode(Journal.self, from: data)
    guard
      journal.entries.allSatisfy({
        !$0.name.isEmpty && $0.name != "." && $0.name != ".." && !$0.name.contains("/")
          && $0.parent.isFileURL
      })
    else {
      throw CoreError.invalidState("invalid transaction journal")
    }
    if journal.phase == .applying {
      for (index, entry) in journal.entries.enumerated().reversed() {
        let parent = try DirectoryHandle(at: entry.parent)
        if entry.existed {
          let restore = temporaryName(journal, index, "restore")
          try parent.remove(restore)
          try parent.copy(restore, from: parent, named: temporaryName(journal, index, "old"))
          try parent.rename(restore, to: entry.name, swap: try parent.info(entry.name) != nil)
          try parent.remove(restore)
        } else {
          try parent.remove(entry.name)
        }
      }
      journal.phase = .rolledBack
      try persist(journal, store: store)
    }
    try cleanup(journal, store: store)
    return true
  }

  private static func cleanup(
    _ journal: Journal, store: StateStore, checkpoint: (String) throws -> Void = { _ in }
  ) throws {
    for (index, entry) in journal.entries.enumerated() {
      if FileManager.default.fileExists(atPath: entry.parent.path) {
        let parent = try DirectoryHandle(at: entry.parent)
        for suffix in ["old", "new", "removed", "restore"] {
          try parent.remove(temporaryName(journal, index, suffix))
        }
      }
      try checkpoint("cleanup.\(index)")
    }
    if journal.phase != .committed {
      for directory in journal.directories.reversed() {
        if FileManager.default.fileExists(atPath: directory.path) {
          let handle = try DirectoryHandle(at: directory)
          if try handle.names().isEmpty {
            try DirectoryHandle(at: directory.deletingLastPathComponent()).remove(
              directory.lastPathComponent)
          }
        }
      }
    }
    let directory = try DirectoryHandle(at: store.directory.resolvingSymlinksInPath())
    try directory.remove("transaction.new")
    try directory.remove(journalURL(store).lastPathComponent)
    try checkpoint("journal.removed")
  }

  private static func temporaryName(_ journal: Journal, _ index: Int, _ suffix: String) -> String {
    ".agents-\(journal.id.uuidString)-\(index).\(suffix)"
  }

  private static func journalURL(_ store: StateStore) -> URL {
    store.directory.appendingPathComponent("transaction.json")
  }

  private static func persist(_ journal: Journal, store: StateStore) throws {
    let directory = try DirectoryHandle(at: store.directory.resolvingSymlinksInPath())
    let staging = "transaction.new"
    try directory.remove(staging)
    try directory.write(staging, data: StateStore.encode(journal))
    try directory.rename(staging, to: journalURL(store).lastPathComponent)
  }

  private func linkDestination(_ source: URL, parent: URL) -> String {
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
