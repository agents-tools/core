import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Canonical install provenance. Git rules identify repositories and HTTP rules identify
/// network origins. Registry and bundle producers must supply every origin used by the selection.
public struct SourceOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
  public enum Kind: String, Sendable, Codable {
    case git, http, local, inline, missing
  }

  public let kind: Kind
  public let identity: String?

  private init(_ kind: Kind, _ identity: String? = nil) {
    self.kind = kind
    self.identity = identity
  }

  private enum CodingKeys: String, CodingKey { case kind, identity }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try fields.decode(Kind.self, forKey: .kind)
    let identity = try fields.decodeIfPresent(String.self, forKey: .identity)
    let value = Self(kind, identity)
    let canonical: Self
    switch (kind, identity) {
    case (.git, .some): canonical = try .git(value.policyLocator!)
    case (.http, .some(let url)): canonical = try .http(url)
    case (.local, .some(let path)) where path.hasPrefix("/") && !path.contains("\0"):
      canonical = .local(path: path)
    case (.local, nil), (.inline, nil), (.missing, nil): canonical = value
    default: throw CoreError.invalidSource("invalid source origin")
    }
    guard value == canonical else { throw CoreError.invalidSource("noncanonical source origin") }
    self = value
  }

  /// A rule matching all explicit local sources. Obtain a concrete origin with `local(at:)`.
  public static var local: Self { .init(.local) }
  public static var inline: Self { .init(.inline) }
  /// External content whose producer coordinates cannot be established by the importer.
  public static var missing: Self { .init(.missing) }

  public static func local(at url: URL) -> Self {
    let path = PathSafety.realPath(url.path) ?? url.resolvingSymlinksInPath().path
    return local(path: path)
  }

  /// A rule naming one absolute, standardized local source root.
  package static func local(path: String) -> Self {
    .init(.local, URL(fileURLWithPath: path).standardizedFileURL.path)
  }

  public static func git(_ location: String) throws -> Self {
    let transport = SourceDeclaration(kind: .git, location: location).gitURL
    let url: String
    if !transport.contains("://"), let colon = transport.firstIndex(of: ":") {
      let repository = transport[transport.index(after: colon)...]
      let separator = repository.hasPrefix("/") ? "" : "/"
      url = "ssh://" + transport[..<colon] + separator + repository
    } else {
      url = transport
    }
    guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
      let defaultPort = ["https": 443, "http": 80, "ssh": 22, "git": 9418][scheme],
      let host = normalizedHost(parts), parts.query == nil, parts.fragment == nil,
      validPort(parts.port)
    else { throw CoreError.invalidSource("invalid Git policy origin") }
    let escaped = parts.percentEncodedPath.lowercased()
    var path = parts.path
    if path.hasSuffix("/") { path.removeLast() }
    let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("/"), !escaped.contains("%2f"), !escaped.contains("%5c"),
      !path.contains("\\"), path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
      segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw CoreError.invalidSource("invalid Git policy repository path") }
    if path.hasSuffix(".git") { path.removeLast(4) }
    if host == "github.com" {
      var parts = path.split(separator: "/").map(String.init)
      for index in parts.indices.prefix(2) { parts[index] = parts[index].lowercased() }
      path = "/" + parts.joined(separator: "/")
    }
    guard path.last != "/" else { throw CoreError.invalidSource("empty Git policy repository") }
    let port = parts.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    var canonical = URLComponents()
    canonical.path = path
    let prefix = scheme == "http" || scheme == "git" ? scheme + "://" : ""
    return .init(.git, prefix + host + port + canonical.percentEncodedPath)
  }

  public static func http(_ location: String) throws -> Self {
    guard let parts = URLComponents(string: location), let scheme = parts.scheme?.lowercased(),
      let defaultPort = ["https": 443, "http": 80][scheme], let host = normalizedHost(parts),
      parts.user == nil, parts.password == nil, parts.fragment == nil, validPort(parts.port)
    else { throw CoreError.invalidSource("invalid HTTP policy origin") }
    let port = parts.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return .init(.http, scheme + "://" + host + port)
  }

  private static func normalizedHost(_ parts: URLComponents) -> String? {
    guard var host = parts.url?.host?.lowercased(), !host.isEmpty,
      !host.contains("%"), host.utf8.allSatisfy({ $0 < 128 })
    else { return nil }
    if host.hasSuffix(".") { host.removeLast() }
    if host.contains(":") {
      var address = in6_addr()
      var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      let literal =
        host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast()) : host
      guard inet_pton(AF_INET6, literal, &address) == 1,
        inet_ntop(AF_INET6, &address, &output, socklen_t(output.count)) != nil
      else { return nil }
      return "["
        + String(decoding: output.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        + "]"
    }
    var address = in_addr()
    if inet_aton(host, &address) == 1 {
      var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &address, &output, socklen_t(output.count)) != nil else {
        return nil
      }
      return String(decoding: output.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
    guard !host.isEmpty, !host.hasSuffix(".") else { return nil }
    return host
  }

  private static func validPort(_ port: Int?) -> Bool {
    port.map { (1...65535).contains($0) } ?? true
  }

  package var policyLocator: String? {
    guard let identity, kind == .git else { return identity }
    if identity.contains("://") { return identity + ".git" }
    let authority = identity.prefix(while: { $0 != "/" })
    let scheme = authority.hasSuffix(":443") ? "ssh://" : "https://"
    return scheme + identity + ".git"
  }

  public var description: String {
    identity.map { kind.rawValue + " " + $0 } ?? kind.rawValue
  }

  package static func declared(_ source: SourceDeclaration, in environment: RuntimeEnvironment)
    throws -> Self
  {
    switch source.kind {
    case .git: try git(source.gitURL)
    case .wellKnown: try http(source.location)
    case .local: local(at: source.localURL(environment: environment))
    }
  }
}

