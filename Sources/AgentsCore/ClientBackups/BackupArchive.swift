import CPlatform
import CSQLite
import Crypto
import Foundation

struct BackupHeader: Codable, Equatable, Sendable {
  let client: BackupClient
  let sourceHome: String
  let sourceClient: String
  let sourceDatabase: String
  let projects: [String]
}

struct BackupEntry: Codable, Equatable, Sendable {
  let number: Int64
  let root: String
  let path: String
  let mode: UInt16
  let digest: BackupDigest
}

struct BackupManifest: Codable, Equatable, Sendable {
  let header: BackupHeader
  var entries: [BackupEntry]

  func hash() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return FileHash.sha256Hex(data: try encoder.encode(self))
  }
}

final class BackupArchive {
  private static let applicationID: Int64 = 0x4147_424b
  private static let version: Int64 = 1
  private static let schema = [
    "CREATE TABLE header (id INTEGER PRIMARY KEY CHECK (id=1), json BLOB NOT NULL, digest TEXT NOT NULL)",
    "CREATE TABLE files (id INTEGER PRIMARY KEY, root TEXT NOT NULL, path TEXT NOT NULL, mode INTEGER NOT NULL, size INTEGER NOT NULL, digest TEXT NOT NULL)",
    "CREATE TABLE chunks (file INTEGER NOT NULL, part INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY(file,part)) WITHOUT ROWID",
  ]
  private let db: BackupSQL
  let readGeneration: BackupGeneration?
  private(set) var manifest: BackupManifest

  init(writing name: String, in directory: DirectoryHandle, header: BackupHeader) throws {
    readGeneration = nil
    try BackupIO.write(name, in: directory) { _ in }
    db = try BackupSQL(directory.url.appendingPathComponent(name), writable: true)
    manifest = BackupManifest(header: header, entries: [])
    try db.execute("PRAGMA application_id=\(Self.applicationID)")
    try db.execute("PRAGMA user_version=\(Self.version)")
    try db.execute("BEGIN IMMEDIATE")
    for table in Self.schema { try db.execute(table) }
  }

  init(reading url: URL) throws {
    _ = try BackupIO.address(url)
    guard let parent = try BackupIO.directory(url.deletingLastPathComponent()),
      let value = try BackupIO.generation(parent, url.lastPathComponent),
      value.value.st_mode & S_IFMT == S_IFREG
    else { throw ClientBackupError.invalidPackage }
    readGeneration = value
    db = try BackupSQL(url, immutable: true)
    var applicationID: Int64?
    var version: Int64?
    try db.rows("PRAGMA application_id") { applicationID = try BackupSQL.integer($0, 0) }
    try db.rows("PRAGMA user_version") { version = try BackupSQL.integer($0, 0) }
    guard applicationID == Self.applicationID, version == Self.version else {
      throw ClientBackupError.invalidPackage
    }
    var actual: [String] = []
    try db.rows("SELECT sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") {
      actual.append(try BackupSQL.text($0, 0))
    }
    guard actual.sorted() == Self.schema.sorted() else { throw ClientBackupError.invalidPackage }
    try db.verify()
    var header: BackupHeader?
    var hash: String?
    try db.rows("SELECT json,digest FROM header WHERE id=1") { row in
      header = try JSONDecoder().decode(
        BackupHeader.self, from: BackupSQL.blob(row, 0, limit: 4 * 1024 * 1024))
      hash = try BackupSQL.text(row, 1)
    }
    guard let header,
      [header.sourceHome, header.sourceClient, header.sourceDatabase].allSatisfy({
        $0 == "/" || BackupIO.originalPath($0)
      }), header.projects.allSatisfy(BackupIO.originalPath),
      Set(header.projects.map(BackupIO.fold)).count == header.projects.count
    else { throw ClientBackupError.invalidPackage }
    var entries: [BackupEntry] = []
    var paths = Set<String>()
    try db.rows("SELECT id,root,path,mode,size,digest FROM files ORDER BY id") { row in
      let number = try BackupSQL.integer(row, 0)
      let root = try BackupSQL.text(row, 1)
      let path = try BackupSQL.text(row, 2)
      let mode = try BackupSQL.integer(row, 3)
      let size = try BackupSQL.integer(row, 4)
      let digest = try BackupSQL.text(row, 5)
      let components = try BackupIO.components(path)
      guard number == Int64(entries.count + 1), (0...0o777).contains(mode), size >= 0,
        digest.utf8.count == 64, digest.utf8.allSatisfy(Self.isHex),
        BackupScope.allows(
          header.client, root: root, components: components, projects: header.projects),
        paths.insert(root + ":" + BackupIO.fold(path)).inserted
      else { throw ClientBackupError.invalidPackage }
      entries.append(
        BackupEntry(
          number: number, root: root, path: path, mode: UInt16(mode),
          digest: BackupDigest(size: size, hash: digest)))
    }
    manifest = BackupManifest(header: header, entries: entries)
    guard try manifest.hash() == hash,
      try BackupIO.generation(parent, url.lastPathComponent) == value
    else { throw ClientBackupError.invalidPackage }
    try db.rows(
      "SELECT 1 FROM chunks WHERE file<1 OR file>? LIMIT 1", [.integer(Int64(entries.count))]
    ) {
      _ in throw ClientBackupError.invalidPackage
    }
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }

  func add(
    root: String, path: String, mode: UInt16, parent: DirectoryHandle, name: String,
    generation: BackupGeneration
  ) throws {
    let number = Int64(manifest.entries.count + 1)
    var part: Int64 = 0
    let fingerprint = try BackupIO.stream(parent, name, expecting: generation) { bytes in
      try db.execute(
        "INSERT INTO chunks VALUES (?,?,?)", [.integer(number), .integer(part), .blob(bytes)])
      part += 1
    }
    let entry = BackupEntry(
      number: number, root: root, path: path, mode: mode, digest: fingerprint.digest)
    try db.execute(
      "INSERT INTO files VALUES (?,?,?,?,?,?)",
      [
        .integer(number), .text(root), .text(path), .integer(Int64(mode)),
        .integer(entry.digest.size), .text(entry.digest.hash),
      ])
    manifest.entries.append(entry)
  }

  func finish() throws {
    try db.execute(
      "INSERT INTO header VALUES (1,?,?)",
      [
        .blob(try JSONEncoder().encode(manifest.header)), .text(try manifest.hash()),
      ])
    try db.execute("COMMIT")
  }

  func read(_ entry: BackupEntry, _ consume: (Data) throws -> Void = { _ in }) throws {
    var hash = SHA256()
    var size: Int64 = 0
    var part: Int64 = 0
    try db.rows(
      "SELECT part,bytes FROM chunks WHERE file=? ORDER BY part", [.integer(entry.number)]
    ) { row in
      let bytes = try BackupSQL.blob(row, 1, limit: BackupIO.chunkSize)
      guard try BackupSQL.integer(row, 0) == part,
        Int64(bytes.count) <= entry.digest.size - size
      else { throw ClientBackupError.invalidPackage }
      size += Int64(bytes.count)
      part += 1
      hash.update(data: bytes)
      try consume(bytes)
    }
    guard size == entry.digest.size, BackupIO.hex(hash.finalize()) == entry.digest.hash else {
      throw ClientBackupError.invalidPackage
    }
  }

  func extract(_ entry: BackupEntry, to parent: DirectoryHandle, named name: String) throws {
    try BackupIO.write(name, in: parent) { output in
      try read(entry) { try output.write(contentsOf: $0) }
    }
  }
}
