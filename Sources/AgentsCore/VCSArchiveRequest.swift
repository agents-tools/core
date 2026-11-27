import Foundation

/// The exact ref semantics used by an archive endpoint.
public enum VCSArchiveRef: Hashable, Codable, Sendable {
  case commit(String)
  case tag(String)
  case branch(String)

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.qualified.utf8.elementsEqual(rhs.qualified.utf8)
  }

  public func hash(into hasher: inout Hasher) { hasher.combine(Data(qualified.utf8)) }

  package var name: String {
    switch self {
    case .commit(let value), .tag(let value), .branch(let value): value
    }
  }

  package var qualified: String {
    switch self {
    case .commit(let value): value
    case .tag(let value): "refs/tags/" + value
    case .branch(let value): "refs/heads/" + value
    }
  }

  package init(requirement: SourceRequirement?) throws {
    switch requirement {
    case .branch(let name): self = .branch(name)
    case .revision(let value) where SourceCache.isObjectID(value): self = .commit(value)
    case .revision(let value) where value.hasPrefix("refs/tags/"):
      self = .tag(String(value.dropFirst("refs/tags/".count)))
    case .revision(let value) where value.hasPrefix("refs/heads/"):
      self = .branch(String(value.dropFirst("refs/heads/".count)))
    default: throw SourceAccessError.discoveryUnavailable
    }
    try validate()
  }

  func validate() throws {
    switch self {
    case .commit(let id):
      guard SourceCache.isObjectID(id) else { throw SourceAccessError.invalidRepository }
    case .tag(let value), .branch(let value):
      guard !value.isEmpty, value.utf8.count <= 1024, value != "@", !value.contains(".."),
        !value.contains("@{"),
        !value.hasSuffix("."), !value.hasPrefix("-"),
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
          SourceURL.safeSegment(String($0), literalRef: true) && !$0.hasPrefix(".")
            && !$0.hasSuffix(".lock")
            && !$0.contains(where: { " ~^:?*[".contains($0) })
        })
      else { throw SourceAccessError.invalidRepository }
    }
  }
}

struct SourceRepository {
  let url: String
  let scheme: String
  let authority: SourceAuthority
  let segments: [String]
  let gitPath: String

  init(_ url: String) throws {
    self.url = url
    let locator: String
    if !url.contains("://"), let colon = url.firstIndex(of: ":") {
      let path = url[url.index(after: colon)...]
      locator = "ssh://" + url[..<colon] + (path.hasPrefix("/") ? "" : "/") + path
    } else {
      locator = url
    }
    guard let parts = URLComponents(string: locator), let scheme = parts.scheme,
      let defaultPort = ["https": 443, "http": 80, "ssh": 22, "git": 9418][scheme],
      parts.password == nil, scheme == "ssh" || parts.user == nil,
      parts.query == nil, parts.fragment == nil
    else { throw SourceAccessError.invalidRepository }
    self.scheme = scheme
    authority = try .init(parts, defaultPort: defaultPort)
    var segments = try SourceURL.segments(parts.percentEncodedPath)
    gitPath =
      "/" + segments.joined(separator: "/")
      + (parts.percentEncodedPath.hasSuffix("/") ? "/" : "")
    if segments[segments.count - 1].hasSuffix(".git") {
      segments[segments.count - 1].removeLast(4)
    }
    guard SourceURL.safeSegment(segments.last!) else { throw SourceAccessError.invalidRepository }
    self.segments = segments
  }
}

struct VCSArchiveRequest {
  let url: URL
  let ref: VCSArchiveRef

