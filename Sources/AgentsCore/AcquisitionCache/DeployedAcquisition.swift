import Foundation

extension AcquisitionCache {
  package static let deployedFileLimit = 4 * 1024 * 1024
  private static let deployedStoreLimit: Int64 = 256 * 1024 * 1024

  /// Reads a disposable copy of bytes addressed by a digest the caller already trusts.
  /// Absence or an integrity mismatch requires recovery from the caller's authoritative state.
  public func verifiedDeployedBytes(sha256 digest: String) throws -> Data? {
    let hash = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
    guard hash.utf8.count == 64,
      hash.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else { throw AcquisitionCacheError.invalidEntry }
    return try? read(.deployed, key: hash, maximumBytes: Self.deployedFileLimit) {
      guard FileHash.sha256Hex(data: $0.data) == hash else {
        throw AcquisitionCacheError.invalidEntry
      }
      return $0.data
    }
  }

  /// The installation owner must verify these bytes against its anonymous source and
  /// the completed deployment before publication.
  package func rememberDeployedBytes(_ data: Data) throws {
    guard data.count <= Self.deployedFileLimit else { return }
    let key = FileHash.sha256Hex(data: data)
    if try verifiedDeployedBytes(sha256: key) != nil { return }
    let current = try publication(.deployed, key: key)
    try write(
      data, store: .deployed, key: key, object: key,
      condition: current.map(WriteCondition.publication) ?? .absent,
      totalLimit: Self.deployedStoreLimit)
  }
}
