import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public struct SourceCredentialReport: Equatable, Encodable, Sendable {
  public enum Transport: String, Encodable, Sendable { case local, git, http, https, ssh, archive }
  public enum Availability: String, Encodable, Sendable {
    case available, unavailable, unconfigured
    case delegatedUnverified = "delegated/unverified"
    case sshManaged = "ssh-managed"
  }
  public enum Validation: String, Encodable, Sendable { case accepted, refused, indeterminate }

  public let provider: SourceProvider?
  public let effectiveHost: String?
  public let transport: Transport
  public let credentialSource: SourceCredentialBinding.Category?
  public let availability: Availability
  public let validation: Validation?
}

/// Read-only source credential status and explicit, pipe-only export.
public enum SourceCredentialOperations {
  public static func inspect(
    source selector: String, declaration: Declaration, environment: RuntimeEnvironment,
    policy: EffectiveSourcePolicy
  ) throws -> SourceCredentialReport {
    let route = try route(
      selector, declaration: declaration, environment: environment, policy: policy)
    return try report(route, environment: environment, validation: nil)
  }

  /// Host-only inspection considers host-wide bindings. A path-scoped binding requires a source.
  public static func inspect(
    host: SourceAuthority, environment: RuntimeEnvironment
  ) throws -> SourceCredentialReport {
    let access = try environment.resolvedSourceAccess()
    let direct = try SourceRoute.binding(access, route: .direct, authority: host, path: nil)
    let mirror = try SourceRoute.binding(access, route: .mirror, authority: host, path: nil)
    guard direct == nil || mirror == nil else { throw SourceAccessError.ambiguousCredential }
    let binding = direct ?? mirror
    return .init(
      provider: access.provider(for: host), effectiveHost: host.display,
      transport: mirror == nil ? .https : .archive, credentialSource: binding?.category,
      availability: binding == nil && delegatesGit(host, environment: environment)
        ? .delegatedUnverified : availability(binding), validation: nil)
  }

  /// Validates only an explicitly authorized provider identity endpoint on the same authority.
  public static func validate(
    source selector: String, declaration: Declaration, environment: RuntimeEnvironment,
    policy: EffectiveSourcePolicy
  ) throws -> SourceCredentialReport {
    let route = try route(
      selector, declaration: declaration, environment: environment, policy: policy)
    var result = SourceCredentialReport.Validation.indeterminate
    let access = try environment.resolvedSourceAccess()
    if case .git(let repository?) = route, repository.scheme == "https",
      let binding = try route.credential(access), binding.available,
      let provider = access.provider(for: repository.authority),
      let endpoint = binding.validationEndpoint,
      let parts = try? SourceURL.https(endpoint), parts.query == nil,
      provider.admitsIdentityEndpoint(parts, authority: repository.authority),
      (try? access.requireDirectHTTP(endpoint, policy: policy)) != nil,
      let secret = try? binding.value()
    {
      var request = URLRequest(url: endpoint)
      request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
      switch (try? PackageSourceHTTP.read(request, maximumBytes: nil))?.status {
      case .some(200): result = .accepted
      case .some(401): result = .refused
      default: break
      }
    }
    return try report(route, environment: environment, validation: result)
  }

  /// Writes the selected value to a caller-owned pipe. The recipient controls its use.
  public static func export(
    source selector: String, declaration: Declaration, environment: RuntimeEnvironment,
    policy: EffectiveSourcePolicy, to descriptor: Int32 = STDOUT_FILENO
  ) throws {
    let route = try route(
      selector, declaration: declaration, environment: environment, policy: policy)
    let output = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    guard output >= 0 else { throw SourceAccessError.exportRefused }
    defer { close(output) }
    var info = stat()
    let access = fcntl(output, F_GETFL)
    guard access >= 0, access & O_ACCMODE != O_RDONLY, fstat(output, &info) == 0,
      info.st_mode & S_IFMT == S_IFIFO,
      isatty(output) == 0,
      let binding = try route.credential(environment.sourceAccess), binding.exportable
    else { throw SourceAccessError.exportRefused }

    var signal = sigset_t()
    sigemptyset(&signal)
    sigaddset(&signal, SIGPIPE)
    var previous = sigset_t()
    guard pthread_sigmask(SIG_BLOCK, &signal, &previous) == 0 else {
      throw SourceAccessError.exportRefused
    }
    defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
    var pending = sigset_t()
    sigpending(&pending)
    let alreadyPending = sigismember(&pending, SIGPIPE) == 1
    let bytes = Data(try binding.value().utf8)
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written == -1 && errno == EINTR {
          continue
        } else {
          if written == -1 && errno == EPIPE && !alreadyPending {
            // Consume only the signal generated by this write, before restoring the mask.
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 {
              var received: Int32 = 0
              sigwait(&signal, &received)
            }
          }
          throw SourceAccessError.exportRefused
        }
      }
    }
  }

  private static func route(
    _ selector: String, declaration: Declaration, environment: RuntimeEnvironment,
    policy: EffectiveSourcePolicy
  ) throws -> SourceRoute {
    let selection = try SourceArgument(selector).selection(
      in: declaration, requirement: nil, path: nil, environment: environment)
    return try SourceRoute(selection.source, environment: environment, policy: policy)
  }

  private static func availability(_ binding: SourceCredentialBinding?)
    -> SourceCredentialReport.Availability
  {
    guard let binding else { return .unconfigured }
    return binding.available ? .available : .unavailable
  }

  private static func report(
    _ route: SourceRoute, environment: RuntimeEnvironment,
    validation: SourceCredentialReport.Validation?
  ) throws -> SourceCredentialReport {
    let access = try environment.resolvedSourceAccess()
    let binding = try route.credential(access)
    let transport: SourceCredentialReport.Transport
    let host: SourceAuthority?
    let provider: SourceProvider?
    switch route {
    case .local:
      transport = .local
      host = nil
      provider = nil
    case .http(let url):
      transport = url.scheme == "http" ? .http : .https
      host = URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap {
        try? SourceAuthority($0, defaultPort: url.scheme == "http" ? 80 : 443)
      }
      provider = nil
    case .git(let repository):
      switch repository?.scheme {
      case "ssh": transport = .ssh
      case "https": transport = .https
      default: transport = .git
      }
      host = repository?.authority
      provider = repository.flatMap { access.provider(for: $0.authority, scheme: $0.scheme) }
    case .archive(let repository, let profile):
      transport = .archive
      host = profile.authority
      provider = access.provider(for: repository.authority, scheme: repository.scheme)
    }
    let status: SourceCredentialReport.Availability
    if transport == .ssh {
      status = .sshManaged
    } else if case .git = route, binding == nil, let host,
      delegatesGit(host, environment: environment)
    {
      status = .delegatedUnverified
    } else {
      status = availability(binding)
    }
    return .init(
      provider: provider, effectiveHost: host?.display, transport: transport,
      credentialSource: binding?.category, availability: status, validation: validation)
  }

  private static func delegatesGit(_ host: SourceAuthority, environment: RuntimeEnvironment) -> Bool
  {
    environment.credentialedGitHosts.contains {
      $0.caseInsensitiveCompare(host.host) == .orderedSame
    }
  }
}
