import CPlatform
import Foundation

/// Publication uses atomic exchange or exclusive rename on each destination volume.
/// The private journal records intent before every publication and survives process exit.
enum BackupRestoreTransaction {
  @TaskLocal static var checkpoint: (@Sendable (String) throws -> Void)?

  private struct Leaf: Codable {
    let path: String
    let digest: BackupDigest
    let mode: UInt16
  }

  private struct Unit: Codable {
    let parent: String
    let parentIdentity: FileObjectIdentity
    let destination: String
    let leafs: [Leaf]
    let before: FileObjectIdentity?
    var staged: FileObjectIdentity?
    var after: FileObjectIdentity?

    var isTree: Bool { leafs.first?.path != "" }
    var target: URL { URL(fileURLWithPath: parent).appendingPathComponent(destination) }

    func openParent() throws -> DirectoryHandle {
      guard BackupIO.safeComponent(destination), BackupIO.originalPath(parent) || parent == "/",
        let directory = try BackupIO.directory(URL(fileURLWithPath: parent)),
        try BackupIO.identity(directory) == parentIdentity
      else { throw ClientBackupError.conflict(target.path) }
      return directory
    }
  }

  private struct Journal: Codable {
    var version = 1
    let id: UUID
    let client: BackupClient
    var phase: Phase = .staging
    var units: [Unit]

    enum Phase: String, Codable { case staging, publishing, committed }

    func container(_ index: Int) -> String {
      ".agents-backup-" + id.uuidString + "-" + String(index)
    }
  }

  private struct Group {
    let parent: URL
    let parentIdentity: FileObjectIdentity
    let destination: String
    var items: [(String, BackupRestoreItem)]
  }

  static func commit(_ plan: BackupRestorePlan) throws {
    let home = try DirectoryHandle(at: plan.home)
    let rootName = ".agents-backup-transactions"
    let changes = plan.items.filter { $0.kind != .unchanged }
    if changes.isEmpty, try home.info(rootName) == nil {
      try validate(plan)
      return
    }
    let transactionRoot: DirectoryHandle
    if try home.info(rootName) != nil {
      transactionRoot = try home.child(rootName)
    } else {
      do {
        transactionRoot = try home.createPrivateDirectory(rootName)
      } catch {
        // Another restore can establish the journal directory before this one locks it.
        transactionRoot = try home.child(rootName)
      }
    }
    try FileAccessEvidence.requirePrivate(descriptor: transactionRoot.descriptor)
    let name = plan.client.rawValue + ".json"
    try FileLock.withDescriptor(in: transactionRoot, name: plan.client.rawValue + ".lock") { _ in
      if try transactionRoot.info(name) != nil {
        try recover(in: transactionRoot, named: name, client: plan.client)
        throw ClientBackupError.conflict("previous restore recovered; preview again")
      }
      try validate(plan)
      if !changes.isEmpty {
        try publish(changes, plan: plan, journalRoot: transactionRoot, name: name)
      }
    }
  }

  private static func validate(_ plan: BackupRestorePlan) throws {
    try plan.package.validate()
    for before in plan.dependencies { try before.validate() }
    for item in plan.items where item.isDatabase {
      try BackupNativeDatabase.requireClosed(item.target)
    }
  }

  private static func group(_ items: [BackupRestoreItem]) throws -> [Group] {
    var groups: [String: Group] = [:]
    for item in items {
      var cursor = item.before.link == nil ? item.target : item.before.target
      var parentURL = cursor.deletingLastPathComponent()
      while try BackupIO.directory(parentURL) == nil {
        cursor = parentURL
        parentURL = parentURL.deletingLastPathComponent()
      }
      let parent = try DirectoryHandle(at: parentURL)
      let relative: String
      if cursor.path == item.target.path {
        relative = ""
      } else {
        relative = String(item.target.path.dropFirst(cursor.path.count + 1))
      }
      if groups[cursor.path] == nil {
        groups[cursor.path] = Group(
          parent: parent.url, parentIdentity: try BackupIO.identity(parent),
          destination: cursor.lastPathComponent, items: [])
      }
      groups[cursor.path]?.items.append((relative, item))
    }
    // Install session files before publishing indexes that refer to them.
    return groups.values.sorted {
      func priority(_ group: Group) -> Int {
        group.items.contains {
          $0.1.isDatabase
            || [
              "projects.json", "session_index.jsonl",
              "sessions-index.json", ".claude.json",
            ].contains($0.1.target.lastPathComponent)
        } ? 1 : 0
      }
      let left = priority($0)
      let right = priority($1)
      if left != right { return left < right }
      let lhs = $0.parent.appendingPathComponent($0.destination).path
      let rhs = $1.parent.appendingPathComponent($1.destination).path
      return lhs < rhs
    }
  }

