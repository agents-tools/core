import AgentsCore
import AgentsManifest
import Foundation
import Synchronization

#if canImport(Security)
  import Security
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Trusted host inputs for hosted marketplace reads. The credential callback receives the
/// canonical index URL only when that exact identity has a user-scoped registration.
public struct HostedMarketplaceAccess: Sendable {
  public typealias CredentialProvider = @Sendable (URL) -> String?

  let downloadOrigins: Set<SourceOrigin>
  let credentialProvider: CredentialProvider?
  let transport: HostedMarketplaceHTTP.Transport

  /// Download origins are HTTPS authorities. Credentials are ephemeral bearer tokens whose
  /// lookup and lifetime are owned by the host.
  public init(
    trustedDownloadOrigins: [URL] = [], credentialProvider: CredentialProvider? = nil
  ) throws {
    let origins = try Set(
      trustedDownloadOrigins.map { url in
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == "https", parts.query == nil,
          parts.path.isEmpty || parts.path == "/"
        else { throw MarketplaceError.invalidOrigin("expected an HTTPS download origin") }
        return try SourceOrigin.http(url.absoluteString)
      })
    self.init(downloadOrigins: origins, credentialProvider: credentialProvider)
  }

  init(
    downloadOrigins: Set<SourceOrigin> = [], credentialProvider: CredentialProvider? = nil,
    transport: @escaping HostedMarketplaceHTTP.Transport = HostedMarketplaceHTTP.fetch
  ) {
    self.downloadOrigins = downloadOrigins
    self.credentialProvider = credentialProvider
    self.transport = transport
  }
}

public enum HostedMarketplaceError: Error, Equatable, Sendable, CustomStringConvertible {
  case registrationRequired
  case credentialRequired
  case invalidCredential
  case redirectDenied
  case requestFailed
  case responseStatus(Int)
  case responseTooLarge

  public var description: String {
    switch self {
    case .registrationRequired:
      "Register the exact hosted catalog in the user marketplace directory."
    case .credentialRequired:
      "Supply a bearer credential for the exact hosted index in your host's user settings."
    case .invalidCredential: "The hosted marketplace bearer credential has an invalid header value."
    case .redirectDenied: "The hosted marketplace redirect exceeds its admitted HTTPS locations."
    case .requestFailed: "The hosted marketplace HTTPS request failed."
    case .responseStatus(let status): "The hosted marketplace returned HTTP \(status)."
    case .responseTooLarge: "The hosted marketplace response exceeded its byte limit."
    }
  }
}

enum HostedMarketplaceHTTP {
  struct Response: Sendable {
    let status: Int
    let location: String?
    let bytes: Data
  }

  typealias Transport = @Sendable (URLRequest, Int) throws -> Response

  static func fetch(_ request: URLRequest, maximumBytes: Int) throws -> Response {
    try fetch(request, maximumBytes: maximumBytes, localTrustAnchor: nil)
  }

  // A synthetic TLS fixture can establish trust for its own session without writing to the keychain.
  static func fetch(
    _ request: URLRequest, maximumBytes: Int, localTrustAnchor: Data?
  ) throws -> Response {
    let reader = Reader(maximumBytes: maximumBytes, localTrustAnchor: localTrustAnchor)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    task.resume()
    while reader.finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    return try reader.state.withLock { state in
      if state.exceeded { throw HostedMarketplaceError.responseTooLarge }
      guard let status = state.status, status != 200 || !state.failed else {
        throw HostedMarketplaceError.requestFailed
      }
      return Response(status: status, location: state.location, bytes: state.bytes)
    }
  }

  private final class Reader: NSObject, URLSessionDataDelegate {
    struct State {
      var status: Int?
      var location: String?
      var bytes = Data()
      var exceeded = false
      var failed = false
    }

    let state = Mutex(State())
    let finished = DispatchSemaphore(value: 0)
    let maximumBytes: Int
    let localTrustAnchor: Data?

    init(maximumBytes: Int, localTrustAnchor: Data?) {
      self.maximumBytes = maximumBytes
      self.localTrustAnchor = localTrustAnchor
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      state.withLock {
        $0.status = response.statusCode
        $0.location = response.value(forHTTPHeaderField: "Location")
      }
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
        Void
    ) {
      respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
        Void
    ) {
      respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(
      to challenge: URLAuthenticationChallenge,
      completionHandler: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
          guard let localTrustAnchor else {
            completionHandler(.performDefaultHandling, nil)
            return
          }
          guard challenge.protectionSpace.host == "127.0.0.1",
            let trust = challenge.protectionSpace.serverTrust,
            let cert = SecCertificateCreateWithData(nil, localTrustAnchor as CFData),
            SecTrustSetAnchorCertificates(trust, [cert] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustEvaluateWithError(trust, nil)
          else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
          }
          completionHandler(.useCredential, URLCredential(trust: trust))
          return
        }
      #endif
      if let response = challenge.failureResponse as? HTTPURLResponse,
        [401, 403].contains(response.statusCode)
      {
        state.withLock { $0.status = response.statusCode }
      }
      completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        return
      }
      let allow = state.withLock { state in
        state.status = http.statusCode
        state.location = http.value(forHTTPHeaderField: "Location")
        guard http.statusCode == 200 else { return false }
        state.exceeded = http.expectedContentLength > maximumBytes
        return !state.exceeded
      }
      completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let overflow = state.withLock { state in
        if data.count > maximumBytes - state.bytes.count { state.exceeded = true }
        if !state.exceeded { state.bytes.append(data) }
        return state.exceeded
      }
      if overflow { dataTask.cancel() }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      state.withLock { $0.failed = error != nil }
      finished.signal()
    }
  }
}

