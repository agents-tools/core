import Foundation
import Yams

/// User-owned route metadata. A credential entry names one process environment variable.
public struct SourceAccessProfile: Equatable, Sendable {
  public enum Egress: String, Sendable { case directAllowed, proxyOnly }

  public struct ProviderRegistration: Equatable, Sendable {
    public let authority: SourceAuthority
    public let provider: SourceProvider

    public init(authority: SourceAuthority, provider: SourceProvider) {
      self.authority = authority
      self.provider = provider
    }
  }

  public struct Credential: Equatable, Sendable {
    public enum Route: String, Sendable, Codable { case direct, mirror }

    public let route: Route
    public let authority: SourceAuthority
    public let path: String?
    public let environmentVariable: String
    public let exportable: Bool
    public let validationEndpoint: URL?
    private let matchingPath: String?

    public init(
      route: Route, authority: SourceAuthority, path: String? = nil,
      environmentVariable: String, exportable: Bool = false, validationEndpoint: URL? = nil
    ) throws {
      let name = environmentVariable.utf8
      func letterOrUnderscore(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
      }
      guard let first = name.first, letterOrUnderscore(first),
        name.dropFirst().allSatisfy({ letterOrUnderscore($0) || (48...57).contains($0) })
      else { throw SourceAccessSettingsError.invalidProfile("Invalid environment variable name.") }
      if let validationEndpoint {
        guard route == .direct, let parts = try? SourceURL.https(validationEndpoint),
          parts.query == nil
        else { throw SourceAccessSettingsError.invalidProfile("Invalid validationEndpoint.") }
      }
      self.route = route
      self.authority = authority
      self.path = path
      matchingPath = try path.map { try SourceURL.credentialPath($0, direct: route == .direct) }
      self.environmentVariable = environmentVariable
      self.exportable = exportable
      self.validationEndpoint = validationEndpoint
    }

    private struct Slot: Hashable {
      let route: Route
      let authority: SourceAuthority
      let path: Data?
    }

    fileprivate static func hasDistinctSlots(_ credentials: [Self]) -> Bool {
      Set(
        credentials.map {
          Slot(
            route: $0.route, authority: $0.authority, path: $0.matchingPath.map { Data($0.utf8) })
        }
      ).count == credentials.count
    }
  }

  public let egress: Egress
  public let providers: [ProviderRegistration]
  public let mirrors: [SourceArchiveMirror]
  public let credentials: [Credential]

  public init(
    egress: Egress, providers: [ProviderRegistration] = [], mirrors: [SourceArchiveMirror] = [],
    credentials: [Credential] = []
  ) throws {
    guard Set(providers.map(\.authority)).count == providers.count else {
      throw SourceAccessSettingsError.invalidProfile("Duplicate provider authority.")
    }
    guard Set(mirrors.map(\.source)).count == mirrors.count else {
      throw SourceAccessSettingsError.invalidProfile("Duplicate mirror source authority.")
    }
    guard
      mirrors.allSatisfy({
        $0.flavor != .artifactory && (!$0.supportsQualifiedGitLabRefs || $0.flavor == .gitlab)
      })
    else { throw SourceAccessSettingsError.invalidProfile("Unsupported mirror flavor or options.") }
    let providersByAuthority = Dictionary(
      uniqueKeysWithValues: providers.map { ($0.authority, $0.provider) })
    for (authority, provider) in providersByAuthority {
      if let standard = SourceProvider.standard(for: authority), standard != provider {
        throw SourceAccessSettingsError.invalidProfile(
          "Conflicting standard provider registration.")
      }
    }
    for credential in credentials {
      guard let endpoint = credential.validationEndpoint else { continue }
      let authority = credential.authority
      guard
        let provider = SourceProvider.standard(for: authority) ?? providersByAuthority[authority],
        let parts = try? SourceURL.https(endpoint),
        provider.admitsIdentityEndpoint(parts, authority: authority)
      else { throw SourceAccessSettingsError.invalidProfile("Unauthorized validationEndpoint.") }
    }
    guard Credential.hasDistinctSlots(credentials) else {
      throw SourceAccessSettingsError.invalidProfile("Duplicate credential binding.")
    }
    self.egress = egress
    self.providers = providers
    self.mirrors = mirrors
    self.credentials = credentials
  }

  static let maximumBytes = 64 * 1024

