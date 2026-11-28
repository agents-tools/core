import Foundation

/// Retrieval evidence for an immutable hosted release. The archive is stored in the lock's
/// content objects under the release digest.
public struct HostedMarketplaceEvidence: Codable, Equatable, Sendable {
  public let indexDigest: String
  public let archiveByteCount: Int
  public let indexRequests: [URL]
  public let archiveRequests: [URL]

  package init(
    indexDigest: String, archiveByteCount: Int, indexRequests: [URL], archiveRequests: [URL]
  ) {
    self.indexDigest = indexDigest
    self.archiveByteCount = archiveByteCount
    self.indexRequests = indexRequests
    self.archiveRequests = archiveRequests
  }

  package func validate(index: String) throws {
    try StateValidation.digest(indexDigest)
    guard (1...LedgerLimits.standard.objectBytes).contains(archiveByteCount),
      indexRequests.first?.absoluteString == index, let first = archiveRequests.first
    else { throw MarketplaceError.invalidOrigin("invalid hosted release evidence") }
    let anchor = try HostedMarketplaceLocation(index)
    try anchor.validate(requests: indexRequests, archive: false)
    guard try anchor.contains(HostedMarketplaceLocation(first.absoluteString)) else {
      throw MarketplaceError.invalidOrigin("archive request is outside its catalog")
    }
    try anchor.validate(requests: archiveRequests, archive: true)
  }

  package var requests: [URL] { indexRequests + archiveRequests }
}

/// An HTTPS origin and an unambiguous absolute path. Reject encoded separators and dot
/// segments before Foundation can reinterpret them during URL resolution.
package struct HostedMarketplaceLocation: Equatable, Sendable {
  package static let maximumRedirects = 5
  package static let indexFilename = "marketplace.json"

  package let url: URL
  package let origin: SourceOrigin
  package let path: String

  package init(_ location: String) throws {
    guard location.utf8.count <= 4096, !location.contains("%"),
      !location.utf8.contains(where: { $0 <= 32 || $0 >= 127 || $0 == 92 }),
      let parts = URLComponents(string: location), parts.scheme?.lowercased() == "https",
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      let host = parts.host, !host.isEmpty, !host.hasSuffix("."),
      host.utf8.allSatisfy({ Self.alphanumeric($0) || [45, 46, 58, 91, 93].contains($0) })
    else { throw Self.invalidLocation }
    let path = parts.percentEncodedPath
    guard path.hasPrefix("/"), Self.validRelativePath(path.dropFirst()) else {
      throw Self.invalidLocation
    }
    let origin = try SourceOrigin.http(location)
    guard let canonical = URL(string: origin.identity! + path) else {
      throw Self.invalidLocation
    }
    self.url = canonical
    self.origin = origin
    self.path = path
  }

  package func archive(_ path: String) throws -> Self {
    try Self.validateArchivePath(path)
    return try Self(origin.identity! + prefix + path)
  }

  package func redirect(to location: String) throws -> Self {
    guard location.utf8.count <= 4096, !location.isEmpty,
      !location.hasPrefix("//"), !location.contains("%")
    else { throw Self.invalidLocation }
    if location.hasPrefix("/") {
      return try Self(origin.identity! + location)
    }
    if location.contains("://") { return try Self(location) }
    return try archive(location)
  }

  package func contains(_ destination: Self) -> Bool {
    origin == destination.origin && destination.path.hasPrefix(prefix)
  }

  package var policyPath: String { String(path.dropFirst()) }

  private var prefix: String { String(path.prefix(through: path.lastIndex(of: "/")!)) }

  fileprivate func validate(requests: [URL], archive: Bool) throws {
    guard (1...Self.maximumRedirects + 1).contains(requests.count),
      Set(requests).count == requests.count
    else { throw Self.invalidLocation }
    var prefixes = [origin: self]
    for request in requests {
      let destination = try Self(request.absoluteString)
      guard request.absoluteString == destination.url.absoluteString else {
        throw Self.invalidLocation
      }
      try admit(destination, prefixes: &prefixes, archive: archive)
    }
  }

  package func admit(
    _ destination: Self, prefixes: inout [SourceOrigin: Self], archive: Bool
  ) throws {
    if let prefix = prefixes[destination.origin] {
      guard prefix.contains(destination) else { throw Self.invalidLocation }
    } else {
      guard archive else { throw Self.invalidLocation }
      prefixes[destination.origin] = destination
    }
  }

  package static func validateArchivePath(_ path: String) throws {
    guard path.utf8.count <= 4096, validRelativePath(path[...]) else { throw invalidLocation }
  }

  private static func validRelativePath(_ path: Substring) -> Bool {
    !path.isEmpty
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
          && $0.utf8.allSatisfy { alphanumeric($0) || [43, 45, 46, 95, 126].contains($0) }
      }
  }

  private static func alphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }

  private static var invalidLocation: MarketplaceError {
    .invalidOrigin("expected an unambiguous HTTPS marketplace URL or relative path")
  }
}

extension MarketplaceOrigin {
  /// The URL persisted in authored roots and stable across registration name changes.
  public var hostedIndex: URL? {
    kind == .hosted ? URL(string: location) : nil
  }

  public init(hostedIndex: URL) throws {
    try self.init(kind: .hosted, location: hostedIndex.absoluteString)
  }

  package var policyPath: String? {
    if kind == .hosted { return (try? HostedMarketplaceLocation(location))?.policyPath }
    return subpath
  }
}
