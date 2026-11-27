import AgentsCore
import Foundation
import Testing

@testable import AgentsUpdates

@Suite("Distributable locked inventory")
struct ComponentInventoryTests {
  private let date = Date(timeIntervalSince1970: 1_704_067_200)
  private let commit = String(repeating: "a", count: 40)
  private let archive = "sha256:" + String(repeating: "b", count: 64)
  private let tree = "sha256:" + String(repeating: "c", count: 64)
  private let file = "sha256:" + String(repeating: "d", count: 64)
  private let catalogCommit = String(repeating: "e", count: 40)
  private let localPath = FileManager.default.temporaryDirectory.appendingPathComponent(
    "private-worktree"
  ).path

  @Test func spdxPackagesAndRelationships() throws {
    let data = try fixture().inventory(format: .spdx, createdAt: date)
    let document = try object(data)
    let creation = try #require(document["creationInfo"] as? [String: Any])
    #expect(document["spdxVersion"] as? String == "SPDX-2.3")
    #expect(document["dataLicense"] as? String == "CC0-1.0")
    #expect(document["SPDXID"] as? String == "SPDXRef-DOCUMENT")
    #expect(creation["created"] as? String == "2024-01-01T00:00:00Z")
    #expect(creation["creators"] as? [String] == ["Tool: agents"])
    let namespace = try #require(document["documentNamespace"] as? String)
    #expect(URL(string: namespace)?.scheme == "https")
    #expect(URL(string: namespace)?.fragment == nil)

    let packages = try #require(document["packages"] as? [[String: Any]])
    let ids = packages.compactMap { $0["SPDXID"] as? String }
    #expect(packages.count == 7)
    #expect(Set(ids).count == packages.count)
    #expect(
      ids.allSatisfy {
        $0.range(of: #"^SPDXRef-[a-zA-Z0-9.-]+$"#, options: .regularExpression) != nil
      })
    for package in packages {
      #expect(package["filesAnalyzed"] as? Bool == false)
      #expect(package["licenseDeclared"] as? String == "NOASSERTION")
      #expect(package["licenseConcluded"] as? String == "NOASSERTION")
      #expect(package["downloadLocation"] as? String == "NOASSERTION")
      #expect(package["copyrightText"] as? String == "NOASSERTION")
    }

    let git = try named("github.com/team/tools", in: packages)
    #expect(git["versionInfo"] as? String == "2.3.4")
    #expect((git["sourceInfo"] as? String)?.contains("agents:revision " + commit) == true)
    let refs = try #require(git["externalRefs"] as? [[String: String]])
    #expect(
      refs == [
        [
          "referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
          "referenceLocator": "pkg:github/team/tools@\(commit)#packages/review%20kit",
        ]
      ])

