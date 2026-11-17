import AgentsCore
import Components
import Foundation

public enum MCPConnectionPreparationError: String, Error, Sendable {
  case invalidSelection, invalidConfiguration, invalidResource, resourceChanged
}

/// Fixed selected input; it neither resolves sources nor looks up a component by
/// name. Literal configuration and captured resource bytes have no debug dump.
public struct MCPConnectionSnapshot: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let id: UUID
  public let selectionID: String
  var durableReadLocations: [URL]
  /// Durable invalidation inputs; never borrowed or per-test staging directories.
  public var readLocations: [URL] { durableReadLocations }
  fileprivate let inputBytes: Int
  fileprivate let transport: MCPTransportDeclaration
  fileprivate let directory: MCPConnectionResource?
  fileprivate let executable: MCPConnectionResource?
  public var description: String { "<MCP connection snapshot>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

public struct MCPConnectionDescription: Codable, Sendable, Equatable {
  public enum Transport: String, Codable, Sendable { case stdio, streamableHTTP, sse }
  public let snapshotID: UUID
  public let transport: Transport
  public let startsOwnedProcess: Bool
  public let requiredBindings: [String]
  public let environmentBindings: [String]
  /// Display text only; never reconstruct a command from this redacted projection.
  public let executable: String?
  public let arguments: [String]?
  public let workingDirectory: String?
  /// Captured paths identify fixed source content, not a future staging location.
  public let executableIsCaptured: Bool
  public let workingDirectoryIsCaptured: Bool
  /// Origin with path/query withheld; no header or credential values are exposed.
  public let endpoint: String?
  public let readLocations: [URL]
}

/// Protocol time excludes the separately bounded owned cleanup. The total timer
/// also includes synchronous binding and per-test resource materialization.
public struct MCPConnectionTestOptions: Sendable {
  fileprivate var limits = MCPConnectionLimits()
  public var clientName = "agents-tools"
  public var clientVersion = "1"
  public var totalTimeout: TimeInterval {
    get { limits.totalTimeout }
    set { limits.totalTimeout = newValue }
  }
  public var requestTimeout: TimeInterval {
    get { limits.requestTimeout }
    set { limits.requestTimeout = newValue }
  }
  public var maximumTools: Int {
    get { limits.tools }
    set { limits.tools = newValue }
  }
  public var maximumPages: Int {
    get { limits.pages }
    set { limits.pages = newValue }
  }
  public init() {}
}

public struct MCPConnectionTestResult: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable {
    case discovered
    /// Handshake succeeded; the server did not advertise tools discovery.
    case noTools
    case incomplete, failed
  }
  public enum Issue: String, Error, Codable, Sendable {
    case invalidInput, bindingUnavailable, invalidBinding, resourceChanged
    case connectionFailed, connectionClosed, protocolError, unsupportedVersion
    case authenticationRequired, forbidden, authorityChanged, sessionExpired
    case messageLimit, receiveLimit, sendLimit, stderrLimit, queueLimit
    case pageLimit, toolLimit, textLimit, redirectLimit, resumeLimit, cursorCycle
    case timeout, cancelled, cleanupFailed
  }
  public struct Tool: Codable, Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String?
  }
  public let snapshotID: UUID
  public let startedAt: Date
  public let finishedAt: Date
  /// Monotonic elapsed time, including owned cleanup.
  public let elapsed: TimeInterval
  public let transport: MCPConnectionDescription.Transport
  public let outcome: Outcome
  public let issue: Issue?
  public let negotiatedVersion: String?
  public let tools: [Tool]
  public let cleanupComplete: Bool
}

