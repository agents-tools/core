import AgentsCore
import Foundation

/// The JSON format for a distributable inventory of a captured scope.
public enum InventoryFormat: String, Sendable {
  case cycloneDX = "cyclonedx"
  case spdx
}

extension ScopeInspection {
  /// Exports the locked package and component inventory from this inspection generation.
  public func cycloneDXInventory() throws -> Data {
    try inventory(format: .cycloneDX)
  }

  /// Encodes the captured lock evidence as CycloneDX 1.6 or SPDX 2.3 JSON.
  /// A fixed creation date produces identical bytes for the same inventory.
  /// With no date, CycloneDX omits the timestamp and SPDX uses the current time.
  public func inventory(format: InventoryFormat, createdAt: Date? = nil) throws -> Data {
    guard !recovery.pending else {
      throw CoreError.recoveryPending(recovery.diagnostic ?? "Transaction recovery is pending")
    }
    if let marketplaceIssue { throw marketplaceIssue }

    let projection = try InventoryProjection(self)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    switch format {
    case .cycloneDX:
      return try encoder.encode(CycloneDXInventory(projection, createdAt: createdAt))
    case .spdx:
      var document = SPDXInventory(projection, createdAt: createdAt ?? Date())
      let digest = FileHash.sha256Hex(data: try encoder.encode(document))
      document.documentNamespace = "https://github.com/agents-tools/core/spdxdocs/" + digest
      return try encoder.encode(document)
    }
  }
}

struct InventoryProjection {
  struct Item {
    let id: String
    let name: String
    let version: String?
    let purl: String?
    let archiveSHA256: String?
    let properties: [Property]
    let contains: [String]
  }

  struct Property: Encodable {
    let name: String
    let value: String

    init(_ name: String, _ value: String) {
      self.name = "agents:" + name
      self.value = value
    }
  }

  let sources: [Item]
  let components: [Item]
  let releases: [Item]
  let dependencies: [Dependency]

  struct Dependency: Encodable {
    let ref: String
    let dependsOn: [String]
  }

  init(_ scope: ScopeInspection) throws {
    let members = Dictionary(grouping: scope.components, by: \.sourceRecord)
    let contained = Dictionary(grouping: scope.sources, by: \.container)
    let byIdentity = Dictionary(grouping: scope.sources, by: \.identity)
    let resources = Dictionary(uniqueKeysWithValues: scope.resources.map { ($0.identity, $0) })

    sources = scope.sources.map { source in
      let roots = Set(source.uses.map(\.root)).sorted()
      let subpath = source.repositorySubpath(roots: roots)
      let origin: SourceOrigin?
      switch source.kind {
      case .git: origin = try? .git(source.identity)
      case .wellKnown: origin = try? .http(source.identity)
      case .local:
        origin = source.container.flatMap { identity in
          guard subpath != nil,
            byIdentity[identity]?.contains(where: {
              $0.kind == .git && $0.revision == source.revision
            }) == true
          else { return nil }
          return try? .git(identity)
        }
      }
      let revision = Self.safeLabel(source.revision)
      var properties = [Property("source-kind", source.kind.rawValue)]
      if let name = origin?.identity { properties.append(Property("source-origin", name)) }
      if let revision { properties.append(Property("revision", revision)) }
      properties += roots.map { Property("source-root", $0) }
      if let subpath { properties.append(Property("source-subpath", subpath)) }

      let matching = byIdentity[source.identity, default: []].filter {
        $0.revision == source.revision
      }
      let children =
        matching.count == 1
        ? contained[source.identity, default: []].filter { $0.revision == source.revision } : []
      let name =
        origin?.identity.map { name in
          if source.container != nil, let subpath { return name + "#" + subpath }
          return name
        } ?? source.kind.rawValue
      return Item(
        id: Self.id("source", source.record), name: name,
        version: source.version.flatMap(Self.safeLabel) ?? revision,
        purl: origin?.inventoryPackageURL(revision: source.revision, subpath: subpath),
        archiveSHA256: nil,
        properties: properties,
        contains: members[source.record, default: []].map { Self.id("component", $0.record) }
          + children.map { Self.id("source", $0.record) })
    }
    components = scope.components.map { component in
      let targets = component.recipients.map(\.rawValue) + (component.chatGPT ? ["chatgpt"] : [])
      var properties = [Property("kind", component.kind.rawValue)]
      properties += targets.sorted().map { Property("target", $0) }
      if let registry = component.mcpRegistry {
        if let origin = try? SourceOrigin.http(registry.registry).identity {
          properties.append(Property("mcp-registry-origin", origin))
        }
        if let server = Self.safeLabel(registry.server) {
          properties.append(Property("mcp-registry-server", server))
        }
        if let version = Self.safeLabel(registry.version) {
          properties.append(Property("mcp-registry-version", version))
        }
        properties.append(Property("mcp-installation-origin", registry.origin))
      }
      let revision = component.revision.flatMap(Self.safeLabel)
      if let revision { properties.append(Property("revision", revision)) }
      for resource in component.resources.compactMap({ resources[$0] }) {
        let rootKind = resource.entries.first { $0.path == "." }?.kind
        let kind = resource.kind == "liveEdit" || rootKind == "directory" ? "tree" : "file"
        let source =
          resource.sourceRecord == component.sourceRecord
          ? "" : " (\(Self.id("source", resource.sourceRecord)))"
        properties.append(
          Property("resource-\(kind)-sha256", "\(resource.hash) \(resource.path)" + source))
      }
      return Item(
        id: Self.id("component", component.record),
        name: Self.safeLabel(component.name) ?? component.kind.rawValue,
        version: component.version.flatMap(Self.safeLabel) ?? revision,
        purl: nil, archiveSHA256: nil, properties: properties, contains: [])
    }
    func release(
      id: String, coordinate: MarketplaceCoordinate, catalog: MarketplaceOrigin,
      digest: String, commit: String?, records: [String], aliases: [String]
    ) -> Item {
      let origin = catalog.isLocal ? nil : try? SourceOrigin.git(catalog.location)
      let releasePath = [catalog.subpath, coordinate.releasePath].compactMap { $0 }.joined(
        separator: "/")
      var properties =
        aliases.map { Property("dependency", $0) } + [
          Property("marketplace-kind", catalog.kind.rawValue),
          Property("marketplace-origin", origin?.identity ?? "local"),
          Property("archive-digest", digest),
        ]
      if let commit {
        properties.append(Property("catalog-commit", commit))
        properties.append(Property("catalog-release-path", releasePath))
      }
      properties += records.filter { (try? StateValidation.digest($0)) != nil }.map {
        Property("component-record", $0)
      }
      return Item(
        id: id, name: coordinate.package, version: coordinate.version,
        purl: commit.flatMap { origin?.inventoryPackageURL(revision: $0, subpath: releasePath) },
        archiveSHA256: String(digest.dropFirst("sha256:".count)), properties: properties,
        contains: records.map { Self.id("component", $0) })
    }
    let exact = scope.marketplacePackages.sorted { $0.dependency.name < $1.dependency.name }.map {
      release(
        id: Self.id("release", $0.dependency.name), coordinate: $0.dependency.coordinate,
        catalog: $0.dependency.catalog, digest: $0.archiveDigest,
        commit: $0.catalogCommit, records: $0.componentRecords, aliases: [$0.dependency.name])
    }
    if let graph = scope.marketplaceGraph {
      let ids = try Dictionary(
        uniqueKeysWithValues: graph.nodes.map {
          ($0.id, Self.id("release-node", try ResolvedLedgerCodec.digest($0.id)))
        })
      releases =
        exact
        + graph.nodes.map { node in
          release(
            id: ids[node.id]!, coordinate: node.coordinate, catalog: node.catalog,
            digest: node.archiveDigest, commit: node.catalogCommit, records: node.componentRecords,
            aliases: graph.roots.filter { $0.node == node.id }.map(\.intent.name))
        }
      dependencies = graph.nodes.filter { !$0.dependencies.isEmpty }.map {
        Dependency(
          ref: ids[$0.id]!, dependsOn: Set($0.dependencies.map { ids[$0.target]! }).sorted())
      }
    } else {
      releases = exact
      dependencies = []
    }
  }

