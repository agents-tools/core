import Foundation

/// Transaction-owned, content-addressed producer trees for imported bundles.
package enum BundleSourceLocation {
  package static let directory = "bundles"
  package static let tree = "source"

  package static func isKey(_ key: String) -> Bool {
    key.utf8.count == 64
      && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  package static func container(of source: URL, in store: StateStore) -> URL? {
    let container = source.deletingLastPathComponent()
    let root = store.directory.appendingPathComponent(directory)
    guard source.lastPathComponent == tree, isKey(container.lastPathComponent),
      container.deletingLastPathComponent().path == root.path
    else { return nil }
    return container
  }
}
