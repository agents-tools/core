import Foundation

/// Captures existing ancestry and the final entry without following that entry's link.
/// Missing ancestors may be created, but existing ancestors cannot be exchanged.
package struct PathIdentity: Sendable {
  private let url: URL
  private let physical: URL
  private let entry: FileObjectIdentity?
  private let ancestors: [(URL, FileObjectIdentity)]

  package init(_ url: URL) throws {
    self.url = url
    physical =
      url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    entry = try Self.read(physical)
    var ancestors: [(URL, FileObjectIdentity)] = []
    var parent = physical.deletingLastPathComponent()
    while parent.path != "/" {
      if let value = try Self.read(parent) { ancestors.append((parent, value)) }
      parent.deleteLastPathComponent()
    }
    self.ancestors = ancestors
  }

  package func validate() throws {
    let current = url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    guard current == physical, try Self.read(physical) == entry else {
      throw CoreError.invalidState("path changed during preparation: \(url.path)")
    }
    for (path, value) in ancestors where try Self.read(path) != value {
      throw CoreError.invalidState("path ancestry changed during preparation: \(url.path)")
    }
  }

  private static func read(_ url: URL) throws -> FileObjectIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      if errno == ENOENT { return nil }
      throw CoreError.unsafePath("cannot inspect path: \(url.path)")
    }
    return FileObjectIdentity(value)
  }
}

/// Prepared evidence checked again before publication, except for targets that the
/// transaction journal verifies itself.
package protocol PreparedEvidence {
  func validate(excludingTargets targets: Set<String>) throws
}

/// State bytes and presence belong to the same generation as the rendered targets.
package struct StatePrecondition: PreparedEvidence {
  private let files: [(url: URL, evidence: TargetPrecondition, bytes: Data?)]

  package init(store: StateStore) throws {
    files = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      let input = try TargetPrecondition.readingFile($0)
      return ($0, input.evidence, input.bytes)
    }
    try validate()
  }

  package func evidence(for url: URL) throws -> TargetPrecondition {
    try file(for: url).evidence
  }

  package func bytes(for url: URL) throws -> Data? {
    try file(for: url).bytes
  }

  private func file(for url: URL) throws -> (url: URL, evidence: TargetPrecondition, bytes: Data?) {
    guard let file = files.first(where: { $0.url.path == url.standardizedFileURL.path }) else {
      throw CoreError.invalidState("state precondition does not include target")
    }
    return file
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    for (url, evidence, _) in files where !targets.contains(url.standardizedFileURL.path) {
      try evidence.validate()
    }
  }
}

/// The generation captured by a plan is also the journal's expected preimage.
package struct TargetPrecondition: Sendable {
  package let url: URL
  let snapshot: FileSnapshot?
  private let identity: PathIdentity
  private let maximumFileBytes: Int?
  private(set) var access: TargetAccessPrecondition?
  package var exists: Bool { snapshot != nil }

  var physicalURL: URL {
    url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(
      url.lastPathComponent
    ).standardizedFileURL
  }

  package init(_ url: URL) throws {
    self.url = url.standardizedFileURL
    maximumFileBytes = nil
    identity = try PathIdentity(url)
    snapshot = try FileSnapshot.read(at: url)
    try identity.validate()
  }

  private init(url: URL, snapshot: FileSnapshot?, identity: PathIdentity, maximumFileBytes: Int?) {
    self.url = url.standardizedFileURL
    self.snapshot = snapshot
    self.identity = identity
    self.maximumFileBytes = maximumFileBytes
  }

  /// Rendering and its expected preimage use the same opened-file bytes and inode.
  package static func readingFile(_ url: URL, maximumFileBytes: Int? = nil) throws
    -> (bytes: Data?, evidence: Self)
  {
    let identity = try PathIdentity(url)
    let capture = try FileSnapshot.captureFile(at: url, maximumFileBytes: maximumFileBytes)
    guard capture.snapshot?.isRegular != false else {
      throw CoreError.unsafePath("expected regular file: \(url.path)")
    }
    try identity.validate()
    return (
      capture.bytes,
      Self(
        url: url, snapshot: capture.snapshot, identity: identity, maximumFileBytes: maximumFileBytes
      )
    )
  }

  func capturingAccess() throws -> Self {
    var result = self
    result.access = try TargetAccessPrecondition.capture(at: physicalURL)
    try result.validate()
    return result
  }

  package func sameGeneration(as other: Self) -> Bool {
    url.path == other.url.path && snapshot == other.snapshot && access == other.access
  }

  func validateIdentity() throws { try identity.validate() }

  package func validate() throws {
    try validateIdentity()
    try access?.validate(at: physicalURL)
    try validateSnapshot()
  }

  func validateSnapshot() throws {
    let current =
      try maximumFileBytes.map {
        try FileSnapshot.captureFile(at: url, maximumFileBytes: $0).snapshot
      } ?? FileSnapshot.read(at: url)
    guard current == snapshot else {
      throw CoreError.invalidState("target changed during preparation: \(url.path)")
    }
  }
}

