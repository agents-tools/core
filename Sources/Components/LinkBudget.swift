import AgentsCore
import Foundation

/// Spent work belongs to the whole search, including rejected candidates and repeated paths.
final class LinkBudget {
  private var steps = 0
  private var snapshots = Set<SourceSnapshotID>()
  private struct Manifest: Hashable {
    let snapshot: SourceSnapshotID
    let path: String
  }
  private var manifests = Set<Manifest>()
  private var bytes = 0
  private var contributions = 0

  func step(_ count: Int = 1) throws {
    try Task.checkCancellation()
    steps += count
    guard steps <= 1_000_000 else { throw LinkError.budget("resolution/evaluation steps") }
  }

  func snapshot(_ value: SourceSnapshotID) throws {
    try step()
    snapshots.insert(value)
    guard snapshots.count <= 256 else { throw LinkError.budget("distinct snapshots") }
  }

  func manifest(_ snapshot: SourceSnapshotID, path: String, bytes count: Int) throws {
    try step()
    if manifests.insert(Manifest(snapshot: snapshot, path: path)).inserted { bytes += count }
    guard bytes <= 16_777_216 else { throw LinkError.budget("aggregate manifest bytes") }
  }

  func contribution(chain: Int) throws {
    try step(1 + chain)
    contributions += 1
    guard contributions <= 10_000 else { throw LinkError.budget("contribution occurrences") }
  }
}
