import Foundation

public enum SourceAccessSettingsError: Error, Equatable, Sendable, LocalizedError {
  case invalidProfile(String)
  case invalidFile(URL, reason: String)
  case unsafeLocation(URL)
  case changed(URL)

  public var errorDescription: String? {
    switch self {
    case .invalidProfile(let reason):
      "Invalid source access settings. \(reason)"
    case .invalidFile(let url, let reason):
      "Invalid source access settings at \(url.path). \(reason)"
    case .unsafeLocation(let url):
      "Cannot establish user control of source access settings at \(url.path)."
    case .changed(let url):
      "Source access settings at \(url.path) changed. Reload them and try again."
    }
  }
}

/// A validated edit or reset based on one observed generation of the user settings.
public struct SourceAccessSettingsPreview: Sendable {
  public let url: URL
  public let profile: SourceAccessProfile?
  public let hasChanges: Bool
  fileprivate let bytes: Data?
  fileprivate let original: SourceAccessSettingsFile.Snapshot
}

/// Opens the operator profile without creating directories. Malformed YAML can be
/// read as bytes and repaired without first admitting it for package operations.
public struct SourceAccessSettingsEditor: Sendable {
  public let url: URL
  /// Original bytes when within the profile size limit. Inspect distinguishes an
  /// oversized profile from a missing file.
  public var original: Data? { snapshot.bytes }
  private let file: SourceAccessSettingsFile
  private let snapshot: SourceAccessSettingsFile.Snapshot

  public static func settingsURL(environment: RuntimeEnvironment = RuntimeEnvironment()) -> URL {
    SourceAccessSettingsFile(homeDirectory: environment.homeDirectory).url
  }

  public init(environment: RuntimeEnvironment = RuntimeEnvironment()) throws {
    let file = SourceAccessSettingsFile(homeDirectory: environment.homeDirectory)
    self.file = file
    url = file.url
    snapshot = try file.read()
  }

  public func inspect() throws -> SourceAccessProfile? {
    try file.profile(in: snapshot)
  }

  /// Validate the proposed YAML. Pass nil to preview a reset to ordinary defaults.
  public func preview(_ bytes: Data?) throws -> SourceAccessSettingsPreview {
    let profile = try bytes.map(SourceAccessProfile.parse)
    return SourceAccessSettingsPreview(
      url: url, profile: profile, hasChanges: file.writesChanges(bytes, comparedTo: snapshot),
      bytes: bytes, original: snapshot)
  }

  /// Atomically publish a preview if its original settings generation is still current.
  public func save(_ preview: SourceAccessSettingsPreview) throws {
    guard preview.url == url, preview.original == snapshot else {
      throw SourceAccessSettingsError.changed(url)
    }
    try file.save(preview.bytes, replacing: snapshot)
  }
}
