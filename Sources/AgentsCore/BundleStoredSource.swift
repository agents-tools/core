import Foundation

package struct BundleStoredSource: Codable, Sendable {
  package struct Coordinate: Codable, Sendable {
    package let name: String
    package let version: String

    package init(name: String, version: String) {
      self.name = name
      self.version = version
    }
  }

  package let package: Coordinate
  package let componentID: String
  package let sources: [PortableSourceEvidence]
  let treeDigest: String
  package let marketplaceNode: MarketplaceNodeID?

  package init(
    package: Coordinate, componentID: String, sources: [PortableSourceEvidence], treeDigest: String,
    marketplaceNode: MarketplaceNodeID? = nil
  ) {
    self.package = package
    self.componentID = componentID
    self.sources = sources
    self.treeDigest = treeDigest
    self.marketplaceNode = marketplaceNode
  }

  package func recording(_ source: PortableSourceEvidence) -> Self {
    Self(
      package: package, componentID: componentID, sources: sources + [source],
      treeDigest: treeDigest, marketplaceNode: marketplaceNode)
  }

  package static let filename = "bundle-source.json"

  package static func read(
    _ container: URL, snapshot: URL? = nil, expectedKey: String? = nil
  ) throws -> Self {
    let seal = try readMarker(container, expectedKey: expectedKey)
    try seal.validateTree(snapshot ?? container.appendingPathComponent(BundleSourceLocation.tree))
    return seal
  }

  static func readMarker(_ container: URL, expectedKey: String? = nil) throws -> Self {
    let directory = try DirectoryHandle(at: container)
    let bytes = try directory.readRegularFile(filename, maximumBytes: 2 * 1024 * 1024)
    guard FileHash.sha256Hex(data: bytes) == (expectedKey ?? container.lastPathComponent)
    else { throw CoreError.invalidSource("bundle source storage conflicts at " + container.path) }
    try LedgerAdmission.check(bytes, limits: .standard)
    let marker = try JSONDecoder().decode(Self.self, from: bytes)
    guard !marker.sources.isEmpty,
      Set(marker.sources).count == marker.sources.count,
      try ResolvedLedgerCodec.bytes(marker) == bytes
    else { throw CoreError.invalidSource("invalid bundle source evidence") }
    for source in marker.sources { try source.validate() }
    return marker
  }

  func validateTree(_ tree: URL) throws {
    guard try treeDigest == Self.digest(tree) else {
      throw CoreError.invalidSource("bundle source tree was changed at " + tree.path)
    }
  }

  package static func digest(_ tree: URL) throws -> String {
    try ResolvedLedgerCodec.digest([
      FileHash.folderHash(tree), ResolvedLedgerCodec.digest(FileHash.executableFlags(tree)),
    ])
  }
}