  private static func publish(
    _ changes: [BackupRestoreItem], plan: BackupRestorePlan, journalRoot: DirectoryHandle,
    name: String
  ) throws {
    let groups = try group(changes)
    var units: [Unit] = []
    for group in groups {
      let old =
        group.items.first?.1.before.link?.identity
        ?? group.items.first { $0.0.isEmpty }?.1.before.before?.generation.identity
      units.append(
        Unit(
          parent: group.parent.path, parentIdentity: group.parentIdentity,
          destination: group.destination,
          leafs: group.items.map { Leaf(path: $0.0, digest: $0.1.digest, mode: $0.1.mode) },
          before: old))
    }
    var journal = Journal(id: UUID(), client: plan.client, units: units)
    try persist(journal, in: journalRoot, name: name)
    do {
      for (index, group) in groups.enumerated() {
        let unit = journal.units[index]
        let parent = try unit.openParent()
        let stage = try parent.createPrivateDirectory(journal.container(index))
        journal.units[index].staged = try BackupIO.identity(stage)
        try construct(group.items, isTree: unit.isTree, in: stage)
        guard let after = try stage.info("payload") else {
          throw ClientBackupError.conflict(unit.target.path)
        }
        journal.units[index].after = FileObjectIdentity(after)
      }
      try validate(plan)
      journal.phase = .publishing
      try persist(journal, in: journalRoot, name: name)
      try checkpoint?("publishing")
      for (index, group) in groups.enumerated() {
        let unit = journal.units[index]
        let parent = try unit.openParent()
        let stage = try openStage(in: parent, journal: journal, index: index)
        guard let stage, let after = unit.after,
          try stage.info("payload").map(FileObjectIdentity.init) == after
        else { throw ClientBackupError.conflict(unit.target.path) }
        try validateSpelling(unit.destination, in: parent)
        for (_, item) in group.items {
          // Prior publications may have populated an unrelated child in the same ancestor.
          try item.before.validate()
          if item.isDatabase { try BackupNativeDatabase.requireClosed(item.target) }
        }
        try stage.move(
          "payload", to: parent, named: unit.destination,
          mode: unit.before == nil ? .exclusive : .exchange)
        guard try parent.info(unit.destination).map(FileObjectIdentity.init) == after,
          try stage.info("payload").map(FileObjectIdentity.init) == unit.before
        else { throw ClientBackupError.conflict(unit.target.path) }
        if let before = group.items.first?.1.before.before, !unit.isTree {
          guard let exchanged = try BackupIO.generation(stage, "payload") else {
            throw ClientBackupError.conflict(unit.target.path)
          }
          let current = try BackupIO.stream(stage, "payload", expecting: exchanged) { _ in }
          guard current.digest == before.digest, current.mode == before.mode else {
            throw ClientBackupError.conflict(unit.target.path)
          }
        }
        _ = try unit.openParent()
        try checkpoint?("published")
      }
      journal.phase = .committed
      try persist(journal, in: journalRoot, name: name)
      try checkpoint?("committed")
    } catch {
      let original = error
      do {
        try checkpoint?("recovering")
        try recover(in: journalRoot, named: name, client: plan.client)
      } catch {
        throw ClientBackupError.storageFailure(
          "restore recovery; journal retained at " + journalRoot.url.path)
      }
      throw original
    }
    try recover(in: journalRoot, named: name, client: plan.client)
  }

  private static func construct(
    _ items: [(String, BackupRestoreItem)], isTree: Bool, in stage: DirectoryHandle
  ) throws {
    let root = isTree ? try stage.createPrivateDirectory("payload") : stage
    for (path, item) in items {
      let parts = isTree ? try BackupIO.components(path) : ["payload"]
      guard let name = parts.last else { throw ClientBackupError.invalidPackage }
      var directory = root
      for subdirectory in parts.dropLast() {
        if try directory.info(subdirectory) == nil {
          directory = try directory.createPrivateDirectory(subdirectory)
        } else {
          directory = try directory.child(subdirectory)
        }
      }
      let copied = try BackupIO.copy(item.payload, to: directory, named: name, mode: item.mode)
      guard copied.digest == item.digest else { throw ClientBackupError.conflict(item.target.path) }
      try directory.sync()
    }
    try stage.sync()
  }

