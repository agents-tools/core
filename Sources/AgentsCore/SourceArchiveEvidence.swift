import Foundation

/// Immutable authority for a source obtained from a VCS archive endpoint.
public struct SourceArchiveEvidence: Codable, Hashable, Sendable {
  public let effectiveURL: URL
  public let flavor: SourceArchiveMirror.Flavor
  public let ref: VCSArchiveRef
  public let treeDigest: String
  public let observedArchiveDigest: String
  public let requiredArchiveDigest: String?

  package init(
    effectiveURL: URL, flavor: SourceArchiveMirror.Flavor, ref: VCSArchiveRef,
    treeDigest: String, observedArchiveDigest: String, requiredArchiveDigest: String?
  ) {
    self.effectiveURL = effectiveURL
    self.flavor = flavor
    self.ref = ref
    self.treeDigest = treeDigest
    self.observedArchiveDigest = observedArchiveDigest
    self.requiredArchiveDigest = requiredArchiveDigest
  }

  func validate() throws {
    _ = try SourceURL.https(effectiveURL)
    guard flavor != .artifactory,
      requiredArchiveDigest == nil || requiredArchiveDigest == observedArchiveDigest
    else { throw SourceAccessError.invalidArchive }
    try ref.validate()
    try StateValidation.digest(treeDigest)
    try StateValidation.digest(observedArchiveDigest)
  }

  func require(
    repository: SourceRepository, profile: SourceArchiveMirror
  ) throws -> VCSArchiveRequest {
    try validate()
    let request = try VCSArchiveRequest(repository: repository, ref: ref, mirror: profile)
    guard request.url.absoluteString == effectiveURL.absoluteString, profile.flavor == flavor,
      !profile.requiresExactArchiveBytes || requiredArchiveDigest != nil
    else { throw SourceAccessError.routeChanged }
    return request
  }

  func verify(_ archive: VerifiedVCSArchive) throws {
    guard archive.treeDigest == treeDigest,
      requiredArchiveDigest == nil || requiredArchiveDigest == archive.byteDigest
    else { throw SourceAccessError.archiveChanged }
  }

  package func admits(_ requirement: SourceRequirement?, version: String?) -> Bool {
    guard let requirement else { return true }
    if requirement.isVersionRequirement {
      return version.map(requirement.admitsMarketplaceVersion) ?? false
    }
    return (try? VCSArchiveRef(requirement: requirement)) == ref
  }
}

extension VCSArchiveRef {
  private enum Keys: String, CodingKey { case kind, name }
  private enum Kind: String, Codable { case commit, tag, branch }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: Keys.self)
    let name = try fields.decode(String.self, forKey: .name)
    switch try fields.decode(Kind.self, forKey: .kind) {
    case .commit: self = .commit(name)
    case .tag: self = .tag(name)
    case .branch: self = .branch(name)
    }
    try validate()
  }

  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: Keys.self)
    let kind: Kind
    switch self {
    case .commit: kind = .commit
    case .tag: kind = .tag
    case .branch: kind = .branch
    }
    try fields.encode(kind, forKey: .kind)
    try fields.encode(name, forKey: .name)
  }
}

extension SourceRoute {
  func requireRecordedArchive(_ evidence: SourceArchiveEvidence?) throws -> VCSArchiveRequest? {
    switch (self, evidence) {
    case (.archive(let repository, let profile), .some(let evidence)):
      return try evidence.require(repository: repository, profile: profile)
    case (.archive, nil), (_, .some):
      throw SourceAccessError.routeChanged
    default:
      return nil
    }
  }
}
