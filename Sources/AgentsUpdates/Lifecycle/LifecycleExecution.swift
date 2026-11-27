import AgentsCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Security)
  import Security
#endif

struct LifecyclePayload: Encodable {
  let version = 1
  let event: LifecycleEvent
  let scope: InstallScope
  let test: Bool
}

enum LifecycleCommand {
  static func spawn(
    _ action: CapturedLifecycleAction, in directory: DirectoryHandle,
    environment: RuntimeEnvironment
  ) throws -> OwnedDuplexProcess {
    guard case .command(let field, let script, let overrides) = action.value.body else {
      throw CoreError.invalidState("Expected a lifecycle command.")
    }
    var child = environment.environment.merging(overrides) { _, authored in authored }
    child["APM_NO_SCRIPTS"] = "1"
    return try OwnedDuplexProcess(
      .init(
        executable: field == .bash ? "/bin/bash" : "/bin/sh", arguments: ["-c", script],
        directory: directory.lifecycleDirectoryURL, environment: child),
      workingDirectory: directory)
  }

  static func finish(
    _ process: OwnedDuplexProcess, action: LifecycleActionSummary, payload: Data
  ) async -> LifecycleActionResult {
    let deadline = ContinuousClock.now + .seconds(action.timeoutSeconds)
    let outputLimit = 64 * 1024
    var stdout = 0
    var stderr = 0
    var offset = 0
    var outputEnded = false
    var errorEnded = false
    var disposition = LifecycleActionDisposition.commandTimedOut
    while ContinuousClock.now < deadline && !Task.isCancelled {
      if offset < payload.count {
        do { offset += try process.write(payload, offset: offset) } catch { offset = payload.count }
      }
      if offset == payload.count { process.closeInput() }
      do {
        switch try process.readStandardOutput() {
        case .bytes(let bytes): stdout += bytes.count
        case .end: outputEnded = true
        case .wouldBlock: break
        }
        switch try process.readStandardError() {
        case .bytes(let bytes): stderr += bytes.count
        case .end: errorEnded = true
        case .wouldBlock: break
        }
      } catch {
        disposition = .commandFailed
        break
      }
      if stdout + stderr > outputLimit {
        disposition = .commandOutputLimit
        break
      }
      if outputEnded && errorEnded, let exited = process.exitIfFinished() {
        switch exited {
        case .status(let status):
          return result(status == 0 ? .commandSucceeded : .commandFailed, status: status)
        case .signal(let signal):
          return result(.commandFailed, signal: signal)
        }
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    if Task.isCancelled { disposition = .commandCancelled }
    let cleaned = await process.finish(
      grace: .zero, terminate: .milliseconds(100), killWait: .seconds(1))
    switch process.exitIfFinished() {
    case .status(let status): return result(disposition, status: status, cleaned: cleaned)
    case .signal(let signal): return result(disposition, signal: signal, cleaned: cleaned)
    case nil: return result(disposition, cleaned: cleaned)
    }

    func result(
      _ disposition: LifecycleActionDisposition, status: Int32? = nil, signal: Int32? = nil,
      cleaned: Bool = true
    ) -> LifecycleActionResult {
      LifecycleActionResult(
        action: action, disposition: disposition, dispatched: true, withholding: nil,
        exitStatus: status, signal: signal, httpStatus: nil, stdoutBytes: min(stdout, outputLimit),
        stderrBytes: min(stderr, outputLimit), processGroupCleanedUp: cleaned, diagnostics: [])
    }
  }

  static func launchFailed(_ action: LifecycleActionSummary) -> LifecycleActionResult {
    LifecycleActionResult(
      action: action, disposition: .commandLaunchFailed, dispatched: false, withholding: nil,
      exitStatus: nil, signal: nil, httpStatus: nil, stdoutBytes: 0, stderrBytes: 0,
      processGroupCleanedUp: nil, diagnostics: [])
  }
}

struct LifecycleHTTPInput {
  let request: URLRequest

  init?(action: DeclaredLifecycleAction, environment: [String: String], payload: Data) {
    guard case .http(let url, let headers, let allowed) = action.body else { return nil }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: TimeInterval(action.timeout))
    request.httpMethod = "POST"
    request.httpBody = payload
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpShouldHandleCookies = false
    for (field, template) in headers {
      guard let value = Self.expand(template, environment: environment, allowed: allowed),
        value.utf8.count <= 8_192
      else { return nil }
      request.setValue(value, forHTTPHeaderField: field)
    }
    self.request = request
  }

  static func expand(
    _ template: String, environment: [String: String], allowed: Set<String>
  ) -> String? {
    let bytes = Array(template.utf8)
    var output = Data()
    var offset = 0
    while offset < bytes.count {
      guard bytes[offset] == 36, offset + 1 < bytes.count else {
        output.append(bytes[offset])
        offset += 1
        continue
      }
      var end = offset + 1
      let braced = bytes[end] == 123
      if braced { end += 1 }
      let start = end
      while end < bytes.count,
        (65...90).contains(bytes[end]) || (97...122).contains(bytes[end])
          || (48...57).contains(bytes[end]) || bytes[end] == 95
      {
        end += 1
      }
      let name = String(decoding: bytes[start..<end], as: UTF8.self)
      if !braced && !LifecycleDeclaration.isVariable(name) {
        output.append(bytes[offset])
        offset += 1
        continue
      }
      guard !braced || (end < bytes.count && bytes[end] == 125),
        LifecycleDeclaration.isVariable(name),
        !isCredentialName(name) || allowed.contains(name),
        let value = environment[name], value.utf8.count <= 8_192
      else { return nil }
      output.append(contentsOf: value.utf8)
      if output.count > 8_192 { return nil }
      offset = end + (braced ? 1 : 0)
    }
    let value = String(decoding: output, as: UTF8.self)
    guard value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) })
    else { return nil }
    return value
  }

  private static func isCredentialName(_ name: String) -> Bool {
    let upper = name.uppercased()
    let fragments = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "APIKEY", "PRIVATEKEY"]
    let words: Set<Substring> = [
      "KEY", "PAT", "PASS", "AUTH", "AUTHORIZATION", "COOKIE", "SESSION", "PASSPHRASE",
    ]
    return fragments.contains(where: upper.contains)
      || !words.isDisjoint(with: upper.split(separator: "_"))
  }
}

