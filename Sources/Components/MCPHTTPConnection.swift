import Foundation
import MCP

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One ephemeral session per explicit connection test. All job and endpoint
/// state is protected by lock; delegate callbacks never create Swift Tasks.
final class MCPHTTPConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Mode { case streamable, legacy }
  private final class Job {
    var request: URLRequest
    let expected: ID?
    let events: Bool
    let legacyPost: Bool
    var continuation: CheckedContinuation<Void, Error>?
    var parser: MCPSSEParser
    var body = Data()
    var sse = false
    var json = false
    var responseSeen = false
    var redirects = 0
    var resumes = 0
    var retryAt = ContinuousClock.now
    init(
      request: URLRequest, expected: ID?, events: Bool, legacyPost: Bool,
      continuation: CheckedContinuation<Void, Error>?, limit: Int
    ) {
      self.request = request
      self.expected = expected
      self.events = events
      self.legacyPost = legacyPost
      self.continuation = continuation
      parser = MCPSSEParser(limit: limit)
    }
    func finish(_ error: MCPConnectionIssue? = nil) {
      let pending = continuation
      continuation = nil
      if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
  }

  private let lock = NSLock()
  private let sink: MCPMessageSink
  private let mode: Mode
  private let url: URL
  private let headers: [String: String]
  private let limits: MCPConnectionLimits
  private var session: URLSession!
  private var sessionID: String?
  private var endpoint: URL?
  private var endpointWaiter: CheckedContinuation<Void, Error>?
  private var active: [Int: Job] = [:]
  private var resumes: [Job] = []
  private var closed = false
  private var invalidated = false

  init(url: URL, headers: [String: String], mode: Mode, sink: MCPMessageSink) {
    self.url = url
    self.headers = headers
    self.mode = mode
    self.sink = sink
    limits = sink.limits
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = limits.totalTimeout
    configuration.timeoutIntervalForResource = limits.totalTimeout
    configuration.httpMaximumConnectionsPerHost = limits.queueMessages
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  static func validURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
      && url.user == nil && url.password == nil && url.fragment == nil
  }

  static func validHeaders(_ headers: [String: String]) -> Bool {
    let reserved = [
      "host", "content-length", "transfer-encoding", "connection", "content-type", "accept",
      "mcp-session-id", "mcp-protocol-version", "last-event-id",
    ]
    let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
    var names = Set<String>()
    return headers.allSatisfy { key, value in
      !key.isEmpty && names.insert(key.lowercased()).inserted
        && !reserved.contains(key.lowercased())
        && key.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || punctuation.contains($0)
        }
        && value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }
  }

  private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
    func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    return validURL(second) && first.scheme?.lowercased() == second.scheme?.lowercased()
      && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
  }

  private func request(_ target: URL, method: String, body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: target)
    request.httpMethod = method
    request.httpBody = body
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if mode == .streamable {
      request.setValue(sink.version ?? Version.latest, forHTTPHeaderField: "MCP-Protocol-Version")
      if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    }
    return request
  }

  private func startLocked(_ job: Job) throws {
    guard !closed else { throw MCPConnectionIssue.connectionClosed }
    guard active.count + resumes.count < limits.queueMessages else {
      throw MCPConnectionIssue.queueLimit
    }
    let task = session.dataTask(with: job.request)
    active[task.taskIdentifier] = job
    task.resume()
  }

  func connect() async throws {
    if mode == .streamable { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock {
        guard !closed else {
          continuation.resume(throwing: MCPConnectionIssue.connectionClosed)
          return
        }
        endpointWaiter = continuation
        do {
          try startLocked(
            Job(
              request: request(url, method: "GET"), expected: nil,
              events: true, legacyPost: false, continuation: nil, limit: limits.frameBytes))
        } catch {
          endpointWaiter = nil
          continuation.resume(throwing: MCPConnectionIssue.connectionFailed)
          sink.fail(.connectionFailed)
        }
      }
    }
  }

  func send(_ data: Data, header: MCPWireHeader) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock {
        guard !closed else {
          continuation.resume(throwing: MCPConnectionIssue.connectionClosed)
          return
        }
        let target = mode == .legacy ? endpoint : url
        guard let target else {
          continuation.resume(throwing: MCPConnectionIssue.protocolError)
          return
        }
        let job = Job(
          request: request(target, method: "POST", body: data),
          expected: header.method == nil ? nil : header.id,
          events: false, legacyPost: mode == .legacy,
          continuation: continuation, limit: limits.frameBytes)
        do { try startLocked(job) } catch {
          let issue = error as? MCPConnectionIssue ?? .connectionFailed
          job.finish(issue)
          sink.fail(issue)
        }
      }
    }
  }

  /// A single transport pump owns bounded resumption scheduling; delegate
  /// callbacks queue at most queueMessages resumptions and never replay POST.
  func tick() {
    lock.withLock {
      guard !closed else { return }
      while let index = resumes.firstIndex(where: { $0.retryAt <= .now }) {
        let job = resumes.remove(at: index)
        do { try startLocked(job) } catch {
          job.finish(.connectionFailed)
          sink.fail(.connectionFailed)
        }
      }
    }
  }

  func abort() {
    let session: URLSession? = lock.withLock {
      guard !closed else { return nil }
      closed = true
      endpointWaiter?.resume(throwing: MCPConnectionIssue.connectionClosed)
      endpointWaiter = nil
      for job in resumes { job.finish(.connectionClosed) }
      resumes.removeAll()
      return self.session
    }
    session?.invalidateAndCancel()
  }

  func finish() async -> Bool {
    abort()
    let deadline = ContinuousClock.now + .seconds(limits.cleanupKillWait)
    repeat {
      if lock.withLock({ invalidated && active.isEmpty && resumes.isEmpty }) { return true }
      try? await Task.sleep(for: .milliseconds(2))
    } while ContinuousClock.now < deadline
    return false
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let allow = lock.withLock { () -> Bool in
      guard !closed, let job = active[dataTask.taskIdentifier],
        let response = response as? HTTPURLResponse
      else { return false }
      let issue: MCPConnectionIssue?
      switch response.statusCode {
      case 401: issue = .authenticationRequired
      case 403: issue = .forbidden
      case 404 where sessionID != nil: issue = .sessionExpired
      case 200, 202, 204: issue = nil
      default: issue = .connectionFailed
      }
      if let issue {
        sink.fail(issue)
        return false
      }
      if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id"), mode == .streamable {
        guard !value.isEmpty, value.utf8.count <= 1024,
          value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
          sessionID == nil || sessionID == value
        else {
          sink.fail(.protocolError)
          return false
        }
        sessionID = value
      }
      let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased()
      job.sse = type == "text/event-stream"
      job.json = type == "application/json"
      if job.events || (job.expected != nil && !job.legacyPost) {
        guard response.statusCode == 200, job.sse || (!job.events && job.json) else {
          sink.fail(.protocolError)
          return false
        }
      }
      return true
    }
    completionHandler(allow ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
    lock.withLock {
      guard !closed, let job = active[dataTask.taskIdentifier] else { return }
      do {
        try sink.receiveBytes(bytes.count)
        if job.legacyPost { return }
        if job.expected == nil && !job.events && !bytes.isEmpty {
          throw MCPConnectionIssue.protocolError
        }
        if job.sse {
          var parser = job.parser
          try parser.feed(bytes) { event in
            if mode == .legacy && job.events && event.name == "endpoint" {
              guard endpoint == nil, let text = String(data: event.data, encoding: .utf8),
                let candidate = URL(string: text, relativeTo: url)?.absoluteURL,
                Self.sameOrigin(url, candidate)
              else { throw MCPConnectionIssue.authorityChanged }
              endpoint = candidate
              endpointWaiter?.resume()
              endpointWaiter = nil
            } else if event.name.isEmpty || event.name == "message" {
              try sink.admit(event.data)
              if let expected = job.expected,
                let header = try? JSONDecoder().decode(MCPWireHeader.self, from: event.data),
                header.id == expected && header.method == nil
              {
                job.responseSeen = true
              }
            }
          }
          job.parser = parser
        } else if job.json {
          guard bytes.count <= limits.frameBytes - job.body.count else {
            throw MCPConnectionIssue.messageLimit
          }
          job.body.append(bytes)
        } else if !bytes.isEmpty {
          throw MCPConnectionIssue.protocolError
        }
      } catch {
        sink.fail(error as? MCPConnectionIssue ?? .protocolError)
        dataTask.cancel()
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.withLock {
      guard let job = active.removeValue(forKey: task.taskIdentifier) else { return }
      if closed || sink.failure != nil {
        job.finish(sink.failure ?? .connectionClosed)
        return
      }
      do {
        if (error as? URLError)?.code == .timedOut { throw MCPConnectionIssue.timeout }
        if job.json && job.expected != nil && !job.legacyPost {
          if error != nil { throw MCPConnectionIssue.connectionFailed }
          let header = try? JSONDecoder().decode(MCPWireHeader.self, from: job.body)
          guard header?.id == job.expected, header?.method == nil else {
            throw MCPConnectionIssue.protocolError
          }
          try sink.admit(job.body)
          job.responseSeen = true
        }
        if job.events { throw MCPConnectionIssue.connectionClosed }
        if job.sse && job.expected != nil && !job.responseSeen && mode == .streamable,
          let id = job.parser.lastID, !id.isEmpty
        {
          guard job.resumes < limits.resumes else { throw MCPConnectionIssue.resumeLimit }
          let delay = job.parser.retry ?? 0
          guard delay < limits.totalTimeout else { throw MCPConnectionIssue.timeout }
          job.resumes += 1
          job.retryAt = .now + .seconds(delay)
          job.request = request(url, method: "GET")
          job.request.setValue(id, forHTTPHeaderField: "Last-Event-ID")
          job.parser.restart()
          resumes.append(job)
          return
        }
        if error != nil { throw MCPConnectionIssue.connectionFailed }
        if job.expected != nil && !job.legacyPost && !job.responseSeen {
          throw MCPConnectionIssue.protocolError
        }
        job.finish()
      } catch {
        let issue = error as? MCPConnectionIssue ?? .connectionFailed
        job.finish(issue)
        sink.fail(issue)
      }
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let next: URLRequest? = lock.withLock {
      guard !closed, let job = active[task.taskIdentifier], let target = request.url,
        Self.sameOrigin(url, target)
      else {
        sink.fail(.authorityChanged)
        return nil
      }
      guard job.redirects < limits.redirects else {
        sink.fail(.redirectLimit)
        return nil
      }
      guard request.httpMethod == job.request.httpMethod else {
        sink.fail(.protocolError)
        return nil
      }
      job.redirects += 1
      job.request.url = target
      return job.request
    }
    completionHandler(next)
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
    sink.fail(.authenticationRequired)
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    lock.withLock {
      invalidated = true
      for job in active.values { job.finish(.connectionClosed) }
      active.removeAll()
    }
  }
}
