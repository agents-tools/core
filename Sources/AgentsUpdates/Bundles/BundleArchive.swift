import AgentsCore
import Components
import Foundation

/// Marketplace coordinates, independent of the archive format version.
public struct BundlePackage: Codable, Equatable, Sendable {
  public let name: String
  public let version: String
  public let description: String?
  public let author: String?
  /// Requirements resolved by a catalog consumer. Omission preserves the canonical leaf format.
  public let dependencies: [MarketplacePackageRequirement]?

  public init(
    name: String, version: String, dependencies: [MarketplacePackageRequirement] = []
  ) {
    self.init(name: name, version: version, dependencies: dependencies, description: nil)
  }

  public init(
    name: String, version: String, dependencies: [MarketplacePackageRequirement] = [],
    description: String?, author: String? = nil
  ) {
    self.name = name
    self.version = version
    self.dependencies = dependencies.isEmpty ? nil : dependencies
    self.description = description
    self.author = author
  }

  func validate() throws {
    for value in [description, author].compactMap({ $0 }) {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        value.utf8.count <= 1024, !value.utf8.contains(0)
      else { throw CoreError.invalidSource("invalid bundle package metadata") }
    }
    if let dependencies {
      guard !dependencies.isEmpty else {
        throw CoreError.invalidSource("omit empty bundle package requirements")
      }
      _ = try MarketplaceCoordinate(package: name, version: version)
      try MarketplacePackageRequirement.validate(dependencies)
    }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+")
    for coordinate in [name, version] {
      guard !coordinate.isEmpty, coordinate.utf8.count <= 128,
        coordinate.utf8.first.map({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) == true,
        coordinate.unicodeScalars.allSatisfy(allowed.contains)
      else { throw CoreError.invalidSource("invalid bundle package name or version") }
    }
  }
}

public typealias BundleSourceEvidence = PortableSourceEvidence

public struct BundleComponent: Sendable {
  /// Content and provenance identity, scoped to this inspection.
  public let id: String
  public let kind: DeclaredComponentKind
  public let name: String
  public let sources: [BundleSourceEvidence]
  /// Portable paths, file digests, link spellings and executable flags in this member.
  public let entries: [LedgerEntry]
  /// Present for MCP. Environment and secret references retain their symbolic keys.
  public let configuration: NativeValue?
  public let mcpRegistry: MCPRegistryEvidence?
  let transport: MCPTransportDeclaration?
  let native: NativeConfiguration
}

extension BundleComponent {
  public var marketplaceKey: MarketplaceMemberKey { .init(kind: kind, name: name) }

  public func supportedTargets(in scope: InstallScope) -> [AgentID] {
    AgentID.allCases.filter { agent in
      switch kind {
      case .skills: return agent.supportsSkills
      case .instructions: return agent.supportsInstructions(in: scope)
      case .mcpServer:
        guard let transport else { return false }
        return
          (try? DeploymentConstruction.validateMCP(
            transport, named: name, agent: agent, scope: scope, native: native,
            requiresSymbolicBindings: mcpRegistry != nil)) != nil
      default: return false
      }
    }
  }
}

public struct BundleInspection: Sendable {
  public let package: BundlePackage
  public let formatVersion: Int
  /// SHA-256 of the exact canonical archive bytes, including its content objects.
  public let archiveDigest: String
  public let components: [BundleComponent]
  let archive: BundleArchive
}

struct BundleArchive: Codable, Sendable {
  static let currentFormat = "agents.bundle"
  static let currentVersion = 1

  struct Manifest: Codable, Sendable {
    let package: BundlePackage
    let components: [BundleItem]
  }

  let format: String
  let version: Int
  let manifest: Manifest
  let manifestDigest: String
  let contentObjects: [String: Data]

  init(package: BundlePackage, components: [BundleItem], objects: [String: Data]) throws {
    format = Self.currentFormat
    version = Self.currentVersion
    manifest = Manifest(package: package, components: components)
    manifestDigest = try ResolvedLedgerCodec.digest(manifest)
    contentObjects = objects
    try validate()
  }

