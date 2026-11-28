import AgentsCore
import AgentsSkills
import Foundation

public enum NativePluginTarget: String, CaseIterable, Codable, Sendable {
  case claudeCode = "claude-code"
  case codex

  fileprivate var pluginManifest: String {
    switch self {
    case .claudeCode: ".claude-plugin/plugin.json"
    case .codex: ".codex-plugin/plugin.json"
    }
  }

  fileprivate var marketplaceManifest: String {
    switch self {
    case .claudeCode: ".claude-plugin/marketplace.json"
    case .codex: ".agents/plugins/marketplace.json"
    }
  }
}

public struct NativePluginMarketplace: Equatable, Sendable {
  public let name: String
  public let category: String?

  public init(name: String, category: String? = nil) {
    self.name = name
    self.category = category
  }
}

/// One checked, client-specific distribution. The digest seals paths, content, links and modes.
public struct NativePluginArtifact: Sendable {
  public let target: NativePluginTarget
  public let package: BundlePackage
  public let digest: String
  public let entries: [LedgerEntry]
  public let contentFindings: [ContentAuditFinding]
  public let policyFindings: [OrganizationPolicyFinding]
  public let warnings: [AuthorPackageWarning]
  fileprivate let output: AuthorOutputTree
  fileprivate let source: AuthorPackageArtifact

  public func contents(at path: String) -> Data? {
    output.tree.entries[path]?.object.flatMap { output.objects[$0] }
  }
}

