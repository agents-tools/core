import AgentsCore
import AgentsManifest
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

package struct OrganizationPolicySnapshot: PreparedEvidence, Sendable {
  let chains: [OrganizationPolicyChain]
  let statuses: [OrganizationPolicyStatus]
  let loadFindings: [OrganizationPolicyFinding]
  let readDependencies: [ReadDependency]
  let fingerprint: String
  private let fileInputs: [TargetPrecondition]
  private let cacheUpdates: [URL: OrganizationPolicyLoader.Cached]
  private let absentRemoteURLs: Set<URL>
  private let observedAt: Date

  static func configured(_ store: StateStore) -> Bool {
    store.environment.userOrganizationPolicy != nil
      || (store.scope == .project && store.environment.projectOrganizationPolicy != nil)
  }

  init(
    store: StateStore, now: Date = Date(), offline: Bool = false,
    offlineObservations: OrganizationPolicySnapshot? = nil,
    fetch: @escaping (URL) throws -> OrganizationPolicyLoader.Response = OrganizationPolicyHTTP
      .fetch
  ) throws {
    let selections: [(InstallScope, OrganizationPolicySelection?)] = [
      (.user, store.environment.userOrganizationPolicy),
      (.project, store.scope == .project ? store.environment.projectOrganizationPolicy : nil),
    ]
    var loader = OrganizationPolicyLoader(
      store: store, now: now,
      fetch: offline ? { _ in throw OrganizationPolicyLoader.Offline() } : fetch)
    if let offlineObservations {
      let absences = offlineObservations.absentRemoteURLs
      let absenceAge = now.timeIntervalSince(offlineObservations.observedAt)
      loader = OrganizationPolicyLoader(
        store: store, now: now,
        fetch: { url in
          if (0...3600).contains(absenceAge), absences.contains(url) {
            return .init(status: 404, url: url, bytes: Data())
          }
          throw OrganizationPolicyLoader.Offline()
        }, previewCache: offlineObservations.cacheUpdates)
    }
    var chains: [OrganizationPolicyChain] = []
    var statuses: [OrganizationPolicyStatus] = []
    var findings: [OrganizationPolicyFinding] = []
    var fingerprints: [String] = []
    for (scope, optional) in selections {
      guard let selection = optional else { continue }
      try Task.checkCancellation()
      fingerprints.append(try ResolvedLedgerCodec.digest(selection))
      do {
        let chain = try loader.load(selection, scope: scope)
        if chain.layers.isEmpty {
          statuses.append(.init(authority: scope, outcome: .absent))
        } else {
          chains.append(chain)
          statuses.append(
            .init(
              authority: scope, outcome: .loaded, mode: chain.mode,
              documents: chain.layers.map(\.evidence)))
          for layer in chain.layers {
            fingerprints += [layer.evidence.url.absoluteString, layer.evidence.digest]
            for warning in layer.rules.warnings {
              findings.append(
                .init(
                  subject: .policy, identity: "organization policy", rule: "policy-field",
                  authority: scope, document: layer.evidence.url,
                  documentDigest: layer.evidence.digest, outcome: .warn, message: warning))
            }
            if layer.evidence.stale {
              findings.append(
                .init(
                  subject: .policy, identity: "organization policy", rule: "policy-stale",
                  authority: scope, document: layer.evidence.url,
                  documentDigest: layer.evidence.digest, outcome: .warn,
                  message: "Using previously verified policy bytes outside the freshness window."))
            }
          }
        }
      } catch let error as OrganizationPolicyLoader.Failure {
        statuses.append(.init(authority: scope, outcome: error.absent ? .absent : .unavailable))
        fingerprints += [error.absent ? "absent" : "unavailable", error.message]
        findings.append(
          .init(
            subject: .policy, identity: "organization policy", rule: "policy-unavailable",
            authority: scope, document: error.url, documentDigest: nil,
            outcome: selection.required || error.block ? .block : .warn, message: error.message))
      }
    }
    self.chains = chains
    self.statuses = statuses
    loadFindings = findings
    fileInputs = loader.fileInputs
    cacheUpdates = loader.cacheUpdates
    absentRemoteURLs = loader.absentRemoteURLs
    observedAt = now
    readDependencies = loader.readLocations.map { .entry($0) }
    fingerprint = try ResolvedLedgerCodec.digest(fingerprints)
    try validate()
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    for input in fileInputs {
      if targets.isEmpty {
        try input.validate()
      } else {
        try input.validateDuringPublication()
      }
    }
  }

  func report(_ findings: [OrganizationPolicyFinding] = []) -> OrganizationPolicyReport {
    var seen = Set<OrganizationPolicyFinding>()
    return .init(
      policies: statuses, findings: (loadFindings + findings).filter { seen.insert($0).inserted })
  }

  /// A read or a refused install never changes the cache. Cached documents are disposable.
  func rememberVerifiedPolicies() {
    for (url, entry) in cacheUpdates {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(entry)
        try bytes.write(to: url, options: .atomic)
      } catch {
        continue
      }
    }
  }
}

