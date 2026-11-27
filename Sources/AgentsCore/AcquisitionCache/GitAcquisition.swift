import Foundation

/// Exact packs borrowed by one synchronous operation and retained independently of the shared
/// cache. The update owns this workspace through apply, including a reviewed pause.
package final class GitAcquisitionCaptures {
  private var directory: DirectoryHandle?
  private var packs = Set<String>()
  private var archives: [String: String] = [:]
  var archiveSelections: [String: SourceRevision] = [:]

  package init() {}

  deinit {
    if let directory { try? FileManager.default.removeItem(at: directory.url) }
  }

  fileprivate func read(_ key: String) throws -> Data? {
    guard packs.contains(key), let directory else { return nil }
    return try directory.read(key, maximumBytes: GitAcquisition.packLimit)
  }

  fileprivate func retain(_ data: Data, key: String) throws {
    guard !packs.contains(key) else { return }
    if directory == nil {
      directory = try PrivateSourceRecovery.makeWorkspace(prefix: "agents-acquisition-captures-")
    }
    guard let directory else { throw AcquisitionCacheError.invalidEntry }
    try directory.write(key, data: data)
    packs.insert(key)
  }

  func readArchive(_ reference: PrivateSourceRecovery.Reference) throws -> Data? {
    guard let directory, let digest = archives[reference.key] else { return nil }
    let data = try directory.read(
      "archive-" + reference.key, maximumBytes: VerifiedVCSArchive.compressedLimit)
    guard "sha256:" + FileHash.sha256Hex(data: data) == digest else {
      throw SourceAccessError.invalidArchive
    }
    return data
  }

  func captureArchive(
    _ data: Data, verified: VerifiedVCSArchive, reference: PrivateSourceRecovery.Reference
  ) throws {
    guard archives[reference.key] == nil else { return }
    if directory == nil {
      directory = try PrivateSourceRecovery.makeWorkspace(prefix: "agents-acquisition-captures-")
    }
    guard let directory else { throw SourceAccessError.recoveryUnavailable }
    let file = try directory.createPrivateFile("archive-" + reference.key)
    try file.write(data)
    archives[reference.key] = verified.byteDigest
  }

  package func containsAnonymousCommit(
    _ source: SourceDeclaration, revision: String,
    environment: RuntimeEnvironment
  ) -> Bool {
    guard let acquisition = GitAcquisition(source, environment: environment) else { return false }
    return packs.contains(acquisition.key(revision))
  }
}

struct GitAcquisition {
  struct Pack {
    let revision: String
    let bytes: Data
  }

  struct Advertisement {
    let catalog: SourceCatalog
    let time: Date
  }

  private struct Observation: Codable {
    let revision: String
    let time: Date
  }

  // A fixture may trust its own CA without changing the OS trust store or Git's ambient config.
  @TaskLocal static var fixtureCertificateAuthority: URL?
  static let packLimit = 128 * 1024 * 1024
  private static let fetchedRef = "refs/agents/acquired"

  let url: String
  let cache: AcquisitionCache
  private let captures: GitAcquisitionCaptures?
  private let access: SourceAccessConfiguration

  init?(
    _ source: SourceDeclaration, environment: RuntimeEnvironment,
    captures: GitAcquisitionCaptures? = nil
  ) {
    guard source.kind == .git,
      let route = try? SourceRoute(source, environment: environment, policy: .init()),
      case .git = route, Self.isAnonymous(route, environment: environment),
      let parts = URLComponents(string: source.gitURL),
      parts.scheme?.lowercased() == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      (try? SourceOrigin.git(source.gitURL)) != nil
    else { return nil }
    let dnsName = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard
      !environment.credentialedGitHosts.contains(where: {
        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == dnsName
      })
    else { return nil }
    // Keep the exact transport URL. Policy and declaration identities may coalesce spellings.
    url = source.gitURL
    cache = AcquisitionCache(environment: environment)
    self.captures = captures
    access = environment.sourceAccess
  }

  private static func isAnonymous(_ route: SourceRoute, environment: RuntimeEnvironment) -> Bool {
    do { return try route.credential(environment.sourceAccess) == nil } catch { return false }
  }

  func key(_ revision: String) -> String {
    AcquisitionCache.key([("transport", Data(url.utf8)), ("commit", Data(revision.utf8))])
  }

