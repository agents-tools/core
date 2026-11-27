import Crypto
import Foundation

package enum FileHash {
  package static func sha256Hex(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func matchesGitBlob(_ bytes: Data, object: String) -> Bool {
    let header = Data("blob \(bytes.count)\u{0}".utf8)
    func matches<H: HashFunction>(_ hasher: H) -> Bool {
      var hasher = hasher
      hasher.update(data: header)
      hasher.update(data: bytes)
      return hasher.finalize().map { String(format: "%02x", $0) }.joined() == object
    }
    return object.count == 40 ? matches(Insecure.SHA1()) : matches(SHA256())
  }

  package static func sha256Hex(file: URL) throws -> String {
    try sha256Hex(data: FileSystem.read(at: file))
  }

  /// Hashes every tree entry in path order, including hidden files and symlink destinations.
  package static func folderHash(_ directory: URL) throws -> String {
    try folderHash(DirectoryHandle(at: directory.resolvingSymlinksInPath()))
  }

  /// Execute permission is compared separately from the persistent content hash.
  package static func executableFlags(_ directory: URL) throws -> [String: Bool] {
    try executableFlags(DirectoryHandle(at: directory.resolvingSymlinksInPath()))
  }

  static func executableFlags(_ directory: DirectoryHandle) throws -> [String: Bool] {
    var flags: [String: Bool] = [:]
    func collect(_ directory: DirectoryHandle, prefix: String) throws {
      for name in try directory.names() {
        guard let info = try directory.info(name) else { throw CoreError.notFound(prefix + name) }
        switch info.st_mode & 0o170000 {
        case 0o040000: try collect(directory.child(name), prefix: prefix + name + "/")
        case 0o100000: flags[prefix + name] = info.st_mode & 0o111 != 0
        case 0o120000: break
        default: throw CoreError.invalidState("unsupported content entry: \(prefix + name)")
        }
      }
    }
    try collect(directory, prefix: "")
    return flags
  }

  static func folderHash(_ directory: DirectoryHandle) throws -> String {
    struct Entry {
      let name: String
      let info: stat
      let descendants: Bool

      var key: String { descendants ? name + "/" : name }
    }

    var hasher = SHA256()
    let regularFilePrefix = Data("file\0".utf8)
    func collect(_ directory: DirectoryHandle, prefix: String) throws {
      var entries: [Entry] = []
      for name in try directory.names() {
        guard let info = try directory.info(name) else { throw CoreError.notFound(prefix + name) }
        entries.append(Entry(name: name, info: info, descendants: false))
        if info.st_mode & 0o170000 == 0o040000 {
          entries.append(Entry(name: name, info: info, descendants: true))
        }
      }
      // A directory record and its descendants have different sort keys. For example,
      // "rules-extra" sorts between "rules" and "rules/guide".
      for entry in entries.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
        let path = prefix + entry.key
        if entry.descendants {
          try collect(directory.child(entry.name, matching: entry.info), prefix: path)
          continue
        }
        appendField(Data(path.utf8), to: &hasher)
        switch entry.info.st_mode & 0o170000 {
        case 0o120000:
          let link = try directory.readLink(entry.name)
          guard let current = try directory.info(entry.name),
            DirectoryHandle.sameGeneration(entry.info, current)
          else { throw CoreError.invalidState("link changed while reading: \(path)") }
          appendField(Data(("link\0" + link).utf8), to: &hasher)
        case 0o040000:
          appendField(Data("directory".utf8), to: &hasher)
        case 0o100000:
          guard let size = Int(exactly: entry.info.st_size), size >= 0 else {
            throw CoreError.invalidState("invalid file length: \(path)")
          }
          appendLength(UInt64(size) + UInt64(regularFilePrefix.count), to: &hasher)
          hasher.update(data: regularFilePrefix)
          let read = try directory.readChunks(entry.name, matching: entry.info, maximumBytes: size)
          {
            hasher.update(bufferPointer: $0)
          }
          guard read == size else {
            throw CoreError.invalidState("file changed while reading: \(path)")
          }
        default: throw CoreError.invalidState("unsupported content entry: \(path)")
        }
      }
    }
    try collect(directory, prefix: "")
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func hashRecords(_ entries: [(String, Data)]) -> String {
    var hasher = SHA256()
    // Each field has a fixed-width byte length, so arbitrary payload bytes cannot
    // impersonate paths, entry types or record boundaries.
    for (path, content) in entries.sorted(by: { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }) {
      appendField(Data(path.utf8), to: &hasher)
      appendField(content, to: &hasher)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func portableTreeHash(_ entries: [LedgerEntry], objects: [String: Data]) throws -> String {
    var hasher = SHA256()
    let regularFilePrefix = Data("file\0".utf8)
    for entry in entries where entry.path != "." {
      try Task.checkCancellation()
      appendField(Data(entry.path.utf8), to: &hasher)
      switch entry.kind {
      case .directory: appendField(Data("directory".utf8), to: &hasher)
      case .symlink: appendField(Data(("link\0" + entry.link!).utf8), to: &hasher)
      case .file:
        guard let id = entry.object, let data = objects[id] else {
          throw CoreError.invalidState("file missing from captured tree")
        }
        appendLength(UInt64(data.count) + UInt64(regularFilePrefix.count), to: &hasher)
        hasher.update(data: regularFilePrefix)
        hasher.update(data: data)
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func appendField(_ field: Data, to hasher: inout SHA256) {
    appendLength(UInt64(field.count), to: &hasher)
    hasher.update(data: field)
  }

  private static func appendLength(_ count: UInt64, to hasher: inout SHA256) {
    var length = count.bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
  }
}
