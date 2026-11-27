import AgentsCore
import AgentsManifest
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum MCPRegistryError: Error, Equatable, LocalizedError, Sendable {
  case invalidEndpoint
  case invalidQuery
  case invalidCredentials
  case requestFailed
  case redirectRejected
  case httpStatus(Int)
  case responseTooLarge
  case invalidResponse
  case unavailableChoice(String)
  case invalidSelection
  case invalidBinding(String)
  case missingBinding(String)
  case invalidPackageCommand
  case missingPackageCommand

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "The MCP registry needs an HTTP(S) base URL without credentials."
    case .invalidQuery: "The MCP registry query is invalid."
    case .invalidCredentials: "The request credentials are invalid for this MCP registry."
    case .requestFailed: "The MCP registry request failed."
    case .redirectRejected: "The MCP registry redirected the request. Use its canonical base URL."
    case .httpStatus(let code): "The MCP registry returned HTTP \(code)."
    case .responseTooLarge: "The MCP registry response exceeded the page size budget."
    case .invalidResponse: "The MCP registry response does not match the request or v0.1 format."
    case .unavailableChoice(let reason): reason
    case .invalidSelection: "Choose a name and at least one distinct MCP recipient."
    case .invalidBinding(let name): "Invalid symbolic MCP binding for \(name)."
    case .missingBinding(let name): "An input is required for \(name)."
    case .invalidPackageCommand: "The package console command is invalid for this choice."
    case .missingPackageCommand: "Enter the console command provided by the Python distribution."
    }
  }
}

public struct MCPRegistryPage: Sendable {
  public let servers: [MCPRegistryServer]
  /// Pass this opaque value back with the same search and version filter.
  public let nextCursor: String?
}

/// A read-only MCP Registry v0.1 client. Authentication is supplied to each request explicitly.
public struct MCPRegistry: Sendable {
  public static let official = try! MCPRegistry(
    endpoint: URL(string: "https://registry.modelcontextprotocol.io")!)

  /// The operator-selected registry for this runtime, or the public registry when unset.
  public static func configured(environment: RuntimeEnvironment = RuntimeEnvironment()) throws
    -> Self
  {
    guard let setting = environment.environment["MCP_REGISTRY_URL"], !setting.isEmpty else {
      return .official
    }
    guard let url = URL(string: setting) else { throw MCPRegistryError.invalidEndpoint }
    return try MCPRegistry(endpoint: url)
  }

  /// The registry base including any path prefix, before `/v0.1`.
  public let endpoint: URL
  private let servers: URLComponents