struct OrganizationPolicyLoader {
  static let maximumBytes = 256 * 1024
  static let offlineLifetime: TimeInterval = 7 * 86_400
  private static let maximumDocuments = 5

  struct Response {
    let status: Int
    let url: URL
    let bytes: Data
  }

  struct Cached: Codable, Sendable {
    let requested: URL
    let effective: URL
    let timestamp: Date
    let digest: String
    let bytes: Data
    var ttl: Int
    var fetchFailure: OrganizationPolicyMode
  }

  struct Failure: Error {
    let url: URL?
    let message: String
    var absent = false
    var block = false
  }

  struct Offline: Error { var block = false }

  private struct Loaded {
    let url: URL
    let bytes: Data
    let age: Int?
    let stale: Bool
    let cached: Cached?
  }

  let store: StateStore
  let now: Date
  let fetch: (URL) throws -> Response
  var fileInputs: [TargetPrecondition] = []
  var readLocations: [URL] = []
  var cacheUpdates: [URL: Cached] = [:]
  var absentRemoteURLs: Set<URL> = []
  var previewCache: [URL: Cached] = [:]

  mutating func load(_ selection: OrganizationPolicySelection, scope: InstallScope) throws
    -> OrganizationPolicyChain
  {
    let urls: [URL]
    let discovery: [URL]
    switch selection.source {
    case .invalidLocation:
      throw Failure(
        url: nil,
        message: "Choose an absolute policy file path, an HTTPS URL, or github:OWNER/REPO.",
        block: true)
    case .local(let url):
      guard url.isFileURL else { throw Failure(url: nil, message: "Expected a local policy file.") }
      urls = [url.standardizedFileURL]
      discovery = []
    case .https(let url):
      urls = [try Self.https(url)]
      discovery = []
    case .organization(let remote):
      discovery = try Self.discoveryURLs(remote)
      urls = discovery
    }
    var earlierOffline = false
    for url in urls {
      do {
        let (layers, updates) = try chain(
          at: url, discovery: discovery, earlierOffline: earlierOffline)
        for (key, entry) in updates {
          var admitted = entry
          if let same = cacheUpdates[key], same.digest == admitted.digest {
            admitted.ttl = min(same.ttl, admitted.ttl)
            admitted.fetchFailure = max(same.fetchFailure, admitted.fetchFailure)
          }
          cacheUpdates[key] = admitted
        }
        return OrganizationPolicyChain(scope: scope, layers: layers.reversed())
      } catch let error as Offline {
        if discovery.isEmpty || error.block {
          throw Failure(
            url: url, message: "The policy is unreachable and has no eligible cache.",
            block: error.block)
        }
        earlierOffline = true
      } catch let failure as Failure where failure.absent && !failure.block && !discovery.isEmpty {
        continue
      }
    }
    if earlierOffline {
      throw Failure(url: urls.first, message: "Organization discovery is incomplete offline.")
    }
    if selection.required {
      throw Failure(
        url: urls.first, message: "The required organization policy is absent.", absent: true)
    }
    return OrganizationPolicyChain(scope: scope, layers: [])
  }

  private mutating func chain(at url: URL, discovery: [URL], earlierOffline: Bool) throws
    -> ([OrganizationPolicyLayer], [URL: Cached])
  {
    for refresh in [false, true] {
      let leaf = try read(url, ttl: nil, forceRefresh: refresh)
      // An earlier unavailable candidate may own stronger policy. Offline discovery can
      // fall back only to a later candidate whose bytes were already verified.
      if earlierOffline && leaf.cached != nil {
        throw Failure(url: url, message: "An earlier organization policy source is unavailable.")
      }
      var layers: [OrganizationPolicyLayer] = []
      var pending: [URL: Cached] = [:]
      try append(
        leaf, request: url, discovery: discovery, authority: leaf.url, visited: [],
        layers: &layers, pendingCache: &pending, forceRefresh: refresh)
      let ttl = layers.map(\.rules.ttl).min()!
      if !refresh,
        layers.contains(where: {
          !$0.evidence.stale && ($0.evidence.ageSeconds ?? 0) > ttl
        })
      {
        continue
      }
      let failure = layers.map(\.rules.fetchFailure).max()!
      return (
        layers,
        pending.mapValues { item in
          var item = item
          item.ttl = ttl
          item.fetchFailure = failure
          return item
        }
      )
    }
    preconditionFailure("remote refresh terminates")
  }

