import AgentsCore
import Components
import Foundation

/// One version returned by a registry. Its choices retain the fetched definition.
public struct MCPRegistryServer: Sendable {
  public let registry: URL
  public let name: String
  public let version: String
  public let title: String?
  public let description: String
  public let status: String?
  public let choices: [MCPRegistryChoice]

  static func attestsBindings(
    in transport: MCPTransportDeclaration, for registry: MCPRegistryEvidence,
    schemas: [Self]
  ) -> Bool {
    var matched = false
    for server in schemas
    where server.registry.absoluteString.utf8.elementsEqual(registry.registry.utf8)
      && server.name.utf8.elementsEqual(registry.server.utf8)
      && server.version.utf8.elementsEqual(registry.version.utf8)
    {
      guard server.choices.filter({ $0.attestsBindings(in: transport, for: registry) }).count == 1
      else { return false }
      matched = true
    }
    return matched
  }
}

public struct MCPRegistryPackage: Sendable {
  public let registryType: String
  public let identifier: String
  public let version: String?
  public let registryBaseURL: URL?
  public let runtimeHint: String?
  public let fileSHA256: String?
}

/// A configurable server header or process environment variable.
public struct MCPRegistryBindingRequirement: Sendable {
  public let name: String
  public let description: String?
  public let isRequired: Bool
  public let isSecret: Bool
  /// Non-secret registry default. A caller can override it through the binding.
  public let defaultValue: String?
  /// When present, selection requires one of these non-secret registry values.
  public let choices: [String]
}

public enum MCPRegistryBinding: Sendable {
  /// The client reads this variable at run time. For headers it supplies the complete value.
  case environment(String)
  /// A value literally listed in the requirement's choices.
  case choice(String)
}

/// A single remote or package choice from an immutable server version.
public struct MCPRegistryChoice: Sendable {
  public enum Source: Sendable {
    case remote(endpoint: URL?)
    case package(MCPRegistryPackage)
  }

  public let source: Source
  /// The v0.1 transport discriminator, including kinds this package cannot deploy.
  public let transport: String
  public let bindings: [MCPRegistryBindingRequirement]
  public let unavailableReason: String?
  /// PyPI metadata identifies the distribution. The caller supplies its console command.
  public var requiresPackageCommand: Bool {
    if case .package(let launcher) = plan { return launcher.coordinate == nil }
    return false
  }
  private let plan: RegistryMCPPlan?
  private let slots: [RegistryMCPSlot]
  private let evidence: MCPRegistryEvidence?

  fileprivate func attestsBindings(
    in definition: MCPTransportDeclaration, for registry: MCPRegistryEvidence
  ) -> Bool {
    guard let plan, evidence?.origin == registry.origin, evidence?.package == registry.package
    else {
      return false
    }
    let fields: [String: RuntimeBinding]
    switch (plan, definition) {
    case (.remote(let expected), .streamableHTTP(let url, let headers))
    where transport == "streamable-http" && expected.absoluteString.utf8.elementsEqual(url.utf8):
      fields = headers
    case (.remote(let expected), .sse(let url, let headers))
    where transport == "sse" && expected.absoluteString.utf8.elementsEqual(url.utf8):
      fields = headers
    case (.package(let launcher), .stdio(let run)):
      let packageCommand =
        launcher.coordinate == nil
        ? run.arguments.dropLast(launcher.arguments.count).last : nil
      guard
        let expected = try? launcher.executable(
          environment: run.environment, packageCommand: packageCommand), expected == run
      else { return false }
      fields = run.environment
    default: return false
    }
    let requirements = Dictionary(uniqueKeysWithValues: slots.map { ($0.name, $0) })
    guard
      slots.allSatisfy({
        ($0.literal == nil && $0.requirement?.isRequired != true) || fields[$0.name] != nil
      })
    else { return false }
    return fields.allSatisfy { name, field in
      guard let slot = requirements[name] else { return false }
      guard case .literal(let value) = field else { return true }
      return slot.requirement?.isSecret != true
        && slot.candidateValues.contains { $0.utf8.elementsEqual(value.utf8) }
    }
  }