/// Within a layer, a deny rule wins. An omitted allow list admits known origins not denied there.
/// An explicitly empty allow list admits nothing. Missing provenance requires explicit admission.
public struct SourcePolicyRules: Equatable, Sendable, Encodable {
  public let allow: [SourceOrigin]?
  public let deny: [SourceOrigin]
  private let allowedOrigins: Set<SourceOrigin>?
  private let deniedOrigins: Set<SourceOrigin>

  private enum CodingKeys: String, CodingKey { case allow, deny }

  public init(allow: [SourceOrigin]? = nil, deny: [SourceOrigin] = []) {
    self.allow = allow
    self.deny = deny
    allowedOrigins = allow.map(Set.init)
    deniedOrigins = Set(deny)
  }

  fileprivate func rejection(of origin: SourceOrigin) -> SourcePolicyViolation.Reason? {
    func contains(_ rules: Set<SourceOrigin>) -> Bool {
      rules.contains(origin) || (origin.kind == .local && rules.contains(.local))
    }
    if contains(deniedOrigins) { return .denied }
    if let allowedOrigins, contains(allowedOrigins) { return nil }
    if origin == .missing { return .missingOrigin }
    return allowedOrigins == nil ? nil : .notAllowed
  }
}

public struct SourcePolicyLayer: Equatable, Sendable, Encodable {
  public enum Scope: String, Sendable, Encodable { case user, project, organization }

  public let scope: Scope
  public let url: URL
  public let rules: SourcePolicyRules

  public init(scope: Scope, url: URL, rules: SourcePolicyRules) {
    self.scope = scope
    self.url = url
    self.rules = rules
  }
}

/// `reference` identifies the source, resource or component causing the check. Callers use
/// stable references without credentials or other sensitive source input.
public struct SourcePolicyViolation: Equatable, Sendable, Encodable {
  public enum Reason: String, Sendable, Encodable { case denied, notAllowed, missingOrigin }

  public let scope: SourcePolicyLayer.Scope
  public let policyURL: URL
  public let origin: SourceOrigin
  public let reference: String?
  public let reason: Reason
}

public struct SourcePolicyFailure: Error, Sendable, CustomStringConvertible {
  public let violations: [SourcePolicyViolation]
  public let context: [SourceSpan]

  package init(violations: [SourcePolicyViolation], context: [SourceSpan] = []) {
    self.violations = violations
    self.context = context
  }

  public var description: String {
    violations.map { violation in
      let reference = violation.reference.map { " (\($0))" } ?? ""
      return "\(violation.scope.rawValue) source policy: \(violation.reason.rawValue) "
        + "\(violation.origin)\(reference) [\(violation.policyURL.path)]"
    }.joined(separator: "\n")
      + context.map { span in
        "\n  at \(span.document.rawValue):\(span.line):\(span.column)"
      }.joined()
  }
}

/// Effective policy is an intersection. A layer cannot grant access rejected by another layer.
public struct EffectiveSourcePolicy: Equatable, Sendable, Encodable {
  public let layers: [SourcePolicyLayer]
  public var isConfigured: Bool { !layers.isEmpty }

  public init(layers: [SourcePolicyLayer] = []) {
    self.layers = layers
  }

  public func violations(for origin: SourceOrigin, reference: String? = nil)
    -> [SourcePolicyViolation]
  {
    layers.compactMap { layer in
      layer.rules.rejection(of: origin).map { reason in
        .init(
          scope: layer.scope, policyURL: layer.url, origin: origin, reference: reference,
          reason: reason)
      }
    }
  }

  public func require(_ origin: SourceOrigin, reference: String? = nil) throws {
    let failures = violations(for: origin, reference: reference)
    guard failures.isEmpty else { throw SourcePolicyFailure(violations: failures) }
  }

  package func require(_ source: SourceDeclaration, environment: RuntimeEnvironment) throws {
    guard isConfigured else { return }
    try require(.declared(source, in: environment))
  }

  package func require(_ artifact: LockedArtifact) throws {
    guard isConfigured else { return }
    for origin in Self.artifactOrigins(artifact) { try require(origin) }
  }

  package static func artifactOrigins(_ artifact: LockedArtifact) -> [SourceOrigin] {
    ([artifact.url] + (artifact.files ?? []).map(\.url)).map { (try? .http($0)) ?? .missing }
  }
}