    let release = try named("team-kit", in: packages)
    #expect(release["versionInfo"] as? String == "1.2.3")
    #expect(
      (release["sourceInfo"] as? String)?.contains("agents:catalog-commit " + catalogCommit) == true
    )
    #expect(
      release["checksums"] as? [[String: String]] == [
        [
          "algorithm": "SHA256", "checksumValue": String(archive.dropFirst(7)),
        ]
      ])
    let child = try named("review", in: packages)
    let evidence = try #require(child["sourceInfo"] as? String)
    #expect(evidence.contains("agents:resource-tree-sha256 " + tree + " skills/review"))
    #expect(evidence.contains("agents:resource-file-sha256 " + file + " notes.md"))

    let relationships = try #require(document["relationships"] as? [[String: String]])
    let known = Set(ids + ["SPDXRef-DOCUMENT"])
    for relationship in relationships {
      #expect(known.contains(relationship["spdxElementId"] ?? ""))
      #expect(known.contains(relationship["relatedSpdxElement"] ?? ""))
    }
    try requireRelationship("DESCRIBES", from: document, to: release, in: relationships)
    try requireRelationship("CONTAINS", from: git, to: child, in: relationships)
    try requireRelationship("CONTAINS", from: release, to: child, in: relationships)
    let contained = try named("github.com/team/tools#extras", in: packages)
    try requireRelationship("CONTAINS", from: git, to: contained, in: relationships)
  }

  @Test func cycloneDXPackagesAndRelationships() throws {
    let data = try fixture().inventory(format: .cycloneDX, createdAt: date)
    let document = try object(data)
    #expect(document["bomFormat"] as? String == "CycloneDX")
    #expect(document["specVersion"] as? String == "1.6")
    #expect(document["version"] as? Int == 1)
    #expect((document["metadata"] as? [String: String])?["timestamp"] == "2024-01-01T00:00:00Z")

    let roots = try #require(document["components"] as? [[String: Any]])
    let all = roots + roots.flatMap { $0["components"] as? [[String: Any]] ?? [] }
    #expect(Set(all.compactMap { $0["bom-ref"] as? String }).count == 7)
    let git = try named("github.com/team/tools", in: roots)
    #expect(git["purl"] as? String == "pkg:github/team/tools@\(commit)#packages/review%20kit")
    #expect(git["version"] as? String == "2.3.4")
    #expect(property("agents:revision", in: git) == commit)
    let children = try #require(git["components"] as? [[String: Any]])
    let child = try named("review", in: children)
    #expect(child["type"] as? String == "data")
    #expect(property("agents:resource-tree-sha256", in: child) == tree + " skills/review")
    #expect(property("agents:resource-file-sha256", in: child) == file + " notes.md")
    #expect(child["hashes"] == nil)

    let release = try named("team-kit", in: roots)
    #expect(release["version"] as? String == "1.2.3")
    #expect(
      release["purl"] as? String
        == "pkg:github/team/catalog@\(catalogCommit)#inventory/releases/team-kit/1.2.3")
    #expect(
      release["hashes"] as? [[String: String]] == [
        [
          "alg": "SHA-256", "content": String(archive.dropFirst(7)),
        ]
      ])
    #expect(property("agents:archive-digest", in: release) == archive)
    #expect(property("agents:contains", in: release) == (child["bom-ref"] as? String))
    let contained = try named("github.com/team/tools#extras", in: roots)
    #expect(contained["purl"] as? String == "pkg:github/team/tools@\(commit)#extras")
    #expect(property("agents:contains", in: git) == (contained["bom-ref"] as? String))
  }

  @Test(arguments: [InventoryFormat.cycloneDX, .spdx])
  func fixedTimestampIsReproducibleAndOmitsPrivateFields(_ format: InventoryFormat) throws {
    let data = try fixture().inventory(format: format, createdAt: date)
    #expect(data == (try fixture().inventory(format: format, createdAt: date)))
    #expect(
      data != (try fixture().inventory(format: format, createdAt: date.addingTimeInterval(1))))
    let encoded = String(decoding: data, as: UTF8.self)
    for privateValue in [
      localPath, "catalog-private-user", "private-index-token", "private-config-value",
    ] {
      #expect(!encoded.contains(privateValue))
    }
    let legacy = try fixture().cycloneDXInventory()
    #expect(legacy == (try fixture().inventory(format: .cycloneDX)))
    #expect(try object(legacy)["metadata"] == nil)
  }

  @Test func repositoryURLsUseEstablishedTypesAndUnambiguousRoots() throws {
    let sources = [
      gitSource("bitbucket.org/Workspace/TeamKit", roots: ["one", "two"]),
      gitSource("gitlab.com/Group/subgroup/TeamKit", roots: ["plugin"]),
      gitSource("git.example.test/Team/kit", roots: ["."]),
      gitSource("git.example.test:8443/Team/kit", roots: ["profile:default"]),
    ]
    let document = try object(inspection(sources: sources).cycloneDXInventory())
    let components = try #require(document["components"] as? [[String: Any]])
    let urls = components.compactMap { $0["purl"] as? String }
    #expect(
      urls == [
        "pkg:bitbucket/workspace/teamkit@" + commit,
        "pkg:git/gitlab.com/Group/subgroup/TeamKit@\(commit)#plugin",
        "pkg:git/git.example.test/Team/kit@\(commit)",
        "pkg:git/git.example.test:8443/Team/kit@\(commit)#profile:default",
      ])
  }

  private func fixture() throws -> ScopeInspection {
    let git = gitSource("github.com/team/tools", roots: ["packages/review kit"])
    let local = SourceInspection(
      record: "local", identity: "local:" + localPath, kind: .local, revision: "live",
      version: nil, container: nil, namespace: nil, location: URL(fileURLWithPath: localPath),
      uses: [])
    let index = SourceInspection(
      record: "index", identity: "https://index.example.test/skills?token=private-index-token",
      kind: .wellKnown, revision: tree, version: nil, container: nil, namespace: nil,
      location: nil, uses: [])
    let childRecord = "sha256:" + String(repeating: "f", count: 64)
    let child = ComponentInspection(
      record: childRecord, sourceRecord: git.record, declaringSourceRecord: local.record,
      selection: .init(identity: localPath + "/review", occurrence: nil, generation: "locked"),
      kind: .skills, name: "review", source: git.identity, declaringSource: local.identity,
      root: "packages/review kit", group: nil, revision: commit, version: "2.3.4", mcpRegistry: nil,
      configuration: .object(["token": .string("private-config-value")]),
      conditions: [], recipients: [.codex], copyRecipients: [], chatGPT: false,
      resources: ["tree", "file"],
      occurrences: [])
    let treeResource = resource(
      "tree", path: "skills/review", hash: tree, kind: "directory", source: git)
    let fileResource = resource("file", path: "notes.md", hash: file, kind: "file", source: git)
    let release = try pin(
      "team-kit", child: childRecord,
      origin: MarketplaceOrigin(
        kind: .git, location: "ssh://catalog-private-user@github.com/team/catalog.git",
        subpath: "inventory"),
      commit: catalogCommit)
    let localRelease = try pin(
      "local-kit", child: childRecord,
      origin: MarketplaceOrigin(kind: .directory, location: localPath),
      commit: nil)
    let contained = SourceInspection(
      record: "contained", identity: git.identity + ":contained:6:extras", kind: .local,
      revision: commit, version: nil, container: git.identity, namespace: ":contained:6:extras",
      location: nil, uses: [])
    return inspection(
      sources: [git, local, index, contained], components: [child],
      resources: [treeResource, fileResource], releases: [release, localRelease])
  }

  private func gitSource(_ identity: String, roots: [String]) -> SourceInspection {
    .init(
      record: identity, identity: identity, kind: .git, revision: commit, version: "2.3.4",
      container: nil, namespace: nil, location: nil,
      uses: roots.map { .init(root: $0, requirement: nil) })
  }

  private func resource(
    _ id: String, path: String, hash: String, kind: String, source: SourceInspection
  ) -> ResourceInspection {
    .init(
      sourceRecord: source.record, identity: id, source: source.identity, path: path, hash: hash,
      kind: "git", location: URL(fileURLWithPath: localPath + "/" + path),
      entries: [.init(path: ".", kind: kind, executable: false, link: nil, byteCount: nil)],
      support: [])
  }

  private func pin(
    _ name: String, child: String, origin: MarketplaceOrigin, commit: String?
  ) throws -> MarketplacePin {
    let coordinate = try MarketplaceCoordinate(package: name, version: "1.2.3")
    return MarketplacePin(
      dependency: try MarketplaceDependency(name: name, catalog: origin, coordinate: coordinate),
      archiveDigest: archive, catalogCommit: commit, sourceAliases: [name],
      componentRecords: [child], contributionDigest: tree)
  }

  private func inspection(
    sources: [SourceInspection], components: [ComponentInspection] = [],
    resources: [ResourceInspection] = [], releases: [MarketplacePin] = []
  ) -> ScopeInspection {
    .init(
      additionDestination: nil, scope: .project, document: nil, declaration: nil,
      generation: "locked", sources: sources, components: components, groups: [],
      marketplacePackages: releases, marketplaceGraph: nil, marketplaceIssue: nil,
      pendingMarketplaceDeployment: nil,
      resources: resources, deployments: [],
      watch: nil, recovery: .init(pending: false, requiresOwner: false, diagnostic: nil),
      readLocations: [URL(fileURLWithPath: localPath)])
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func named(_ name: String, in objects: [[String: Any]]) throws -> [String: Any] {
    try #require(objects.first { $0["name"] as? String == name })
  }

  private func property(_ name: String, in component: [String: Any]) -> String? {
    (component["properties"] as? [[String: String]])?.first { $0["name"] == name }?["value"]
  }

  private func requireRelationship(
    _ kind: String, from: [String: Any], to: [String: Any], in relationships: [[String: String]]
  ) throws {
    let source = try #require(from["SPDXID"] as? String)
    let target = try #require(to["SPDXID"] as? String)
    #expect(
      relationships.contains([
        "spdxElementId": source, "relationshipType": kind, "relatedSpdxElement": target,
      ]))
  }
}