  /// Checks the portable choice and current native mappings for these references. Scope
  /// ownership and existing configuration are checked by the ordinary preview.
  public func compatibleAgents(
    in scope: InstallScope, bindings: [String: MCPRegistryBinding] = [:],
    packageCommand: String? = nil
  ) throws -> [AgentID] {
    let declaration = try transportDeclaration(bindings, packageCommand: packageCommand)
    return AgentID.allCases.filter { agent in
      (try? DeploymentConstruction.validateMCP(
        declaration, named: "mcp", agent: agent, scope: scope, requiresSymbolicBindings: true))
        != nil
    }
  }

  /// Composes this captured choice into a finite managed addition. Binding keys are the
  /// requirement names. Selection makes no registry request and targets are explicit.
  public func select(
    named name: String, agents: [AgentID], in destination: ScopeInspection,
    bindings: [String: MCPRegistryBinding] = [:], packageCommand: String? = nil
  ) throws -> ComponentDiscovery {
    guard !name.isEmpty, !agents.isEmpty, Set(agents).count == agents.count else {
      throw MCPRegistryError.invalidSelection
    }
    let transport = try transportDeclaration(bindings, packageCommand: packageCommand)
    for agent in agents {
      try DeploymentConstruction.validateMCP(
        transport, named: name, agent: agent, scope: destination.scope,
        requiresSymbolicBindings: true)
    }
    guard let evidence else { throw MCPRegistryError.invalidSelection }
    let addition = Declaration(components: [
      .mcpServer(
        name: name, transport: transport, agents: agents,
        registry: try evidence.bound(to: transport))
    ])
    guard let discovery = try UpdateOperations.captureAddition(addition, in: destination) else {
      throw MCPRegistryError.invalidSelection
    }
    return discovery
  }

  private func transportDeclaration(
    _ supplied: [String: MCPRegistryBinding], packageCommand: String?
  ) throws -> MCPTransportDeclaration {
    guard let plan else {
      throw MCPRegistryError.unavailableChoice(
        unavailableReason ?? "MCP choice cannot be deployed.")
    }
    let expected = Set(bindings.map(\.name))
    if let unknown = supplied.keys.sorted().first(where: { !expected.contains($0) }) {
      throw MCPRegistryError.invalidBinding(unknown)
    }
    var values: [String: RuntimeBinding] = [:]
    for slot in slots {
      if let literal = slot.literal {
        values[slot.name] = .literal(literal)
        continue
      }
      guard let requirement = slot.requirement else { continue }
      switch supplied[slot.name] {
      case .environment(let name):
        guard requirement.choices.isEmpty, RegistryInput.isEnvironmentName(name) else {
          throw MCPRegistryError.invalidBinding(slot.name)
        }
        values[slot.name] = .environment(name)
      case .choice(let value):
        guard requirement.choices.contains(value) else {
          throw MCPRegistryError.invalidBinding(slot.name)
        }
        values[slot.name] = .literal(value)
      case nil:
        if requirement.choices.isEmpty, let fallback = requirement.defaultValue {
          values[slot.name] = .literal(fallback)
        } else if requirement.isRequired {
          throw MCPRegistryError.missingBinding(slot.name)
        }
      }
    }
    switch plan {
    case .remote(let url):
      guard packageCommand == nil else { throw MCPRegistryError.invalidPackageCommand }
      if supplied.values.contains(where: {
        if case .environment = $0 { return true }
        return false
      }), !RegistryHTTP.protectsCredentials(url) {
        throw MCPRegistryError.unavailableChoice("An MCP endpoint with bindings requires HTTPS.")
      }
      return transport == "sse"
        ? .sse(url: url.absoluteString, headers: values)
        : .streamableHTTP(url: url.absoluteString, headers: values)
    case .package(let launcher):
      return .stdio(try launcher.executable(environment: values, packageCommand: packageCommand))
    }
  }

