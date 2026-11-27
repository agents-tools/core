import CPlatform
import CSQLite
import Crypto
import Foundation

public enum ClientBackupError: Error, LocalizedError, Sendable {
  case invalidPackage
  case invalidLocation(String)
  case conflict(String)
  case unsupportedLayout(String)
  case storageFailure(String)

  public var errorDescription: String? {
    switch self {
    case .invalidPackage: "The file is not an intact Agents client backup."
    case .invalidLocation(let path): "The backup location is unsafe or unavailable: \(path)"
    case .conflict(let path): "Client data changed or conflicts at \(path)."
    case .unsupportedLayout(let path): "The client data layout is unsupported at \(path)."
    case .storageFailure(let action): "The backup operation failed during \(action)."
    }
  }
}

struct BackupDigest: Codable, Equatable, Sendable {
  let size: Int64
  let hash: String
}

struct BackupFingerprint: Equatable, Sendable {
  let generation: BackupGeneration
  let digest: BackupDigest
  var mode: UInt16 { generation.mode & 0o777 }
}

struct BackupGeneration: Equatable, Sendable {
  let value: stat

  var mode: UInt16 { UInt16(value.st_mode & 0o177777) }
  var identity: FileObjectIdentity { FileObjectIdentity(value) }

  static func == (lhs: Self, rhs: Self) -> Bool {
    DirectoryHandle.sameGeneration(lhs.value, rhs.value)
  }
}

enum BackupIO {
  static let chunkSize = 1024 * 1024

