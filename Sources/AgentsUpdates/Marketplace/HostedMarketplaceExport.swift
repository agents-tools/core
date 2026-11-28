import AgentsCore
import Foundation

extension MarketplaceOperations {
  public static var hostedIndexFilename: String { HostedMarketplaceLocation.indexFilename }

  /// Adds a verified native bundle to an existing local staging directory and returns the
  /// index file URL. The visible index is replaced only after its archives are durable.
  @discardableResult
  public static func exportHostedBundle(
    _ archive: Data, to directory: URL, summary: String? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> URL {
    let inspection = try BundleOperations.inspect(archive)
    let policy = try AuthorPackagePolicy(environment, registrySchemas: registrySchemas)
    _ = try policy.admit(inspection.archive)
    try policy.admitCatalog(directory, package: inspection.package)
    try policy.validate()
    return try exportHostedBundle(
      archive, to: directory, summary: summary, inspection: inspection,
      validatePolicy: policy.validate, beforeIndexReplacement: {})
  }

  static func exportHostedBundle(
    _ archive: Data, to directory: URL, summary: String?,
    inspection: BundleInspection? = nil, validatePolicy: () throws -> Void = {},
    beforeIndexReplacement: () throws -> Void
  ) throws -> URL {
    let bundle = try inspection ?? BundleOperations.inspect(archive)
    let coordinate = try MarketplaceCoordinate(
      package: bundle.package.name, version: bundle.package.version)
    let entry = HostedMarketplaceIndex.Entry(
      coordinate: coordinate, archiveDigest: bundle.archiveDigest, archiveByteCount: archive.count,
      summary: summary, archivePath: coordinate.releasePath + "/" + ReleaseMetadata.archiveName)
    try entry.metadata.validate()
    guard archive.count <= LedgerLimits.standard.objectBytes else {
      throw HostedMarketplaceError.responseTooLarge
    }
    try validatePolicy()
    let root = try DirectoryHandle.readDirectory(at: directory)
    let indexName = hostedIndexFilename
    let indexURL = directory.appendingPathComponent(indexName)
    return try FileLock.withLock(in: root, named: ".marketplace.lock") {
      try validatePolicy()
      let existing = try root.readRegularFileIfPresent(
        indexName, maximumBytes: HostedMarketplaceIndex.maximumBytes)
      var entries =
        try existing.map {
          try HostedMarketplaceIndex.read(
            $0, maximumReleases: HostedMarketplaceIndex.maximumReleases
          )
          .releases
        } ?? []
      for published in entries {
        try Task.checkCancellation()
        let bytes = try readArchive(published, in: root)
        let package = try BundleOperations.inspect(bytes).package
        guard package.name == published.coordinate.package,
          package.version == published.coordinate.version
        else { throw MarketplaceError.integrityMismatch(published.coordinate.label) }
      }
      if let published = entries.first(where: { $0.coordinate == coordinate }) {
        guard published.archiveDigest == entry.archiveDigest,
          published.archiveByteCount == entry.archiveByteCount
        else { throw MarketplaceError.publicationConflict(coordinate.label) }
        try validatePolicy()
        return indexURL
      }
      entries.append(entry)
      let next = HostedMarketplaceIndex(
        formatVersion: 1, releases: entries.sorted(by: HostedMarketplaceIndex.Entry.ordered))
      let indexBytes = try ResolvedLedgerCodec.bytes(next)
      _ = try HostedMarketplaceIndex.read(
        indexBytes, maximumReleases: HostedMarketplaceIndex.maximumReleases)

      try validatePolicy()
      let releases = try root.createDirectoryIfAbsent("releases")
      let package = try releases.createDirectoryIfAbsent(coordinate.package)
      if try !package.publishDirectory(
        named: coordinate.version, files: [ReleaseMetadata.archiveName: archive])
      {
        guard let bytes = try? readArchive(entry, in: root), bytes == archive else {
          throw MarketplaceError.publicationConflict(coordinate.label)
        }
      }
      try root.publishIndex(indexName, data: indexBytes) {
        try Task.checkCancellation()
        try validatePolicy()
        try beforeIndexReplacement()
      }
      return indexURL
    }
  }

  private static func readArchive(_ entry: HostedMarketplaceIndex.Entry, in root: DirectoryHandle)
    throws -> Data
  {
    let parts = entry.archivePath.split(separator: "/").map(String.init)
    var directory = root
    for part in parts.dropLast() {
      guard let child = try directory.directory(part) else {
        throw MarketplaceError.integrityMismatch(entry.coordinate.label)
      }
      directory = child
    }
    let bytes = try directory.readRegularFile(parts.last!, maximumBytes: entry.archiveByteCount)
    try entry.metadata.validateArchive(bytes)
    return bytes
  }
}
