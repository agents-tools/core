import Foundation

/// Producer claims sealed by the archive. Local producer paths are omitted. A catalog
/// acquisition may provide the policy identity of a real local catalog directory.
public struct PortableSourceEvidence: Codable, Equatable, Hashable, Sendable {
  public let kind: SourceKind
  public let identity: String?
  public let revision: String
  public let version: String?

  /// Captures a catalog or artifact origin, or the transport of a source with a
  /// policy identity that cannot be recovered from its scheme-neutral identity.
  public let origin: SourceOrigin?
  /// Present for an exact marketplace release contributing to the portable closure.
  public let packageName: String?
  public let root: String?

  package init(
    kind: SourceKind, identity: String?, revision: String, version: String?,
    origin: SourceOrigin? = nil, packageName: String? = nil, root: String? = nil
  ) {
    self.kind = kind
    self.identity = identity
    self.revision = revision
    self.version = version
    self.origin = origin
    self.packageName = packageName
    self.root = root
  }

  package init(
    origin: SourceOrigin, revision: String, version: String? = nil,
    packageName: String? = nil, root: String? = nil
  ) throws {
    let kind: SourceKind
    switch origin.kind {
    case .git: kind = .git
    case .http: kind = .wellKnown
    case .local, .missing, .inline: kind = .local
    }
    let identity: String?
    if packageName != nil, origin.kind == .http, let root, let authority = origin.identity {
      identity = try HostedMarketplaceLocation(authority + "/" + root).url.absoluteString
    } else {
      identity = try origin.policyLocator.flatMap {
        kind == .local ? nil : try SourceDeclaration(kind: kind, location: $0).transportIdentity()
      }
    }
    self.init(
      kind: kind, identity: identity, revision: revision, version: version, origin: origin,
      packageName: packageName, root: root)
  }

  package var policyOrigin: SourceOrigin {
    if let origin { return origin }
    guard let identity else { return .missing }
    switch kind {
    case .git: return .missing
    case .wellKnown: return (try? .http(identity)) ?? .missing
    case .local: return .missing
    }
  }

  package func validate() throws {
    guard !revision.isEmpty, revision.utf8.count <= 256, !revision.utf8.contains(0),
      !revision.utf8.contains(47), !revision.utf8.contains(92),
      version.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) ?? true
    else { throw CoreError.invalidSource("invalid bundle source revision") }
    if let root {
      guard root != ".", try PathSafety.sanitizeSubpath(root) == root else {
        throw CoreError.invalidSource("invalid portable source root")
      }
    }
    if let packageName, let version {
      _ = try MarketplaceCoordinate(package: packageName, version: version)
      try StateValidation.digest(revision)
      switch origin?.kind {
      case .git, .local: break
      case .http:
        guard let identity, let root else {
          throw CoreError.invalidSource("missing portable hosted catalog path")
        }
        let hosted = try HostedMarketplaceLocation(identity)
        guard hosted.url.absoluteString == identity, hosted.origin == origin,
          hosted.policyPath == root
        else { throw CoreError.invalidSource("invalid portable hosted catalog identity") }
      default: throw CoreError.invalidSource("invalid portable package origin")
      }
    } else if packageName != nil {
      throw CoreError.invalidSource("incomplete portable package coordinates")
    }
    switch kind {
    case .local:
      guard identity == nil,
        origin.map({ [.missing, .local, .inline].contains($0.kind) }) ?? true
      else {
        throw CoreError.invalidSource("nonportable local source identity")
      }
    case .git:
      guard origin.map({ $0.kind == .git }) ?? true,
        let identity, !identity.contains("@"), !identity.contains("://"),
        !identity.contains("?"), !identity.contains("#"),
        try SourceDeclaration(kind: .git, location: identity).transportIdentity() == identity
      else { throw CoreError.invalidSource("invalid portable Git identity") }
    case .wellKnown:
      guard origin.map({ $0.kind == .http }) ?? true,
        let identity, let url = URLComponents(string: identity), url.query == nil,
        try SourceDeclaration(kind: .wellKnown, location: identity).transportIdentity() == identity
      else { throw CoreError.invalidSource("invalid portable index identity") }
    }
  }
}