  static func safeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
      && !value.contains("\\") && !value.contains("\0")
  }

  static func components(_ relative: String) throws -> [String] {
    let parts = relative.components(separatedBy: "/")
    guard parts.count <= 128, parts.allSatisfy(safeComponent) else {
      throw ClientBackupError.invalidPackage
    }
    return parts
  }

  static func address(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw ClientBackupError.invalidLocation(url.path)
    }
    return url.standardizedFileURL
  }

  static func originalPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path != "/" && !path.contains("\0")
      && URL(fileURLWithPath: path).standardizedFileURL.path == path
  }

  static func fold(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  static func directory(_ url: URL) throws -> DirectoryHandle? {
    try descend(url) { _ in }
  }

  static func ancestry(_ url: URL) throws -> [FileObjectIdentity] {
    var result: [FileObjectIdentity] = []
    _ = try descend(url) { result.append(try identity($0)) }
    return result
  }

  private static func descend(
    _ url: URL, visit: (DirectoryHandle) throws -> Void
  ) throws -> DirectoryHandle? {
    var current = try DirectoryHandle(at: URL(fileURLWithPath: "/"))
    try visit(current)
    for (index, name) in url.standardizedFileURL.pathComponents.dropFirst().enumerated() {
      guard let value = try current.info(name) else { return nil }
      if index == 0 && platform_system_alias(name) {
        current = try DirectoryHandle(at: current.url.appendingPathComponent(name))
      } else {
        guard value.st_mode & S_IFMT == S_IFDIR else {
          throw ClientBackupError.invalidLocation(url.path)
        }
        current = try current.child(name)
      }
      try visit(current)
    }
    return current
  }

  static func generation(_ parent: DirectoryHandle, _ name: String) throws -> BackupGeneration? {
    try parent.info(name).map(BackupGeneration.init(value:))
  }

  static func identity(_ directory: DirectoryHandle) throws -> FileObjectIdentity {
    var value = stat()
    guard fstat(directory.descriptor, &value) == 0 else {
      throw ClientBackupError.invalidLocation(directory.url.path)
    }
    return FileObjectIdentity(value)
  }

  static func fingerprint(_ url: URL) throws -> BackupFingerprint? {
    guard let parent = try directory(url.deletingLastPathComponent()),
      let before = try generation(parent, url.lastPathComponent)
    else { return nil }
    return try stream(parent, url.lastPathComponent, expecting: before) { _ in }
  }

  static func stream(
    _ parent: DirectoryHandle, _ name: String, expecting before: BackupGeneration,
    consume: (Data) throws -> Void
  ) throws -> BackupFingerprint {
    let path = parent.url.appendingPathComponent(name).path
    guard before.value.st_mode & S_IFMT == S_IFREG else {
      throw ClientBackupError.invalidLocation(path)
    }
    let fd = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw ClientBackupError.invalidLocation(path) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var opened = stat()
    guard fstat(fd, &opened) == 0, before == BackupGeneration(value: opened) else {
      throw ClientBackupError.conflict(path)
    }
    var hash = SHA256()
    var size: Int64 = 0
    while let bytes = try handle.read(upToCount: chunkSize), !bytes.isEmpty {
      size += Int64(bytes.count)
      guard size <= Int64(before.value.st_size) else { throw ClientBackupError.conflict(path) }
      hash.update(data: bytes)
      try consume(bytes)
    }
    guard size == Int64(before.value.st_size), fstat(fd, &opened) == 0,
      before == BackupGeneration(value: opened), try generation(parent, name) == before
    else { throw ClientBackupError.conflict(path) }
    return BackupFingerprint(
      generation: before, digest: BackupDigest(size: size, hash: hex(hash.finalize())))
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  static func write(
    _ name: String, in parent: DirectoryHandle, mode: UInt16 = 0o600,
    _ body: (FileHandle) throws -> Void
  ) throws {
    let fd = openat(
      parent.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw ClientBackupError.invalidLocation(parent.url.appendingPathComponent(name).path)
    }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? output.close() }
    if mode == 0o600 { try FileAccessEvidence.requirePrivate(descriptor: fd) }
    try body(output)
    guard fchmod(fd, mode_t(mode)) == 0 else {
      throw ClientBackupError.storageFailure("setting file permissions")
    }
    try output.synchronize()
  }

  @discardableResult
  static func copy(
    _ source: URL, to parent: DirectoryHandle, named name: String, mode: UInt16 = 0o600
  ) throws -> BackupFingerprint {
    let sourceParent = try DirectoryHandle(at: source.deletingLastPathComponent())
    let sourceName = source.lastPathComponent
    guard let expected = try generation(sourceParent, sourceName) else {
      throw ClientBackupError.conflict(source.path)
    }
    var copied: BackupFingerprint?
    try write(name, in: parent, mode: mode) { output in
      copied = try stream(sourceParent, sourceName, expecting: expected) {
        try output.write(contentsOf: $0)
      }
    }
    guard let copied else { throw ClientBackupError.storageFailure("copying file") }
    return copied
  }
}

/// Only private, engine-owned directories may hold plaintext staging files.
final class BackupScratch: @unchecked Sendable {
  let url: URL

  init(in base: URL = FileManager.default.temporaryDirectory) throws {
    let parent = try DirectoryHandle(at: base.resolvingSymlinksInPath())
    let name = ".agents-backup-" + UUID().uuidString
    let created = try parent.createPrivateDirectory(name)
    url = created.url
  }

  deinit {
    if let parent = try? DirectoryHandle(at: url.deletingLastPathComponent()) {
      try? parent.remove(url.lastPathComponent)
    }
  }

  func open() throws -> DirectoryHandle { try DirectoryHandle(at: url) }

  func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

final class BackupSQL {
  private let db: OpaquePointer
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  enum Value {
    case text(String)
    case integer(Int64)
    case blob(Data)
  }

  init(_ url: URL, writable: Bool = false, immutable: Bool = false) throws {
    var opened: OpaquePointer?
    let flags =
      (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW
      | SQLITE_OPEN_URI
    let canonical = Self.absoluteFileURL(url)
    let path = immutable ? canonical.absoluteString + "?immutable=1" : canonical.path
    let code = sqlite3_open_v2(path, &opened, flags, nil)
    guard code == SQLITE_OK, let opened else {
      let extended = opened.map(sqlite3_extended_errcode) ?? code
      if let opened { sqlite3_close_v2(opened) }
      throw ClientBackupError.storageFailure("opening SQLite data (SQLite \(extended))")
    }
    db = opened
    sqlite3_busy_timeout(db, 1000)
    sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 1)
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 64 * 1024 * 1024)
    try execute("PRAGMA trusted_schema=OFF")
  }