  static func read(_ input: Data) throws -> Self {
    let bytes = input.startIndex == 0 ? input : Data(input)
    try LedgerAdmission.check(bytes, limits: .standard)
    let archive = try JSONDecoder().decode(Self.self, from: bytes)
    try archive.validate()
    guard try ResolvedLedgerCodec.bytes(archive) == bytes else {
      throw CoreError.invalidSource("bundle JSON must use the canonical version 1 encoding")
    }
    return archive
  }

  func validate() throws {
    guard format == Self.currentFormat, version == Self.currentVersion,
      manifestDigest == (try ResolvedLedgerCodec.digest(manifest)), !manifest.components.isEmpty
    else { throw CoreError.invalidSource("invalid bundle format, version or manifest digest") }
    try manifest.package.validate()
    let limits = LedgerLimits.standard
    var remainingObjects = limits.objectBytes
    for (digest, bytes) in contentObjects {
      guard bytes.count <= remainingObjects, digest == Self.digest(bytes) else {
        throw CoreError.invalidSource("invalid bundle content digest or byte budget")
      }
      remainingObjects -= bytes.count
    }
    var remainingEntries = limits.entries
    var remainingBytes = limits.resourceBytes
    var referenced = Set<String>()
    var items = Set<String>()
    for item in manifest.components {
      try Task.checkCancellation()
      guard items.insert(try item.id).inserted, item.entries.count <= remainingEntries else {
        throw CoreError.invalidSource("duplicate bundle component or entry budget")
      }
      remainingEntries -= item.entries.count
      try item.validate()
      for entry in item.entries where entry.kind == .file {
        guard let digest = entry.object, let bytes = contentObjects[digest],
          let count = entry.byteCount, bytes.count == count, count <= remainingBytes
        else { throw CoreError.invalidSource("bundle file is missing or exceeds the byte budget") }
        remainingBytes -= count
        referenced.insert(digest)
      }
    }
    guard referenced == Set(contentObjects.keys) else {
      throw CoreError.invalidSource("bundle contains unreferenced content")
    }
  }

  static func digest(_ bytes: Data) -> String {
    "sha256:" + FileHash.sha256Hex(data: bytes)
  }
}

struct BundleItem: Codable, Sendable {
  enum Kind: String, Codable, Sendable {
    case instructions, skills, mcpServer
  }

  let kind: Kind
  let name: String
  let sources: [BundleSourceEvidence]
  let entries: [LedgerEntry]
  /// Discovery root relative to the generated producer for instructions and skills.
  let discovery: String?
  let configuration: LedgerValue?
  let mcpRegistry: MCPRegistryEvidence?

  var id: String { get throws { try ResolvedLedgerCodec.digest(self) } }
  var resource: LedgerResource {
    .init(kind: .embedded, source: "", path: ".", hash: "", entries: entries)
  }

  /// Endpoints are inputs even in archives whose producer list predates endpoint evidence.
  func installationSources() throws -> [BundleSourceEvidence] {
    guard let url = configuration?.object?["transport"]?.object?["url"]?.text else {
      return sources
    }
    let origin = try SourceOrigin.http(url)
    guard !sources.contains(where: { $0.policyOrigin == origin }) else { return sources }
    return try sources + [.init(origin: origin, revision: ResolvedLedgerCodec.digest(origin))]
  }

