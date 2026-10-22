import CryptoKit
import Foundation

package enum FileHash {
  package static func sha256Hex(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  package static func sha256Hex(file: URL) throws -> String {
    try sha256Hex(data: Data(contentsOf: file))
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
    var entries: [(String, Data)] = []
    func collect(_ directory: DirectoryHandle, prefix: String) throws {
      for name in try directory.names() {
        let path = prefix + name
        guard let info = try directory.info(name) else { throw CoreError.notFound(path) }
        switch info.st_mode & 0o170000 {
        case 0o120000:
          entries.append((path, Data(("link\0" + (try directory.readLink(name))).utf8)))
        case 0o040000:
          entries.append((path, Data("directory".utf8)))
          try collect(directory.child(name), prefix: path + "/")
        case 0o100000:
          entries.append((path, Data("file\0".utf8) + (try directory.read(name))))
        default: throw CoreError.invalidState("unsupported content entry: \(path)")
        }
      }
    }
    try collect(directory, prefix: "")
    var hasher = SHA256()
    // Each field has a fixed-width byte length, so arbitrary payload bytes cannot
    // impersonate paths, entry types or record boundaries.
    for (path, content) in entries.sorted(by: { $0.0 < $1.0 }) {
      for field in [Data(path.utf8), content] {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: field)
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
