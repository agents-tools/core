import Foundation

public enum MarketplaceError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidOrigin(String)
  case invalidPackage(String)
  case releaseNotFound(String)
  case publicationConflict(String)
  case integrityMismatch(String)
  case originConflict(String)
  case missingPin(String)
  case selectionMismatch(String)
  case contributionMismatch(String)
  case unsatisfiable(String)
  case dependencyCycle(String)
  case resolutionLimit(String)
  case dependenciesRequireResolution(String)
  case pendingDeployment
  case changedPendingDeclaration

  public var description: String {
    switch self {
    case .invalidOrigin(let detail): "Invalid marketplace origin: " + detail
    case .invalidPackage(let coordinate): "Invalid marketplace package: " + coordinate
    case .releaseNotFound(let coordinate): "Marketplace release not found: " + coordinate
    case .publicationConflict(let coordinate): "Marketplace release already exists: " + coordinate
    case .integrityMismatch(let coordinate): "Marketplace release integrity mismatch: " + coordinate
    case .originConflict(let name): "Marketplace dependency origin changed: " + name
    case .missingPin(let name): "Missing marketplace pin: " + name
    case .selectionMismatch(let name):
      "Marketplace selection differs from committed intent: " + name
    case .contributionMismatch(let name): "Marketplace package contribution differs: " + name
    case .unsatisfiable(let detail): "Marketplace requirements cannot be resolved: " + detail
    case .dependencyCycle(let detail): "Marketplace dependency cycle: " + detail
    case .resolutionLimit(let detail): "Marketplace resolution exceeded the budget for " + detail
    case .dependenciesRequireResolution(let detail):
      "Marketplace dependencies require catalog resolution: " + detail
    case .pendingDeployment: "A marketplace resolution is awaiting explicit deployment."
    case .changedPendingDeclaration:
      "The declaration changed after the marketplace resolution was locked."
    }
  }
}

