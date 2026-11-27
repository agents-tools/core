import AgentsCore
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// An index artifact records the requested origin. Keep any redirects on that origin so a
/// later offline restore can enforce the same provenance that acquisition enforced.
final class PolicyHTTPRead: NSObject, URLSessionTaskDelegate {
  private let policy: EffectiveSourcePolicy
  private let origin: SourceOrigin
  private let requireOrigin: (@Sendable (SourceOrigin) throws -> Void)?
  private let redirectFailure = Mutex<(any Error)?>(nil)

  private init(
    policy: EffectiveSourcePolicy, origin: SourceOrigin,
    requireOrigin: (@Sendable (SourceOrigin) throws -> Void)?
  ) {
    self.policy = policy
    self.origin = origin
    self.requireOrigin = requireOrigin
  }

  static func fetch(
    _ url: URL, policy: EffectiveSourcePolicy,
    requireOrigin: (@Sendable (SourceOrigin) throws -> Void)? = nil
  ) throws -> Data {
    let origin = try SourceOrigin.http(url.absoluteString)
    try policy.require(origin)
    try requireOrigin?(origin)
    let delegate = PolicyHTTPRead(policy: policy, origin: origin, requireOrigin: requireOrigin)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let finished = DispatchSemaphore(value: 0)
    let result = Mutex<Result<Data, any Error>?>(nil)
    let task = session.dataTask(with: url) { bytes, response, error in
      result.withLock { output in
        if let failure = delegate.redirectFailure.withLock({ $0 }) {
          output = .failure(failure)
        } else if let error {
          output = .failure(
            CoreError.invalidSource("HTTP source request failed (code \((error as NSError).code))"))
        } else if let status = (response as? HTTPURLResponse)?.statusCode,
          (200..<300).contains(status), let bytes
        {
          output = .success(bytes)
        } else {
          output = .failure(CoreError.invalidSource("source returned no successful HTTP response"))
        }
      }
      finished.signal()
    }
    task.resume()
    while finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      if Task.isCancelled {
        task.cancel()
        throw CancellationError()
      }
    }
    return try result.withLock { try $0!.get() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    do {
      let destination = request.url.flatMap { try? SourceOrigin.http($0.absoluteString) }
      try policy.require(destination ?? .missing)
      try requireOrigin?(destination ?? .missing)
      guard destination == origin else { throw UnrecordedSourceRedirect() }
      completionHandler(request)
    } catch {
      redirectFailure.withLock { $0 = error }
      completionHandler(nil)
    }
  }
}

struct UnrecordedSourceRedirect: Error, CustomStringConvertible {
  var description: String {
    "Source policy requires an explicit origin for cross-origin downloads."
  }
}