  private static func persist(_ journal: Journal, in root: DirectoryHandle, name: String) throws {
    let bytes = try JSONEncoder().encode(journal)
    try root.replaceFile(name, through: name + ".new", with: bytes, afterWrite: {}, afterRename: {})
    try root.requirePrivateAccess(name)
  }

  private static func recover(in root: DirectoryHandle, named name: String, client: BackupClient)
    throws
  {
    try root.requirePrivateAccess(name)
    let data = try root.read(name, maximumBytes: 64 * 1024 * 1024)
    let journal = try JSONDecoder().decode(Journal.self, from: data)
    guard journal.version == 1, journal.client == client else {
      throw ClientBackupError.conflict("restore journal")
    }
    if journal.phase == .publishing {
      for index in journal.units.indices.reversed() {
        try rollBack(journal, index: index)
      }
    }
    for index in journal.units.indices {
      let unit = journal.units[index]
      let parent = try unit.openParent()
      guard let stage = try openStage(in: parent, journal: journal, index: index) else { continue }
      try parent.remove(journal.container(index), identity: BackupIO.identity(stage))
    }
    try root.removeFiles([name, name + ".new"])
  }

  private static func openStage(
    in parent: DirectoryHandle, journal: Journal, index: Int
  ) throws -> DirectoryHandle? {
    let name = journal.container(index)
    guard let state = try parent.info(name) else { return nil }
    guard state.st_mode & S_IFMT == S_IFDIR,
      journal.phase == .staging || journal.units[index].staged == FileObjectIdentity(state)
    else { throw ClientBackupError.conflict(parent.url.appendingPathComponent(name).path) }
    let stage = try parent.child(name, matching: state)
    try FileAccessEvidence.requirePrivate(descriptor: stage.descriptor)
    return stage
  }

  private static func rollBack(_ journal: Journal, index: Int) throws {
    let unit = journal.units[index]
    let parent = try unit.openParent()
    let stage = try openStage(in: parent, journal: journal, index: index)
    let current = try parent.info(unit.destination).map(FileObjectIdentity.init)
    let staged = try stage?.info("payload").map(FileObjectIdentity.init)
    if staged == unit.after || (stage == nil && current == unit.before) { return }
    guard let stage, let after = unit.after, after == current, staged == unit.before else {
      throw ClientBackupError.conflict(unit.target.path)
    }
    try verifyPublished(unit, in: parent)
    try parent.move(
      unit.destination, to: stage, named: "payload",
      mode: unit.before == nil ? .exclusive : .exchange)
  }

  private static func verifyPublished(_ unit: Unit, in parent: DirectoryHandle) throws {
    var expected = Dictionary(
      unit.leafs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    guard expected.count == unit.leafs.count else {
      throw ClientBackupError.conflict(unit.target.path)
    }
    func verifyFile(_ directory: DirectoryHandle, name: String, path: String) throws {
      guard let leaf = expected.removeValue(forKey: path),
        let generation = try BackupIO.generation(directory, name)
      else { throw ClientBackupError.conflict(unit.target.path) }
      let actual = try BackupIO.stream(directory, name, expecting: generation) { _ in }
      guard actual.digest == leaf.digest, actual.mode == leaf.mode else {
        throw ClientBackupError.conflict(unit.target.path)
      }
    }
    func walk(_ directory: DirectoryHandle, prefix: String) throws {
      for name in try directory.names() {
        let path = prefix + name
        if let info = try directory.info(name), info.st_mode & S_IFMT == S_IFDIR,
          expected.keys.contains(where: { $0.hasPrefix(path + "/") })
        {
          try walk(directory.child(name), prefix: path + "/")
        } else {
          try verifyFile(directory, name: name, path: path)
        }
      }
    }
    if unit.isTree {
      try walk(parent.child(unit.destination), prefix: "")
    } else {
      try verifyFile(parent, name: unit.destination, path: "")
    }
    guard expected.isEmpty else { throw ClientBackupError.conflict(unit.target.path) }
  }

  private static func validateSpelling(_ name: String, in parent: DirectoryHandle) throws {
    let folded = BackupIO.fold(name)
    guard try !parent.names().contains(where: { BackupIO.fold($0) == folded && $0 != name }) else {
      throw ClientBackupError.conflict(parent.url.appendingPathComponent(name).path)
    }
  }
}