  public init(endpoint: URL) throws {
    guard var servers = URLComponents(url: endpoint, resolvingAgainstBaseURL: true),
      RegistryHTTP.validURL(servers), servers.query == nil,
      let absolute = servers.url
    else { throw MCPRegistryError.invalidEndpoint }
    servers.percentEncodedPath =
      servers.percentEncodedPath.replacingOccurrences(
        of: #"/+$"#, with: "", options: .regularExpression)
      + "/v0.1/servers"
    self.endpoint = absolute
    self.servers = servers
  }

  /// An omitted query lists servers. An omitted version lists all versions. Credential
  /// headers are scoped to this call and are never attached to results or selections.
  public func search(
    _ query: String? = nil, version: String? = "latest", limit: Int = 20, cursor: String? = nil,
    credentials: [String: String] = [:], scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(), refresh: Bool = false
  ) async throws -> MCPRegistryPage {
    let policy = try SourcePolicySnapshot(store: StateStore(scope: scope, environment: environment))
    try policy.effective.require(.http(endpoint.absoluteString))
    guard (1...100).contains(limit), version?.isEmpty != true else {
      throw MCPRegistryError.invalidQuery
    }
    var url = servers
    var fields = [("limit", String(limit))]
    if let query, !query.isEmpty { fields.append(("search", query)) }
    if let version { fields.append(("version", version)) }
    if let cursor, !cursor.isEmpty { fields.append(("cursor", cursor)) }
    url.percentEncodedQuery = fields.map { $0.0 + "=" + Self.escape($0.1) }.joined(separator: "&")
    return try await read(
      RegistryPageResponse.self, from: url, credentials: credentials, environment: environment,
      refresh: refresh
    ) { page in
      try policy.validate()
      return MCPRegistryPage(
        servers: try page.servers.map { try $0.inspection(registry: endpoint) },
        nextCursor: page.metadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
    }
  }

  /// Retrieves one server by its full registry name and exact version or the `latest` alias.
  public func server(
    named name: String, version: String = "latest", credentials: [String: String] = [:],
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    refresh: Bool = false
  ) async throws -> MCPRegistryServer {
    let policy = try SourcePolicySnapshot(store: StateStore(scope: scope, environment: environment))
    try policy.effective.require(.http(endpoint.absoluteString), reference: name)
    let invalidSegments = ["", ".", ".."]
    guard !invalidSegments.contains(name), !invalidSegments.contains(version) else {
      throw MCPRegistryError.invalidQuery
    }
    var url = servers
    url.percentEncodedPath += "/" + Self.escape(name) + "/versions/" + Self.escape(version)
    return try await read(
      RegistryServerResponse.self, from: url, credentials: credentials, environment: environment,
      refresh: refresh
    ) { result in
      guard result.server.name.utf8.elementsEqual(name.utf8),
        version == "latest" || result.server.version.utf8.elementsEqual(version.utf8)
      else { throw MCPRegistryError.invalidResponse }
      try policy.validate()
      return try result.inspection(registry: endpoint)
    }
  }

  private static func escape(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
  }

  private func read<Value: Decodable, Result>(
    _ type: Value.Type, from components: URLComponents, credentials: [String: String],
    environment: RuntimeEnvironment, refresh: Bool, validate: (Value) throws -> Result
  ) async throws -> Result {
    guard let url = components.url else { throw MCPRegistryError.invalidQuery }
    try environment.requireMCPRegistry(endpoint)
    let reserved = [
      "accept", "connection", "content-length", "content-type", "host", "proxy-authorization",
      "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
    ]
    guard credentials.isEmpty || RegistryHTTP.protectsCredentials(url),
      Set(credentials.keys.map { $0.lowercased() }).count == credentials.count,
      credentials.allSatisfy({
        RegistryHTTP.isHeaderName($0.key) && !reserved.contains($0.key.lowercased())
          && RegistryHTTP.isHeaderValue($0.value)
      })
    else { throw MCPRegistryError.invalidCredentials }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in credentials { request.setValue(value, forHTTPHeaderField: name) }

    request.httpShouldHandleCookies = false
    return try await RegistryAcquisition(environment: environment, endpoint: endpoint).read(
      request, anonymous: credentials.isEmpty, refresh: refresh
    ) { data in
      try Task.checkCancellation()
      try environment.requireMCPRegistry(endpoint)
      let value: Value
      do {
        value = try JSONDecoder().decode(type, from: data)
      } catch {
        // Decoder errors can contain server-provided content, including reflected credentials.
        throw MCPRegistryError.invalidResponse
      }
      return try validate(value)
    }
  }
}

/// Bounded in-memory response transfer. The delegate refuses redirects before any new request.
final class RegistryHTTP: NSObject, URLSessionDataDelegate {
  static let responseLimit = AcquisitionCache.registryResponseLimit
  struct Response: Sendable {
    let url: URL
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  private struct Transfer {
    var response: HTTPURLResponse?
    var body = Data()
    var failure: MCPRegistryError?
    var continuation: CheckedContinuation<Response, any Error>?
    var cancelled = false
  }
  private let transfer = Mutex(Transfer())

  static func validURL(_ url: URLComponents) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
      && url.user == nil && url.password == nil && url.fragment == nil
  }

  static func protectsCredentials(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" || ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? "")
  }

  static func isHeaderName(_ name: String) -> Bool {
    !name.isEmpty
      && name.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || "!#$%&'*+-.^_`|~".utf8.contains($0)
      }
  }

  static func isHeaderValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) }
  }

  func read(_ request: URLRequest) async throws -> Response {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [
      "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
      "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
    ]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        transfer.withLock {
          if $0.cancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            $0.continuation = continuation
            task.resume()
          }
        }
      }
    } onCancel: {
      let started = self.transfer.withLock {
        $0.cancelled = true
        return $0.continuation != nil
      }
      if started { task.cancel() }
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    transfer.withLock { $0.failure = .redirectRejected }
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    #if canImport(Security)
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        completionHandler(.performDefaultHandling, nil)
        return
      }
    #endif
    let status = (challenge.failureResponse as? HTTPURLResponse)?.statusCode
    transfer.withLock { $0.failure = status.map(MCPRegistryError.httpStatus) ?? .requestFailed }
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let allowed = transfer.withLock {
      guard $0.failure == nil else { return false }
      guard let response = response as? HTTPURLResponse else {
        $0.failure = .invalidResponse
        return false
      }
      guard response.statusCode == 200 || response.statusCode == 304 else {
        $0.failure = .httpStatus(response.statusCode)
        return false
      }
      guard response.expectedContentLength <= Self.responseLimit else {
        $0.failure = .responseTooLarge
        return false
      }
      $0.response = response
      return true
    }
    completionHandler(allowed ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = transfer.withLock {
      guard data.count <= Self.responseLimit - $0.body.count else {
        $0.failure = .responseTooLarge
        return true
      }
      $0.body.append(data)
      return false
    }
    if exceeded { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    transfer.withLock {
      guard let continuation = $0.continuation else { return }
      $0.continuation = nil
      if $0.cancelled {
        continuation.resume(throwing: CancellationError())
      } else if let failure = $0.failure {
        continuation.resume(throwing: failure)
      } else if error != nil {
        continuation.resume(throwing: MCPRegistryError.requestFailed)
      } else if let response = $0.response, let url = response.url {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
          if let key = key as? String, let value = value as? String {
            let field = key.lowercased()
            headers[field] = headers[field].map { $0 + ", " + value } ?? value
          }
        }
        continuation.resume(
          returning: .init(
            url: url, status: response.statusCode, headers: headers, body: $0.body))
      } else {
        continuation.resume(throwing: MCPRegistryError.invalidResponse)
      }
    }
  }
}
