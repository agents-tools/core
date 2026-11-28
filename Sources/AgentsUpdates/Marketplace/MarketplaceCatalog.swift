import AgentsCore
import AgentsManifest
import Foundation

/// A catalog name in a front end's registration list. Project dependencies store the origin.
public struct MarketplaceRegistration: Codable, Equatable, Sendable {
  public let name: String
  public let origin: MarketplaceOrigin

  public init(name: String, origin: MarketplaceOrigin) throws {
    guard MarketplaceCoordinate.isName(name) else { throw MarketplaceError.invalidPackage(name) }
    try origin.validate()
    self.name = name
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey { case name, origin }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: fields.decode(String.self, forKey: .name),
      origin: fields.decode(MarketplaceOrigin.self, forKey: .origin))
  }
}

public struct MarketplaceRelease: Equatable, Sendable {
  public var coordinate: MarketplaceCoordinate { metadata.coordinate }
  public var archiveDigest: String { metadata.archiveDigest }
  public var archiveByteCount: Int { metadata.archiveByteCount }
  public var summary: String? { metadata.summary }
  public let origin: MarketplaceOrigin
  public let catalogCommit: String?
  let metadata: ReleaseMetadata
  let originPath: String?
  var hosted: HostedReleaseLocation? = nil

  public var indexDigest: String? { hosted?.indexDigest }

  func policyOrigin() throws -> SourceOrigin {
    if let originPath { return .local(path: originPath) }
    return try origin.remotePolicyOrigin()
  }
}

/// One catalog observation. Registration carries no write to consumer configuration.
public struct MarketplaceCatalog: Sendable {
  public let registration: MarketplaceRegistration
  public let catalogCommit: String?
  public let releases: [MarketplaceRelease]
  public let indexDigest: String?

  /// Case-insensitive substring search over the package name and release summary.
  public func search(_ query: String) -> [MarketplaceRelease] {
    guard !query.isEmpty else { return releases }
    return releases.filter {
      $0.coordinate.package.range(of: query, options: .caseInsensitive) != nil
        || $0.summary?.range(of: query, options: .caseInsensitive) != nil
    }
  }

  /// Selects an exact version or the highest available SemVer precedence.
  public func select(package: String, version: String? = nil) throws -> MarketplaceRelease {
    guard
      let release = releases.first(where: {
        $0.coordinate.package == package && (version == nil || $0.coordinate.version == version)
      })
    else { throw MarketplaceError.releaseNotFound(package + (version.map { "@" + $0 } ?? "")) }
    return release
  }

  /// Available higher versions for this exact origin. A changed digest at a locked coordinate
  /// is an integrity failure even when newer versions are present.
  public func updates(for pin: MarketplacePin) throws -> [MarketplaceRelease] {
    guard registration.origin == pin.dependency.catalog else {
      throw MarketplaceError.originConflict(pin.dependency.name)
    }
    let coordinate = pin.dependency.coordinate
    if let current = releases.first(where: { $0.coordinate == coordinate }),
      current.archiveDigest != pin.archiveDigest
    {
      throw MarketplaceError.integrityMismatch(coordinate.label)
    }
    return releases.filter {
      $0.coordinate.package == coordinate.package
        && $0.coordinate.hasHigherPrecedence(than: coordinate)
    }
  }
}

/// The exact bytes verified against the immutable release observation. The bundle importer
/// validates their format, package coordinates, selections and producer evidence.
public struct VerifiedMarketplacePackage: Sendable {
  public let release: MarketplaceRelease
  public let archive: Data

  public let hostedEvidence: HostedMarketplaceEvidence?

  init(
    release: MarketplaceRelease, archive: Data, hostedEvidence: HostedMarketplaceEvidence? = nil
  ) {
    self.hostedEvidence = hostedEvidence
    self.release = release
    self.archive = archive
  }
}

