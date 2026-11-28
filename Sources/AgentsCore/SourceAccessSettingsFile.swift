import Foundation

struct SourceAccessSettingsFile: Sendable {
  private static let name = "source-access.yaml"
  private static let lock = ".source-access.lock"
  private let home: URL
  private let directory: URL
  let url: URL

  init(homeDirectory: URL) {
    home = homeDirectory
    directory = home.appendingPathComponent(".agents", isDirectory: true)
    url = directory.appendingPathComponent(Self.name)
  }

  struct Snapshot: Equatable, Sendable {
    let bytes: Data?
    fileprivate let entry: stat?
    fileprivate let ancestry: DirectoryAccessEvidence?

    var exists: Bool { entry != nil }

    var fingerprint: String? {
      guard let entry, let bytes else { return nil }
      #if os(macOS)
        let changed = entry.st_ctimespec
      #else
        let changed = entry.st_ctim
      #endif
      let generation = "\(entry.st_dev):\(entry.st_ino):\(changed.tv_sec):\(changed.tv_nsec)\n"
      return FileHash.sha256Hex(data: Data(generation.utf8) + bytes)
    }

    static let absent = Self(bytes: nil, entry: nil, ancestry: nil)

    static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs.entry, rhs.entry) {
      case (nil, nil): true
      case (.some(let first), .some(let second)):
        DirectoryHandle.sameGeneration(first, second) && lhs.ancestry == rhs.ancestry
          && lhs.bytes == rhs.bytes
      default: false
      }
    }
  }

  func read() throws -> Snapshot {
    guard let (parent, ancestry) = try openParent(create: false) else { return .absent }
    return try read(from: parent, ancestry: ancestry)
  }

  func profile(in snapshot: Snapshot) throws -> SourceAccessProfile? {
    if snapshot.exists, snapshot.bytes == nil {
      throw SourceAccessSettingsError.invalidFile(url, reason: "Expected YAML up to 64 KiB.")
    }
    do {
      return try snapshot.bytes.map(SourceAccessProfile.parse)
    } catch SourceAccessSettingsError.invalidProfile(let reason) {
      throw SourceAccessSettingsError.invalidFile(url, reason: reason)
    }
  }

  private func read(from parent: DirectoryHandle, ancestry: DirectoryAccessEvidence) throws
    -> Snapshot
  {
    do {
      guard let entry = try parent.info(Self.name) else { return .absent }
      guard entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1,
        entry.st_uid == geteuid()
      else { throw SourceAccessSettingsError.unsafeLocation(url) }
      try parent.requireUserControlledFile(Self.name, matching: entry)
      let bytes =
        entry.st_size > SourceAccessProfile.maximumBytes
        ? nil
        : try parent.read(
          Self.name, matching: entry, maximumBytes: SourceAccessProfile.maximumBytes)
      try parent.requireUserControlledFile(Self.name, matching: entry)
      try ancestry.validate(at: directory)
      return Snapshot(bytes: bytes, entry: entry, ancestry: ancestry)
    } catch let exhaustion as OpenFileLimitError {
      throw exhaustion
    } catch {
      throw SourceAccessSettingsError.unsafeLocation(url)
    }
  }

  func writesChanges(_ bytes: Data?, comparedTo original: Snapshot) -> Bool {
    if let bytes { return bytes != original.bytes }
    return original.exists
  }

  func save(_ bytes: Data?, replacing original: Snapshot) throws {
    guard try read() == original else { throw SourceAccessSettingsError.changed(url) }
    guard writesChanges(bytes, comparedTo: original) else { return }
    guard let (parent, ancestry) = try openParent(create: bytes != nil) else {
      throw SourceAccessSettingsError.changed(url)
    }
    try FileLock.withDescriptor(in: parent, name: Self.lock) { descriptor in
      let lock = try FileAccessEvidence.requirePrivate(descriptor: descriptor)
      try parent.requirePrivateAccess(Self.lock, matching: lock)
      try require(original, in: parent, ancestry: ancestry)
      if let bytes {
        let staging = ".source-access-\(UUID().uuidString)"
        let temporary = try parent.createPrivateFile(staging)
        defer { try? parent.remove(staging, identity: temporary.evidence.identity) }
        try temporary.write(bytes)
        try require(original, in: parent, ancestry: ancestry)
        if original.entry == nil {
          let rename = parent.atomicRename(staging, to: parent, named: Self.name, mode: .exclusive)
          if case .exists = rename { throw SourceAccessSettingsError.changed(url) }
          try rename.requireSuccess("publish source access settings")
        } else {
          guard renameat(parent.descriptor, staging, parent.descriptor, Self.name) == 0 else {
            throw FileSystem.posixError(
              errno, at: url, otherwise: .invalidState("cannot publish source access settings"))
          }
        }
        try parent.sync()
      } else {
        try parent.remove(Self.name, identity: original.entry.map(FileObjectIdentity.init))
      }
    }
  }

  private func require(
    _ original: Snapshot, in parent: DirectoryHandle, ancestry: DirectoryAccessEvidence
  ) throws {
    try ancestry.validate(at: directory)
    guard try read(from: parent, ancestry: ancestry) == original else {
      throw SourceAccessSettingsError.changed(url)
    }
  }

  private func openParent(create: Bool) throws -> (DirectoryHandle, DirectoryAccessEvidence)? {
    do {
      guard home.isFileURL, home.path != "/" else {
        throw SourceAccessSettingsError.unsafeLocation(url)
      }
      var ancestry = try DirectoryAccessEvidence.capture(at: directory)
      let homeDepth = home.pathComponents.count
      if ancestry.directories.count == homeDepth, create {
        guard ancestry.directories.last?.owner == geteuid() else {
          throw SourceAccessSettingsError.unsafeLocation(url)
        }
        let homeHandle = try DirectoryHandle(at: home)
        guard try homeHandle.objectIdentity == ancestry.directories.last?.identity else {
          throw SourceAccessSettingsError.changed(url)
        }
        do {
          _ = try homeHandle.createPrivateDirectory(".agents")
        } catch {
          // Another writer may have installed the directory in the same user home.
          guard try homeHandle.info(".agents") != nil else { throw error }
        }
        ancestry = try DirectoryAccessEvidence.capture(at: directory)
      }
      guard ancestry.directories.count == directory.pathComponents.count else { return nil }
      guard ancestry.directories[homeDepth - 1].owner == geteuid(),
        let evidence = ancestry.directories.last, evidence.owner == geteuid()
      else { throw SourceAccessSettingsError.unsafeLocation(url) }
      let parent = try DirectoryHandle(at: directory)
      try evidence.validate(descriptor: parent.descriptor)
      return (parent, ancestry)
    } catch let error as SourceAccessSettingsError {
      throw error
    } catch let exhaustion as OpenFileLimitError {
      throw exhaustion
    } catch {
      throw SourceAccessSettingsError.unsafeLocation(url)
    }
  }
}
