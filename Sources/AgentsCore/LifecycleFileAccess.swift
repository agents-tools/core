import CPlatform
import Foundation

package enum LifecycleFileAuthority: Sendable {
  case administrator, user, project, privateState
}

extension DirectoryHandle {
  /// Walks physical ancestry from the filesystem root before privileged bytes may be read.
  /// A missing component is optional only when reached through admitted ancestry.
  package static func lifecycleDirectory(
    at path: URL, authority: LifecycleFileAuthority
  ) throws -> DirectoryHandle? {
    var components = Array(path.standardizedFileURL.pathComponents.dropFirst())
    var directory = try DirectoryHandle(at: URL(fileURLWithPath: "/", isDirectory: true))
    if let name = components.first, platform_system_alias(name),
      let info = try directory.info(name), info.st_mode & S_IFMT == S_IFLNK
    {
      guard info.st_uid == 0, try directory.readLink(name) == "private/" + name else {
        throw CoreError.unsafePath("Untrusted system alias.")
      }
      components.insert("private", at: 0)
    }
    for name in components {
      let admin = authority == .administrator
      _ = try FileAccessEvidence.requireLifecycleWriter(
        descriptor: directory.descriptor, owner: admin ? 0 : nil, kind: S_IFDIR,
        protectingChild: !admin)
      guard let info = try directory.info(name) else { return nil }
      guard info.st_mode & S_IFMT == S_IFDIR,
        admin ? info.st_uid == 0 : (info.st_uid == 0 || info.st_uid == geteuid())
      else { throw CoreError.unsafePath("Untrusted lifecycle directory: \(name)") }
      directory = try directory.lifecycleOpenChild(name, matching: info)
    }
    _ = try FileAccessEvidence.requireLifecycleWriter(
      descriptor: directory.descriptor, owner: authority == .administrator ? 0 : geteuid(),
      kind: S_IFDIR)
    return directory
  }

  package func lifecycleChild(_ name: String, authority: LifecycleFileAuthority) throws
    -> DirectoryHandle?
  {
    guard let info = try info(name) else { return nil }
    let result = try lifecycleOpenChild(name, matching: info)
    switch authority {
    case .administrator, .user:
      _ = try FileAccessEvidence.requireLifecycleWriter(
        descriptor: result.descriptor, owner: authority == .administrator ? 0 : geteuid(),
        kind: S_IFDIR)
    case .privateState: try FileAccessEvidence.requirePrivate(descriptor: result.descriptor)
    case .project: break
    }
    return result
  }

  private func lifecycleOpenChild(_ name: String, matching info: stat) throws -> DirectoryHandle {
    let opened = try child(name)
    guard try opened.objectIdentity == FileObjectIdentity(info) else {
      throw CoreError.unsafePath("Lifecycle directory changed during admission.")
    }
    return opened
  }

  package func createPrivateLifecycleChild(
    _ name: String, existingAuthority: LifecycleFileAuthority = .privateState
  ) throws -> DirectoryHandle {
    if let existing = try lifecycleChild(name, authority: existingAuthority) { return existing }
    do {
      return try createPrivateDirectory(name)
    } catch {
      if let concurrent = try lifecycleChild(name, authority: existingAuthority) {
        return concurrent
      }
      throw error
    }
  }

  package func readLifecycleFile(
    _ name: String, authority: LifecycleFileAuthority, maximumBytes: Int
  ) throws -> (bytes: Data, provenance: String)? {
    guard let before = try info(name) else { return nil }
    guard before.st_nlink == 1, before.st_mode & S_IFMT == S_IFREG else {
      throw CoreError.unsafePath("Lifecycle source requires a regular, single-link file.")
    }
    var evidence: FileAccessEvidence?
    var bytes = Data()
    try readChunks(
      name, matching: before, maximumBytes: maximumBytes,
      verifyAccess: { descriptor in
        let current: FileAccessEvidence
        switch authority {
        case .administrator, .user:
          current = try FileAccessEvidence.requireLifecycleWriter(
            descriptor: descriptor, owner: authority == .administrator ? 0 : geteuid(),
            kind: S_IFREG)
        case .privateState: current = try FileAccessEvidence.requirePrivate(descriptor: descriptor)
        case .project: current = try FileAccessEvidence.capture(descriptor: descriptor)
        }
        guard evidence == nil || evidence == current else {
          throw CoreError.invalidState("Lifecycle source permissions changed while reading.")
        }
        evidence = current
      }, { bytes.append(contentsOf: $0) })
    guard let after = try info(name), Self.sameGeneration(before, after), let evidence else {
      throw CoreError.invalidState("Lifecycle source changed while reading.")
    }
    return (bytes, try ResolvedLedgerCodec.digest(evidence))
  }

  package func replacePrivateLifecycleFile(_ name: String, bytes: Data) throws {
    try FileAccessEvidence.requirePrivate(descriptor: descriptor)
    let stage = ".\(name).new"
    try replaceFile(
      name, through: stage, with: bytes,
      afterWrite: {
        _ = try requirePrivateAccess(stage)
      }, afterRename: {})
  }

  package var lifecycleDirectoryURL: URL { url }
  package var lifecycleIdentity: String {
    get throws {
      var seconds: Int64 = 0
      var nanoseconds: Int64 = 0
      guard platform_directory_birthtime(descriptor, &seconds, &nanoseconds) == 0 else {
        throw CoreError.invalidState("The project directory identity could not be established.")
      }
      return try ResolvedLedgerCodec.digest(
        LifecycleDirectoryIdentity(
          object: objectIdentity, birthSeconds: seconds, birthNanoseconds: nanoseconds))
    }
  }
}

private struct LifecycleDirectoryIdentity: Encodable {
  let object: FileObjectIdentity
  let birthSeconds: Int64
  let birthNanoseconds: Int64
}