struct TargetAccessPrecondition: Equatable, Sendable {
  let ancestry: DirectoryAccessEvidence
  let target: FileAccessEvidence?
  let linkOwner: UInt32?
  let linkGroup: UInt32?

  static func capture(at url: URL) throws -> Self {
    let parentURL = url.deletingLastPathComponent()
    let ancestry = try DirectoryAccessEvidence.capture(at: parentURL)
    let complete = ancestry.directories.count == parentURL.standardizedFileURL.pathComponents.count
    var info = stat()
    let link = lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    let target =
      try complete && !link
      ? DirectoryHandle(at: parentURL).accessEvidence(url.lastPathComponent) : nil
    return Self(
      ancestry: ancestry, target: target, linkOwner: link ? info.st_uid : nil,
      linkGroup: link ? info.st_gid : nil)
  }

  func validate(at url: URL) throws {
    guard try Self.capture(at: url) == self else {
      throw CoreError.invalidState("target or ancestry access changed during preparation")
    }
  }
}

/// An existing selected project, captured without creating lock or state ancestry.
/// Passing this observation never grants authority outside registered transaction targets.
public struct ExistingProjectRoot: Sendable {
  public let directory: URL
  private let identity: FileObjectIdentity

  fileprivate init(directory: URL) throws {
    self.directory = directory.standardizedFileURL
    identity = try DirectoryHandle(at: directory.resolvingSymlinksInPath()).objectIdentity
  }

  func validate() throws {
    guard try DirectoryHandle(at: directory.resolvingSymlinksInPath()).objectIdentity == identity
    else { throw CoreError.invalidState("selected project root changed") }
  }

  package func validateForLifecycle() throws { try validate() }

  /// Returns nil for a separately registered external loader; selected-root descendants
  /// are opened from the pinned descriptor and never recreate the selected pathname.
  func descendant(
    at url: URL, from root: DirectoryHandle, create: Bool,
    checkpoint: (DirectoryHandle.AncestryStep) throws -> Void = { _ in }
  ) throws -> DirectoryHandle? {
    try validate()
    let prefix = Array(root.url.path.utf8)
    let bytes = Array(url.path.utf8)
    guard bytes == prefix || bytes.starts(with: prefix + [47]) else { return nil }
    let relative = String(
      decoding: bytes.dropFirst(min(prefix.count + 1, bytes.count)), as: UTF8.self)
    let parts = relative.split(separator: "/").map(String.init)
    var current = root
    for (index, name) in parts.enumerated() {
      if create {
        let depth = parts.count - index - 1
        if try current.info(name) == nil {
          try current.makeDirectory(name) { try checkpoint(.created(depth: depth)) }
          try checkpoint(.synced(depth: depth))
        } else {
          try current.sync()
        }
      }
      current = try current.child(name)
      try validate()
    }
    return current
  }

  func open(for store: StateStore) throws -> DirectoryHandle {
    guard store.scope == .project,
      directory.path.utf8.elementsEqual(
        store.environment.projectDirectory.standardizedFileURL.path.utf8)
    else { throw CoreError.invalidState("project observation belongs to another scope") }
    try validate()
    let opened = try DirectoryHandle(at: directory.resolvingSymlinksInPath())
    guard try opened.objectIdentity == identity else {
      throw CoreError.invalidState("selected project root changed during admission")
    }
    return opened
  }
}

extension StateStore {
  public func captureExistingProjectRoot() throws -> ExistingProjectRoot {
    guard scope == .project else {
      throw CoreError.invalidState("existing project root requires project scope")
    }
    return try ExistingProjectRoot(directory: environment.projectDirectory)
  }
}

/// Exact, absent authoring file owned by one explicit local skill initialization.
package struct SkillInitializationTarget {
  package let file: URL
  let scope: URL
  let descendants: [String]
  let evidence: TargetPrecondition

  fileprivate init(store: StateStore, name: String?, selectedDirectory: String? = nil) throws {
    guard store.scope == .project,
      name == nil || (name == PathSafety.sanitizeName(name!) && !name!.contains("/")),
      selectedDirectory.map({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
          && !$0.contains("\\") && !$0.contains("\0")
      }) ?? true
    else { throw CoreError.unsafePath("invalid local skill initialization target") }
    scope = store.directory
    descendants =
      (selectedDirectory.map { [$0] } ?? [])
      + (name.map { [$0] } ?? []) + ["SKILL.md"]
    file = descendants.reduce(store.environment.projectDirectory.resolvingSymlinksInPath()) {
      $0.appendingPathComponent($1)
    }
    evidence = try TargetPrecondition(file)
    guard evidence.snapshot == nil else {
      throw CoreError.invalidSkill("skill file already exists")
    }
  }
}

extension StateStore {
  package func skillInitializationTarget(named name: String? = nil) throws
    -> SkillInitializationTarget
  {
    try SkillInitializationTarget(store: self, name: name)
  }

  /// Preserves an explicitly selected directory spelling below the observed existing parent.
  package func skillInitializationTarget(
    inChildDirectory directory: String, named name: String? = nil
  ) throws
    -> SkillInitializationTarget
  {
    try SkillInitializationTarget(store: self, name: name, selectedDirectory: directory)
  }
}