  fileprivate init(
    source: Source, transport: String, slots: [RegistryMCPSlot], deleted: Bool,
    registry: RegistryServerCoordinate,
    prepare: () throws -> RegistryMCPPlan
  ) {
    self.source = source
    self.transport = transport
    self.slots = slots
    bindings = slots.compactMap(\.requirement)
    do {
      if deleted { throw unavailable("This MCP registry version was deleted.") }
      guard slots.allSatisfy(\.isRepresentable) else {
        throw unavailable("The registry listed choices that cannot be preserved for an MCP input.")
      }
      let prepared = try prepare()
      evidence = try registry.evidence(for: prepared)
      plan = prepared
      unavailableReason = nil
    } catch {
      evidence = nil
      plan = nil
      unavailableReason =
        (error as? MCPRegistryError)?.errorDescription
        ?? "MCP choice cannot be deployed."
    }
  }
}

struct RegistryPageResponse: Decodable {
  struct Metadata: Decodable {
    let nextCursor: String?
  }
  let servers: [RegistryServerResponse]
  let metadata: Metadata?
}

struct RegistryServerResponse: Decodable {
  struct Server: Decodable {
    let name: String
    let description: String
    let title: String?
    let version: String
    let remotes: [RegistryTransport]?
    let packages: [RegistryPackage]?
  }

  struct Metadata: Decodable {
    struct Official: Decodable {
      let status: String?
    }
    enum CodingKeys: String, CodingKey {
      case official = "io.modelcontextprotocol.registry/official"
    }
    let official: Official?
  }

  let server: Server
  let _meta: Metadata?

  func inspection(registry: URL) throws -> MCPRegistryServer {
    guard !server.name.isEmpty, !server.version.isEmpty, server.version != "latest" else {
      throw MCPRegistryError.invalidResponse
    }
    let status = _meta?.official?.status
    let deleted = status == "deleted"
    let coordinate = RegistryServerCoordinate(
      registry: registry, name: server.name, version: server.version)
    return .init(
      registry: registry, name: server.name, version: server.version, title: server.title,
      description: server.description, status: status,
      choices: (server.remotes ?? []).map { $0.choice(deleted: deleted, registry: coordinate) }
        + (server.packages ?? []).map { $0.choice(deleted: deleted, registry: coordinate) })
  }
}

struct RegistryTransport: Decodable {
  let type: String
  let url: String?
  let headers: [RegistryInput]?
  let variables: [String: RegistryInput]?

  fileprivate func choice(deleted: Bool, registry: RegistryServerCoordinate) -> MCPRegistryChoice {
    let resolved = RegistryInput.resolve(url, variables: variables)
    let endpoint = resolved.flatMap { URLComponents(string: $0) }.flatMap { url in
      RegistryHTTP.validURL(url)
        && url.queryItems?.contains(where: {
          RegistryInput.isCredentialName($0.name)
        }) != true ? url.url : nil
    }
    let slots = (headers ?? []).compactMap { $0.slot() }
    return MCPRegistryChoice(
      source: .remote(endpoint: endpoint), transport: type, slots: slots, deleted: deleted,
      registry: registry
    ) {
      guard type == "streamable-http" || type == "sse" else {
        throw unavailable("The registry listed an unsupported remote transport.")
      }
      guard let endpoint else {
        throw unavailable("The registry endpoint needs a fixed, credential-free HTTP URL.")
      }
      let reserved = [
        "host", "connection", "content-length", "proxy-authorization", "proxy-connection",
        "transfer-encoding", "te", "trailer", "upgrade",
      ]
      let names = slots.map { $0.name.lowercased() }
      guard slots.count == (headers ?? []).count, Set(names).count == names.count,
        slots.allSatisfy({
          RegistryHTTP.isHeaderName($0.name) && !reserved.contains($0.name.lowercased())
            && $0.candidateValues.allSatisfy(RegistryHTTP.isHeaderValue)
        })
      else { throw unavailable("The registry listed invalid or duplicate MCP headers.") }
      return .remote(endpoint)
    }
  }
}