  /// Parses one version 1 settings document. Diagnostics exclude YAML values.
  public static func parse(_ bytes: Data) throws -> Self {
    guard bytes.count <= maximumBytes, let text = String(data: bytes, encoding: .utf8) else {
      throw SourceAccessSettingsError.invalidProfile("Expected UTF-8 YAML up to 64 KiB.")
    }
    let node: Node
    do {
      guard let root = try Yams.compose(yaml: text) else {
        throw SourceAccessSettingsError.invalidProfile("Expected a YAML mapping.")
      }
      node = root
    } catch {
      throw SourceAccessSettingsError.invalidProfile("Expected one valid YAML document.")
    }
    let root = try SettingsFields(
      node,
      keys: [
        "version", "egress", "providers", "mirrors",
        "credentials",
      ])
    guard try root.integer("version") == 1 else {
      throw SourceAccessSettingsError.invalidProfile("Expected version 1.")
    }
    return try Self(
      egress: root.value("egress", as: Egress.self),
      providers: root.items("providers").map { node in
        let item = try SettingsFields(node, keys: ["host", "port", "provider"])
        return try ProviderRegistration(
          authority: item.authority(), provider: item.value("provider", as: SourceProvider.self))
      },
      mirrors: root.items("mirrors").map { node in
        let item = try SettingsFields(
          node,
          keys: [
            "source", "base", "flavor", "supportsQualifiedGitLabRefs",
            "requiresExactArchiveBytes",
          ])
        let source = try SettingsFields(item.required("source"), keys: ["host", "port"])
        let authority = try source.authority()
        let base = try item.url("base")
        let flavor = try item.value("flavor", as: SourceArchiveMirror.Flavor.self)
        let qualified = try item.flag("supportsQualifiedGitLabRefs")
        let exact = try item.flag("requiresExactArchiveBytes")
        do {
          return try SourceArchiveMirror(
            source: authority, base: base, flavor: flavor, supportsQualifiedGitLabRefs: qualified,
            requiresExactArchiveBytes: exact)
        } catch {
          throw SettingsFields.failure("base")
        }
      },
      credentials: root.items("credentials").map { node in
        let item = try SettingsFields(
          node,
          keys: [
            "route", "host", "port", "path", "environmentVariable", "exportable",
            "validationEndpoint",
          ])
        let path = try item.optionalString("path")
        let route = try item.value("route", as: Credential.Route.self)
        let authority = try item.authority()
        let variable = try item.string("environmentVariable")
        let exportable = try item.flag("exportable")
        let endpoint = try item.fields["validationEndpoint"].map { _ in
          try item.url("validationEndpoint")
        }
        do {
          return try Credential(
            route: route, authority: authority, path: path, environmentVariable: variable,
            exportable: exportable, validationEndpoint: endpoint)
        } catch let error as SourceAccessSettingsError {
          throw error
        } catch {
          throw SettingsFields.failure("path")
        }
      })
  }
}

private struct SettingsFields {
  let fields: [String: Node]

  init(_ node: Node, keys: Set<String>) throws {
    guard node.tag == Tag(.map), let mapping = node.mapping else {
      throw SourceAccessSettingsError.invalidProfile("Expected a mapping.")
    }
    var fields: [String: Node] = [:]
    for (key, value) in mapping {
      guard key.tag == Tag(.str), let name = key.scalar?.string, keys.contains(name),
        fields.updateValue(value, forKey: name) == nil
      else { throw SourceAccessSettingsError.invalidProfile("Unknown or duplicate field.") }
    }
    self.fields = fields
  }

  static func failure(_ key: String) -> SourceAccessSettingsError {
    .invalidProfile("Missing or invalid \(key).")
  }

  func required(_ key: String) throws -> Node {
    guard let node = fields[key] else { throw Self.failure(key) }
    return node
  }

  func string(_ key: String) throws -> String {
    let node = try required(key)
    guard node.tag == Tag(.str), let value = node.scalar?.string, !value.isEmpty else {
      throw Self.failure(key)
    }
    return value
  }

  func optionalString(_ key: String) throws -> String? {
    try fields[key].map { _ in try string(key) }
  }

  func integer(_ key: String) throws -> Int {
    let node = try required(key)
    guard node.tag == Tag(.int), let text = node.scalar?.string,
      text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text)
    else { throw Self.failure(key) }
    return value
  }

  func flag(_ key: String) throws -> Bool {
    guard let node = fields[key] else { return false }
    guard node.tag == Tag(.bool), let text = node.scalar?.string, let value = Bool(text) else {
      throw Self.failure(key)
    }
    return value
  }

  func value<T: RawRepresentable>(_ key: String, as type: T.Type) throws -> T
  where T.RawValue == String {
    guard let value = T(rawValue: try string(key)) else { throw Self.failure(key) }
    return value
  }

  func url(_ key: String) throws -> URL {
    guard let url = URL(string: try string(key), encodingInvalidCharacters: false) else {
      throw Self.failure(key)
    }
    return url
  }

  func items(_ key: String) throws -> [Node] {
    guard let node = fields[key] else { return [] }
    guard node.tag == Tag(.seq), let sequence = node.sequence else { throw Self.failure(key) }
    return Array(sequence)
  }

  func authority() throws -> SourceAuthority {
    let host = try string("host")
    let port = try fields["port"].map { _ in try integer("port") } ?? 443
    do {
      return try SourceAuthority(host: host, port: port)
    } catch {
      throw Self.failure("host or port")
    }
  }
}