  deinit { sqlite3_close_v2(db) }

  static func absoluteFileURL(_ url: URL) -> URL {
    let path = url.standardizedFileURL.path
    if let first = url.pathComponents.dropFirst().first, platform_system_alias(first) {
      return URL(fileURLWithPath: "/private" + path)
    }
    return URL(fileURLWithPath: path)
  }

  func disableTriggers() throws {
    guard agents_sqlite_disable_triggers(db) == SQLITE_OK else {
      throw ClientBackupError.storageFailure("disabling SQLite triggers")
    }
  }

  func execute(_ sql: String, _ values: [Value] = []) throws {
    try rows(sql, values) { _ in }
  }

  func rows(
    _ sql: String, _ values: [Value] = [], _ visit: (OpaquePointer) throws -> Void
  ) throws {
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
      throw ClientBackupError.storageFailure("preparing SQLite data")
    }
    defer { sqlite3_finalize(prepared) }
    guard sqlite3_bind_parameter_count(prepared) == values.count else {
      throw ClientBackupError.storageFailure("binding SQLite data")
    }
    for (index, value) in values.enumerated() {
      let column = Int32(index + 1)
      let result: Int32
      switch value {
      case .text(let text):
        guard !text.contains("\0") else { throw ClientBackupError.invalidPackage }
        result = sqlite3_bind_text(prepared, column, text, -1, Self.transient)
      case .integer(let number): result = sqlite3_bind_int64(prepared, column, number)
      case .blob(let bytes):
        result = bytes.withUnsafeBytes {
          sqlite3_bind_blob64(
            prepared, column, $0.baseAddress, UInt64($0.count), Self.transient)
        }
      }
      guard result == SQLITE_OK else {
        throw ClientBackupError.storageFailure("binding SQLite data")
      }
    }
    while true {
      switch sqlite3_step(prepared) {
      case SQLITE_DONE: return
      case SQLITE_ROW: try visit(prepared)
      default: throw ClientBackupError.storageFailure("reading or writing SQLite data")
      }
    }
  }

  static func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
    guard sqlite3_column_type(row, column) == SQLITE_TEXT,
      let pointer = sqlite3_column_text(row, column),
      let value = String(
        bytes: UnsafeBufferPointer(
          start: pointer, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8),
      !value.contains("\0")
    else { throw ClientBackupError.invalidPackage }
    return value
  }

  static func integer(_ row: OpaquePointer, _ column: Int32) throws -> Int64 {
    guard sqlite3_column_type(row, column) == SQLITE_INTEGER else {
      throw ClientBackupError.invalidPackage
    }
    return sqlite3_column_int64(row, column)
  }

  static func blob(_ row: OpaquePointer, _ column: Int32, limit: Int) throws -> Data {
    guard sqlite3_column_type(row, column) == SQLITE_BLOB else {
      throw ClientBackupError.invalidPackage
    }
    let count = Int(sqlite3_column_bytes(row, column))
    guard count > 0, count <= limit, let bytes = sqlite3_column_blob(row, column) else {
      throw ClientBackupError.invalidPackage
    }
    return Data(bytes: bytes, count: count)
  }

  func snapshot(into destination: BackupSQL) throws {
    guard let backup = sqlite3_backup_init(destination.db, "main", db, "main") else {
      throw ClientBackupError.storageFailure("starting SQLite snapshot")
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK else {
      throw ClientBackupError.storageFailure("capturing SQLite snapshot")
    }
  }

  func verify() throws {
    var count = 0
    try rows("PRAGMA quick_check(1)") { row in
      guard try Self.text(row, 0) == "ok" else { throw ClientBackupError.invalidPackage }
      count += 1
    }
    guard count == 1 else { throw ClientBackupError.invalidPackage }
  }
}