  func discover() throws -> Advertisement {
    let time = Date()
    let advertised = try workspace { root in
      try git(["ls-remote", "--symref", "--", url], in: root, .listRemoteReferences, network: true)
    }
    var raw: [String: String] = [:]
    for line in advertised.split(separator: "\n") {
      let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
      guard fields.count == 2, SourceCache.isObjectID(fields[0]),
        fields[1] == "HEAD" || fields[1].hasPrefix("refs/")
      else { continue }
      guard raw.updateValue(fields[0], forKey: fields[1]) == nil else {
        throw CoreError.invalidSource("duplicate Git reference in remote advertisement")
      }
    }
    var references = raw
    var tags: [String: String] = [:]
    for (ref, object) in raw where ref.hasPrefix("refs/tags/") && !ref.hasSuffix("^{}") {
      let commit = raw[ref + "^{}"] ?? object
      references[ref] = commit
      tags[String(ref.dropFirst("refs/tags/".count))] = commit
    }
    return Advertisement(catalog: .init(tags: tags, references: references), time: time)
  }

  /// Accepts only expressions whose result is determined by the current advertisement.
  static func reference(_ expression: String, in catalog: SourceCatalog) -> (String, String)? {
    if let revision = catalog.references[expression] { return (expression, revision) }
    let matches = ["refs/tags/", "refs/heads/", "refs/remotes/"].compactMap { prefix in
      catalog.references[prefix + expression].map { (prefix + expression, $0) }
    }
    return matches.count == 1 ? matches.first : nil
  }

  func exact(_ requested: String, offline: Bool = false) throws -> Pack? {
    guard SourceCache.isObjectID(requested) else { return nil }
    let key = key(requested)
    if let bytes = try captures?.read(key) {
      return Pack(revision: requested, bytes: bytes)
    }
    if let pack = try? cache.read(
      .git, key: key, maximumBytes: Self.packLimit,
      { value in
        let pack = Pack(revision: requested, bytes: value.data)
        try withVerifiedRepository(pack) { _, _ in }
        try captures?.retain(pack.bytes, key: key)
        return pack
      })
    {
      return pack
    }
    guard !offline else { return nil }
    try Task.checkCancellation()
    let pack = try download(requested)
    try captures?.retain(pack.bytes, key: self.key(pack.revision))
    return pack
  }

  /// Publication is optional. The caller may continue with the verified, owned bytes.
  func remember(_ pack: Pack) {
    _ = try? cache.write(pack.bytes, store: .git, key: key(pack.revision), object: pack.revision)
  }

  func note(_ ref: String, pack: Pack, observedAt time: Date) {
    let key = observationKey(ref)
    let observation = Observation(revision: pack.revision, time: time)
    guard let bytes = try? JSONEncoder().encode(observation) else { return }
    for _ in 0..<4 {
      let previous = try? cache.read(.git, key: key, maximumBytes: 1024, touching: false) { value in
        (try JSONDecoder().decode(Observation.self, from: value.data), value.publication)
      }
      if let previous, previous.0.time >= time { return }
      let condition = previous.map { AcquisitionCache.WriteCondition.publication($0.1) } ?? .absent
      guard
        let written = try? cache.write(
          bytes, store: .git, key: key,
          object: "ref:" + String(decoding: ref.utf8.prefix(120), as: UTF8.self),
          condition: condition, now: time)
      else { return }
      if written { return }
    }
  }

  func observedRevision(_ ref: String) throws -> String? {
    try cache.read(.git, key: observationKey(ref), maximumBytes: 1024, touching: false) {
      try JSONDecoder().decode(Observation.self, from: $0.data).revision
    }
  }

  private func observationKey(_ ref: String) -> String {
    AcquisitionCache.key([("transport", Data(url.utf8)), ("ref", Data(ref.utf8))])
  }

  private func download(_ object: String) throws -> Pack {
    try workspace { root in
      let repository = try initialize(in: root, object: object)
      _ = try git(
        [
          "-C", repository.path, "fetch", "--no-tags", "--no-recurse-submodules", "--", url,
          "+" + object + ":" + Self.fetchedRef,
        ],
        in: root, .fetch, network: true)
      let received = try git(
        ["-C", repository.path, "rev-parse", "--verify", Self.fetchedRef],
        in: root, .resolveRevision(revision: object))
      guard received == object else { throw AcquisitionCacheError.invalidEntry }
      let revision = try git(
        ["-C", repository.path, "rev-parse", "--verify", Self.fetchedRef + "^{commit}"],
        in: root, .resolveRevision(revision: object))
      guard SourceCache.isObjectID(revision) else { throw AcquisitionCacheError.invalidEntry }
      _ = try git(
        ["-C", repository.path, "repack", "-a", "-d"], in: root, .extractRevision)
      let packs = try DirectoryHandle(at: repository).child("objects").child("pack")
      let files = try packs.names().filter { $0.hasSuffix(".pack") }
      guard files.count == 1 else { throw AcquisitionCacheError.invalidEntry }
      let pack = Pack(
        revision: revision, bytes: try packs.read(files[0], maximumBytes: Self.packLimit))
      try withVerifiedRepository(pack) { _, _ in }
      return pack
    }
  }