struct RegistryPackage: Decodable {
  let registryType: String
  let registryBaseUrl: String?
  let identifier: String
  let version: String?
  let fileSha256: String?
  let runtimeHint: String?
  let transport: RegistryTransport
  let runtimeArguments: [RegistryInput]?
  let packageArguments: [RegistryInput]?
  let environmentVariables: [RegistryInput]?

  fileprivate func choice(deleted: Bool, registry: RegistryServerCoordinate) -> MCPRegistryChoice {
    let baseURL = registryBaseUrl.flatMap { URLComponents(string: $0) }.flatMap { url in
      RegistryHTTP.validURL(url) && url.scheme?.lowercased() == "https" && url.query == nil
        ? url : nil
    }
    let package = MCPRegistryPackage(
      registryType: registryType, identifier: identifier, version: version,
      registryBaseURL: baseURL?.url, runtimeHint: runtimeHint, fileSHA256: fileSha256)
    let slots = (environmentVariables ?? []).compactMap { $0.slot() }
    return MCPRegistryChoice(
      source: .package(package), transport: transport.type, slots: slots, deleted: deleted,
      registry: registry
    ) {
      guard transport.type == "stdio" else {
        throw unavailable("Managed packages support stdio only.")
      }
      guard fileSha256 == nil else {
        throw unavailable("This package requires launcher-level checksum verification.")
      }
      guard runtimeArguments?.isEmpty != false else {
        throw unavailable("This package requires custom launcher arguments.")
      }
      guard registryBaseUrl == nil || baseURL?.url != nil else {
        throw unavailable("The package registry needs a credential-free HTTPS base URL.")
      }
      let names = slots.map(\.name)
      guard slots.count == (environmentVariables ?? []).count, Set(names).count == names.count,
        names.allSatisfy(RegistryInput.isEnvironmentName)
      else { throw unavailable("The registry listed invalid or duplicate environment names.") }
      let arguments = try (packageArguments ?? []).flatMap { try $0.argument() }
      return .package(try launcher(baseURL: baseURL, arguments: arguments))
    }
  }

