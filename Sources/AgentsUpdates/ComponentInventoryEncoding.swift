import Foundation

struct CycloneDXInventory: Encodable {
  let bomFormat = "CycloneDX"
  let specVersion = "1.6"
  let version = 1
  let metadata: Metadata?
  let components: [Component]
  let dependencies: [InventoryProjection.Dependency]?

  init(_ inventory: InventoryProjection, createdAt: Date?) {
    dependencies = inventory.dependencies.isEmpty ? nil : inventory.dependencies
    metadata = createdAt.map { Metadata(timestamp: $0.ISO8601Format()) }
    let members = Dictionary(uniqueKeysWithValues: inventory.components.map { ($0.id, $0) })
    components =
      inventory.sources.map { source in
        let children = source.contains.compactMap { members[$0] }.map {
          Component($0, type: "data")
        }
        return Component(
          source, type: "library", components: children,
          additionalMembers: source.contains.filter { members[$0] == nil })
      }
      + inventory.releases.map {
        Component($0, type: "library", additionalMembers: $0.contains)
      }
  }

  struct Metadata: Encodable {
    let timestamp: String
  }

  struct Component: Encodable {
    let type: String
    let bomRef: String
    let name: String
    let version: String?
    let purl: String?
    let hashes: [Hash]?
    let properties: [InventoryProjection.Property]
    let components: [Component]?

    enum CodingKeys: String, CodingKey {
      case type
      case bomRef = "bom-ref"
      case name, version, purl, hashes, properties
      case components
    }

    init(
      _ item: InventoryProjection.Item, type: String, components: [Component]? = nil,
      additionalMembers: [String] = []
    ) {
      self.type = type
      bomRef = item.id
      name = item.name
      version = item.version
      purl = item.purl
      hashes = item.archiveSHA256.map { [Hash(content: $0)] }
      properties =
        item.properties
        + additionalMembers.map {
          InventoryProjection.Property("contains", $0)
        }
      self.components = components
    }
  }

  struct Hash: Encodable {
    let alg = "SHA-256"
    let content: String
  }
}

struct SPDXInventory: Encodable {
  private static let documentID = "SPDXRef-DOCUMENT"

  let spdxVersion = "SPDX-2.3"
  let dataLicense = "CC0-1.0"
  let spdxID = documentID
  let name = "Agents scope inventory"
  var documentNamespace = ""
  let creationInfo: CreationInfo
  let packages: [Package]
  let relationships: [Relationship]

  enum CodingKeys: String, CodingKey {
    case spdxVersion, dataLicense
    case spdxID = "SPDXID"
    case name, documentNamespace, creationInfo
    case packages, relationships
  }

  init(_ inventory: InventoryProjection, createdAt: Date) {
    creationInfo = CreationInfo(created: createdAt.ISO8601Format())
    let roots = inventory.sources + inventory.releases
    packages = (roots + inventory.components).map(Package.init)
    let contained = Set(inventory.sources.flatMap(\.contains))
    relationships =
      roots.filter { !contained.contains($0.id) }.map {
        Relationship(
          spdxElementId: Self.documentID, relationshipType: "DESCRIBES",
          relatedSpdxElement: Self.id($0.id))
      }
      + roots.flatMap { item in
        item.contains.map { target in
          Relationship(
            spdxElementId: Self.id(item.id), relationshipType: "CONTAINS",
            relatedSpdxElement: Self.id(target))
        }
      }
      + inventory.dependencies.flatMap { source in
        source.dependsOn.map {
          Relationship(
            spdxElementId: Self.id(source.ref), relationshipType: "DEPENDS_ON",
            relatedSpdxElement: Self.id($0))
        }
      }
  }

  private static func id(_ id: String) -> String { "SPDXRef-" + id }

  struct CreationInfo: Encodable {
    let creators = ["Tool: agents"]
    let created: String
  }

  struct Package: Encodable {
    let spdxID: String
    let name: String
    let versionInfo: String?
    let downloadLocation = "NOASSERTION"
    let filesAnalyzed = false
    let licenseConcluded = "NOASSERTION"
    let licenseDeclared = "NOASSERTION"
    let copyrightText = "NOASSERTION"
    let sourceInfo: String
    let externalRefs: [ExternalRef]?
    let checksums: [Checksum]?

    enum CodingKeys: String, CodingKey {
      case spdxID = "SPDXID"
      case name, versionInfo, downloadLocation, filesAnalyzed, licenseConcluded
      case licenseDeclared, copyrightText, sourceInfo, externalRefs, checksums
    }

    init(_ item: InventoryProjection.Item) {
      spdxID = SPDXInventory.id(item.id)
      name = item.name
      versionInfo = item.version
      sourceInfo = item.properties.map { $0.name + " " + $0.value }.joined(separator: "\n")
      externalRefs = item.purl.map { [ExternalRef(referenceLocator: $0)] }
      checksums = item.archiveSHA256.map { [Checksum(checksumValue: $0)] }
    }
  }

  struct Relationship: Encodable {
    let spdxElementId: String
    let relationshipType: String
    let relatedSpdxElement: String
  }

  struct ExternalRef: Encodable {
    let referenceCategory = "PACKAGE-MANAGER"
    let referenceType = "purl"
    let referenceLocator: String
  }

  struct Checksum: Encodable {
    let algorithm = "SHA256"
    let checksumValue: String
  }
}
