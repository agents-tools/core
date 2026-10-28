import CPlatform
import Foundation

/// Captures existing ancestry and the final entry without following that entry's link.
/// Missing ancestors may be created, but existing ancestors cannot be exchanged.
package struct PathIdentity {
  private struct Entry: Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32
  }
  private let url: URL
  private let physical: URL
  private let entry: Entry?
  private let ancestors: [(URL, Entry)]

  package init(_ url: URL) throws {
    self.url = url
    physical =
      url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    entry = try Self.read(physical)
    var ancestors: [(URL, Entry)] = []
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

  private static func read(_ url: URL) throws -> Entry? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      if errno == ENOENT { return nil }
      throw CoreError.unsafePath("cannot inspect path: \(url.path)")
    }
    return Entry(
      device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
      kind: UInt32(value.st_mode & 0o170000))
  }
}

/// State bytes and presence belong to the same generation as the rendered targets.
package struct StatePrecondition {
  private let store: StateStore
  private let files: [(URL, PathIdentity, Data?)]

  package init(store: StateStore) throws {
    self.store = store
    files = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      ($0, try PathIdentity($0), try store.existingData($0))
    }
  }

  package func validate() throws {
    for (url, identity, bytes) in files {
      try identity.validate()
      guard try store.existingData(url) == bytes else {
        throw CoreError.invalidState("state changed during preparation: \(url.lastPathComponent)")
      }
    }
  }
}