public enum MCPConnectionOperations {
  /// Call within the source borrowing scope after selecting an exact payload.
  /// Resource handles already captured that scope's bytes; no lock survives here.
  public static func snapshot(
    selectionID: String, transport: MCPTransportDeclaration,
    workingDirectory: MCPConnectionResource? = nil, executable: MCPConnectionResource? = nil
  ) throws -> MCPConnectionSnapshot {
    guard !selectionID.isEmpty, selectionID.utf8.count <= 4096, !selectionID.utf8.contains(0) else {
      throw MCPConnectionPreparationError.invalidSelection
    }
    var remaining = MCPConnectionLimits().inputBytes
    func charge(_ text: String) throws {
      guard !text.utf8.contains(0), text.utf8.count < remaining else {
        throw MCPConnectionPreparationError.invalidConfiguration
      }
      remaining -= text.utf8.count + 1
    }
    func chargeBinding(_ binding: RuntimeBinding) throws {
      switch binding {
      case .environment(let name), .secret(let name):
        guard !name.isEmpty else { throw MCPConnectionPreparationError.invalidConfiguration }
      case .literal: break
      }
      try charge(binding.text)
    }
    switch transport {
    case .stdio(let run):
      guard workingDirectory?.directory == true,
        !run.executable.isEmpty, run.executable.contains("/") == (executable != nil),
        executable?.directory != true
      else { throw MCPConnectionPreparationError.invalidConfiguration }
      try charge(run.executable)
      for argument in run.arguments { try charge(argument) }
      for (key, binding) in run.environment {
        guard !key.isEmpty, !key.contains("=") else {
          throw MCPConnectionPreparationError.invalidConfiguration
        }
        try charge(key)
        try chargeBinding(binding)
      }
    case .streamableHTTP(let url, let headers), .sse(let url, let headers):
      guard workingDirectory == nil, executable == nil,
        let parsed = URL(string: url),
        ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
        parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil,
        parsed.fragment == nil
      else { throw MCPConnectionPreparationError.invalidConfiguration }
      try charge(url)
      let token = Set(
        "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
      let reserved = Set([
        "host", "content-length", "transfer-encoding", "connection", "content-type", "accept",
        "mcp-session-id", "mcp-protocol-version", "last-event-id",
      ])
      var names = Set<String>()
      for (key, binding) in headers {
        guard !key.isEmpty, key.utf8.allSatisfy({ token.contains($0) }),
          !reserved.contains(key.lowercased()), names.insert(key.lowercased()).inserted
        else {
          throw MCPConnectionPreparationError.invalidConfiguration
        }
        try charge(key)
        try chargeBinding(binding)
        if case .literal(let value) = binding,
          !value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) })
        {
          throw MCPConnectionPreparationError.invalidConfiguration
        }
      }
    }
    let bytes = (workingDirectory?.byteCount ?? 0) + (executable?.byteCount ?? 0)
    guard bytes <= LedgerLimits.standard.resourceBytes else {
      throw MCPConnectionPreparationError.invalidResource
    }
    return MCPConnectionSnapshot(
      id: UUID(), selectionID: selectionID,
      durableReadLocations: Array(
        Set(
          (workingDirectory?.readLocations ?? []) + (executable?.readLocations ?? [])
        )
      ).sorted { $0.path < $1.path },
      inputBytes: MCPConnectionLimits().inputBytes - remaining,
      transport: transport,
      directory: workingDirectory, executable: executable)
  }

  /// Pure metadata projection: no filesystem, provider, process or network access.
  public static func describe(_ snapshot: MCPConnectionSnapshot) -> MCPConnectionDescription {
    let bindings = snapshot.transport.bindings.values
    var privateValues = bindings.compactMap {
      if case .literal(let value) = $0 { value } else { nil }
    }
    if snapshot.transport.kind != .stdio {
      privateValues += privateValues.flatMap {
        $0.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      }
    }
    let redaction = MCPConnectionRedaction(
      privateValues: privateValues, byteLimit: MCPConnectionLimits().textBytes)
    var executable: String?
    var arguments: [String]?
    var directory: String?
    var endpoint: String?
    switch snapshot.transport {
    case .stdio(let run):
      executable = redaction.text(run.executable)
      arguments = run.arguments.map(redaction.text)
      directory = snapshot.directory.map { redaction.text($0.displayPath) }
    case .streamableHTTP(let url, _), .sse(let url, _):
      if var origin = URLComponents(string: url) {
        let withheld = !origin.percentEncodedPath.isEmpty || origin.percentEncodedQuery != nil
        origin.percentEncodedPath = ""
        origin.percentEncodedQuery = nil
        endpoint = redaction.text((origin.string ?? "[redacted]") + (withheld ? "/[redacted]" : ""))
      }
    }
    return MCPConnectionDescription(
      snapshotID: snapshot.id, transport: snapshot.transport.kind,
      startsOwnedProcess: snapshot.transport.kind == .stdio,
      requiredBindings: Set(
        bindings.compactMap { if case .secret(let name) = $0 { name } else { nil } }
      ).sorted(),
      environmentBindings: Set(
        bindings.compactMap { if case .environment(let name) = $0 { name } else { nil } }
      ).sorted(),
      executable: executable, arguments: arguments, workingDirectory: directory,
      executableIsCaptured: snapshot.executable?.isCaptured ?? false,
      workingDirectoryIsCaptured: snapshot.directory?.isCaptured ?? false,
      endpoint: endpoint, readLocations: snapshot.readLocations)
  }

  /// Tests only this selected value, never a refreshed source or matching name.
  /// The sole shared provider must obey its bounded synchronous data contract.
  public static func test(
    _ snapshot: MCPConnectionSnapshot, options: MCPConnectionTestOptions = .init(),
    environment: RuntimeEnvironment, bindings provider: any RuntimeBindingProvider
  ) async -> MCPConnectionTestResult {
    let started = Date()
    let clock = ContinuousClock.now
    var workspace: URL?
    var tools: [MCPConnectionTestResult.Tool] = []
    var version: String?
    var outcome = MCPConnectionTestResult.Outcome.failed
    var issue: MCPConnectionTestResult.Issue?
    var clean = true
    do {
      guard
        [options.totalTimeout, options.requestTimeout].allSatisfy({
          $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 1_000_000_000
        }), options.maximumTools > 0, options.maximumPages > 0
      else {
        throw MCPConnectionTestResult.Issue.invalidInput
      }
      guard !options.clientName.isEmpty, !options.clientVersion.isEmpty,
        [options.clientName, options.clientVersion].allSatisfy({
          !$0.utf8.contains(0) && $0.utf8.count <= options.limits.textBytes
        })
      else { throw MCPConnectionTestResult.Issue.invalidInput }
      try Task.checkCancellation()
      try snapshot.directory?.revalidate()
      try snapshot.executable?.revalidate()
      let description = describe(snapshot)
      var remaining = options.limits.inputBytes - snapshot.inputBytes
      for (key, value) in environment.environment {
        guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0), !value.utf8.contains(0),
          key.utf8.count < remaining
        else { throw MCPConnectionTestResult.Issue.invalidInput }
        remaining -= key.utf8.count + 1
        guard value.utf8.count < remaining else { throw MCPConnectionTestResult.Issue.invalidInput }
        remaining -= value.utf8.count + 1
      }
      for name in description.environmentBindings {
        guard environment.environment[name] != nil else {
          throw MCPConnectionTestResult.Issue.bindingUnavailable
        }
      }
      var secrets: [String: String] = [:]
      for name in description.requiredBindings {
        try Task.checkCancellation()
        let data: Data
        do {
          data = try provider.value(for: name, environment: environment)
        } catch is CancellationError {
          throw CancellationError()
        } catch { throw MCPConnectionTestResult.Issue.bindingUnavailable }
        guard data.count < remaining, let value = String(data: data, encoding: .utf8),
          !value.utf8.contains(0)
        else { throw MCPConnectionTestResult.Issue.invalidBinding }
        remaining -= data.count + 1
        secrets[name] = value
      }
      var privateValues =
        Array(environment.environment.values) + Array(secrets.values)
        + [options.clientName, options.clientVersion]
      func resolve(_ binding: RuntimeBinding, header: Bool) throws -> String {
        let value: String
        switch binding {
        case .literal(let text): value = text
        case .environment(let name):
          guard let text = environment.environment[name] else {
            throw MCPConnectionTestResult.Issue.bindingUnavailable
          }
          value = text
        case .secret(let name): value = secrets[name]!
        }
        guard !value.utf8.contains(0),
          !header || value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) })
        else {
          throw MCPConnectionTestResult.Issue.invalidBinding
        }
        privateValues.append(value)
        if header {
          privateValues += value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        return value
      }
      let input: MCPConnectionInput
      switch snapshot.transport {
      case .stdio(let run):
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "agents-mcp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        workspace = directory
        let cwd = try snapshot.directory!.materialize(in: directory, name: "cwd")
        let executable =
          try snapshot.executable?.materialize(in: directory, name: "executable")
          .path ?? run.executable
        var values = environment.environment
        for key in run.environment.keys.sorted() {
          values[key] = try resolve(run.environment[key]!, header: false)
        }
        try snapshot.directory?.revalidate()
        try snapshot.executable?.revalidate()
        privateValues +=
          run.arguments + [run.executable, executable, directory.path, cwd.path]
          + (snapshot.directory?.sensitivePaths ?? []) + (snapshot.executable?.sensitivePaths ?? [])
        input = .stdio(
          .init(
            executable: executable, arguments: run.arguments, directory: cwd, environment: values))
      case .streamableHTTP(let endpoint, let headers), .sse(let endpoint, let headers):
        var values: [String: String] = [:]
        for key in headers.keys.sorted() { values[key] = try resolve(headers[key]!, header: true) }
        privateValues.append(endpoint)
        if let url = URL(string: endpoint) {
          privateValues +=
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap(\.value)
            ?? []
        }
        if snapshot.transport.kind == .sse {
          input = .legacySSE(URL(string: endpoint)!, headers: values)
        } else {
          input = .streamableHTTP(URL(string: endpoint)!, headers: values)
        }
      }
      try Task.checkCancellation()
      let elapsed = clock.duration(to: .now)
      let spent = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      guard spent < options.totalTimeout else { throw MCPConnectionTestResult.Issue.timeout }
      var limits = options.limits
      limits.totalTimeout -= spent
      let result = await MCPConnectionRunner.run(
        input, client: .init(name: options.clientName, version: options.clientVersion),
        limits: limits)
      clean = result.cleanupComplete
      version = result.negotiatedVersion
      switch result.status {
      case .discovered: outcome = .discovered
      case .noTools: outcome = .noTools
      case .incomplete(let error):
        outcome = .incomplete
        issue = .init(rawValue: error.rawValue)
      case .failed(let error):
        outcome = .failed
        issue = .init(rawValue: error.rawValue)
      }
      let redaction = MCPConnectionRedaction(
        privateValues: privateValues, byteLimit: options.limits.textBytes)
      tools = result.tools.map {
        .init(
          name: redaction.text($0.name), title: $0.title.map(redaction.text),
          description: $0.description.map(redaction.text))
      }
    } catch is CancellationError {
      issue = .cancelled
    } catch is MCPConnectionPreparationError {
      issue = .resourceChanged
    } catch let error as MCPConnectionTestResult.Issue {
      issue = error
    } catch {
      issue = .invalidInput
    }
    if let workspace {
      do { try FileManager.default.removeItem(at: workspace) } catch { clean = false }
    }
    if !clean {
      outcome = .failed
      issue = .cleanupFailed
    }
    let elapsed = clock.duration(to: .now)
    return MCPConnectionTestResult(
      snapshotID: snapshot.id, startedAt: started, finishedAt: Date(),
      elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
      transport: snapshot.transport.kind, outcome: outcome,
      issue: issue,
      negotiatedVersion: version, tools: tools, cleanupComplete: clean)
  }
}

extension RuntimeBinding {
  fileprivate var text: String {
    switch self {
    case .literal(let text), .environment(let text), .secret(let text): text
    }
  }
}

extension MCPTransportDeclaration {
  fileprivate var bindings: [String: RuntimeBinding] {
    switch self {
    case .stdio(let run): run.environment
    case .streamableHTTP(_, let headers), .sse(_, let headers): headers
    }
  }
  fileprivate var kind: MCPConnectionDescription.Transport {
    switch self {
    case .stdio: .stdio
    case .streamableHTTP: .streamableHTTP
    case .sse: .sse
    }
  }
}