public enum MarketplaceOperations {
  /// Publishes an archive already admitted by its format owner. The callback returns the
  /// coordinate read from that archive. The catalog root must exist.
  @discardableResult
  public static func publish(
    _ archive: Data, to directory: URL, summary: String? = nil,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = [],
    inspecting inspect: (Data) throws -> MarketplaceCoordinate
  ) throws -> MarketplaceRelease {
    try ReleaseMetadata.validateSize(archive.count)
    let coordinate = try inspect(archive)
    if let bundle = try? BundleOperations.inspect(archive) {
      guard bundle.package.name == coordinate.package, bundle.package.version == coordinate.version
      else { throw MarketplaceError.integrityMismatch(coordinate.label) }
      return try publishAdmitted(
        archive, inspection: bundle, to: directory, summary: summary, scope: scope,
        environment: environment, registrySchemas: registrySchemas)
    }
    let policy = try AuthorPackagePolicy(environment, scope: scope)
    try AuthorPackageOperations.requireLocalFileURL(directory)
    let destination = try PathIdentity(directory)
    let package = BundlePackage(name: coordinate.package, version: coordinate.version)
    try policy.admit(package)
    try policy.source.effective.require(.missing, reference: coordinate.package)
    try policy.organization.admit(policy.organization.evaluator.source(.missing))
    try policy.admitCatalog(directory, package: package)
    return try publish(archive, coordinate: coordinate, to: directory, summary: summary) {
      try policy.validate()
      try destination.validate()
    }
  }

  static func publish(
    _ archive: Data, coordinate: MarketplaceCoordinate, to directory: URL, summary: String?,
    beforeCommit: () throws -> Void
  ) throws -> MarketplaceRelease {
    try ReleaseMetadata.validateSize(archive.count)
    let metadata = ReleaseMetadata(
      coordinate: coordinate, archiveDigest: ReleaseMetadata.digest(archive),
      archiveByteCount: archive.count, summary: summary)
    try metadata.validate()
    let origin = try MarketplaceOrigin(
      kind: .directory, location: directory.standardizedFileURL.path)
    let root = try DirectoryHandle.readDirectory(at: directory)
    let path = SourceOrigin.local(at: directory).identity
    try beforeCommit()
    let releases = try root.createDirectoryIfAbsent("releases")
    let package = try releases.createDirectoryIfAbsent(coordinate.package)
    let bytes = try ResolvedLedgerCodec.bytes(metadata)
    if try package.directory(coordinate.version) == nil,
      try package.publishDirectory(
        named: coordinate.version,
        files: [
          ReleaseMetadata.filename: bytes, ReleaseMetadata.archiveName: archive,
        ], beforeCommit: beforeCommit)
    {
      return MarketplaceRelease(
        origin: origin, catalogCommit: nil, metadata: metadata, originPath: path)
    }
    guard let existing = try package.directory(coordinate.version),
      try ReleaseMetadata.read(in: existing, at: coordinate) == metadata
    else { throw MarketplaceError.publicationConflict(coordinate.label) }
    guard try metadata.readArchive(in: existing) == archive else {
      throw MarketplaceError.publicationConflict(coordinate.label)
    }
    return MarketplaceRelease(
      origin: origin, catalogCommit: nil, metadata: metadata, originPath: path)
  }