  private static func id(_ category: String, _ record: String) -> String {
    category + "-" + FileHash.sha256Hex(data: Data(record.utf8))
  }

  private static func safeLabel(_ value: String) -> String? {
    guard (try? PathSafety.sanitizeSubpath(value)) != nil, !value.hasPrefix("~"),
      !value.contains("://"), value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
    else { return nil }
    return value
  }
}

extension SourceOrigin {
  fileprivate func inventoryPackageURL(revision: String, subpath: String?) -> String? {
    guard kind == .git, SourceCache.isObjectID(revision),
      let locator = policyLocator, let url = URLComponents(string: locator),
      let host = url.host
    else { return nil }
    var path = url.path.dropLast(".git".count).split(separator: "/").map(String.init)
    guard !path.isEmpty else { return nil }

    let type: String
    if url.port == nil, path.count == 2, ["github.com", "bitbucket.org"].contains(host) {
      type = host == "github.com" ? "github" : "bitbucket"
      path = path.map { $0.lowercased() }
    } else {
      type = "git"
      let authority = host + (url.port.map { ":\($0)" } ?? "")
      path.insert(authority, at: 0)
    }
    let package = path.map(Self.encodePackageURLSegment).joined(separator: "/")
    let suffix =
      subpath.map {
        "#" + $0.split(separator: "/").map(Self.encodePackageURLSegment).joined(separator: "/")
      } ?? ""
    return "pkg:\(type)/\(package)@\(revision)" + suffix
  }

  fileprivate static func encodePackageURLSegment(_ value: some StringProtocol) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")
    return String(value).addingPercentEncoding(withAllowedCharacters: allowed)!
  }
}

extension SourceInspection {
  fileprivate func repositorySubpath(roots: [String]) -> String? {
    if let namespace, namespace.hasPrefix(":contained:") {
      let fields = namespace.dropFirst(":contained:".count).split(separator: ":", maxSplits: 1)
      if fields.count == 2, Int(fields[0]) == fields[1].utf8.count,
        let path = try? PathSafety.sanitizeSubpath(String(fields[1])), path != "."
      {
        return path
      }
    }
    guard kind == .git, roots.count == 1, roots[0] != "." else { return nil }
    return roots[0]
  }
}
