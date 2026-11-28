import Foundation

public enum SourceProvider: String, Sendable, Codable {
  case github, gitlab
}

extension SourceProvider {
  static func standard(for authority: SourceAuthority, scheme: String = "https") -> Self? {
    guard authority.port == ["https": 443, "ssh": 22, "http": 80][scheme] else { return nil }
    switch authority.host {
    case "github.com": return .github
    case "gitlab.com": return .gitlab
    default: return nil
    }
  }

  func admitsIdentityEndpoint(_ endpoint: URLComponents, authority: SourceAuthority) -> Bool {
    guard let destination = try? SourceAuthority(endpoint) else { return false }
    if self == .github, authority.host == "github.com", authority.port == 443 {
      return destination.host == "api.github.com" && destination.port == 443
        && endpoint.percentEncodedPath == "/user"
    }
    let path = self == .github ? "/api/v3/user" : "/api/v4/user"
    return destination == authority && endpoint.percentEncodedPath == path
  }
}

/// A network authority with an explicit port. An omitted HTTPS port means 443.
public struct SourceAuthority: Hashable, Sendable {
  public let host: String
  public let port: Int

  public init(host: String, port: Int = 443) throws {
    guard (1...65535).contains(port),
      host.utf8.allSatisfy({ $0 < 128 }),
      let value = URLComponents(string: "https://\(host):\(port)"),
      value.port == port, value.path.isEmpty, value.query == nil,
      let authority = try SourceOrigin.http(value.string ?? "").identity,
      let canonical = URLComponents(string: authority)?.host
    else { throw SourceAccessError.invalidConfiguration }
    self.host = canonical
    self.port = port
  }

  init(_ url: URLComponents, defaultPort: Int = 443) throws {
    guard let host = url.host else { throw SourceAccessError.invalidRepository }
    try self.init(host: host, port: url.port ?? defaultPort)
  }

  package var display: String { port == 443 ? host : "\(host):\(port)" }
}

public struct SourceArchiveMirror: Equatable, Sendable {
  public enum Flavor: String, Sendable, Codable {
    case github, gitlab, artifactory
  }

  public let source: SourceAuthority
  public let base: URL
  public let flavor: Flavor
  public let supportsQualifiedGitLabRefs: Bool
  public let requiresExactArchiveBytes: Bool
  package let authority: SourceAuthority
  package let baseSegments: [String]

  public init(
    source: SourceAuthority, base: URL, flavor: Flavor,
    supportsQualifiedGitLabRefs: Bool = false, requiresExactArchiveBytes: Bool = false
  ) throws {
    let parts = try SourceURL.https(base)
    guard parts.query == nil else { throw SourceAccessError.invalidConfiguration }
    authority = try SourceAuthority(parts)
    baseSegments = try SourceURL.segments(parts.percentEncodedPath, allowingRoot: true)
    self.source = source
    self.base = base
    self.flavor = flavor
    self.supportsQualifiedGitLabRefs = supportsQualifiedGitLabRefs
    self.requiresExactArchiveBytes = requiresExactArchiveBytes
  }
}

public enum SourceAccessError: Error, Sendable, Equatable, LocalizedError {
  case invalidConfiguration, invalidRepository, ambiguousRoute, egressDenied
  case unsupportedMirror, discoveryUnavailable, historyUnavailable, routeChanged
  case ambiguousCredential, credentialUnavailable, exportRefused
  case requestFailed, invalidArchive, archiveChanged, recoveryUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The trusted package source access configuration is invalid."
    case .invalidRepository: "A trusted source route requires a valid repository URL."
    case .ambiguousRoute: "Multiple archive mirrors are configured for this source authority."
    case .egressDenied: "Current egress policy does not admit this package source route."
    case .unsupportedMirror: "This archive mirror flavor has no supported request mapper."
    case .discoveryUnavailable:
      "This archive route cannot discover or disambiguate the requested ref."
    case .historyUnavailable: "This operation requires Git history."
    case .routeChanged: "The locked source route differs from the current source configuration."
    case .ambiguousCredential: "More than one credential binding matches this source route."
    case .credentialUnavailable: "The selected source credential is unavailable."
    case .exportRefused: "Credential export requires an exportable binding and pipe-backed stdout."
    case .requestFailed: "The package source HTTPS request failed."
    case .invalidArchive: "The source archive failed verification."
    case .archiveChanged: "The source archive differs from its locked content authority."
    case .recoveryUnavailable: "Verified private source recovery is unavailable."
    }
  }
}

enum SourceURL {
  static func https(_ url: URL) throws -> URLComponents {
    guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
      value.scheme == "https", value.user == nil, value.password == nil,
      value.fragment == nil, (try? SourceOrigin.http(url.absoluteString)) != nil
    else { throw SourceAccessError.invalidConfiguration }
    return value
  }

  static func segments(_ path: String, allowingRoot: Bool = false) throws -> [String] {
    guard path.isEmpty || path.hasPrefix("/") else { throw SourceAccessError.invalidRepository }
    var input = path.dropFirst()
    if input.hasSuffix("/") { input.removeLast() }
    if input.isEmpty {
      guard allowingRoot else { throw SourceAccessError.invalidRepository }
      return []
    }
    return try input.split(separator: "/", omittingEmptySubsequences: false).map {
      guard let segment = $0.removingPercentEncoding, safeSegment(segment) else {
        throw SourceAccessError.invalidRepository
      }
      return segment
    }
  }

  static func credentialPath(_ path: String, direct: Bool) throws -> String {
    var segments = try segments(path, allowingRoot: !direct)
    if direct, let last = segments.last, last.hasSuffix(".git") {
      let name = String(last.dropLast(4))
      guard safeSegment(name) else { throw SourceAccessError.invalidConfiguration }
      segments[segments.count - 1] = name
    }
    return "/" + segments.joined(separator: "/")
  }

  static func safeSegment(_ segment: String, literalRef: Bool = false) -> Bool {
    func safe(_ value: String) -> Bool {
      !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\\")
        && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    guard safe(segment) else { return false }
    guard literalRef else { return !segment.contains("%") }
    // Ref text is literal. Also refuse a spelling that decodes to a path escape
    // if a reverse proxy decodes the path again.
    var value = segment
    while let decoded = value.removingPercentEncoding, decoded != value {
      guard safe(decoded) else { return false }
      value = decoded
    }
    return true
  }

  static func encode(_ value: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved)!
  }
}
