import Foundation

public struct ResolvedSource: Equatable, Sendable {
  public var parsed: ParsedSource
  public var identity: String
  public var checkoutURL: URL
  public var revision: String?
  public var requestedRef: String?
  public var resolvedVersion: String?
  public var watchID: String?
  public var watchPath: String?
  public var watchInstallCommit: String?

  public init(
    parsed: ParsedSource, identity: String, checkoutURL: URL, revision: String? = nil,
    requestedRef: String? = nil, resolvedVersion: String? = nil, watchID: String? = nil,
    watchPath: String? = nil,
    watchInstallCommit: String? = nil
  ) {
    self.parsed = parsed
    self.identity = identity
    self.checkoutURL = checkoutURL
    self.revision = revision
    self.requestedRef = requestedRef
    self.resolvedVersion = resolvedVersion
    self.watchID = watchID
    self.watchPath = watchPath
    self.watchInstallCommit = watchInstallCommit
  }

  public var sourcePin: SourcePin {
    let kind: String
    switch parsed.type {
    case .local:
      kind = "localFileSystem"
    case .github, .gitlab, .git:
      kind = "remoteSourceControl"
    case .wellKnown:
      kind = "wellKnown"
    }
    return SourcePin(
      identity: identity,
      kind: kind,
      location: lockLocation,
      requirement: parsed.requirement,
      state: pinState
    )
  }

  private var pinState: PinState {
    var state = PinState(revision: revision)
    guard let requirement = parsed.requirement else {
      state.ref = requestedRef
      return state
    }
    switch requirement.kind {
    case "branch":
      state.branch = requirement.value
    case "revision":
      state.revision = revision ?? requirement.value
    case "ref":
      state.ref = requirement.value
    case "exact", "from", "minor", "range":
      state.version = resolvedVersion ?? requestedRef
    default:
      state.ref = requestedRef
    }
    return state
  }

  private var lockLocation: String {
    switch parsed.type {
    case .github, .gitlab, .git:
      if parsed.url.hasPrefix("git@") || parsed.url.hasPrefix("ssh://") {
        return parsed.url
      }
      return SourceParser.ownerRepo(for: parsed) ?? parsed.url
    case .local, .wellKnown:
      return parsed.url
    }
  }
}
