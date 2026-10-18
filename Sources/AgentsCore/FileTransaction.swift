import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Stages complete replacements, then restores originals if a write fails.
/// Callers hold their scope's writer lock across planning and commit.
package final class FileTransaction {
  private struct Replacement {
    var destination: URL
    var staged: URL?
    var backup: URL
    var atomicFile: Bool
  }
  private var replacements: [Replacement] = []
  private var directories: [URL] = []

  package init() {}

  deinit {
    for entry in replacements {
      if let staged = entry.staged { try? FileManager.default.removeItem(at: staged) }
    }
    for directory in directories.reversed() {
      if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  package func replace(_ destination: URL, content: URL?, link: Bool = false, data: Data? = nil)
    throws
  {
    guard !replacements.contains(where: { $0.destination.path == destination.path }) else {
      throw CoreError.invalidState("duplicate transaction destination: \(destination.path)")
    }
    try createParents(destination.deletingLastPathComponent())
    let base = destination.deletingLastPathComponent().appendingPathComponent(
      ".agents-" + UUID().uuidString)
    let staged = base.appendingPathExtension("new")
    let backup = base.appendingPathExtension("old")
    var replacement = Replacement(
      destination: destination, staged: nil, backup: backup, atomicFile: data != nil)
    replacement.staged = content != nil || data != nil ? staged : nil
    replacements.append(replacement)
    if let data {
      try data.write(to: staged)
      replacement.staged = staged
    } else if let content {
      if link {
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: content)
      } else {
        try FileManager.default.copyItem(at: content, to: staged)
      }
      replacement.staged = staged
    }
    replacements[replacements.count - 1] = replacement
  }

  package func commit() throws {
    var moved: [Replacement] = []
    do {
      for entry in replacements {
        if exists(entry.destination) {
          if entry.atomicFile {
            try FileManager.default.copyItem(at: entry.destination, to: entry.backup)
          } else {
            try FileManager.default.moveItem(at: entry.destination, to: entry.backup)
          }
        }
        moved.append(entry)
        if let staged = entry.staged {
          if entry.atomicFile {
            guard rename(staged.path, entry.destination.path) == 0 else {
              throw CoreError.invalidState("cannot replace state file: \(entry.destination.path)")
            }
          } else {
            try FileManager.default.moveItem(at: staged, to: entry.destination)
          }
        }
      }
    } catch {
      for entry in moved.reversed() {
        if exists(entry.destination) { try FileManager.default.removeItem(at: entry.destination) }
        if exists(entry.backup) {
          try FileManager.default.moveItem(at: entry.backup, to: entry.destination)
        }
      }
      throw error
    }
    for entry in moved where exists(entry.backup) {
      try? FileManager.default.removeItem(at: entry.backup)
    }
  }

  private func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  private func createParents(_ directory: URL) throws {
    guard !exists(directory) else { return }
    try createParents(directory.deletingLastPathComponent())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    directories.append(directory)
  }
}
