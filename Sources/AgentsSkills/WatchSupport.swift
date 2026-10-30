import AgentsCore
import AgentsManifest
import Foundation

extension SkillOperations {
  /// Core subscriptions using the same skill discovery and well-known formats as installations.
  public static func watchOperations(
    includeInternal: Bool = false,
    fetch: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
  ) -> WatchOperations {
    WatchOperations(
      discoverSkills: { root in
        try Discovery.discover(
          in: root, options: DiscoveryOptions(includeInternal: includeInternal)
        )
        .map {
          WatchSkill(
            name: PathSafety.sanitizeName($0.name),
            path: PathSafety.relativePath($0.path, to: root.path))
        }
      },
      fetchArtifacts: { location in
        try WellKnownProvider(fetch: fetch).fetchAllSkills(from: location).map {
          WatchArtifact(
            name: $0.installName, artifact: $0.artifact, files: $0.files, payloads: $0.payloads)
        }
      },
      declarations: .manifest)
  }
}