/// The delegate consumes response metadata only. URLSession owns all network work after resume.
final class LifecycleHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var transfers: [Int: LifecycleHTTPTransfer] = [:]

  // Test fixtures can assign an ephemeral loopback-only anchor without changing OS trust.
  @TaskLocal static var loopbackTrustAnchorForTesting: Data?
  private let loopbackTrustAnchor = loopbackTrustAnchorForTesting

  func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  func start(
    _ request: URLRequest, in session: URLSession, action: LifecycleActionSummary
  ) -> LifecycleHTTPTransfer {
    let task = session.dataTask(with: request)
    let transfer = LifecycleHTTPTransfer(task: task, action: action)
    lock.withLock { transfers[task.taskIdentifier] = transfer }
    task.resume()
    return transfer
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    complete(task, status: response.statusCode)
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    respond(to: challenge, task: task, completionHandler: completionHandler)
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    respond(to: challenge, task: nil, completionHandler: completionHandler)
  }

  private func respond(
    to challenge: URLAuthenticationChallenge, task: URLSessionTask?,
    completionHandler: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    #if canImport(Security)
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        guard let loopbackTrustAnchor else {
          completionHandler(.performDefaultHandling, nil)
          return
        }
        guard challenge.protectionSpace.host == "127.0.0.1",
          let trust = challenge.protectionSpace.serverTrust,
          let anchor = SecCertificateCreateWithData(nil, loopbackTrustAnchor as CFData),
          SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
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
    if let task, let response = challenge.failureResponse as? HTTPURLResponse {
      complete(task, status: response.statusCode)
    }
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    complete(dataTask, status: (response as? HTTPURLResponse)?.statusCode)
    completionHandler(.cancel)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    complete(task, status: nil)
  }

  private func complete(_ task: URLSessionTask, status: Int?) {
    let transfer = lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
    transfer?.complete(status: status)
  }
}

final class LifecycleHTTPTransfer: @unchecked Sendable {
  private enum Response {
    case pending
    case received(Int)
    case unknown
  }
  private let lock = NSLock()
  private let task: URLSessionDataTask
  private let action: LifecycleActionSummary
  private let deadline: ContinuousClock.Instant
  private var response = Response.pending

  init(task: URLSessionDataTask, action: LifecycleActionSummary) {
    self.task = task
    self.action = action
    deadline = ContinuousClock.now + .seconds(action.timeoutSeconds)
  }

  func complete(status: Int?) {
    lock.withLock {
      guard case .pending = response else { return }
      response = (ContinuousClock.now < deadline ? status : nil).map(Response.received) ?? .unknown
    }
  }

  func result(drainBy: ContinuousClock.Instant? = nil) async -> LifecycleActionResult {
    let limit = min(deadline, drainBy ?? deadline)
    while true {
      let snapshot = lock.withLock { response }
      switch snapshot {
      case .received(let status):
        return result((200...299).contains(status) ? .httpSucceeded : .httpRejected, status: status)
      case .unknown: return result(.deliveryUnknown)
      case .pending:
        if Task.isCancelled || ContinuousClock.now >= limit {
          complete(status: nil)
          task.cancel()
        } else {
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
  }

  private func result(
    _ disposition: LifecycleActionDisposition, status: Int? = nil
  ) -> LifecycleActionResult {
    .init(
      action: action, disposition: disposition, dispatched: true, withholding: nil,
      exitStatus: nil, signal: nil, httpStatus: status, stdoutBytes: 0, stderrBytes: 0,
      processGroupCleanedUp: nil, diagnostics: [])
  }
}
