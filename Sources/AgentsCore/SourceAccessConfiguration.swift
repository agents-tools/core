import Foundation

/// Limits a trusted credential binding to an authority and, optionally, one exact request path.
public struct SourceCredentialBinding: Sendable, CustomReflectable {
  public typealias Route = SourceAccessProfile.Credential.Route
  public enum Category: String, Sendable, Codable { case supplied, environment, opaque }

  public let route: Route
  public let authority: SourceAuthority
  public let path: String?
  public let category: Category
  public let exportable: Bool
  let validationEndpoint: URL?
  let gitUsername: String
  private let resolve: @Sendable () -> String?

  /// The host supplies narrowly scoped bytes. Core does not discover credentials or invoke
  /// providers during inspection. A missing value is represented by nil.
  public init(
    route: Route, authority: SourceAuthority, path: String? = nil,
    category: Category = .supplied, available: Bool = true, exportable: Bool = false,
    validationEndpoint: URL? = nil, gitUsername: String = "oauth2",
    resolve: @escaping @Sendable () -> String?
  ) throws {
    let canonicalPath = try path.map { try SourceURL.credentialPath($0, direct: route == .direct) }
    if let validationEndpoint {
      _ = try SourceURL.https(validationEndpoint)
    }
    guard Self.valid(gitUsername), !gitUsername.isEmpty else {
      throw SourceAccessError.invalidConfiguration
    }
    self.route = route
    self.authority = authority
    self.path = canonicalPath
    self.category = category
    self.available = available
    self.exportable = exportable && category != .opaque
    self.validationEndpoint = validationEndpoint
    self.gitUsername = gitUsername
    self.resolve = resolve
  }

  public let available: Bool

  func value() throws -> String {
    guard available, let value = resolve(), Self.valid(value), !value.isEmpty else {
      throw SourceAccessError.credentialUnavailable
    }
    return value
  }

  static func valid(_ value: String) -> Bool {
    value.utf8.count <= 4096 && value.utf8.allSatisfy { (33...126).contains($0) }
  }

  public var customMirror: Mirror { Mirror(self, children: ["category": category]) }
}

/// Trusted runtime input. Declarations and locks cannot register providers, routes or credentials.
public struct SourceAccessConfiguration: Sendable {
  public typealias Egress = SourceAccessProfile.Egress

  private enum UserSettings: Sendable {
    case captured(SourceAccessSettingsFile, SourceAccessSettingsFile.Snapshot)
    case invalid(any Error)
  }

  private var userSettings: UserSettings?

  public let egress: Egress
  public let providers: [SourceAuthority: SourceProvider]
  public let mirrors: [SourceArchiveMirror]
  public let credentials: [SourceCredentialBinding]

  public init(
    egress: Egress = .directAllowed, providers: [SourceAuthority: SourceProvider] = [:],
    mirrors: [SourceArchiveMirror] = [], credentials: [SourceCredentialBinding] = []
  ) {
    self.egress = egress
    self.providers = providers
    self.mirrors = mirrors
    self.credentials = credentials
  }

  func provider(for authority: SourceAuthority, scheme: String = "https") -> SourceProvider? {
    SourceProvider.standard(for: authority, scheme: scheme) ?? providers[authority]
  }

  static func loadUserSettings(home: URL, environment: [String: String]) -> Self {
    let file = SourceAccessSettingsFile(homeDirectory: home)
    do {
      let snapshot = try file.read()
      let profile = try file.profile(in: snapshot)
      let credentials = try (profile?.credentials ?? []).map { entry in
        let value = environment[entry.environmentVariable]
        return try SourceCredentialBinding(
          route: entry.route, authority: entry.authority, path: entry.path, category: .environment,
          available: value.map { !$0.isEmpty && SourceCredentialBinding.valid($0) } ?? false,
          exportable: entry.exportable, validationEndpoint: entry.validationEndpoint
        ) { value }
      }
      var access = Self(
        egress: profile?.egress ?? .directAllowed,
        providers: Dictionary(
          uniqueKeysWithValues: (profile?.providers ?? []).map { ($0.authority, $0.provider) }),
        mirrors: profile?.mirrors ?? [], credentials: credentials)
      access.userSettings = .captured(file, snapshot)
      return access
    } catch {
      var access = Self(egress: .proxyOnly)
      access.userSettings = .invalid(
        error is OpenFileLimitError
          ? error : (error as? SourceAccessSettingsError ?? .unsafeLocation(file.url)))
      return access
    }
  }

  var usesUserSettings: Bool { userSettings != nil }

  package var settingsURL: URL? {
    if case .captured(let file, _) = userSettings { return file.url }
    return nil
  }

  /// Local generation of the admitted profile. This only identifies metadata.
  public var settingsFingerprint: String? {
    if case .captured(_, let snapshot) = userSettings { return snapshot.fingerprint }
    return nil
  }

  package func requireCurrentSettings() throws {
    switch userSettings {
    case nil: return
    case .invalid(let error): throw error
    case .captured(let file, let snapshot):
      guard try file.read() == snapshot else { throw SourceAccessSettingsError.changed(file.url) }
    }
  }

  package func requireDirectHTTP(
    _ url: URL, policy: EffectiveSourcePolicy = .init()
  ) throws {
    try requireCurrentSettings()
    guard egress == .directAllowed else { throw SourceAccessError.egressDenied }
    try policy.require(.http(url.absoluteString))
  }
}
