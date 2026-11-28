import AgentsCore
import AgentsUpdates
import Foundation

func sourceArchiveProbe(
  root: URL, input: URL, checkpoint: @escaping (String) throws -> Void
) throws {
  let bytes = try Data(contentsOf: input)
  let authority = try SourceAuthority(host: "origin.invalid", port: 8443)
  let mirror = try SourceArchiveMirror(
    source: authority, base: URL(string: "https://mirror.invalid:9443/base/")!, flavor: .github)
  let environment = RuntimeEnvironment(
    projectDirectory: root.appendingPathComponent("project"),
    homeDirectory: root.appendingPathComponent("home"), environment: [:],
    acquisitionCacheRoot: root.appendingPathComponent("disposable"),
    sourceAccess: .init(egress: .proxyOnly, mirrors: [mirror]))
  let declaration = Declaration(
    agents: [.codex],
    sources: [
      "fixture": .init(
        kind: .git, location: "https://origin.invalid:8443/org/repo.git",
        requirement: .revision("refs/tags/release/v1"))
    ],
    skills: ["fixture": .init(select: .names(["demo"]), mode: .link)])
  try PackageSourceHTTP.$fixture.withValue(
    .init { _, _ in .init(status: 200, body: bytes) },
    operation: {
      try UpdateOperations.withPreparedUpdate(
        .init(operation: .declaration(declaration)), environment: environment,
        checkpoint: checkpoint
      ) { _ = try $0.apply() }
    })
}