  private mutating func append(
    _ loaded: Loaded, request: URL, discovery: [URL], authority: URL, visited: Set<URL>,
    layers: inout [OrganizationPolicyLayer], pendingCache: inout [URL: Cached], forceRefresh: Bool
  ) throws {
    guard layers.count < Self.maximumDocuments,
      !visited.contains(request), !visited.contains(loaded.url)
    else {
      throw Failure(
        url: loaded.url, message: "Organization policy inheritance cycle or depth limit.",
        block: true)
    }
    let rules: OrganizationRules
    do {
      rules = try OrganizationPolicyDocument.parse(loaded.bytes, url: loaded.url)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let known = try request.isFileURL ? nil : cachedEntry(request)
      throw Failure(
        url: loaded.url, message: "Invalid organization policy. \(error)",
        block: known?.fetchFailure == .block)
    }
    let digest = "sha256:" + FileHash.sha256Hex(data: loaded.bytes)
    layers.append(
      .init(
        rules: rules,
        evidence: .init(
          url: loaded.url, digest: digest, name: rules.name, version: rules.version,
          ageSeconds: loaded.age, stale: loaded.stale)))
    if let cached = loaded.cached { pendingCache[cacheURL(request)] = cached }
    guard let reference = rules.parent else { return }
    let parents: [URL]
    do {
      parents = try parentURLs(
        reference, child: loaded.url, authority: authority, discovery: discovery)
    } catch {
      throw Failure(
        url: loaded.url, message: "Invalid organization policy parent location.", block: true)
    }
    let ttl = layers.map(\.rules.ttl).min()
    for parent in parents {
      do {
        guard !visited.contains(parent), parent != loaded.url, parent != request,
          layers.count < Self.maximumDocuments
        else {
          throw Failure(
            url: parent, message: "Organization policy inheritance cycle or depth limit.",
            block: true)
        }
        let document = try read(parent, ttl: ttl, forceRefresh: forceRefresh)
        let inheritedAuthority = authority.isFileURL && !parent.isFileURL ? parent : authority
        try append(
          document, request: parent, discovery: discovery, authority: inheritedAuthority,
          visited: visited.union([request, loaded.url]), layers: &layers,
          pendingCache: &pendingCache, forceRefresh: forceRefresh)
        return
      } catch let error as Failure where error.absent && parents.count > 1 {
        continue
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let reason = (error as? Failure).map { " " + $0.message } ?? ""
        throw Failure(
          url: parent, message: "Organization policy parent could not be admitted." + reason,
          block: true)
      }
    }
    throw Failure(
      url: loaded.url, message: "The organization policy parent is absent.", block: true)
  }

  private func parentURLs(_ reference: String, child: URL, authority: URL, discovery: [URL])
    throws -> [URL]
  {
    if child.isFileURL {
      if reference.hasPrefix("https://"), let remote = URL(string: reference) {
        return [try Self.https(remote)]
      }
      guard !reference.contains("://"), reference != "org" else {
        throw Failure(url: child, message: "Expected a local path or an HTTPS policy parent.")
      }
      return [
        URL(fileURLWithPath: reference, relativeTo: child.deletingLastPathComponent())
          .standardizedFileURL
      ]
    }
    if reference == "org" {
      if !discovery.isEmpty { return discovery }
      if authority.host == "raw.githubusercontent.com" {
        let parts = authority.path.split(separator: "/")
        if parts.count >= 2 {
          return try Self.discoveryURLs("github.com/" + parts.prefix(2).joined(separator: "/"))
        }
      }
    }
    let qualified: URL?
    if reference.hasPrefix("https://") {
      qualified = URL(string: reference)
    } else if child.host == "raw.githubusercontent.com" {
      let segments = reference.split(separator: "/", omittingEmptySubsequences: false)
      qualified =
        segments.count == 2 && segments.allSatisfy(Self.repositorySegment)
        ? Self.githubURL(owner: String(segments[0]), repository: String(segments[1])) : nil
    } else {
      qualified = nil
    }
    guard let qualified else {
      throw Failure(url: child, message: "Expected a same-origin HTTPS parent.")
    }
    let parent = try Self.https(qualified)
    guard
      try SourceOrigin.http(parent.absoluteString) == SourceOrigin.http(authority.absoluteString)
    else { throw Failure(url: child, message: "Organization policy parent crosses HTTPS origins.") }
    return [parent]
  }