  private func launcher(baseURL: URLComponents?, arguments: [String]) throws -> RegistryLauncher {
    let runtime: String
    let prefix: [String]
    let coordinate: String?
    let package: String
    let origin: String
    switch registryType {
    case "npm":
      runtime = "npx"
      guard identifier.matches(#"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"#),
        let version,
        version.matches(#"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$"#)
      else { throw unavailable("The npm choice needs a package name and an exact version.") }
      origin = baseURL?.string ?? "https://registry.npmjs.org"
      prefix = ["--yes", "--registry=" + origin, "--"]
      package = identifier + "@" + version
      coordinate = package
    case "pypi":
      runtime = "uvx"
      guard identifier.matches(#"^[A-Za-z0-9][A-Za-z0-9._-]*$"#),
        let version, version.matches(#"^[0-9][A-Za-z0-9._+!-]*$"#)
      else { throw unavailable("The PyPI choice needs a distribution name and an exact version.") }
      let index = baseURL.flatMap { url in
        url.host == "pypi.org" && ["", "/"].contains(url.path)
          ? "https://pypi.org/simple" : url.string
      }
      origin = index ?? "https://pypi.org/simple"
      package = identifier + "==" + version
      prefix = ["--default-index", origin, "--from", package, "--"]
      coordinate = nil
    case "oci":
      runtime = "docker"
      prefix = ["run", "--rm", "-i"]
      let image = try image(baseURL: baseURL)
      package = image.reference
      coordinate = package
      origin = "https://" + image.host
    default:
      throw unavailable("The registry listed an unsupported package type.")
    }
    guard runtimeHint == nil || runtimeHint == runtime else {
      throw unavailable("The package requires an unsupported launcher.")
    }
    return .init(
      command: runtime, prefix: prefix, coordinate: coordinate, arguments: arguments,
      package: package, origin: origin)
  }

  private func image(baseURL: URLComponents?) throws -> (reference: String, host: String) {
    let reference = identifier.split(separator: "@", omittingEmptySubsequences: false)
    guard let coordinate = reference.first, reference.count <= 2 else {
      throw unavailable("The OCI choice needs a valid image name.")
    }
    let path = coordinate.split(separator: "/", omittingEmptySubsequences: false)
    let tail = path.last?.split(separator: ":", omittingEmptySubsequences: false) ?? []
    guard let last = tail.first, tail.count <= 2 else {
      throw unavailable("The OCI choice needs a valid image name.")
    }
    let segments = path.dropLast() + [last]
    let first = segments[0]
    let qualified =
      path.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
    let registryHost = baseURL?.host.map { $0 + (baseURL?.port.map { ":" + String($0) } ?? "") }
    let repositoryPath = qualified ? segments.dropFirst() : segments[...]
    guard repositoryPath.allSatisfy({ $0.matches(#"^[a-z0-9][a-z0-9._-]*$"#) }),
      !qualified || first.matches(#"^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?$"#),
      baseURL.map({ ["", "/"].contains($0.path) }) ?? true,
      registryHost == nil || !qualified || String(first) == registryHost
    else { throw unavailable("The OCI image and its registry are inconsistent.") }

    let repository =
      (qualified ? "" : registryHost.map { $0 + "/" } ?? "")
      + segments.joined(separator: "/")
    let host = qualified ? String(first) : registryHost ?? "docker.io"
    if reference.count == 2 {
      guard reference[1].matches(#"^sha256:[a-f0-9]{64}$"#) else {
        throw unavailable("The OCI image digest is invalid.")
      }
      return (repository + "@" + reference[1], host)
    }
    let tag = tail.count == 2 ? String(tail[1]) : version
    guard let tag, tag.lowercased() != "latest",
      tag.matches(#"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#),
      version == nil || tag == version
    else { throw unavailable("The OCI choice needs an exact image tag or digest.") }
    return (repository + ":" + tag, host)
  }
}

private struct RegistryServerCoordinate: Sendable {
  let registry: URL
  let name: String
  let version: String

  func evidence(for plan: RegistryMCPPlan) throws -> MCPRegistryEvidence {
    let url: String
    let package: String?
    switch plan {
    case .remote(let endpoint):
      url = endpoint.absoluteString
      package = nil
    case .package(let launcher):
      url = launcher.origin
      package = launcher.package
    }
    let origin = try SourceOrigin.http(url)
    let evidence = MCPRegistryEvidence(
      registry: registry.absoluteString, server: name, version: version,
      origin: origin.identity!, package: package)
    try evidence.validate()
    return evidence
  }
}

private enum RegistryMCPPlan: Sendable {
  case remote(URL)
  case package(RegistryLauncher)
}

private struct RegistryLauncher: Sendable {
  let command: String
  let prefix: [String]
  let coordinate: String?
  let arguments: [String]
  let package: String
  let origin: String

  func executable(
    environment: [String: RuntimeBinding], packageCommand: String?
  ) throws -> ExecutableDeclaration {
    let target: String
    if let coordinate {
      guard packageCommand == nil else { throw MCPRegistryError.invalidPackageCommand }
      target = coordinate
    } else {
      guard let packageCommand else { throw MCPRegistryError.missingPackageCommand }
      guard packageCommand.matches(#"^[A-Za-z0-9][A-Za-z0-9._-]*$"#) else {
        throw MCPRegistryError.invalidPackageCommand
      }
      target = packageCommand
    }
    let forwarded = command == "docker" ? environment.keys.sorted().flatMap { ["-e", $0] } : []
    return .init(
      executable: command, arguments: prefix + forwarded + [target] + arguments,
      environment: environment)
  }
}

private struct RegistryMCPSlot: Sendable {
  let name: String
  let literal: String?
  let requirement: MCPRegistryBindingRequirement?
  let isRepresentable: Bool

  var candidateValues: [String] {
    if let literal { return [literal] }
    return (requirement?.choices ?? []) + (requirement?.defaultValue.map { [$0] } ?? [])
  }
}

struct RegistryInput: Decodable {
  let name: String?
  let type: String?
  let valueHint: String?
  let description: String?
  let value: String?
  let `default`: String?
  let isRequired: Bool?
  let isSecret: Bool?
  let choices: [String]?
  let variables: [String: RegistryInput]?

  private var secret: Bool {
    isSecret == true || (name ?? valueHint).map(Self.isCredentialName) == true
      || variables?.contains(where: { Self.isCredentialName($0.key) || $0.value.secret }) == true
  }

  fileprivate func slot() -> RegistryMCPSlot? {
    guard let name else { return nil }
    let fixed = secret ? nil : Self.resolve(value, variables: variables)
    let options = choices ?? []
    let unrepresentableOptions =
      (fixed.map { !options.isEmpty && !options.contains($0) } ?? (secret && !options.isEmpty))
      || (fixed == nil
        && variables?.values.contains(where: { $0.choices?.isEmpty == false }) == true)
    let fallback = secret ? nil : Self.resolve(`default`, variables: variables)
    return .init(
      name: name, literal: fixed,
      requirement: fixed == nil
        ? .init(
          name: name, description: description,
          isRequired: isRequired == true || value != nil || !options.isEmpty
            || (secret && `default` != nil),
          isSecret: secret, defaultValue: fallback, choices: secret ? [] : options)
        : nil,
      isRepresentable: !unrepresentableOptions)
  }

  fileprivate func argument() throws -> [String] {
    let fixed = secret ? nil : Self.resolve(value, variables: variables)
    let options = choices ?? []
    if let fixed, !options.isEmpty, !options.contains(fixed) {
      throw unavailable("The package argument is outside its declared choices.")
    }
    switch type {
    case "named":
      guard let name, name.matches(#"^-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*$"#) else {
        throw unavailable("The package listed an invalid command-line option.")
      }
      if let fixed { return [name + "=" + fixed] }
      if !secret, value == nil, `default` == nil, options.isEmpty, variables == nil {
        if isRequired != true { return [] }
      }
    case "positional":
      if let fixed { return [fixed] }
    default: break
    }
    throw unavailable("The package requires an unrepresentable command-line argument.")
  }

  static func isEnvironmentName(_ value: String) -> Bool {
    value.matches(#"^[A-Za-z_][A-Za-z0-9_]*$"#)
  }

  static func isCredentialName(_ value: String) -> Bool {
    let key = value.lowercased().filter { $0.isASCII && $0.isLetter }
    return key == "key" || key == "sig" || key.hasSuffix("auth")
      || [
        "authorization", "token", "apikey", "password", "secret", "credential", "privatekey",
        "cookie", "signature",
      ].contains(where: key.contains)
  }

  /// Substitute only fixed, non-secret variable values. The portable declaration cannot
  /// interpolate run-time values into a URL or an individual argument.
  static func resolve(_ value: String?, variables: [String: RegistryInput]?) -> String? {
    guard var value else { return nil }
    for (name, variable) in variables ?? [:] {
      let token = "{" + name + "}"
      guard value.contains(token), !isCredentialName(name), !variable.secret,
        let fixed = variable.value,
        variable.choices?.isEmpty != false || variable.choices?.contains(fixed) == true,
        !Self.containsTemplate(fixed)
      else { continue }
      value = value.replacingOccurrences(of: token, with: fixed)
    }
    return containsTemplate(value) ? nil : value
  }

  private static func containsTemplate(_ value: String) -> Bool {
    value.range(of: #"\{[A-Za-z_][A-Za-z0-9_]*\}"#, options: .regularExpression) != nil
  }
}

private func unavailable(_ reason: String) -> MCPRegistryError {
  .unavailableChoice(reason)
}

extension StringProtocol {
  fileprivate func matches(_ expression: String) -> Bool {
    range(of: expression, options: .regularExpression).map { $0 == startIndex..<endIndex } == true
  }
}