public enum NativePluginOperations {
  /// Prepares a standalone plugin, or a local one-plugin marketplace containing it.
  /// No client settings, marketplace registrations or installations are changed.
  public static func preview(
    _ artifact: AuthorPackageArtifact, for target: NativePluginTarget,
    marketplace: NativePluginMarketplace? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> NativePluginArtifact {
    let policy = try AuthorPackagePolicy(environment, registrySchemas: artifact.registrySchemas)
    let findings = try policy.admit(artifact.inspection.archive)
    let package = artifact.inspection.package
    guard validName(package.name),
      (try? MarketplaceCoordinate(package: package.name, version: package.version)) != nil,
      let description = package.description, let author = package.author
    else {
      throw CoreError.invalidSource(
        "native plugins require a kebab-case name, SemVer, description and author")
    }
    guard package.dependencies == nil else {
      throw CoreError.unsupported("native plugins cannot resolve Agents catalog requirements")
    }
    if let marketplace, !validName(marketplace.name) {
      throw CoreError.invalidSource("invalid native marketplace name")
    }
    let prefix = marketplace == nil ? "" : "plugins/" + package.name + "/"
    var builder = NativePluginBuilder(
      target: target, prefix: prefix, archive: artifact.inspection.archive)
    for item in artifact.inspection.archive.manifest.components {
      try Task.checkCancellation()
      switch item.kind {
      case .skills: try builder.addSkill(item)
      case .mcpServer: try builder.addMCP(item)
      case .instructions:
        throw CoreError.unsupported(
          "native plugin cannot load an Agents instruction section: " + item.name)
      }
    }
    try builder.finish(package: package, description: description, author: author)
    if let marketplace {
      try builder.addMarketplace(
        marketplace, package: package, description: description, author: author)
    }
    let entries = try builder.output.validatedEntries()
    let digest = try ResolvedLedgerCodec.digest(entries)
    try policy.validate()
    return .init(
      target: target, package: package, digest: digest, entries: entries,
      contentFindings: artifact.contentFindings + builder.audit.findings, policyFindings: findings,
      warnings: artifact.warnings, output: builder.output, source: artifact)
  }

  /// Publishes the complete checked tree under an existing parent, never replacing a destination.
  /// Pass a reviewed digest when using a capture rebuilt in a different process.
  public static func write(
    _ artifact: NativePluginArtifact, to destination: URL, expectedDigest: String? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws {
    guard expectedDigest.map({ $0 == artifact.digest }) ?? true else {
      throw CoreError.invalidState("native artifact digest differs from the reviewed tree")
    }
    let policy = try AuthorPackageOperations.outputPolicy(artifact.source, environment: environment)
    try artifact.output.write(to: destination, beforeCommit: policy.validate)
  }

  fileprivate static func validName(_ name: String) -> Bool {
    name.utf8.count <= 64
      && name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
  }
}

private struct NativePluginBuilder {
  let target: NativePluginTarget
  let prefix: String
  let archive: BundleArchive
  var output = AuthorOutputTree()
  var audit = AuthorContentAudit()
  private var skills = Set<String>()
  private var servers: [String: [String: Any]] = [:]
  private var secretOptions = Set<String>()

  init(target: NativePluginTarget, prefix: String, archive: BundleArchive) {
    self.target = target
    self.prefix = prefix
    self.archive = archive
  }

  mutating func addSkill(_ item: BundleItem) throws {
    guard NativePluginOperations.validName(item.name), skills.insert(item.name).inserted,
      let discovery = item.discovery,
      let manifest = item.entries.first(where: { $0.path == discovery + "/SKILL.md" }),
      let digest = manifest.object, let bytes = archive.contentObjects[digest],
      try SkillSnapshotReader.manifestName(bytes, path: manifest.path) == item.name
    else { throw CoreError.invalidSource("native plugin needs a unique named skill: " + item.name) }
    try moveTree(item, from: discovery, to: "skills/" + item.name)
  }

  mutating func addMCP(_ item: BundleItem) throws {
    let name = item.name
    guard name.utf8.count <= 128,
      name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
      servers.keys.allSatisfy({ $0.lowercased() != name.lowercased() })
    else { throw CoreError.invalidSource("native plugin needs a unique named MCP: " + name) }
    guard try item.native()[target.rawValue]?.isEmpty != false else {
      throw CoreError.unsupported("client MCP overrides cannot be projected to plugin: " + name)
    }
    let unsupported = CoreError.unsupported(
      target.rawValue + " plugin cannot represent MCP member: " + name)
    var config: [String: Any] = [:]
    let transport = try item.transport()
    switch transport {
    case .stdio(let run):
      guard run.workingDirectory == nil else { throw unsupported }
      var command = run.executable
      if command.contains("/") {
        guard target == .claudeCode, command.hasPrefix("payload/"),
          item.entries.contains(where: { $0.path == command && $0.kind == .file && $0.executable })
        else { throw unsupported }
        let destination = "mcp-resources/" + name
        try moveTree(item, from: "payload", to: destination)
        command = "${CLAUDE_PLUGIN_ROOT}/" + destination + "/" + command.dropFirst("payload/".count)
      } else if item.entries.count != 1 {
        throw unsupported
      }
      config["type"] = "stdio"
      config["command"] = command
      if !run.arguments.isEmpty { config["args"] = run.arguments }
      if !run.environment.isEmpty {
        switch target {
        case .claudeCode: config["env"] = try claudeBindings(run.environment)
        case .codex:
          guard
            run.environment.allSatisfy({ key, value in
              value == .environment(key) && Self.validVariable(key)
            })
          else { throw unsupported }
          config["env_vars"] = run.environment.keys.sorted()
        }
      }
    case .streamableHTTP(let url, let headers), .sse(let url, let headers):
      guard item.entries.count == 1 else { throw unsupported }
      let isSSE = transport.organizationPolicyName == "sse"
      guard !isSSE || target != .codex else { throw unsupported }
      config["type"] = isSSE ? "sse" : "http"
      config["url"] = url
      if !headers.isEmpty {
        switch target {
        case .claudeCode: config["headers"] = try claudeBindings(headers)
        case .codex:
          config["env_http_headers"] = try headers.mapValues {
            guard case .environment(let key) = $0, Self.validVariable(key)
            else { throw unsupported }
            return key
          }
        }
      }
    }
    servers[name] = config
  }

  private mutating func claudeBindings(_ bindings: [String: RuntimeBinding]) throws
    -> [String: String]
  {
    var rendered: [String: String] = [:]
    for (field, binding) in bindings {
      switch binding {
      case .environment(let key) where Self.validVariable(key):
        rendered[field] = "${" + key + "}"
      case .secret(let key) where Self.validVariable(key):
        secretOptions.insert(key)
        rendered[field] = "${user_config." + key + "}"
      default: throw CoreError.unsupported("invalid symbolic binding for Claude plugin")
      }
    }
    return rendered
  }

  private static func validVariable(_ name: String) -> Bool {
    name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
  }

  private mutating func moveTree(_ item: BundleItem, from root: String, to destination: String)
    throws
  {
    let tree = try LedgerResources.validatedEntries(item.resource)
    var moved: [LedgerEntry] = []
    for original in item.entries {
      var entry = original
      if original.path == root {
        entry.path = "."
      } else if original.path.hasPrefix(root + "/") {
        entry.path = String(original.path.dropFirst(root.count + 1))
      } else if original.kind == .directory,
        original.path == "." || root.hasPrefix(original.path + "/")
      {
        continue
      } else {
        throw CoreError.unsupported("native plugin member needs out-of-tree support: " + item.name)
      }
      moved.append(entry)
    }
    guard tree[root]?.kind == .directory else {
      throw CoreError.invalidSource("missing native member root: " + item.name)
    }
    _ = try LedgerResources.validatedEntries(
      .init(kind: .embedded, source: "", path: ".", hash: "", entries: moved))
    for var entry in moved {
      entry.path = prefix + destination + (entry.path == "." ? "" : "/" + entry.path)
      try output.tree.insert(entry)
      if let digest = entry.object { output.objects[digest] = archive.contentObjects[digest]! }
    }
  }

  mutating func finish(package: BundlePackage, description: String, author: String) throws {
    var manifest: [String: Any] = [
      "name": package.name, "version": package.version, "description": description,
      "author": ["name": author],
    ]
    if !skills.isEmpty { manifest["skills"] = "./skills/" }
    if !servers.isEmpty {
      manifest["mcpServers"] = "./.mcp.json"
      try addJSON(["mcpServers": servers], path: prefix + ".mcp.json")
    }
    if target == .codex {
      manifest["interface"] = [
        "displayName": String(package.name.prefix(30)),
        "shortDescription": String(description.prefix(30)), "longDescription": description,
      ]
    }
    if !secretOptions.isEmpty {
      manifest["userConfig"] = Dictionary(
        uniqueKeysWithValues: secretOptions.sorted().map {
          (
            $0,
            [
              "type": "string", "title": $0, "description": "Credential required by an MCP server.",
              "sensitive": true, "required": true,
            ] as [String: Any]
          )
        })
    }
    try addJSON(manifest, path: prefix + target.pluginManifest)
  }

  mutating func addMarketplace(
    _ marketplace: NativePluginMarketplace, package: BundlePackage, description: String,
    author: String
  ) throws {
    let source = "./" + prefix.dropLast()
    var listing: [String: Any] = [
      "name": package.name, "description": description, "version": package.version,
      "source": source,
    ]
    var catalog: [String: Any] = ["name": marketplace.name]
    if target == .codex {
      guard let category = marketplace.category, !category.isEmpty, !category.utf8.contains(0),
        category.utf8.count <= 128
      else { throw CoreError.invalidSource("Codex marketplace needs an explicit category") }
      listing = [
        "name": package.name, "source": ["source": "local", "path": source],
        "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
        "category": category,
      ]
      catalog["interface"] = ["displayName": marketplace.name]
    } else {
      catalog["owner"] = ["name": author]
      catalog["metadata"] = ["description": description]
    }
    catalog["plugins"] = [listing]
    try addJSON(catalog, path: target.marketplaceManifest)
  }

  private mutating func addJSON(_ value: [String: Any], path: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    try output.add(path, bytes: data)
    try audit.scan(data, path: path)
  }
}