  init(repository: SourceRepository, ref: VCSArchiveRef, mirror: SourceArchiveMirror) throws {
    try ref.validate()
    var components = try SourceURL.https(mirror.base)
    let prefix = mirror.baseSegments.map(SourceURL.encode)
    let suffix: [String]
    switch mirror.flavor {
    case .github:
      guard repository.segments.count == 2 else { throw SourceAccessError.invalidRepository }
      let refParts = ref.qualified.split(separator: "/").map(String.init)
      suffix = (repository.segments + ["archive"] + refParts).map(SourceURL.encode)
    case .gitlab:
      guard repository.segments.count >= 2 else { throw SourceAccessError.invalidRepository }
      if case .commit = ref {
      } else if !mirror.supportsQualifiedGitLabRefs {
        throw SourceAccessError.discoveryUnavailable
      }
      suffix = [
        "api", "v4", "projects", SourceURL.encode(repository.segments.joined(separator: "/")),
        "repository", "archive",
      ]
      components.percentEncodedQuery = "sha=" + SourceURL.encode(ref.qualified)
    case .artifactory:
      throw SourceAccessError.unsupportedMirror
    }
    components.percentEncodedPath = "/" + (prefix + suffix).joined(separator: "/") + ".zip"
    guard let url = components.url else { throw SourceAccessError.invalidConfiguration }
    self.url = url
    self.ref = ref
  }
}

/// Admit the logical producer first, then its effective destination. Credential selection stays
/// outside the egress decision.
enum SourceRoute {
  case local
  case http(URL)
  case git(SourceRepository?)
  case archive(SourceRepository, SourceArchiveMirror)

  init(
    _ source: SourceDeclaration, environment: RuntimeEnvironment, policy: EffectiveSourcePolicy
  ) throws {
    try policy.require(source, environment: environment)
    let access = try environment.resolvedSourceAccess()
    switch source.kind {
    case .local:
      self = .local
    case .wellKnown:
      guard let url = URL(string: source.location) else {
        throw SourceAccessError.invalidRepository
      }
      try access.requireDirectHTTP(url, policy: policy)
      self = .http(url)
    case .git:
      let repository = try? SourceRepository(source.gitURL)
      let mirrors = access.mirrors.filter { $0.source == repository?.authority }
      guard mirrors.count <= 1 else { throw SourceAccessError.ambiguousRoute }
      if let mirror = mirrors.first, let repository {
        guard mirror.flavor != .artifactory else { throw SourceAccessError.unsupportedMirror }
        try policy.require(.http(mirror.base.absoluteString))
        self = .archive(repository, mirror)
      } else {
        guard access.egress == .directAllowed else { throw SourceAccessError.egressDenied }
        if repository == nil, !access.credentials.isEmpty || !access.mirrors.isEmpty {
          throw SourceAccessError.invalidRepository
        }
        self = .git(repository)
      }
    }
  }

  func requireGitObjects() throws {
    if case .archive = self { throw SourceAccessError.historyUnavailable }
  }

  func credential(_ access: SourceAccessConfiguration) throws -> SourceCredentialBinding? {
    try access.requireCurrentSettings()
    let route: SourceCredentialBinding.Route
    let authority: SourceAuthority
    let path: String
    switch self {
    case .git(let repository?) where repository.scheme == "https":
      route = .direct
      authority = repository.authority
      path = "/" + repository.segments.joined(separator: "/")
    case .archive(let repository, let mirror):
      route = .mirror
      authority = mirror.authority
      path = "/" + (mirror.baseSegments + repository.segments).joined(separator: "/")
    default:
      return nil
    }
    return try Self.binding(access, route: route, authority: authority, path: path)
  }

  static func binding(
    _ access: SourceAccessConfiguration, route: SourceCredentialBinding.Route,
    authority: SourceAuthority, path: String?
  ) throws -> SourceCredentialBinding? {
    let matches = access.credentials.filter {
      guard $0.route == route, $0.authority == authority else { return false }
      guard let bindingPath = $0.path else { return true }
      return path.map { bindingPath.utf8.elementsEqual($0.utf8) } ?? false
    }
    let exact = matches.filter { $0.path != nil }
    let eligible = exact.isEmpty ? matches : exact
    guard eligible.count <= 1 else { throw SourceAccessError.ambiguousCredential }
    return eligible.first
  }
}
