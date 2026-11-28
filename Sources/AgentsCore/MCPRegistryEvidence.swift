import Foundation

/// Registry metadata associated with a selected, symbolic MCP definition.
public struct MCPRegistryEvidence: Codable, Equatable, Hashable, Sendable {
  public let registry: String
  public let server: String
  public let version: String
  /// Canonical HTTP origin of the endpoint or artifact registry.
  public let origin: String
  /// Exact package or image coordinate for a stdio selection.
  public let package: String?
  /// Digest of the exact selected transport, arguments and symbolic configuration.
  public let invocationDigest: String?
  /// Digests of portable, non-secret literals captured by Registry selection.
  package let portableBindings: [String: String]?

  package init(
    registry: String, server: String, version: String, origin: String, package: String?,
    invocationDigest: String? = nil, portableBindings: [String: String]? = nil
  ) {
    self.registry = registry
    self.server = server
    self.version = version
    self.origin = origin
    self.package = package
    self.invocationDigest = invocationDigest
    self.portableBindings = portableBindings
  }

  package func validate() throws {
    guard let base = URLComponents(string: registry), base.query == nil,
      try SourceOrigin.http(origin).identity == origin,
      version != "latest",
      [server, version, package].compactMap({ $0 }).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 1024 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 })
      }),
      invocationDigest.map(Self.isDigest) ?? (portableBindings == nil),
      portableBindings?.values.allSatisfy(Self.isDigest) ?? true
    else { throw CoreError.invalidSource("invalid MCP registry evidence") }
    _ = try SourceOrigin.http(registry)
  }

  /// Captures the actual declaration after the caller configures its inputs.
  package func bound(to transport: MCPTransportDeclaration) throws -> Self {
    let literals = try Self.bindings(in: transport).compactMapValues { binding in
      if case .literal(let value) = binding { return try ResolvedLedgerCodec.digest(value) }
      return nil
    }
    let portable = literals.isEmpty ? nil : literals
    let result = Self(
      registry: registry, server: server, version: version, origin: origin, package: package,
      invocationDigest: try digest(of: transport, portable: portable), portableBindings: portable)
    try result.validate(matching: transport)
    return result
  }

  package func validate(matching transport: MCPTransportDeclaration) throws {
    try validate()
    let selectedOrigin: String?
    switch transport {
    case .stdio(let run):
      selectedOrigin = package.flatMap { Self.launcherOrigin(run, coordinate: $0) }
    case .streamableHTTP(let url, _), .sse(let url, _):
      selectedOrigin = package == nil ? url : nil
    }
    guard let selectedOrigin, (try? SourceOrigin.http(selectedOrigin).identity) == origin,
      try invocationDigest.map({ try $0 == digest(of: transport, portable: portableBindings) })
        ?? true
    else {
      throw CoreError.invalidSource(
        "MCP registry evidence does not match the configured invocation. "
          + Self.reselectionMessage)
    }
  }

  /// Returns only literal names whose current values match captured Registry selections.
  /// Archive admission still applies its own secret and portability checks.
  package func portableLiteralBindings(in transport: MCPTransportDeclaration) throws -> Set<String>
  {
    try validate(matching: transport)
    let bindings = Self.bindings(in: transport)
    if invocationDigest == nil,
      bindings.values.contains(where: {
        if case .literal = $0 { return true }
        return false
      })
    {
      throw CoreError.invalidSource(Self.reselectionMessage)
    }
    return try Set(
      (portableBindings ?? [:]).compactMap { name, digest in
        guard case .literal(let value) = bindings[name],
          try ResolvedLedgerCodec.digest(value) == digest
        else { return nil }
        return name
      })
  }

  package static let reselectionMessage =
    "Reselect the exact MCP registry version and replace the managed declaration, "
    + "or regenerate it from a refreshed bundle."

  private struct Invocation: Encodable {
    let format = 1
    let coordinate: [String]
    let command: [String]
    let bindings: [String: [String]]
    let portableLiterals: [String: String]?
  }

  private func digest(of transport: MCPTransportDeclaration, portable: [String: String]?) throws
    -> String
  {
    let invocation: [String]
    switch transport {
    case .stdio(let run): invocation = ["stdio", run.executable] + run.arguments
    case .streamableHTTP(let url, _): invocation = ["streamableHTTP", url]
    case .sse(let url, _): invocation = ["sse", url]
    }
    let inputs = Self.bindings(in: transport).mapValues { binding in
      switch binding {
      case .literal(let value): ["literal", value]
      case .environment(let name): ["environment", name]
      case .secret(let name): ["secret", name]
      }
    }
    return try ResolvedLedgerCodec.digest(
      Invocation(
        coordinate: [registry, server, version, origin] + (package.map { [$0] } ?? []),
        command: invocation, bindings: inputs, portableLiterals: portable))
  }

  private static func bindings(in transport: MCPTransportDeclaration) -> [String: RuntimeBinding] {
    switch transport {
    case .stdio(let run): run.environment
    case .streamableHTTP(_, let headers), .sse(_, let headers): headers
    }
  }

  private static func launcherOrigin(_ run: ExecutableDeclaration, coordinate: String) -> String? {
    guard run.executableSource == nil, run.workingDirectory == nil else { return nil }
    let arguments = run.arguments
    let index: String
    switch run.executable {
    case "npx":
      let flag = "--registry="
      guard arguments.count >= 4, arguments[0] == "--yes", arguments[1].hasPrefix(flag),
        arguments[2] == "--", arguments[3].utf8.elementsEqual(coordinate.utf8),
        matches(
          coordinate,
          #"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$"#
        )
      else { return nil }
      index = String(arguments[1].dropFirst(flag.count))
    case "uvx":
      guard arguments.count >= 6, arguments[0] == "--default-index", arguments[2] == "--from",
        arguments[3].utf8.elementsEqual(coordinate.utf8), arguments[4] == "--",
        matches(coordinate, #"^[A-Za-z0-9][A-Za-z0-9._-]*==[0-9][A-Za-z0-9._+!-]*$"#),
        matches(arguments[5], #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)
      else { return nil }
      index = arguments[1]
    case "docker":
      let prefix = ["run", "--rm", "-i"] + run.environment.keys.sorted().flatMap { ["-e", $0] }
      guard arguments.starts(with: prefix),
        arguments.dropFirst(prefix.count).first?.utf8.elementsEqual(coordinate.utf8) == true
      else { return nil }
      return imageOrigin(coordinate)
    default:
      return nil
    }
    guard let parts = URLComponents(string: index), parts.scheme?.lowercased() == "https",
      parts.query == nil
    else { return nil }
    return index
  }

  private static func imageOrigin(_ coordinate: String) -> String? {
    let path = coordinate.split(separator: "/", omittingEmptySubsequences: false)
    guard let image = path.last,
      matches(
        String(image),
        #"^[a-z0-9][a-z0-9._-]*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(?:@sha256:[a-f0-9]{64})?$"#),
      image.contains(":"),
      !image.lowercased().hasSuffix(":latest")
    else { return nil }
    let first = path[0]
    let qualified =
      path.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
    let namespace = qualified ? path.dropFirst().dropLast() : path.dropLast()
    guard namespace.allSatisfy({ matches(String($0), #"^[a-z0-9][a-z0-9._-]*$"#) }) else {
      return nil
    }
    if !qualified { return "https://docker.io" }
    let origin = "https://" + first
    guard let url = URL(string: origin), let parts = try? SourceURL.https(url),
      parts.path.isEmpty, parts.query == nil
    else { return nil }
    return origin
  }

  private static func isDigest(_ value: String) -> Bool {
    matches(value, #"^sha256:[0-9a-f]{64}$"#)
  }

  private static func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
  }

  package var origins: [SourceOrigin] {
    let producer = (try? SourceOrigin.http(registry)) ?? .missing
    let selected = (try? SourceOrigin.http(origin)) ?? .missing
    return producer == selected ? [producer] : [producer, selected]
  }
}

extension RuntimeEnvironment {
  package func requireMCPRegistryRoutes(in ledger: ResolvedLedger) throws {
    guard try resolvedSourceAccess().egress == .proxyOnly else { return }
    for (_, component) in ledger.components.sorted(by: { $0.key < $1.key }) {
      guard let registry = component.mcpRegistry?.registry else { continue }
      try Task.checkCancellation()
      guard let endpoint = URL(string: registry) else {
        throw SourceAccessError.invalidRepository
      }
      try requireMCPRegistry(endpoint)
    }
  }

  /// A proxy-only runtime authorizes the operator's exact HTTPS registry namespace.
  package func requireMCPRegistry(_ endpoint: URL) throws {
    let access = try resolvedSourceAccess()
    guard access.egress == .proxyOnly else { return }
    guard let setting = environment["MCP_REGISTRY_URL"] else {
      throw SourceAccessError.egressDenied
    }

    func location(_ url: URL) throws -> (SourceAuthority, [String]) {
      let parts = try SourceURL.https(url)
      guard parts.query == nil else { throw SourceAccessError.invalidConfiguration }
      return (
        try SourceAuthority(parts),
        try SourceURL.segments(parts.percentEncodedPath, allowingRoot: true)
      )
    }
    guard let configured = URL(string: setting),
      let (configuredAuthority, configuredPath) = try? location(configured)
    else { throw SourceAccessError.invalidConfiguration }
    let (authority, path) = try location(endpoint)
    guard authority == configuredAuthority,
      path.elementsEqual(configuredPath, by: { $0.utf8.elementsEqual($1.utf8) })
    else { throw SourceAccessError.egressDenied }
  }
}

extension ComponentDeclaration {
  package var mcpRegistry: MCPRegistryEvidence? {
    if case .mcpServer(_, _, _, _, _, let evidence) = self { return evidence }
    return nil
  }
}
