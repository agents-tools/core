import CPlatform
import Foundation

/// Descriptor-relative access for a caller-selected audit root.
package enum ContentAuditFiles {
  package enum EntryKind { case directory, regular, symbolicLink, other }

  package static func kind(
    _ name: String, in directory: DirectoryHandle
  ) throws -> EntryKind? {
    guard let value = try directory.info(name) else { return nil }
    switch value.st_mode & S_IFMT {
    case S_IFDIR: return .directory
    case S_IFREG: return .regular
    case S_IFLNK: return .symbolicLink
    default: return .other
    }
  }

  package static func link(_ name: String, in directory: DirectoryHandle) throws -> String {
    let bytes = try directory.readLinkData(name)
    guard let link = String(data: bytes, encoding: .utf8) else {
      throw CoreError.unsafePath("invalid prompt link")
    }
    return link
  }

  package static func readPrompt(
    _ name: String, in parent: DirectoryHandle, maximumBytes: Int
  ) throws -> Data {
    guard let info = try parent.info(name), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1
    else {
      throw CoreError.unsafePath("expected a regular, unshared prompt")
    }
    return try parent.read(name, matching: info, maximumBytes: maximumBytes)
  }

  package struct FileIdentity: Sendable {
    fileprivate let parent: FileObjectIdentity
    fileprivate let file: FileObjectIdentity
  }

  package static func readEditable(
    _ name: String, in parent: DirectoryHandle, maximumBytes: Int
  ) throws -> (Data, FileIdentity) {
    guard let info = try parent.info(name), info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_mode & 0o7111 == 0
    else { throw CoreError.unsafePath("strip requires a regular, non-executable, unshared file") }
    let bytes = try parent.read(name, matching: info, maximumBytes: maximumBytes)
    return (bytes, try .init(parent: parent.objectIdentity, file: FileObjectIdentity(info)))
  }

  /// Stage on the same volume, preserve metadata and verify the displaced preimage.
  /// Keep the staging directory if concurrent changes prevent a safe rollback.
  package static func applyReviewedEdit(
    _ url: URL, before: Data, after: Data, identity: FileIdentity
  ) throws {
    let parentURL = url.deletingLastPathComponent()
    let parent = try DirectoryHandle(at: parentURL)
    let name = url.lastPathComponent
    guard try parent.objectIdentity == identity.parent,
      let original = try parent.info(name), original.st_mode & S_IFMT == S_IFREG,
      original.st_nlink == 1, original.st_mode & 0o7111 == 0,
      FileObjectIdentity(original) == identity.file,
      try parent.read(name, matching: original, maximumBytes: before.count) == before
    else { throw CoreError.invalidState("prompt changed since strip preview") }

    try FileSystem.requireAccess(R_OK | W_OK, at: url, parent: parent.descriptor)
    let staging = ".agents-audit-" + UUID().uuidString
    let stage = try parent.makeDirectory(staging)
    let stageIdentity = try stage.objectIdentity
    var disposable = true
    defer {
      if disposable { try? parent.remove(staging, identity: stageIdentity) }
    }
    let payload = "prompt"
    try stage.write(
      payload, data: after, preservingMetadataOf: name, originalParent: parent)
    guard let staged = try stage.info(payload),
      let current = try parent.info(name), DirectoryHandle.sameGeneration(original, current),
      try DirectoryHandle(at: parentURL).objectIdentity == identity.parent
    else { throw CoreError.invalidState("prompt changed since strip preview") }
    let replacement = FileObjectIdentity(staged)
    try stage.atomicRename(payload, to: parent, named: name, mode: .exchange)
      .requireSuccess("apply reviewed prompt edit")
    disposable = false

    do {
      guard let displaced = try stage.info(payload), displaced.st_mode & S_IFMT == S_IFREG,
        displaced.st_nlink == 1, FileObjectIdentity(displaced) == identity.file,
        try stage.read(payload, matching: displaced, maximumBytes: before.count) == before,
        try parent.info(name).map(FileObjectIdentity.init) == replacement,
        try DirectoryHandle(at: parentURL).objectIdentity == identity.parent
      else { throw CoreError.invalidState("prompt changed during publication") }
    } catch {
      guard let published = try? parent.info(name), FileObjectIdentity(published) == replacement,
        (try? parent.read(name, matching: published, maximumBytes: after.count)) == after,
        (try? stage.info(payload)) != nil,
        (try? stage.atomicRename(payload, to: parent, named: name, mode: .exchange)
          .requireSuccess("restore original prompt")) != nil
      else {
        throw CoreError.invalidState(
          "concurrent prompt change; original retained at " + stage.url.path)
      }
      try syncPublication(parent: parent, stage: stage)
      disposable = true
      throw error
    }
    try syncPublication(parent: parent, stage: stage)
    do {
      try parent.remove(staging, identity: stageIdentity)
    } catch {
      throw CoreError.invalidState(
        "prompt published; staging cleanup incomplete at " + stage.url.path)
    }
  }

  private static func syncPublication(parent: DirectoryHandle, stage: DirectoryHandle) throws {
    do {
      try stage.sync()
      try parent.sync()
    } catch {
      throw CoreError.invalidState("prompt publication sync failed; inspect " + stage.url.path)
    }
  }
}