/// A team catalog locator. Relative filesystem locations are interpreted from the consumer's
/// project directory. The Git ref controls discovery; a selected release records its full commit.
public struct MarketplaceOrigin: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case directory, git, hosted }

  public let kind: Kind
  public let location: String
  public let ref: String?
  public let subpath: String?

  public init(kind: Kind, location: String, ref: String? = nil, subpath: String? = nil) throws {
    guard !location.isEmpty, location.utf8.count <= 4096,
      !location.contains("\\"), !location.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw MarketplaceError.invalidOrigin("invalid catalog location") }
    self.kind = kind
    switch kind {
    case .directory:
      guard ref == nil, subpath == nil, !location.contains("://"), !location.hasPrefix("~") else {
        throw MarketplaceError.invalidOrigin("invalid directory catalog")
      }
      self.location = Self.normalizedPath(location)
      self.ref = nil
      self.subpath = nil
    case .hosted:
      guard ref == nil, subpath == nil else {
        throw MarketplaceError.invalidOrigin("hosted catalog uses one HTTPS index URL")
      }
      self.location = try HostedMarketplaceLocation(location).url.absoluteString
      self.ref = nil
      self.subpath = nil
    case .git:
      if let ref {
        try SourceRequirement.revision(ref).validate()
        guard ref.utf8.count <= 1024,
          !ref.utf8.contains(where: { $0 <= 32 || $0 == 127 })
        else { throw MarketplaceError.invalidOrigin("invalid Git catalog ref") }
      }
      if location.hasPrefix("/") || location.hasPrefix("./") || location.hasPrefix("../")
        || location == "." || location == ".."
      {
        let path = Self.normalizedPath(location)
        self.location =
          path.hasPrefix("/") || path.hasPrefix("../") || path == ".." || path == "."
          ? path : "./" + path
      } else {
        let source = SourceDeclaration(kind: .git, location: location)
        guard var url = URLComponents(string: source.gitURL),
          let scheme = url.scheme?.lowercased(), ["https", "http", "ssh", "file"].contains(scheme),
          url.query == nil, url.fragment == nil, url.password == nil,
          scheme == "ssh" || url.user == nil
        else { throw MarketplaceError.invalidOrigin("invalid Git catalog URL") }
        if scheme == "file" {
          guard url.host == nil || url.host == "" || url.host == "localhost", url.port == nil,
            url.path.hasPrefix("/"), !url.path.utf8.contains(where: { $0 < 32 || $0 == 127 })
          else { throw MarketplaceError.invalidOrigin("invalid local Git catalog URL") }
          self.location = Self.normalizedPath(url.path)
        } else {
          guard let host = url.host, !host.isEmpty, url.path.count > 1 else {
            throw MarketplaceError.invalidOrigin("Git catalog needs a host and repository path")
          }
          url.scheme = scheme
          url.host = host.lowercased()
          self.location = url.string!
        }
      }
      self.ref = ref == "HEAD" ? nil : ref
      let path = try PathSafety.sanitizeSubpath(subpath ?? ".")
      self.subpath = path == "." ? nil : path
    }
  }

  package func validate() throws {
    guard try Self(kind: kind, location: location, ref: ref, subpath: subpath) == self else {
      throw MarketplaceError.invalidOrigin("catalog origin is not canonical")
    }
  }

  package var isLocal: Bool {
    kind == .directory || location.hasPrefix("/") || location.hasPrefix("./")
      || location.hasPrefix("../") || location == "." || location == ".."
  }

  package func validatePortable() throws {
    try validate()
    guard !isLocal else {
      throw MarketplaceError.invalidOrigin("portable dependencies require a remote catalog")
    }
    _ = try policyOrigin(environment: RuntimeEnvironment(environment: [:]))
  }

  package func fileURL(environment: RuntimeEnvironment) -> URL? {
    guard isLocal else { return nil }
    return URL(
      fileURLWithPath: location, isDirectory: true,
      relativeTo: URL(fileURLWithPath: environment.projectDirectory.path, isDirectory: true)
    ).standardizedFileURL
  }

  package func policyOrigin(environment: RuntimeEnvironment) throws -> SourceOrigin {
    if let file = fileURL(environment: environment) { return .local(at: file) }
    return try remotePolicyOrigin()
  }

  package func remotePolicyOrigin() throws -> SourceOrigin {
    try kind == .hosted ? .http(location) : .git(location)
  }

  package func gitSource(commit: String? = nil) -> SourceDeclaration {
    SourceDeclaration(
      kind: isLocal ? .local : .git, location: location,
      requirement: (commit ?? ref).map(SourceRequirement.revision))
  }

  private static func normalizedPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == "..", let previous = parts.last, previous != ".." {
        parts.removeLast()
      } else if part != ".." || !absolute {
        parts.append(part)
      }
    }
    let relative = parts.joined(separator: "/")
    return absolute ? "/" + relative : relative.isEmpty ? "." : relative
  }
}

/// Package IDs are lowercase portable directory names. Versions use canonical SemVer spelling.
public struct MarketplaceCoordinate: Codable, Equatable, Hashable, Sendable {
  public let package: String
  public let version: String

  public init(package: String, version: String) throws {
    guard Self.isName(package), version.utf8.count <= 128,
      version.utf8.first.map({ (48...57).contains($0) }) == true,
      SemanticVersion(version)?.description == version
    else { throw MarketplaceError.invalidPackage("\(package)@\(version)") }
    self.package = package
    self.version = version
  }

  package var label: String { "\(package)@\(version)" }

  public var releasePath: String { "releases/\(package)/\(version)" }

  package func validate() throws { _ = try Self(package: package, version: version) }

