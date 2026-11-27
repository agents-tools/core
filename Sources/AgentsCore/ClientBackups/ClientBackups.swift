import CPlatform
import Foundation

public enum BackupClient: String, CaseIterable, Hashable, Codable, Sendable {
  case codex
  case claudeCode
  case geminiCLI

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .geminiCLI: "Gemini CLI"
    }
  }
}

public struct ClientBackupInfo: Sendable {
  public let client: BackupClient
  public let projects: [String]
}

public enum ClientBackupChangeKind: String, Hashable, Sendable {
  case add
  case replace
  case unchanged
}

public struct ClientBackupFileChange: Hashable, Sendable {
  public let path: String
  public let kind: ClientBackupChangeKind
}

public struct ClientBackupPreview: Sendable {
  public let client: BackupClient
  public let files: [ClientBackupFileChange]
  fileprivate let plan: BackupRestorePlan

  fileprivate init(client: BackupClient, plan: BackupRestorePlan) {
    self.client = client
    self.plan = plan
    var seen = Set<String>()
    files = plan.items.compactMap {
      let path = $0.before.link == nil ? $0.target.path : $0.before.target.path
      return seen.insert(path).inserted ? ClientBackupFileChange(path: path, kind: $0.kind) : nil
    }
  }
}

/// Synchronous local file operations. Consumers can perform these operations on a worker thread.
public enum ClientBackups {
  public static func create(
    client: BackupClient, projects: [URL], to directory: URL,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> URL {
    let output = try BackupIO.address(directory)
    var selected: [String: URL] = [:]
    for project in projects {
      let root = try BackupIO.address(project)
      guard BackupIO.originalPath(root.path), try BackupIO.directory(root) != nil else {
        throw ClientBackupError.invalidLocation(root.path)
      }
      selected[root.path] = root
    }
    try requireDistinct(Array(selected.values))
    let roots = try BackupRoots(client, environment: environment, projects: selected)
    let parent = try DirectoryHandle(at: output)
    let scratch = try BackupScratch(in: parent.url)
    let staging = try scratch.open()
    let partial = "backup.sqlite"
    let header = BackupHeader(
      client: client, sourceHome: roots.home.path, sourceClient: roots.client.path,
      sourceDatabase: roots.database.path, projects: selected.keys.sorted())
    do {
      let archive = try BackupArchive(writing: partial, in: staging, header: header)
      try BackupInventory(client: client, roots: roots, output: output).capture(
        into: archive, in: staging)
      try archive.finish()
    }
    let verified = try BackupArchive(reading: scratch.path(partial))
    for entry in verified.manifest.entries { try verified.read(entry) }
    try staging.syncFile(partial)
    let publishedParent = try BackupIO.directory(output)
    guard let publishedParent, try BackupIO.identity(publishedParent) == BackupIO.identity(parent)
    else { throw ClientBackupError.conflict(output.path) }
    let name = client.rawValue + "-" + UUID().uuidString.lowercased() + ".agentsbackup"
    try staging.move(partial, to: parent, named: name, mode: .exclusive)
    return parent.url.appendingPathComponent(name)
  }

  public static func inspect(_ package: URL) throws -> ClientBackupInfo {
    let archive = try BackupArchive(reading: package)
    let header = archive.manifest.header
    let evidence = try BackupPackageReference(url: package, archive: archive)
    for entry in archive.manifest.entries { try archive.read(entry) }
    try evidence.validate()
    return ClientBackupInfo(client: header.client, projects: header.projects)
  }

  public static func preview(
    _ package: URL, projects: [String: URL], environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ClientBackupPreview {
    let archive = try BackupArchive(reading: package)
    let header = archive.manifest.header
    guard Set(projects.keys) == Set(header.projects) else {
      throw ClientBackupError.conflict("project mappings")
    }
    let selected = try projects.mapValues(BackupIO.address)
    try requireDistinct(Array(selected.values))
    for root in selected.values {
      guard BackupIO.originalPath(root.path), try BackupIO.directory(root) != nil else {
        throw ClientBackupError.invalidLocation(root.path)
      }
    }
    let roots = try BackupRoots(header.client, environment: environment, projects: selected)
    let plan = try BackupRestorePlanner(package: package, archive: archive, roots: roots).prepare()
    return ClientBackupPreview(client: header.client, plan: plan)
  }

  public static func restore(_ preview: ClientBackupPreview) throws {
    try BackupRestoreTransaction.commit(preview.plan)
  }

  private static func requireDistinct(_ roots: [URL]) throws {
    let unique = Set(roots.map { BackupIO.fold($0.path) })
    guard unique.count == roots.count else { throw ClientBackupError.conflict("project roots") }
    let ids = try roots.compactMap { root in
      try BackupIO.directory(root).map(BackupIO.identity)
    }
    guard Set(ids).count == ids.count else { throw ClientBackupError.conflict("project roots") }
  }
}

struct BackupPathFence: Equatable, Sendable {
  let target: URL
  let ancestors: [FileObjectIdentity]
  let before: BackupFingerprint?
  let link: BackupGeneration?

  static func captureLink(_ target: URL) throws -> Self {
    let parentURL = target.deletingLastPathComponent()
    guard let parent = try BackupIO.directory(parentURL),
      let link = try BackupIO.generation(parent, target.lastPathComponent),
      link.identity.kind == S_IFLNK
    else { throw ClientBackupError.conflict(target.path) }
    return BackupPathFence(
      target: target, ancestors: try BackupIO.ancestry(parentURL), before: nil, link: link)
  }

  static func capture(_ target: URL) throws -> Self {
    let parent = target.deletingLastPathComponent()
    let ancestors = try BackupIO.ancestry(parent)
    let before = try BackupIO.fingerprint(target)
    if let before, before.generation.value.st_nlink != 1 {
      throw ClientBackupError.conflict(target.path)
    }
    return BackupPathFence(target: target, ancestors: ancestors, before: before, link: nil)
  }

  func validate() throws {
    guard try (link == nil ? Self.capture(target) : Self.captureLink(target)) == self else {
      throw ClientBackupError.conflict(target.path)
    }
  }
}

struct BackupRestoreItem: Sendable {
  let target: URL
  let payload: URL
  let mode: UInt16
  let digest: BackupDigest
  let before: BackupPathFence
  let isDatabase: Bool

  var kind: ClientBackupChangeKind {
    if before.link != nil { return .replace }
    guard let old = before.before else { return .add }
    return old.digest == digest && old.mode == mode ? .unchanged : .replace
  }
}

struct BackupPackageReference: Sendable {
  let target: URL
  private let generation: BackupGeneration
  private let ancestry: [FileObjectIdentity]

  init(url: URL, archive: BackupArchive) throws {
    target = try BackupIO.address(url)
    guard let captured = archive.readGeneration else { throw ClientBackupError.invalidPackage }
    generation = captured
    ancestry = try BackupIO.ancestry(target.deletingLastPathComponent())
    try validate()
  }

  func validate() throws {
    let parentURL = target.deletingLastPathComponent()
    guard let parent = try BackupIO.directory(parentURL),
      try BackupIO.ancestry(parentURL) == ancestry,
      try BackupIO.generation(parent, target.lastPathComponent) == generation
    else { throw ClientBackupError.conflict(target.path) }
  }
}

struct BackupRestorePlan: Sendable {
  let scratch: BackupScratch
  let package: BackupPackageReference
  let home: URL
  let client: BackupClient
  let items: [BackupRestoreItem]
  let dependencies: [BackupPathFence]
}

final class BackupRestorePlanner {
  private let archive: BackupArchive
  private let package: BackupPackageReference
  private let roots: BackupRoots
  private let scratch: BackupScratch
  private let staging: DirectoryHandle
  private let mapping: BackupRelocation
  private var dependencies: [URL: BackupPathFence] = [:]
  private var targets: [String: String] = [:]
  private var occupiedNames: [URL: [String: String]] = [:]
  private var rolloutOffsets: [String: BackupRolloutOffsets] = [:]
  private var geminiOriginals: [String: String] = [:]
  private var geminiKeys: [String: String] = [:]
  private var geminiRegistry: (target: URL, payload: URL, mode: UInt16)?
  private var geminiCheckpointCommits: [Int64: String] = [:]
  private var geminiShadowFiles: [URL: URL] = [:]
  private var claudeOriginals: [String: String] = [:]
  private var claudeKeys: [String: String] = [:]
  private var claudeInstructions = Set<BackupClaudeImports.File>()

  init(package: URL, archive: BackupArchive, roots: BackupRoots) throws {
    self.archive = archive
    self.package = try BackupPackageReference(url: package, archive: archive)
    self.roots = roots
    scratch = try BackupScratch()
    staging = try scratch.open()
    mapping = BackupRelocation(header: archive.manifest.header, roots: roots)
    if let config = roots.codexConfig { dependencies[config.target] = config }
  }

  func prepare() throws -> BackupRestorePlan {
    let entries = archive.manifest.entries
    let client = archive.manifest.header.client
    var payloads: [Int64: URL] = [:]
    for entry in entries {
      let name = "entry-" + String(entry.number)
      try archive.extract(entry, to: staging, named: name)
      payloads[entry.number] = scratch.path(name)
    }
    if client == .geminiCLI {
      try prepareGemini(payloads)
      try prepareGeminiCheckpoints(payloads)
    }
    if client == .claudeCode {
      try prepareClaude(payloads)
      try prepareClaudeImports(payloads)
    }
    var items: [BackupRestoreItem] = []
    let manifestPaths = Dictionary(
      uniqueKeysWithValues: entries.map {
        ($0.root + "\0" + $0.path, $0.number)
      })
    let restoreOrder =
      entries.filter { $0.root != "database" } + entries.filter { $0.root == "database" }
    for entry in restoreOrder {
      guard let original = payloads[entry.number] else { throw ClientBackupError.invalidPackage }
      if client == .geminiCLI, entry.root == "runtime", entry.path == "projects.json" { continue }
      let target = try destination(entry, client: client)
      let link = try installedSkillLink(for: entry, client: client, manifestPaths: manifestPaths)
      try register(target, replacingLink: link?.target)
      let database = entry.root == "database"
      if database { try BackupNativeDatabase.requireClosed(target) }
      let before = try link ?? observe(target)
      let payload = try transform(
        entry, client: client, incoming: original, target: target, before: before)
      guard let desired = try BackupIO.fingerprint(payload) else {
        throw ClientBackupError.storageFailure("staging restore preview")
      }
      items.append(
        BackupRestoreItem(
          target: target, payload: payload, mode: entry.mode, digest: desired.digest,
          before: before, isDatabase: database))
    }
    if let registry = geminiRegistry {
      try register(registry.target)
      guard let desired = try BackupIO.fingerprint(registry.payload) else {
        throw ClientBackupError.storageFailure("staging Gemini project registry")
      }
      items.append(
        BackupRestoreItem(
          target: registry.target, payload: registry.payload, mode: registry.mode,
          digest: desired.digest, before: try observe(registry.target), isDatabase: false))
    }
    for (target, payload) in geminiShadowFiles {
      try register(target)
      guard let desired = try BackupIO.fingerprint(payload) else {
        throw ClientBackupError.storageFailure("staging Gemini checkpoint dependency")
      }
      let before = try observe(target)
      if let previous = before.before, previous.digest != desired.digest {
        throw ClientBackupError.conflict(target.path)
      }
      items.append(
        BackupRestoreItem(
          target: target, payload: payload, mode: 0o600, digest: desired.digest, before: before,
          isDatabase: false))
    }
    try package.validate()
    for item in dependencies.values { try item.validate() }
    return BackupRestorePlan(
      scratch: scratch, package: package, home: roots.home, client: client,
      items: items.sorted { $0.target.path < $1.target.path },
      dependencies: Array(dependencies.values))
  }

  private var originalClaudeLocations: BackupClaudeImports.Locations {
    let header = archive.manifest.header
    return BackupClaudeImports.Locations(
      home: URL(fileURLWithPath: header.sourceHome),
      client: URL(fileURLWithPath: header.sourceClient),
      projects: Dictionary(
        uniqueKeysWithValues: header.projects.map { ($0, URL(fileURLWithPath: $0)) }))
  }

  private func prepareClaudeImports(_ payloads: [Int64: URL]) throws {
    var available: [BackupClaudeImports.File: URL] = [:]
    var imported = Set<BackupClaudeImports.File>()
    for entry in archive.manifest.entries {
      let file = BackupClaudeImports.File(root: entry.root, path: entry.path)
      guard let payload = payloads[entry.number],
        available.updateValue(payload, forKey: file) == nil
      else { throw ClientBackupError.invalidPackage }
      if entry.root.hasPrefix(BackupClaudeImports.archivePrefix) { imported.insert(file) }
    }
    let entries = available.keys.filter {
      BackupClaudeImports.isEntry($0, projects: roots.projects)
    }
    // Earlier packages may contain native instruction files without the added dependency records.
    // Validate the graph whenever the package claims imported resources.
    if imported.isEmpty {
      claudeInstructions = Set(entries)
      return
    }
    claudeInstructions = try BackupClaudeImports.closure(
      entries: entries, locations: originalClaudeLocations
    ) { key in
      try available[key].map { try Data(contentsOf: $0) }
    }
    guard imported.isSubset(of: claudeInstructions) else { throw ClientBackupError.invalidPackage }
  }

  private func installedSkillLink(
    for entry: BackupEntry, client: BackupClient, manifestPaths: [String: Int64]
  ) throws -> BackupPathFence? {
    guard
      let unit = BackupScope.skillUnit(
        client, root: entry.root, project: roots.projects[entry.root] != nil, path: entry.path),
      entry.path.hasPrefix(unit + "/"),
      let manifest = manifestPaths[entry.root + "\0" + unit + "/SKILL.md"]
    else { return nil }
    let target = try roots.url(entry.root).appendingPathComponent(unit)
    if let existing = dependencies[target] { return existing.link == nil ? nil : existing }
    guard let parent = try BackupIO.directory(target.deletingLastPathComponent()),
      let info = try parent.info(target.lastPathComponent), info.st_mode & S_IFMT == S_IFLNK
    else { return nil }
    let bytes = try staging.read("entry-" + String(manifest), maximumBytes: 1024 * 1024)
    guard BackupScope.isSkillManifest(bytes) else { throw ClientBackupError.conflict(target.path) }
    let fence = try BackupPathFence.captureLink(target)
    dependencies[target] = fence
    return fence
  }

  private func observe(_ url: URL) throws -> BackupPathFence {
    if let before = dependencies[url] { return before }
    let before = try BackupPathFence.capture(url)
    dependencies[url] = before
    return before
  }

  private func existing(_ url: URL, before: BackupPathFence) throws -> URL? {
    guard let prior = before.before else { return nil }
    let name = "existing-" + UUID().uuidString
    guard try BackupIO.copy(url, to: staging, named: name) == prior else {
      throw ClientBackupError.conflict(url.path)
    }
    return scratch.path(name)
  }

  private func write(_ bytes: Data) throws -> URL {
    let name = "derived-" + UUID().uuidString
    try BackupIO.write(name, in: staging) { try $0.write(contentsOf: bytes) }
    return scratch.path(name)
  }

  private func register(_ url: URL, replacingLink: URL? = nil) throws {
    guard
      BackupIO.fold(BackupSQL.absoluteFileURL(url).path)
        != BackupIO.fold(BackupSQL.absoluteFileURL(package.target).path)
    else {
      throw ClientBackupError.conflict(url.path)
    }
    let parts = url.pathComponents.dropFirst()
    var parent = URL(fileURLWithPath: "/", isDirectory: true)
    for name in parts {
      let next = parent.appendingPathComponent(name)
      let key = BackupIO.fold(next.path)
      if let previous = targets[key], previous != next.path {
        throw ClientBackupError.conflict(url.path)
      }
      targets[key] = next.path
      let belowLink =
        replacingLink.map { parent.path == $0.path || parent.path.hasPrefix($0.path + "/") }
        ?? false
      if !belowLink && occupiedNames[parent] == nil {
        var index: [String: String] = [:]
        if let directory = try BackupIO.directory(parent) {
          for existing in try directory.names() {
            let folded = BackupIO.fold(existing)
            if let prior = index[folded], prior != existing {
              index[folded] = ""
            } else {
              index[folded] = existing
            }
          }
        }
        occupiedNames[parent] = index
      }
      if let existing = occupiedNames[parent]?[BackupIO.fold(name)], existing != name {
        throw ClientBackupError.conflict(url.path)
      }
      parent = next
    }
    let physical = BackupIO.fold(BackupSQL.absoluteFileURL(url).path)
    guard targets.updateValue(url.path, forKey: "file:" + physical) == nil
    else { throw ClientBackupError.conflict(url.path) }
  }

  private func destination(_ entry: BackupEntry, client: BackupClient) throws -> URL {
    var components = try BackupIO.components(entry.path)
    if client == .claudeCode, entry.root == "client", components.first == "projects",
      components.count >= 3, let target = claudeKeys[components[1]]
    {
      components[1] = target
    }
    if client == .geminiCLI, entry.root == "runtime", components.count >= 3,
      ["tmp", "history"].contains(components[0]), let target = geminiKeys[components[1]]
    {
      components[1] = target
    }
    return try roots.url(entry.root).appendingPathComponent(components.joined(separator: "/"))
  }

  private func transform(
    _ entry: BackupEntry, client: BackupClient, incoming: URL, target: URL, before: BackupPathFence
  ) throws -> URL {
    if client == .codex, entry.root == "client", entry.path == "config.toml",
      let config = try BackupCodexConfig.relocated(
        incoming, sourceHome: archive.manifest.header.sourceHome,
        sourceDatabase: archive.manifest.header.sourceDatabase, destination: roots.database,
        preserveDestinationSetting: roots.configuredCodexDatabase)
    {
      return try write(config)
    }
    if entry.root == "database" {
      let old = try existing(target, before: before)
      return try BackupNativeDatabase.adapt(
        incoming, destination: old, name: entry.path, using: mapping, rolloutOffsets: rolloutOffsets
      )
    }
    if client == .claudeCode {
      let file = BackupClaudeImports.File(root: entry.root, path: entry.path)
      if claudeInstructions.contains(file),
        let relocated = try BackupClaudeImports.relocated(
          Data(contentsOf: incoming), file: file, source: originalClaudeLocations,
          destination: .init(home: roots.home, client: roots.client, projects: roots.projects))
      {
        return try write(relocated)
      }
    }
    if client == .claudeCode, entry.root == "profile" {
      return try claudeProfile(incoming, old: existing(target, before: before))
    }
    if client == .claudeCode, entry.root == "client", entry.path.hasPrefix("projects/"),
      entry.path.hasSuffix("/sessions-index.json")
    {
      return try claudeIndex(incoming, old: existing(target, before: before))
    }
    if client == .geminiCLI, entry.root == "runtime" {
      if entry.path.hasSuffix("/.project_root") { return try geminiMarker(incoming) }
      let parts = try BackupIO.components(entry.path)
      if BackupGeminiCheckpoints.isRecord(parts) {
        return try geminiCheckpoint(incoming, commit: geminiCheckpointCommits[entry.number])
      }
      if parts.count >= 4, parts[0] == "tmp", parts[2] == "chats",
        let original = geminiOriginals[parts[1]], mapping.projectPath(original) != original
      {
        return try geminiChat(incoming, path: entry.path, original: original)
      }
      if entry.path.hasSuffix("/logs.json"), let old = try existing(target, before: before),
        before.before?.digest != entry.digest
      {
        return try geminiLogs(incoming, old: old)
      }
    }
    let index = client == .codex && entry.root == "client" && entry.path == "session_index.jsonl"
    let history = entry.root == "client" && entry.path == "history.jsonl"
    let changedProject = roots.projects.contains { $0.key != $0.value.path }
    let changedHome = archive.manifest.header.sourceClient != roots.client.path
    if index || history, let old = try existing(target, before: before),
      before.before?.digest != entry.digest || changedProject || changedHome
    {
      let name = "merged-" + UUID().uuidString
      try BackupIO.write(name, in: staging) {
        try BackupJSONL.merge(
          incoming: incoming, existing: old, to: $0, index: index, mapping: mapping)
      }
      return scratch.path(name)
    }
    let isRollout =
      client == .codex && entry.root == "client"
      && (entry.path.hasPrefix("sessions/") || entry.path.hasPrefix("archived_sessions/"))
    if isRollout, entry.path.hasSuffix(".jsonl.zst"), changedProject {
      guard let zstd = BackupZstd.executable(path: roots.zstdPath) else {
        throw ClientBackupError.unsupportedLayout("zstd is required to relocate Codex rollouts")
      }
      let plain = "uncompressed-" + UUID().uuidString
      try BackupIO.write(plain, in: staging) {
        try BackupZstd.transcode(incoming, into: $0, using: zstd, decode: true)
      }
      let relocated = try relocateLines(scratch.path(plain), isRollout: true)
      if relocated.path == scratch.path(plain).path {
        try staging.remove(plain)
        return incoming
      }
      let encoded = "compressed-" + UUID().uuidString
      try BackupIO.write(encoded, in: staging) {
        try BackupZstd.transcode(relocated, into: $0, using: zstd, decode: false)
      }
      try staging.remove(plain)
      try staging.remove(relocated.lastPathComponent)
      return scratch.path(encoded)
    }
    if entry.root == "client", entry.path.hasSuffix(".jsonl"), changedProject || changedHome {
      return try relocateLines(incoming, isRollout: isRollout)
    }
    return incoming
  }

  private func relocateLines(_ incoming: URL, isRollout: Bool) throws -> URL {
    let name = "relocated-" + UUID().uuidString
    var offsets = BackupRolloutOffsets()
    try BackupIO.write(name, in: staging) {
      offsets = try BackupJSONL.remap(incoming, to: $0) {
        BackupNativeJSON.pathFields($0, using: mapping)
      }
    }
    if offsets.edits.isEmpty {
      try staging.remove(name)
      return incoming
    }
    if isRollout,
      archive.manifest.entries.contains(where: {
        $0.root == "database" && $0.path.hasPrefix("thread_history_")
      })
    {
      guard let id = offsets.thread, rolloutOffsets.updateValue(offsets, forKey: id) == nil else {
        throw ClientBackupError.unsupportedLayout("Codex rollout identity")
      }
    }
    return scratch.path(name)
  }

}

extension BackupRestorePlanner {
  private func prepareGemini(_ payloads: [Int64: URL]) throws {
    let entries = archive.manifest.entries.filter { $0.root == "runtime" }
    guard !entries.isEmpty else { return }
    let source = entries.first { $0.path == "projects.json" }
    let sourceRegistry = try source.flatMap { payloads[$0.number] }.map(BackupNativeJSON.object)
    let target = roots.runtime.appendingPathComponent("projects.json")
    let before = try observe(target)
    let old = try existing(target, before: before)
    let currentRegistry = try old.map(BackupNativeJSON.object)
    let archived = try geminiProjects(sourceRegistry)
    var merged = try geminiProjects(currentRegistry)
    var originals: [String: String] = [:]
    for (path, key) in archived {
      guard originals.updateValue(path, forKey: key) == nil else {
        throw ClientBackupError.conflict("Gemini project registry")
      }
    }
    for entry in entries where entry.path.hasSuffix("/.project_root") {
      let parts = try BackupIO.components(entry.path)
      guard parts.count == 3, ["tmp", "history"].contains(parts[0]),
        let payload = payloads[entry.number]
      else { throw ClientBackupError.invalidPackage }
      let path = try markerPath(payload)
      if let prior = originals[parts[1]], prior != path {
        throw ClientBackupError.conflict(entry.path)
      }
      originals[parts[1]] = path
    }
    let storageKeys = Set(
      try entries.compactMap { entry -> String? in
        let parts = try BackupIO.components(entry.path)
        return parts.count >= 3 && ["tmp", "history"].contains(parts[0]) ? parts[1] : nil
      })
    for path in roots.projects.keys {
      let legacy = FileHash.sha256Hex(data: Data(path.utf8))
      if storageKeys.contains(legacy) {
        if let original = originals[legacy], original != path {
          throw ClientBackupError.conflict("Gemini legacy project key")
        }
        originals[legacy] = path
      }
    }
    for (key, original) in originals.sorted(by: { $0.key < $1.key }) {
      let local = mapping.projectPath(original)
      let selected = merged[local] ?? key
      guard Self.geminiKey(selected),
        !merged.contains(where: { $0.key != local && $0.value == selected })
      else { throw ClientBackupError.conflict("Gemini project key " + selected) }
      if let marker = try existingGeminiMarker(selected), marker != local {
        throw ClientBackupError.conflict("Gemini project key " + selected)
      }
      merged[local] = selected
      geminiKeys[key] = selected
    }
    for unknown in storageKeys.subtracting(originals.keys) {
      if try merged.values.contains(unknown) || existingGeminiMarker(unknown) != nil {
        throw ClientBackupError.conflict("Gemini project key " + unknown)
      }
    }
    geminiOriginals = originals
    if let source, let original = payloads[source.number], merged == archived {
      geminiRegistry = (target, original, source.mode)
    } else if merged != (try geminiProjects(currentRegistry)) || source != nil {
      var combined = (currentRegistry ?? [:]).merging(sourceRegistry ?? [:]) { _, new in new }
      combined["projects"] = merged
      geminiRegistry = (target, try write(BackupNativeJSON.encode(combined)), source?.mode ?? 0o600)
    }
  }

  private static func geminiKey(_ key: String) -> Bool {
    !key.isEmpty
      && key.utf8.allSatisfy { $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }
  }

  private func geminiProjects(_ registry: [String: Any]?) throws -> [String: String] {
    guard let registry else { return [:] }
    guard let projects = registry["projects"] as? [String: String],
      projects.keys.allSatisfy(BackupIO.originalPath), projects.values.allSatisfy(Self.geminiKey),
      Set(projects.values).count == projects.count
    else { throw ClientBackupError.unsupportedLayout("Gemini projects.json") }
    return projects
  }

  private func existingGeminiMarker(_ key: String) throws -> String? {
    var result: String?
    for area in ["tmp", "history"] {
      let marker = roots.runtime.appendingPathComponent(area + "/" + key + "/.project_root")
      if let old = try existing(marker, before: observe(marker)) {
        let path = try markerPath(old)
        if let result, result != path { throw ClientBackupError.conflict(marker.path) }
        result = path
      }
    }
    return result
  }

  private func markerPath(_ url: URL) throws -> String {
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent())
    let bytes = try parent.read(url.lastPathComponent, maximumBytes: 64 * 1024)
    guard let value = String(data: bytes, encoding: .utf8) else {
      throw ClientBackupError.unsupportedLayout("Gemini project marker")
    }
    let path = value.trimmingCharacters(in: .newlines)
    guard BackupIO.originalPath(path) else {
      throw ClientBackupError.unsupportedLayout("Gemini project marker")
    }
    return path
  }

  private func geminiMarker(_ incoming: URL) throws -> URL {
    let path = try markerPath(incoming)
    let local = mapping.projectPath(path)
    if path == local { return incoming }
    return try write(Data(local.utf8))
  }

  private func prepareGeminiCheckpoints(_ payloads: [Int64: URL]) throws {
    var records: [String: [(Int64, String)]] = [:]
    var packs: [String: [String: URL]] = [:]
    for entry in archive.manifest.entries where entry.root == "runtime" {
      let parts = try BackupIO.components(entry.path)
      guard let payload = payloads[entry.number] else { throw ClientBackupError.invalidPackage }
      if BackupGeminiCheckpoints.isRecord(parts),
        let commit = try BackupGeminiCheckpoints.commit(in: payload)
      {
        records[parts[1], default: []].append((entry.number, commit))
      }
      if BackupGeminiCheckpoints.isPack(parts) {
        packs[parts[1], default: [:]][parts[5]] = payload
      }
    }
    guard Set(records.keys) == Set(packs.keys) else {
      throw ClientBackupError.unsupportedLayout("Gemini checkpoint dependencies")
    }
    var initialized = Set<String>()
    for (key, values) in records.sorted(by: { $0.key < $1.key }) {
      guard let files = packs[key] else { throw ClientBackupError.invalidPackage }
      let nativeKey = geminiKeys[key] ?? key
      let shadow = roots.runtime.appendingPathComponent("history/" + nativeKey + "/.git")
      let head = try observe(shadow.appendingPathComponent("HEAD"))
      let needsInitialization = head.before == nil && initialized.insert(nativeKey).inserted
      let structure: BackupGeminiCheckpoints.Prepared
      do {
        structure = try BackupGeminiCheckpoints.prepare(
          commits: values.map(\.1), packs: files, scratch: staging,
          initialize: needsInitialization)
      } catch {
        throw ClientBackupError.unsupportedLayout(shadow.path)
      }
      for (id, commit) in values { geminiCheckpointCommits[id] = structure.commits[commit] }
      for (path, payload) in structure.initialFiles {
        geminiShadowFiles[shadow.appendingPathComponent(path)] = payload
      }
      for (path, payload) in structure.references {
        geminiShadowFiles[shadow.appendingPathComponent(path)] = payload
      }
    }
  }

  private func geminiCheckpoint(_ incoming: URL, commit: String?) throws -> URL {
    let name = "gemini-checkpoint-" + UUID().uuidString
    var changed = false
    try BackupIO.write(name, in: staging) { output in
      let json = try BackupJSONStream(
        incoming, output: output,
        selection: [["commitHash"], ["toolCall", "args", "file_path"]]
      ) { path, value in
        if path == ["commitHash"] { return commit }
        return self.mapping.projectPath(value)
      }
      try json.process()
      changed = json.changed
    }
    if changed { return scratch.path(name) }
    try staging.remove(name)
    return incoming
  }

  private func geminiChat(_ incoming: URL, path: String, original: String) throws -> URL {
    let records = path.hasSuffix(".jsonl")
    guard records || path.hasSuffix(".json") else { return incoming }
    let oldHash = FileHash.sha256Hex(data: Data(original.utf8))
    let newHash = FileHash.sha256Hex(data: Data(mapping.projectPath(original).utf8))
    let fields = ["projectHash", "directories", "cwd", "projectPath", "originalPath", "rootPath"]
    let selected = Set(fields.flatMap { [[$0], ["$set", $0]] })
    let name = "gemini-chat-" + UUID().uuidString
    var changed = false
    try BackupIO.write(name, in: staging) { output in
      let json = try BackupJSONStream(incoming, output: output, selection: selected) {
        path, value in
        if path.last == "projectHash" { return value == oldHash ? newHash : nil }
        return self.mapping.projectPath(value)
      }
      try json.process(records: records)
      changed = json.changed
    }
    if changed { return scratch.path(name) }
    try staging.remove(name)
    return incoming
  }

  private func geminiLogs(_ incoming: URL, old: URL) throws -> URL {
    guard let source = try BackupNativeJSON.value(incoming) as? [[String: Any]],
      let destination = try BackupNativeJSON.value(old) as? [[String: Any]]
    else { throw ClientBackupError.unsupportedLayout("Gemini logs.json") }
    var seen = Set<Data>()
    var rows: [[String: Any]] = []
    for record in destination + source {
      if try seen.insert(BackupNativeJSON.encode(record)).inserted { rows.append(record) }
    }
    if rows.count == destination.count { return old }
    return try write(BackupNativeJSON.encode(rows))
  }

  private func prepareClaude(_ payloads: [Int64: URL]) throws {
    let source = archive.manifest.entries.first {
      $0.root == "profile" && $0.path == ".claude.json"
    }
    guard source != nil || !roots.projects.isEmpty else { return }
    let profile = try source.flatMap { payloads[$0.number] }.map(BackupNativeJSON.object)
    let projectConfig = try claudeProjectConfig(profile)
    for path in Array(projectConfig.keys) + Array(roots.projects.keys) {
      guard BackupIO.originalPath(path) else {
        throw ClientBackupError.unsupportedLayout("Claude Code project path")
      }
      let key = Self.claudeKey(path)
      if let prior = claudeOriginals[key], prior != path {
        throw ClientBackupError.conflict("Claude Code project key")
      }
      claudeOriginals[key] = path
    }
    var localKeys: [String: String] = [:]
    for (key, original) in claudeOriginals {
      let local = mapping.projectPath(original)
      let resulting = Self.claudeKey(local)
      guard localKeys.updateValue(original, forKey: resulting) == nil else {
        throw ClientBackupError.conflict("Claude Code project key")
      }
      if original != local {
        claudeKeys[key] = resulting
      }
    }
    let target = roots.profile.appendingPathComponent(".claude.json")
    if let old = try existing(target, before: observe(target)) {
      for path in try claudeProjectConfig(BackupNativeJSON.object(old)).keys {
        if let original = localKeys[Self.claudeKey(path)], mapping.projectPath(original) != path {
          throw ClientBackupError.conflict("Claude Code project key")
        }
      }
    }
  }

  private static func claudeKey(_ path: String) -> String {
    let codeUnits = path.utf16
    let name = String(
      decoding: codeUnits.map { unit in
        switch unit {
        case 48...57, 65...90, 97...122: UInt8(unit)
        default: 45
        }
      }, as: UTF8.self)
    if name.count <= 200 { return name }
    // Claude Code hashes the original UTF-16 path with 32-bit overflow.
    let hash = codeUnits.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
    return String(name.prefix(200)) + "-" + String(Int64(hash).magnitude, radix: 36)
  }

  private func claudeProjectConfig(_ profile: [String: Any]?) throws -> [String: Any] {
    guard let projects = profile?["projects"] else { return [:] }
    guard let values = projects as? [String: Any] else {
      throw ClientBackupError.unsupportedLayout("Claude Code .claude.json projects")
    }
    return values
  }

  private func claudeProfile(_ incoming: URL, old: URL?) throws -> URL {
    var source = try BackupNativeJSON.object(incoming)
    let projects = try claudeProjectConfig(source)
    let relocated = projects.keys.contains { mapping.projectPath($0) != $0 }
    if relocated {
      source["projects"] = try BackupNativeJSON.remappedRecords(projects, using: mapping)
    }
    if let old {
      let current = try BackupNativeJSON.object(old)
      let merged = try BackupNativeJSON.mergeMaps(
        source, into: current, keys: ["projects", "mcpServers"])
      let bytes = try BackupNativeJSON.encode(merged)
      if bytes == (try BackupNativeJSON.encode(source)), !relocated { return incoming }
      if bytes == (try BackupNativeJSON.encode(current)) { return old }
      return try write(bytes)
    }
    return relocated ? try write(BackupNativeJSON.encode(source)) : incoming
  }

  private func claudeIndex(_ incoming: URL, old: URL?) throws -> URL {
    var source = try BackupNativeJSON.object(incoming)
    guard let entries = source["entries"] as? [[String: Any]] else {
      throw ClientBackupError.unsupportedLayout("Claude Code sessions-index.json")
    }
    var seen = Set<String>()
    var changed = false
    var result: [[String: Any]] = []
    for entry in entries {
      guard let id = entry["sessionId"] as? String, seen.insert(id).inserted else {
        throw ClientBackupError.unsupportedLayout("Claude Code session index")
      }
      var mapped = BackupNativeJSON.pathFields(entry, using: mapping)
      if let fullPath = mapped.value["fullPath"] as? String {
        let prefix = roots.client.path + "/projects/"
        if fullPath.hasPrefix(prefix) {
          let path = fullPath.dropFirst(prefix.count)
          if let separator = path.firstIndex(of: "/"),
            let key = claudeKeys[String(path[..<separator])]
          {
            mapped.value["fullPath"] = prefix + key + path[separator...]
            mapped.changed = true
          }
        }
      }
      result.append(mapped.value)
      changed = changed || mapped.changed
    }
    if let old {
      let previous = try BackupNativeJSON.object(old)
      guard let prior = previous["entries"] as? [[String: Any]],
        let version = source["version"] as? Int, version == previous["version"] as? Int
      else { throw ClientBackupError.unsupportedLayout("Claude Code session index") }
      for row in prior {
        guard let id = row["sessionId"] as? String else {
          throw ClientBackupError.unsupportedLayout("Claude Code session index")
        }
        if seen.insert(id).inserted {
          result.append(row)
          changed = true
        }
      }
      source = previous.merging(source) { _, new in new }
    }
    source["entries"] = result
    let mapped = BackupNativeJSON.pathFields(source, using: mapping)
    if !changed && !mapped.changed { return incoming }
    return try write(BackupNativeJSON.encode(mapped.value))
  }
}
