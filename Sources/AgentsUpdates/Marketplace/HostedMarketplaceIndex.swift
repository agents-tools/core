import AgentsCore
import AgentsManifest
import Foundation

struct HostedMarketplaceIndex: Codable {
  static let maximumBytes = 8 * 1024 * 1024
  static let maximumReleases = 4096

  struct Entry: Codable {
    let coordinate: MarketplaceCoordinate
    let archiveDigest: String
    let archiveByteCount: Int
    let summary: String?
    let archivePath: String

    var metadata: ReleaseMetadata {
      ReleaseMetadata(
        coordinate: coordinate, archiveDigest: archiveDigest, archiveByteCount: archiveByteCount,
        summary: summary)
    }

    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
      if lhs.coordinate.package != rhs.coordinate.package {
        return lhs.coordinate.package < rhs.coordinate.package
      }
      return MarketplaceCoordinate.newer(lhs.coordinate, than: rhs.coordinate)
    }
  }

  let formatVersion: Int
  let releases: [Entry]

  static func read(_ bytes: Data, maximumReleases: Int)
    throws -> Self
  {
    var limits = LedgerLimits.standard
    limits.encodedBytes = maximumBytes
    limits.nodes = Self.maximumReleases * 16 + 16
    try LedgerAdmission.check(bytes, limits: limits)
    guard let document = try? JSONDecoder().decode(Self.self, from: bytes),
      document.formatVersion == 1
    else { throw MarketplaceError.invalidPackage("invalid hosted marketplace index") }
    guard document.releases.count <= min(maximumReleases, Self.maximumReleases) else {
      throw MarketplaceError.resolutionLimit("catalog release metadata")
    }
    var coordinates = Set<MarketplaceCoordinate>()
    var paths = Set<String>()
    for entry in document.releases {
      try Task.checkCancellation()
      try entry.metadata.validate()
      try HostedMarketplaceLocation.validateArchivePath(entry.archivePath)
      guard entry.archiveByteCount <= LedgerLimits.standard.objectBytes,
        coordinates.insert(entry.coordinate).inserted,
        paths.insert(entry.archivePath).inserted
      else { throw MarketplaceError.invalidPackage("invalid or duplicate hosted release") }
    }
    return document
  }
}

struct HostedReleaseLocation: Equatable, Sendable {
  let archive: HostedMarketplaceLocation
  let indexDigest: String
  let indexRequests: [URL]
}

extension HostedMarketplaceReader {
  func observe(
    origin: MarketplaceOrigin, maximumReleases: Int
  ) throws -> ObservedMarketplaceCatalog {
    let observation = try read(index, maximumBytes: HostedMarketplaceIndex.maximumBytes)
    let effective = try HostedMarketplaceLocation(observation.requests.last!.absoluteString)
    let document = try HostedMarketplaceIndex.read(
      observation.bytes, maximumReleases: maximumReleases)
    let digest = ReleaseMetadata.digest(observation.bytes)
    return try ObservedMarketplaceCatalog(
      location: .hosted(self), commit: nil, indexDigest: digest,
      releases: document.releases.sorted(by: HostedMarketplaceIndex.Entry.ordered).map { entry in
        let archive = try effective.archive(entry.archivePath)
        guard !observation.requests.contains(archive.url) else {
          throw MarketplaceError.invalidPackage("archive points to a hosted marketplace index")
        }
        return MarketplaceRelease(
          origin: origin, catalogCommit: nil, metadata: entry.metadata, originPath: nil,
          hosted: HostedReleaseLocation(
            archive: archive, indexDigest: digest,
            indexRequests: observation.requests))
      })
  }

  func acquire(_ release: MarketplaceRelease) throws -> VerifiedMarketplacePackage {
    guard let hosted = release.hosted else {
      throw MarketplaceError.integrityMismatch(release.coordinate.label)
    }
    // A release can outlive its browse operation. Re-admit the observed index redirects
    // before reading the archive, even when their URLs will not be contacted again.
    try Self.requireRequests(
      hosted.indexRequests, index: index, coordinate: release.coordinate,
      policy: policy.effective, organization: organization)
    let archive = try read(
      hosted.archive, coordinate: release.coordinate, maximumBytes: release.archiveByteCount)
    let evidence = HostedMarketplaceEvidence(
      indexDigest: hosted.indexDigest, archiveByteCount: release.archiveByteCount,
      indexRequests: hosted.indexRequests, archiveRequests: archive.requests)
    try evidence.validate(index: release.origin.location)
    try release.metadata.validateArchive(archive.bytes)
    let result = VerifiedMarketplacePackage(
      release: release, archive: archive.bytes, hostedEvidence: evidence)
    _ = try result.inspectBundle()
    return result
  }

  static func requireRequests(
    _ requests: [URL], index: HostedMarketplaceLocation, coordinate: MarketplaceCoordinate,
    policy: EffectiveSourcePolicy, organization: OrganizationPolicySnapshot
  ) throws {
    for url in requests {
      let request = try HostedMarketplaceLocation(url.absoluteString)
      try policy.require(request.origin, reference: coordinate.label)
      try organization.admit(
        findings(
          for: request, index: index, coordinate: coordinate, evaluator: organization.evaluator))
    }
  }
}