  /// Rebuilds the object database from the same verified bytes consumed from the entry.
  /// The callback receives a private repository and the Git pack stem in its objects/pack.
  func withVerifiedRepository<T>(
    _ pack: Pack, _ body: (URL, String) throws -> T
  ) throws -> T {
    try workspace { root in
      let repository = try initialize(in: root, object: pack.revision)
      let temp = root.appendingPathComponent("incoming.pack")
      try DirectoryHandle(at: root).write("incoming.pack", data: pack.bytes)
      let digest = try git(
        ["-C", repository.path, "index-pack", "--strict", temp.path], in: root, .extractRevision)
      guard SourceCache.isObjectID(digest), digest.utf8.count == pack.revision.utf8.count
      else { throw AcquisitionCacheError.invalidEntry }
      let stem = "pack-" + digest
      let objects = repository.appendingPathComponent("objects/pack")
      try FileManager.default.moveItem(
        at: temp, to: objects.appendingPathComponent(stem + ".pack"))
      try FileManager.default.moveItem(
        at: root.appendingPathComponent("incoming.idx"),
        to: objects.appendingPathComponent(stem + ".idx"))
      let actual = try git(
        ["-C", repository.path, "rev-parse", "--verify", pack.revision + "^{commit}"],
        in: root, .resolveRevision(revision: pack.revision))
      guard actual == pack.revision else { throw AcquisitionCacheError.invalidEntry }
      _ = try git(
        [
          "-C", repository.path, "fsck", "--full", "--strict", "--no-reflogs",
          "--no-dangling", pack.revision,
        ], in: root, .extractRevision)
      return try body(repository, stem)
    }
  }

  func initializeMirror(at repository: URL, object: String) throws {
    let root = repository.deletingLastPathComponent()
    // Scope paths may carry ordinary config. Run init from a clean external workspace.
    try workspace { clean in
      _ = try initialize(named: repository.path, in: clean, object: object)
      _ = try git(
        ["-C", repository.path, "config", "remote.origin.url", url], in: clean, .readOrigin)
      _ = try git(
        ["-C", repository.path, "config", "remote.origin.fetch", "+refs/*:refs/*"],
        in: clean, .readOrigin)
      _ = try git(
        ["-C", repository.path, "config", "remote.origin.mirror", "true"], in: clean, .readOrigin)
    }
    try DirectoryHandle(at: root).sync()
  }

  func archive(_ revision: String, repository: URL, to archive: URL) throws {
    try workspace { root in
      _ = try git(
        ["-C", repository.path, "archive", "--format=tar", "--output=" + archive.path, revision],
        in: root, .extractRevision)
    }
  }

  private func initialize(named name: String = "repository", in root: URL, object: String) throws
    -> URL
  {
    let format = object.utf8.count == 64 ? "sha256" : "sha1"
    _ = try git(
      ["init", "--bare", "--template=", "--object-format=" + format, name], in: root, .clone)
    return URL(
      fileURLWithPath: name, relativeTo: URL(fileURLWithPath: root.path, isDirectory: true)
    ).standardizedFileURL
  }

  private func workspace<T>(_ body: (URL) throws -> T) throws -> T {
    let parent = try DirectoryHandle(at: FileManager.default.temporaryDirectory)
    let directory = try parent.makeDirectory("agents-acquisition-git-" + UUID().uuidString)
    defer {
      try? parent.remove(directory.url.lastPathComponent, identity: directory.objectIdentity)
    }
    return try body(directory.url)
  }

  private func git(
    _ args: [String], in root: URL, _ operation: GitError.Operation, network: Bool = false
  ) throws -> String {
    if network { try access.requireCurrentSettings() }
    return try ProcessRunner.isolatedGit(
      args, in: root, operation: operation, source: url, network: network,
      certificateAuthority: Self.fixtureCertificateAuthority)
  }
}