extension StateStore {
  /// Read the ledger under the existing scope lock, pinned to the caller's admitted root.
  /// Journals can refer to other loaders, so pending recovery stops this local inspection.
  package func withContentAuditLedger<Result>(
    root: DirectoryHandle, _ body: (ResolvedLedger?) throws -> Result
  ) throws -> Result {
    guard !TransactionLockContext.isHeld else {
      throw CoreError.invalidState("nested scope lock acquisition")
    }
    let folder = directory.lastPathComponent
    func validateRoot() throws {
      guard try DirectoryHandle(at: root.url).objectIdentity == root.objectIdentity else {
        throw CoreError.invalidState("selected audit root changed")
      }
    }
    while true {
      guard let state = try root.directory(folder) else {
        let result = try body(ResolvedLedger())
        if try root.info(folder) != nil { continue }
        try validateRoot()
        return result
      }
      let lock = ".agents.lock"
      let descriptor = openat(
        state.descriptor, lock, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 || errno == ENOENT else {
        throw CoreError.unsafePath("cannot open content audit scope lock")
      }
      defer { if descriptor >= 0 { close(descriptor) } }
      if descriptor >= 0 {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
          throw CoreError.unsafePath("expected a regular content audit scope lock")
        }
        while platform_flock(descriptor, LOCK_SH) != 0 {
          if errno != EINTR { throw CoreError.invalidState("cannot acquire content audit lock") }
        }
        guard try state.info(lock).map(FileObjectIdentity.init) == FileObjectIdentity(info) else {
          throw CoreError.invalidState("content audit scope lock changed")
        }
      }
      guard try !TransactionJournal.isPresent(in: state),
        try state.info("watch-refs.pending") == nil
      else {
        throw CoreError.recoveryPending("content audit scope has pending recovery")
      }
      var ledger: ResolvedLedger? = ResolvedLedger()
      if try state.info(Self.resolvedFileName) != nil {
        ledger = try? ResolvedLedgerCodec.decode(
          ContentAuditFiles.readPrompt(
            Self.resolvedFileName, in: state, maximumBytes: LedgerLimits.standard.encodedBytes),
          limits: .standard)
      }
      let result = try body(ledger)
      if descriptor < 0, try state.info(lock) != nil { continue }
      guard try root.info(folder).map(FileObjectIdentity.init) == state.objectIdentity else {
        throw CoreError.invalidState("content audit state directory changed")
      }
      try validateRoot()
      return result
    }
  }

  /// Resolves only the lexical location recorded for a scope-compatible deployment.
  /// The audit admits each resulting path against its own prompt profile before opening it.
  package func contentAuditLocation(_ location: LedgerLocation) throws -> URL? {
    guard location.kind == .registered, let key = location.root else { return nil }
    let root: URL?
    if key == "project", scope == .project {
      root = environment.projectDirectory
    } else if key == InstructionLocations.ruleRoot(in: scope) {
      root = InstructionLocations.antigravityAuthority(environment, scope: scope).logicalDirectory
    } else if key.hasPrefix("skills-"), let agent = AgentID(rawValue: String(key.dropFirst(7))),
      agent.supportsSkills
    {
      root = AgentRegistry.installSkillsDirectory(
        for: agent, scope: scope, environment: environment)
    } else if key.hasPrefix("instructions-"),
      let agent = AgentID(rawValue: String(key.dropFirst("instructions-".count)))
    {
      root = InstructionLocations.file(for: agent, scope: scope, environment: environment)?
        .deletingLastPathComponent()
    } else if let route = NativeTargetRoute.targetRoute(key), route.permits(scope),
      location.path.utf8.elementsEqual(route.basename.utf8)
    {
      root = try route.rootAuthority(environment, validateExistingOverride: false).logicalDirectory
    } else {
      root = nil
    }
    guard let root else { return nil }
    try location.validate()
    return root.appendingPathComponent(location.path).standardizedFileURL
  }
}
