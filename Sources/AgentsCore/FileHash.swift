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
    let directory = directory.resolvingSymlinksInPath()
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
    else {
      throw CoreError.notFound("content directory: \(directory.path)")
    }
    var entries: [(String, Data)] = []
    for case let url as URL in enumerator {
      let relative = PathSafety.relativePath(url.path, to: directory.path)
      let values = try url.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
      ])
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        entries.append(
          (
            relative,
            Data(
              ("link\0" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)))
                .utf8)
          ))
      } else if values.isDirectory == true {
        entries.append((relative, Data("directory".utf8)))
      } else if values.isRegularFile == true {
        entries.append((relative, Data("file\0".utf8) + (try Data(contentsOf: url))))
      } else {
        throw CoreError.invalidState("unsupported content entry: \(relative)")
      }
    }
    var hasher = SHA256()
    for (path, content) in entries.sorted(by: { $0.0 < $1.0 }) {
      hasher.update(data: Data(path.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: content)
      hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