  private mutating func read(_ url: URL, ttl: Int?, forceRefresh: Bool) throws -> Loaded {
    if url.isFileURL {
      do {
        readLocations.append(url)
        let captured = try TargetPrecondition.readingFile(url, maximumFileBytes: Self.maximumBytes)
        fileInputs.append(captured.evidence)
        guard let bytes = captured.bytes else {
          throw Failure(url: url, message: "Organization policy file is absent.", absent: true)
        }
        guard bytes.count <= Self.maximumBytes else {
          throw Failure(url: url, message: "Organization policy exceeds the byte limit.")
        }
        return Loaded(url: url, bytes: bytes, age: nil, stale: false, cached: nil)
      } catch let error as Failure {
        throw error
      } catch {
        throw Failure(url: url, message: "Organization policy file cannot be read.")
      }
    }
    let persisted = try cachedEntry(url)
    let captured = previewCache[cacheURL(url)]
    let useCapture = captured.map { $0.timestamp > (persisted?.timestamp ?? .distantPast) } ?? false
    let cached = useCapture ? captured : persisted
    if let cached {
      let age = now.timeIntervalSince(cached.timestamp)
      if !forceRefresh, age <= Double(min(ttl ?? cached.ttl, cached.ttl)) {
        return Loaded(
          url: cached.effective, bytes: cached.bytes, age: Int(age), stale: false,
          cached: useCapture ? captured : nil)
      }
    }
    let response: Response
    do {
      response = try fetch(url)
    } catch is Offline {
      guard let cached, now.timeIntervalSince(cached.timestamp) <= Self.offlineLifetime else {
        throw Offline(block: cached?.fetchFailure == .block)
      }
      return Loaded(
        url: cached.effective, bytes: cached.bytes,
        age: Int(now.timeIntervalSince(cached.timestamp)), stale: true, cached: nil)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Failure(url: url, message: "Organization policy HTTPS request failed.", block: true)
    }
    do {
      try Self.requireSameOrigin(response.url, as: url)
    } catch {
      throw Failure(
        url: url, message: "Organization policy redirected outside its HTTPS origin.", block: true)
    }
    guard (200..<300).contains(response.status) else {
      if response.status == 404 { absentRemoteURLs.insert(url) }
      throw Failure(
        url: url, message: "Organization policy server returned HTTP \(response.status).",
        absent: response.status == 404,
        block: [401, 403].contains(response.status) || cached?.fetchFailure == .block)
    }
    guard response.bytes.count <= Self.maximumBytes else {
      throw Failure(url: url, message: "Organization policy exceeds the byte limit.")
    }
    let entry = Cached(
      requested: url, effective: response.url, timestamp: now,
      digest: FileHash.sha256Hex(data: response.bytes), bytes: response.bytes,
      ttl: 3600, fetchFailure: .warn)
    return Loaded(url: response.url, bytes: response.bytes, age: 0, stale: false, cached: entry)
  }

  private func cacheURL(_ url: URL) -> URL {
    let root = store.environment.homeDirectory.appendingPathComponent(
      ".cache/agents/organization-policies")
    let key = FileHash.sha256Hex(data: Data(url.absoluteString.utf8))
    return root.appendingPathComponent(key + ".json")
  }

  private mutating func cachedEntry(_ url: URL) throws -> Cached? {
    let location = cacheURL(url)
    readLocations.append(location)
    guard
      let captured = try? TargetPrecondition.readingFile(
        location, maximumFileBytes: Self.maximumBytes * 2)
    else { return nil }
    fileInputs.append(captured.evidence)
    guard let bytes = captured.bytes, bytes.count <= Self.maximumBytes * 2,
      let entry = try? JSONDecoder().decode(Cached.self, from: bytes),
      entry.requested == url, (try? Self.requireSameOrigin(entry.effective, as: url)) != nil,
      entry.bytes.count <= Self.maximumBytes,
      entry.digest == FileHash.sha256Hex(data: entry.bytes),
      now.timeIntervalSince(entry.timestamp) >= 0, (1...86_400).contains(entry.ttl),
      entry.fetchFailure != .off,
      (try? OrganizationPolicyDocument.parse(entry.bytes, url: entry.effective)) != nil
    else { return nil }
    return entry
  }

