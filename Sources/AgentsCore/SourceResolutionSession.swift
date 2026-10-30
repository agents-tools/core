import Foundation

/// Owns disposable exact snapshots for one scope-locked preparation.
package final class SourceResolutionSession {
  private struct Snapshot {
    let identity: String
    let source: LockedSource
    let pin: SourceRevision
    let root: URL
  }
  private let store: StateStore
  private let cache: SourceCache
  private let workspace: URL
  private var snapshots: [Snapshot] = []

  package init(store: StateStore) throws {
    self.store = store
    cache = SourceCache(store: store)
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-resolution-" + UUID().uuidString)
    try FileSystem.createDirectory(at: workspace)
  }

  deinit { try? FileManager.default.removeItem(at: workspace) }

  package func withSnapshot<T>(
    _ source: SourceDeclaration, _ body: (SourceRevision, URL) throws -> T
  ) throws -> T {
    let identity = try source.identity(environment: store.environment)
    let effective = LockedSource(
      kind: source.kind, url: source.kind == .git ? source.gitURL : nil,
      requirement: source.requirement, path: source.path)
    if let snapshot = snapshots.first(where: { $0.identity == identity && $0.source == effective })
    {
      return try body(snapshot.pin, snapshot.root)
    }
    let snapshot = try cache.withResolvedSnapshot(source) { pin, tree in
      let root = workspace.appendingPathComponent(UUID().uuidString)
      try FileSystem.withAccessErrors(at: root) {
        try FileManager.default.copyItem(at: tree, to: root)
      }
      return Snapshot(identity: identity, source: effective, pin: pin, root: root)
    }
    snapshots.append(snapshot)
    return try body(snapshot.pin, snapshot.root)
  }
}