struct HostedMarketplaceReader {
  let index: HostedMarketplaceLocation
  let access: HostedMarketplaceAccess
  let policy: SourcePolicySnapshot
  let organization: OrganizationPolicySnapshot
  let trustedRegistration: TargetPrecondition?
  let credentialRegistration: TargetPrecondition?
  let credentialEligible: Bool
  let sourceAccess: SourceAccessConfiguration

  init(
    origin: MarketplaceOrigin, store: StateStore, access: HostedMarketplaceAccess?,
    policy: SourcePolicySnapshot, organization: OrganizationPolicySnapshot,
    trustedRegistration: TargetPrecondition? = nil
  ) throws {
    index = try HostedMarketplaceLocation(origin.location)
    sourceAccess = store.environment.sourceAccess
    try sourceAccess.requireDirectHTTP(index.url, policy: policy.effective)
    self.access = access ?? HostedMarketplaceAccess(downloadOrigins: [])
    self.policy = policy
    self.organization = organization
    self.trustedRegistration = trustedRegistration
    if self.access.credentialProvider != nil {
      let trusted = try MarketplaceDirectory.trustedHostedOrigins(environment: store.environment)
      credentialEligible = trusted.origins.contains(origin)
      credentialRegistration = trusted.evidence
    } else {
      credentialEligible = false
      credentialRegistration = nil
    }
  }

  func read(
    _ initial: HostedMarketplaceLocation, coordinate: MarketplaceCoordinate? = nil,
    maximumBytes: Int
  ) throws -> (bytes: Data, requests: [URL]) {
    var current = initial
    var visited: [URL] = []
    var prefixes = [index.origin: index]
    var authorization: String?
    while true {
      try Task.checkCancellation()
      guard visited.count <= HostedMarketplaceLocation.maximumRedirects,
        !visited.contains(current.url)
      else { throw HostedMarketplaceError.redirectDenied }
      try index.admit(current, prefixes: &prefixes, archive: coordinate != nil)
      if current.origin != index.origin {
        guard access.downloadOrigins.contains(current.origin) else {
          throw HostedMarketplaceError.redirectDenied
        }
        authorization = nil
      }
      try sourceAccess.requireDirectHTTP(current.url)
      try policy.effective.require(current.origin, reference: coordinate?.label)
      try organization.admit(
        Self.findings(
          for: current, index: index, coordinate: coordinate, evaluator: organization.evaluator))
      try policy.validate()
      try organization.validate()
      try trustedRegistration?.validate()
      try credentialRegistration?.validate()
      if visited.isEmpty, credentialEligible, let token = access.credentialProvider?(index.url) {
        guard !token.isEmpty, token.utf8.count <= 8192,
          token.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw HostedMarketplaceError.invalidCredential }
        authorization = "Bearer " + token
      }

      var request = URLRequest(url: current.url)
      request.httpShouldHandleCookies = false
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
      visited.append(current.url)
      try trustedRegistration?.validate()
      try credentialRegistration?.validate()
      try policy.validate()
      try organization.validate()
      let response = try access.transport(request, maximumBytes)
      switch response.status {
      case 200:
        guard response.bytes.count <= maximumBytes else {
          throw HostedMarketplaceError.responseTooLarge
        }
        try policy.validate()
        try organization.validate()
        try credentialRegistration?.validate()
        try trustedRegistration?.validate()
        return (response.bytes, visited)
      case 301, 302, 303, 307, 308:
        guard let location = response.location else { throw HostedMarketplaceError.redirectDenied }
        current = try current.redirect(to: location)
      case 401 where authorization == nil, 403 where authorization == nil:
        throw HostedMarketplaceError.credentialRequired
      default: throw HostedMarketplaceError.responseStatus(response.status)
      }
    }
  }

  static func findings(
    for destination: HostedMarketplaceLocation, index: HostedMarketplaceLocation,
    coordinate: MarketplaceCoordinate?, evaluator: OrganizationPolicyEvaluator
  ) -> [OrganizationPolicyFinding] {
    let catalog = OrganizationPolicyIdentity(index.origin, root: index.policyPath)
    var result = evaluator.catalogAdmission(catalog)
    if destination != index {
      result += evaluator.source(destination.origin, root: destination.policyPath)
    }
    if let coordinate {
      result += evaluator.packageIdentity(
        .init(index.origin, suffix: coordinate.package, root: index.policyPath),
        catalog: catalog)
    }
    return result
  }
}