  package static func isName(_ name: String) -> Bool {
    func alphanumeric(_ byte: UInt8) -> Bool {
      (97...122).contains(byte) || (48...57).contains(byte)
    }
    return name.utf8.count <= 128 && name.utf8.first.map(alphanumeric) == true
      && name.utf8.allSatisfy { alphanumeric($0) || [45, 46, 95].contains($0) }
      && !name.hasSuffix(".")
  }

  /// SemVer precedence with a deterministic tie-break for different build metadata.
  package static func newer(_ lhs: Self, than rhs: Self) -> Bool {
    guard let a = SemanticVersion(lhs.version), let b = SemanticVersion(rhs.version) else {
      return false
    }
    return a == b ? lhs.version > rhs.version : a > b
  }

  package func hasHigherPrecedence(than other: Self) -> Bool {
    guard let version = SemanticVersion(version), let previous = SemanticVersion(other.version)
    else { return false }
    return version > previous
  }
}

/// The committed selection addressed by a dependency name in one consumer scope.
public struct MarketplaceDependency: Codable, Equatable, Sendable {
  public let name: String
  public let catalog: MarketplaceOrigin
  public let coordinate: MarketplaceCoordinate

  public init(name: String, catalog: MarketplaceOrigin, coordinate: MarketplaceCoordinate) throws {
    self.name = name
    self.catalog = catalog
    self.coordinate = coordinate
    try validate()
  }

  package func validate() throws {
    guard MarketplaceCoordinate.isName(name) else { throw MarketplaceError.invalidPackage(name) }
    try catalog.validate()
    try coordinate.validate()
  }
}

/// Verified acquisition and the exact imported contributions frozen in one scope ledger.
public struct MarketplacePin: Codable, Equatable, Sendable {
  public let dependency: MarketplaceDependency
  public let archiveDigest: String
  public let catalogCommit: String?
  /// The physical catalog origin observed at acquisition.
  public let catalogOrigin: SourceOrigin?
  public let sourceAliases: [String]
  public let componentRecords: [String]
  package let contributionDigest: String

  package init(
    dependency: MarketplaceDependency, archiveDigest: String, catalogCommit: String?,
    sourceAliases: [String], componentRecords: [String], contributionDigest: String,
    catalogOrigin: SourceOrigin? = nil
  ) {
    self.dependency = dependency
    self.archiveDigest = archiveDigest
    self.catalogCommit = catalogCommit
    self.catalogOrigin = catalogOrigin
    self.sourceAliases = sourceAliases
    self.componentRecords = componentRecords
    self.contributionDigest = contributionDigest
  }

  package func policyOrigin(environment: RuntimeEnvironment) throws -> SourceOrigin {
    if let catalogOrigin { return catalogOrigin }
    if dependency.catalog.fileURL(environment: environment) != nil { return .missing }
    return try dependency.catalog.policyOrigin(environment: environment)
  }

  package func validate() throws {
    try dependency.validate()
    try StateValidation.digest(archiveDigest)
    try StateValidation.digest(contributionDigest)
    if let catalogOrigin {
      if dependency.catalog.fileURL(environment: RuntimeEnvironment(environment: [:])) != nil {
        guard catalogOrigin.kind == .local, catalogOrigin.identity != nil else {
          throw MarketplaceError.originConflict(dependency.name)
        }
      } else if try catalogOrigin != dependency.catalog.remotePolicyOrigin() {
        throw MarketplaceError.originConflict(dependency.name)
      }
    }
    guard dependency.catalog.kind != .hosted,
      (dependency.catalog.kind == .git) == (catalogCommit != nil),
      catalogCommit.map(SourceCache.isObjectID) ?? true,
      !sourceAliases.isEmpty, sourceAliases.count == Set(sourceAliases).count,
      sourceAliases.allSatisfy({ !$0.isEmpty && $0 != "." && !$0.contains(":") }),
      componentRecords == Array(Set(componentRecords)).sorted(), !componentRecords.isEmpty
    else { throw MarketplaceError.contributionMismatch(dependency.name) }
  }
}