  /// Reads release metadata from a local directory, exact Git tree or hosted HTTPS index.
  public static func browse(
    _ registration: MarketplaceRegistration, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> MarketplaceCatalog {
    try withObservedCatalog(
      registration.origin, scope: scope, environment: environment,
      maximumReleases: LedgerLimits.standard.entries, hostedAccess: hostedAccess
    ) { observed in
      MarketplaceCatalog(
        registration: registration, catalogCommit: observed.commit, releases: observed.releases,
        indexDigest: observed.indexDigest)
    }
  }

  static func withObservedCatalog<T>(
    _ origin: MarketplaceOrigin, scope: InstallScope, environment: RuntimeEnvironment,
    maximumReleases: Int, expectedOrigin: SourceOrigin? = nil,
    requireRecordedTransport: Bool = false, hostedAccess: HostedMarketplaceAccess? = nil,
    organizationPolicy: OrganizationPolicySnapshot? = nil,
    trustedRegistration: TargetPrecondition? = nil, _ body: (ObservedMarketplaceCatalog) throws -> T
  ) throws -> T {
    if origin.kind == .hosted {
      try origin.validate()
      let store = StateStore(scope: scope, environment: environment)
      let policy = try SourcePolicySnapshot(store: store)
      let organization = try organizationPolicy ?? OrganizationPolicySnapshot(store: store)
      let reader = try HostedMarketplaceReader(
        origin: origin, store: store, access: hostedAccess, policy: policy,
        organization: organization,
        trustedRegistration: trustedRegistration)
      if let expectedOrigin, expectedOrigin != reader.index.origin {
        throw MarketplaceError.originConflict(origin.location)
      }
      return try body(reader.observe(origin: origin, maximumReleases: maximumReleases))
    }
    return try withCatalog(
      origin, commit: nil, scope: scope, environment: environment, expectedOrigin: expectedOrigin,
      requireRecordedTransport: requireRecordedTransport
    ) { root, commit, source in
      let path = source.kind == .local ? source.identity : nil
      var entries: [MarketplaceRelease] = []
      if let releases = try root.directory("releases") {
        for name in try releases.names(maximumCount: maximumReleases) where !name.hasPrefix(".") {
          guard MarketplaceCoordinate.isName(name), let package = try releases.directory(name)
          else { throw MarketplaceError.invalidPackage(name) }
          for version in try package.names(maximumCount: maximumReleases)
          where !version.hasPrefix(".") {
            try Task.checkCancellation()
            guard entries.count < maximumReleases else {
              throw MarketplaceError.resolutionLimit("catalog release metadata")
            }
            let coordinate = try MarketplaceCoordinate(package: name, version: version)
            guard let directory = try package.directory(version) else {
              throw MarketplaceError.invalidPackage(coordinate.label)
            }
            let metadata = try ReleaseMetadata.read(in: directory, at: coordinate)
            entries.append(
              MarketplaceRelease(
                origin: origin, catalogCommit: commit, metadata: metadata, originPath: path))
          }
        }
      }
      return try body(
        ObservedMarketplaceCatalog(
          location: .directory(root), commit: commit, indexDigest: nil,
          releases: entries.sorted {
            if $0.coordinate.package != $1.coordinate.package {
              return $0.coordinate.package < $1.coordinate.package
            }
            return MarketplaceCoordinate.newer($0.coordinate, than: $1.coordinate)
          }))
    }
  }

  /// Reads from the selected Git commit or directory and verifies metadata and archive bytes.
  /// A moving Git ref never changes the observation used for this acquisition.
  public static func acquire(
    _ release: MarketplaceRelease, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> VerifiedMarketplacePackage {
    let origin = try release.policyOrigin()
    let store = StateStore(scope: scope, environment: environment)
    let organization = try OrganizationPolicySnapshot(store: store)
    if release.origin.kind == .hosted {
      return try HostedMarketplaceReader(
        origin: release.origin, store: store, access: hostedAccess,
        policy: SourcePolicySnapshot(store: store), organization: organization
      ).acquire(release)
    }
    try organization.admit(
      organization.evaluator.packageIdentity(
        .init(origin, suffix: release.coordinate.package, root: release.origin.subpath),
        catalog: .init(origin, root: release.origin.subpath)))
    try organization.validate()
    return try withRelease(
      release.coordinate, origin: release.origin, commit: release.catalogCommit,
      scope: scope, environment: environment, expectedOrigin: origin,
      requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin
    ) { directory, current, _ in
      guard current == release.metadata else {
        throw MarketplaceError.integrityMismatch(release.coordinate.label)
      }
      return VerifiedMarketplacePackage(
        release: release, archive: try current.readArchive(in: directory))
    }
  }

  /// Reacquires the exact archive referenced by a committed pin, including its original
  /// catalog commit. Restore can use the embedded closure without reacquiring the archive.
  public static func acquire(
    _ pin: MarketplacePin, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> VerifiedMarketplacePackage {
    try pin.validate()
    let dependency = pin.dependency
    let store = StateStore(scope: scope, environment: environment)
    let origin = try pin.policyOrigin(environment: store.marketplaceEnvironment)
    let organization = try OrganizationPolicySnapshot(store: store)
    try organization.admit(
      organization.evaluator.packageIdentity(
        .init(origin, suffix: dependency.coordinate.package, root: dependency.catalog.subpath),
        catalog: .init(origin, root: dependency.catalog.subpath)))
    try organization.validate()
    return try withRelease(
      dependency.coordinate, origin: dependency.catalog, commit: pin.catalogCommit,
      scope: scope, environment: environment, expectedOrigin: pin.catalogOrigin,
      additionalOrigin: origin,
      requireRecordedTransport: organization.evaluator.requiresRecordedGitOrigin
    ) { directory, metadata, source in
      guard metadata.archiveDigest == pin.archiveDigest else {
        throw MarketplaceError.integrityMismatch(dependency.coordinate.label)
      }
      let release = MarketplaceRelease(
        origin: dependency.catalog, catalogCommit: pin.catalogCommit, metadata: metadata,
        originPath: source.kind == .local ? source.identity : nil)
      return VerifiedMarketplacePackage(
        release: release, archive: try metadata.readArchive(in: directory))
    }
  }

  private static func withRelease<Result>(
    _ coordinate: MarketplaceCoordinate, origin: MarketplaceOrigin, commit: String?,
    scope: InstallScope, environment: RuntimeEnvironment, expectedOrigin: SourceOrigin?,
    additionalOrigin: SourceOrigin? = nil, requireRecordedTransport: Bool = false,
    _ body: (DirectoryHandle, ReleaseMetadata, SourceOrigin) throws -> Result
  ) throws -> Result {
    try withCatalog(
      origin, commit: commit, scope: scope, environment: environment,
      expectedOrigin: expectedOrigin, additionalOrigin: additionalOrigin,
      requireRecordedTransport: requireRecordedTransport
    ) { root, observedCommit, source in
      guard observedCommit == commit,
        let directory = try root.directory("releases")?.directory(coordinate.package)?
          .directory(coordinate.version)
      else { throw MarketplaceError.releaseNotFound(coordinate.label) }
      let metadata = try ReleaseMetadata.read(in: directory, at: coordinate)
      return try body(directory, metadata, source)
    }
  }

  private static func withCatalog<Result>(
    _ origin: MarketplaceOrigin, commit: String?, scope: InstallScope,
    environment: RuntimeEnvironment, expectedOrigin: SourceOrigin? = nil,
    additionalOrigin: SourceOrigin? = nil, requireRecordedTransport: Bool = false,
    _ body: (DirectoryHandle, String?, SourceOrigin) throws -> Result
  ) throws -> Result {
    try origin.validate()
    let store = StateStore(scope: scope, environment: environment)
    let policy = try SourcePolicySnapshot(store: store)
    let source = try origin.policyOrigin(environment: environment)
    if let expectedOrigin, expectedOrigin != source {
      throw MarketplaceError.originConflict(origin.location)
    }
    if let additionalOrigin, additionalOrigin != source {
      try policy.effective.require(additionalOrigin)
    }
    try policy.effective.require(source)
    let result: Result
    if origin.kind == .directory {
      result = try body(
        DirectoryHandle.readDirectory(at: URL(fileURLWithPath: source.identity!)), nil, source)
    } else {
      let gitSource =
        source.kind == .local
        ? SourceDeclaration(
          kind: .local, location: source.identity!,
          requirement: (commit ?? origin.ref).map(SourceRequirement.revision))
        : origin.gitSource(commit: commit)
      let cache = SourceCache(
        store: store, sourcePolicy: policy.effective,
        requireRecordedTransport: requireRecordedTransport)
      try cache.requireGit(gitSource)
      result = try cache.withResolvedSnapshot(
        gitSource, cacheSource: false
      ) { pin, root in
        var directory = try DirectoryHandle.readDirectory(at: root)
        for name in origin.subpath?.split(separator: "/") ?? [] {
          guard let child = try directory.directory(String(name)) else {
            throw MarketplaceError.invalidOrigin("catalog subpath is absent")
          }
          directory = child
        }
        return try body(directory, pin.revision, source)
      }
    }
    try policy.validate()
    return result
  }
}

/// One catalog observation and its archive acquisition context.
struct ObservedMarketplaceCatalog {
  enum Location {
    case directory(DirectoryHandle)
    case hosted(HostedMarketplaceReader)
  }

  let location: Location
  let commit: String?
  let indexDigest: String?
  let releases: [MarketplaceRelease]

  func acquire(_ release: MarketplaceRelease) throws -> VerifiedMarketplacePackage {
    switch location {
    case .hosted(let reader): return try reader.acquire(release)
    case .directory(let root): return try acquire(release, in: root)
    }
  }

  private func acquire(_ release: MarketplaceRelease, in root: DirectoryHandle) throws
    -> VerifiedMarketplacePackage
  {
    let coordinate = release.coordinate
    guard
      let directory = try root.directory("releases")?.directory(coordinate.package)?
        .directory(coordinate.version),
      try ReleaseMetadata.read(in: directory, at: coordinate) == release.metadata
    else { throw MarketplaceError.integrityMismatch(coordinate.label) }
    return VerifiedMarketplacePackage(
      release: release, archive: try release.metadata.readArchive(in: directory))
  }
}

/// Records a mutable catalog's observed metadata and the archives read by the solver.
struct MarketplaceCatalogInput: Sendable {
  let origin: MarketplaceOrigin
  let source: SourceOrigin
  let releases: [MarketplaceRelease]
  let archives: Set<MarketplaceCoordinate>

  var readLocations: [URL] {
    guard let path = source.identity else { return [] }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    return [root.appendingPathComponent("releases")]
      + releases.flatMap { release in
        let directory = root.appendingPathComponent(release.coordinate.releasePath)
        let metadata = directory.appendingPathComponent(ReleaseMetadata.filename)
        return archives.contains(release.coordinate)
          ? [metadata, directory.appendingPathComponent(ReleaseMetadata.archiveName)] : [metadata]
      }
  }

  func validate(scope: InstallScope, environment: RuntimeEnvironment) throws {
    try MarketplaceOperations.withObservedCatalog(
      origin, scope: scope, environment: environment,
      maximumReleases: MarketplaceSolver.maximumMetadataReleases,
      expectedOrigin: source
    ) { observed in
      guard observed.releases == releases else {
        throw CoreError.invalidState("marketplace catalog changed; refresh the preview")
      }
      for release in observed.releases where archives.contains(release.coordinate) {
        _ = try observed.acquire(release)
      }
    }
  }
}
struct ReleaseMetadata: Codable, Equatable, Sendable {
  static let filename = "release.json"
  static let archiveName = "package.bundle"
  static let maximumMetadataBytes = 8192

  let formatVersion: Int
  let coordinate: MarketplaceCoordinate
  let archiveDigest: String
  let archiveByteCount: Int
  let summary: String?

  init(
    coordinate: MarketplaceCoordinate, archiveDigest: String, archiveByteCount: Int,
    summary: String?
  ) {
    formatVersion = 1
    self.coordinate = coordinate
    self.archiveDigest = archiveDigest
    self.archiveByteCount = archiveByteCount
    self.summary = summary
  }

  static func digest(_ bytes: Data) -> String { "sha256:" + FileHash.sha256Hex(data: bytes) }

  static func validateSize(_ bytes: Int) throws {
    guard bytes > 0, bytes <= LedgerLimits.standard.encodedBytes else {
      throw MarketplaceError.invalidPackage("archive byte limit")
    }
  }

  func validate() throws {
    try coordinate.validate()
    try StateValidation.digest(archiveDigest)
    try Self.validateSize(archiveByteCount)
    guard formatVersion == 1, summary.map({ $0.utf8.count <= 1024 }) ?? true else {
      throw MarketplaceError.invalidPackage(coordinate.label)
    }
  }

  static func read(in directory: DirectoryHandle, at coordinate: MarketplaceCoordinate) throws
    -> Self
  {
    let bytes = try directory.readRegularFile(filename, maximumBytes: maximumMetadataBytes)
    guard let metadata = try? JSONDecoder().decode(Self.self, from: bytes),
      metadata.coordinate == coordinate
    else { throw MarketplaceError.integrityMismatch(coordinate.label) }
    try metadata.validate()
    guard try ResolvedLedgerCodec.bytes(metadata) == bytes,
      try directory.regularFileSize(archiveName) == metadata.archiveByteCount
    else { throw MarketplaceError.integrityMismatch(coordinate.label) }
    return metadata
  }

  func readArchive(in directory: DirectoryHandle) throws -> Data {
    let bytes = try directory.readRegularFile(Self.archiveName, maximumBytes: archiveByteCount)
    try validateArchive(bytes)
    return bytes
  }

  func validateArchive(_ bytes: Data) throws {
    guard bytes.count == archiveByteCount, Self.digest(bytes) == archiveDigest else {
      throw MarketplaceError.integrityMismatch(coordinate.label)
    }
  }
}

extension StateStore {
  /// Relative catalog locators are authored against the owning project or home.
  var marketplaceEnvironment: RuntimeEnvironment {
    var environment = environment
    if scope == .user { environment.projectDirectory = environment.homeDirectory }
    return environment
  }
}