  static func https(_ url: URL) throws -> URL {
    guard url.scheme?.lowercased() == "https",
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      let canonical = parts.url, (try? SourceOrigin.http(canonical.absoluteString)) != nil
    else {
      throw Failure(
        url: nil, message: "Policy URLs must use HTTPS without credentials, query or fragment.")
    }
    return canonical
  }

  static func requireSameOrigin(_ destination: URL, as reference: URL) throws {
    let destination = try https(destination)
    guard
      try SourceOrigin.http(destination.absoluteString)
        == SourceOrigin.http(reference.absoluteString)
    else { throw Failure(url: reference, message: "Cross-origin policy redirect.") }
  }

  private static func repositorySegment(_ value: Substring) -> Bool {
    !value.isEmpty && value != "." && value != ".."
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }
  }

  private static func githubURL(owner: String, repository: String) -> URL {
    URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/HEAD/agents-policy.yaml")!
  }

  private static func discoveryURLs(_ remote: String) throws -> [URL] {
    guard let origin = try? SourceOrigin.git(remote), let identity = origin.identity,
      identity.hasPrefix("github.com/")
    else { throw Failure(url: nil, message: "Organization discovery requires a GitHub remote.") }
    let parts = identity.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.dropFirst().allSatisfy(repositorySegment) else {
      throw Failure(
        url: nil, message: "Organization discovery requires a GitHub repository remote.")
    }
    return [".github-private", ".github", ".apm", "_apm"].map {
      githubURL(owner: String(parts[1]), repository: $0)
    }
  }
}

final class OrganizationPolicyHTTP: NSObject, URLSessionDataDelegate {
  private struct State: Sendable {
    var response: HTTPURLResponse?
    var bytes = Data()
    var rejected = false
    var redirects = 0
  }

  private let origin: URL
  private let state = Mutex(State())
  private let finished = DispatchSemaphore(value: 0)
  private let result = Mutex<Result<OrganizationPolicyLoader.Response, any Error>?>(nil)

  private init(origin: URL) { self.origin = origin }

  static func fetch(_ url: URL) throws -> OrganizationPolicyLoader.Response {
    let delegate = Self(origin: url)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 20
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.dataTask(with: url)
    task.resume()
    while delegate.finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      if Task.isCancelled {
        task.cancel()
        throw CancellationError()
      }
    }
    return try delegate.result.withLock { try $0!.get() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let allowed = state.withLock { state in
      state.redirects += 1
      guard state.redirects <= 5, let url = request.url,
        (try? OrganizationPolicyLoader.requireSameOrigin(url, as: origin)) != nil
      else {
        state.rejected = true
        return false
      }
      return true
    }
    completionHandler(allowed ? request : nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let allowed = state.withLock { state in
      state.response = response as? HTTPURLResponse
      if response.expectedContentLength > Int64(OrganizationPolicyLoader.maximumBytes) {
        state.rejected = true
      }
      return state.response != nil && !state.rejected
    }
    completionHandler(allowed ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let cancel = state.withLock { state in
      guard data.count <= OrganizationPolicyLoader.maximumBytes - state.bytes.count else {
        state.rejected = true
        return true
      }
      state.bytes.append(data)
      return false
    }
    if cancel { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let output = state.withLock { state -> Result<OrganizationPolicyLoader.Response, any Error> in
      if state.rejected {
        return .failure(CoreError.invalidSource("organization policy HTTPS boundary"))
      }
      if let code = (error as? URLError)?.code,
        [
          .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
          .cannotConnectToHost, .dnsLookupFailed,
        ].contains(code)
      {
        return .failure(OrganizationPolicyLoader.Offline())
      }
      if let error { return .failure(error) }
      guard let response = state.response, let url = response.url else {
        return .failure(CoreError.invalidSource("missing organization policy HTTP response"))
      }
      return .success(.init(status: response.statusCode, url: url, bytes: state.bytes))
    }
    result.withLock { $0 = output }
    finished.signal()
  }
}
