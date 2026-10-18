import Foundation

/// A subscription baseline: a Git commit or artifact names mapped to SHA-256 digests.
public enum WatchSeen: Codable, Equatable, Sendable {
  case revision(String)
  case artifacts([String: String])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let revision = try? container.decode(String.self) {
      self = .revision(revision)
    } else {
      self = .artifacts(try container.decode([String: String].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .revision(let revision): try container.encode(revision)
    case .artifacts(let artifacts): try container.encode(artifacts)
    }
  }
}

public struct WatchSourceState: Codable, Equatable, Sendable {
  public var seen: WatchSeen

  public init(seen: WatchSeen) { self.seen = seen }
}

/// Version 1 of agents.watch, keyed by provider-qualified source identity.
public struct WatchState: Codable, Equatable, Sendable {
  public var version: Int
  public var sources: [String: WatchSourceState]

  public init(version: Int = 1, sources: [String: WatchSourceState] = [:]) {
    self.version = version
    self.sources = sources
  }

  public func validate() throws {
    guard version == 1 else {
      throw CoreError.invalidState("unsupported agents.watch version: \(version)")
    }
    for (id, state) in sources {
      let kind: SourceKind =
        id.hasPrefix("local:") ? .local : id.contains("://") ? .wellKnown : .git
      let location = kind == .local ? String(id.dropFirst(6)) : id
      guard
        try SourceDeclaration(kind: kind, location: location).identity(
          environment: RuntimeEnvironment()) == id
      else { throw CoreError.invalidState("invalid watch source identity: \(id)") }
      switch state.seen {
      case .revision(let revision):
        guard kind != .wellKnown,
          revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
        else { throw CoreError.invalidState("Git watch state requires an exact commit") }
      case .artifacts(let artifacts):
        guard kind == .wellKnown else {
          throw CoreError.invalidState("only well-known watch sources have artifact digests")
        }
        try Declaration.validateNames(Array(artifacts.keys))
        for digest in artifacts.values { try StateValidation.digest(digest) }
      }
    }
  }
}
