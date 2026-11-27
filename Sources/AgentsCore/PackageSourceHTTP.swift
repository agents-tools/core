import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Bounded HTTPS transfer with one effective request and no credential storage.
package enum PackageSourceHTTP {
  package struct Response: Sendable {
    let status: Int
    let body: Data

    package init(status: Int, body: Data) {
      self.status = status
      self.body = body
    }
  }

  // Tests supply a local transport without modifying URLSession or OS trust.
  @TaskLocal package static var fixture: (@Sendable (URLRequest, Int?) throws -> Response)?

  static func read(_ request: URLRequest, maximumBytes: Int?) throws -> Response {
    guard let url = request.url else { throw SourceAccessError.requestFailed }
    _ = try SourceURL.https(url)
    if let fixture {
      let response = try fixture(request, maximumBytes)
      if let maximumBytes, response.body.count > maximumBytes {
        throw SourceAccessError.requestFailed
      }
      return response
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 90

    var request = request
    request.httpShouldHandleCookies = false
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let delegate = Transfer(maximumBytes: maximumBytes)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    session.dataTask(with: request).resume()
    guard delegate.finished.wait(timeout: .now() + 95) == .success else {
      throw SourceAccessError.requestFailed
    }
    return try delegate.response()
  }

  private final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
    struct State {
      var status: Int?
      var body = Data()
      var failed = false
    }

    let finished = DispatchSemaphore(value: 0)
    let maximumBytes: Int?
    let state = Mutex(State())

    init(maximumBytes: Int?) { self.maximumBytes = maximumBytes }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
        -> Void
    ) {
      // Foundation still performs its standard TLS certificate checks.
      let serverTrust =
        challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust"
      completionHandler(serverTrust ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      let status = (response as? HTTPURLResponse)?.statusCode
      let readBody = status == 200 && maximumBytes != nil
      state.withLock {
        $0.status = status
        if let maximumBytes, readBody, response.expectedContentLength > maximumBytes {
          $0.failed = true
        }
      }
      completionHandler(readBody && !state.withLock({ $0.failed }) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let accepted = state.withLock {
        guard !$0.failed, let maximumBytes, data.count <= maximumBytes - $0.body.count else {
          $0.failed = true
          return false
        }
        $0.body.append(data)
        return true
      }
      if !accepted { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      state.withLock {
        if $0.status == nil || ($0.status == 200 && maximumBytes != nil && error != nil) {
          $0.failed = true
        }
      }
      finished.signal()
    }

    func response() throws -> Response {
      try state.withLock {
        guard !$0.failed, let status = $0.status else { throw SourceAccessError.requestFailed }
        return Response(status: status, body: $0.body)
      }
    }
  }
}