  func validate() throws {
    guard !name.isEmpty, name.utf8.count <= 1024, !name.utf8.contains(0), !sources.isEmpty,
      Set(sources).count == sources.count
    else { throw CoreError.invalidSource("invalid bundle component metadata") }
    for source in sources { try source.validate() }
    var paths = Set<String>()
    for entry in entries {
      if entry.path != "." {
        try Self.validatePath(entry.path)
        guard entry.path == "payload" || entry.path.utf8.starts(with: "payload/".utf8) else {
          throw CoreError.unsafePath("bundle members must stay in the payload tree")
        }
      }
      let folded = entry.path.folding(
        options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
      )
      .precomposedStringWithCanonicalMapping
      guard paths.insert(folded).inserted else {
        throw CoreError.invalidSource("colliding bundle paths")
      }
      switch entry.kind {
      case .directory:
        guard !entry.executable, entry.object == nil, entry.byteCount == nil, entry.link == nil
        else { throw CoreError.invalidSource("invalid bundle directory") }
      case .file:
        guard entry.object != nil, entry.byteCount != nil, entry.link == nil
        else { throw CoreError.invalidSource("invalid bundle file") }
      case .symlink:
        guard !entry.executable, entry.object == nil, entry.byteCount == nil, let link = entry.link
        else { throw CoreError.invalidSource("invalid bundle symlink") }
        try Self.validatePath(link, link: true)
      }
    }
    let tree = try LedgerResources.validatedEntries(resource)
    guard tree["."]?.kind == .directory else {
      throw CoreError.invalidSource("missing bundle tree root")
    }
    if let payload = tree["payload"] {
      guard payload.kind == .directory else {
        throw CoreError.invalidSource("invalid bundle payload root")
      }
      var contents = resource
      contents.entries = entries.filter { $0.path != "." }.map { entry in
        var member = entry
        member.path = entry.path == "payload" ? "." : String(entry.path.dropFirst("payload/".count))
        return member
      }
      _ = try LedgerResources.validatedEntries(contents)
    }
    if kind == .mcpServer {
      guard discovery == nil, let configuration else {
        throw CoreError.invalidSource("invalid bundle MCP component")
      }
      try configuration.validate()
      let transport = try transport()
      try mcpRegistry?.validate(matching: transport)
      _ = try native()
      if case .stdio(let run) = transport {
        guard run.executableSource == nil, run.workingDirectory?.source == nil else {
          throw CoreError.invalidSource("bundle MCP resources must be self-contained")
        }
        if run.executable.contains("/") {
          try Self.validatePath(run.executable)
          guard let entry = tree[run.executable],
            (entry.kind == .file && entry.executable) || entry.kind == .symlink
          else { throw CoreError.invalidSource("missing executable in bundle MCP component") }
        }
        if let workingDirectory = run.workingDirectory {
          try Self.validatePath(workingDirectory.path)
          guard let entry = tree[workingDirectory.path], entry.kind != .file else {
            throw CoreError.invalidSource("missing working directory in bundle MCP component")
          }
        }
      }
    } else {
      guard configuration == nil, mcpRegistry == nil, let discovery else {
        throw CoreError.invalidSource("invalid bundle discovery metadata")
      }
      try Self.validatePath(discovery)
      guard tree[discovery]?.kind == .directory else {
        throw CoreError.invalidSource("missing bundle discovery root")
      }
      switch kind {
      case .instructions:
        guard Declaration.isInstructionName(name),
          ["instructions", ".agents/instructions"].contains(where: {
            tree[discovery + "/" + $0 + "/" + name + ".md"]?.kind == .file
          })
        else { throw CoreError.invalidSource("missing bundle instruction file") }
      case .skills:
        guard tree[discovery + "/SKILL.md"]?.kind == .file else {
          throw CoreError.invalidSource("missing bundle skill manifest")
        }
      case .mcpServer: break
      }
    }
  }

  func transport() throws -> MCPTransportDeclaration {
    guard let configuration, let object = configuration.object,
      Set(object.keys) == ["transport", "native"], let native = object["native"]?.object,
      native.values.allSatisfy({ $0.kind == .object })
    else { throw CoreError.invalidSource("invalid bundle MCP fields") }
    return try MCPConnectionOperations.managedTransport(configuration)
  }

  func native() throws -> NativeConfiguration {
    func convert(_ value: LedgerValue) throws -> NativeValue {
      switch value.kind {
      case .environment, .secret, .literal:
        throw CoreError.invalidSource("unexpected binding in bundle native configuration")
      case .array: return try .array(value.array!.map(convert))
      case .object: return try .object(value.object!.mapValues(convert))
      default: return UpdateOperations.symbolicValue(value)
      }
    }
    return try (configuration?.object?["native"]?.object ?? [:]).mapValues {
      try $0.object!.mapValues(convert)
    }
  }

  static func validatePath(_ path: String, link: Bool = false) throws {
    let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
    guard path.utf8.count <= 3072, parts.count <= 64,
      parts.count == path.split(separator: "/", omittingEmptySubsequences: false).count,
      !path.utf8.contains(0), !path.utf8.contains(92), !path.utf8.contains(58),
      parts.allSatisfy({ !$0.isEmpty && $0.count <= 255 }),
      link || !parts.contains(where: { $0.elementsEqual([46]) || $0.elementsEqual([46, 46]) })
    else { throw CoreError.unsafePath("nonportable bundle member path") }
  }
}
