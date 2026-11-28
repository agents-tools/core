import AgentsCore
import Foundation

/// Relative skill evidence read from an already selected snapshot. This reader never resolves
/// a source or retains content. Live paths belong only to an actual local edit selection.
package struct SnapshotSkill: Equatable, Sendable {
  package let name: String
  package let description: String
  package let path: String
  package let condition: DeclarationCondition
  package let hash: String
  package let executableFlags: [String: Bool]
  package let livePath: String?
}

package enum SkillSnapshotReader {
  package static func manifestName(_ bytes: Data, path: String) throws -> String {
    guard let content = String(data: bytes, encoding: .utf8),
      let skill = try Discovery.parseSkill(
        content, at: URL(fileURLWithPath: "/" + path), includeInternal: true, strict: true,
        diagnosticPath: path)
    else { throw CoreError.invalidSource("invalid packaged SKILL.md: " + path) }
    return skill.name
  }

  package static func read(
    _ view: SourceSnapshot, live: Bool = false, selecting: SkillMemberSelection? = nil
  ) throws -> [SnapshotSkill] {
    let base: URL
    if live {
      guard let root = view.liveRoot else {
        throw CoreError.invalidSource("skill source is immutable")
      }
      base = root
    } else {
      base = view.root
    }
    let selected = try SourceSnapshot(
      snapshot: view.snapshot, pin: view.pin, root: base,
      discoveryPath: view.discoveryPath, localEnvironment: view.localEnvironment,
      liveRoot: view.liveRoot,
      packageIdentity: view.packageIdentity)
    var options = DiscoveryOptions(fullDepth: true)
    options.strict = true
    options.selecting = selecting
    let skills = try Discovery.discover(in: base, subpath: selected.discoveryPath, options: options)
    return try skills.filter {
      selecting?($0.name, URL(fileURLWithPath: $0.path).lastPathComponent) ?? true
    }.map {
      skill in
      try Task.checkCancellation()
      let path = try selected.relativePath(URL(fileURLWithPath: skill.path))
      let directory = try selected.resource(path)
      try selected.validateResourceTree(directory)
      let file = try selected.resource(path + "/SKILL.md")
      let bytes = try FileSystem.read(at: file)
      let fields = try Discovery.parseFrontmatter(String(decoding: bytes, as: UTF8.self))
      return try SnapshotSkill(
        name: skill.name, description: skill.description, path: path,
        condition: Discovery.producerCondition(
          fields, file: file, content: String(decoding: bytes, as: UTF8.self),
          diagnosticPath: path + "/SKILL.md"),
        hash: "sha256:" + FileHash.folderHash(directory),
        executableFlags: FileHash.executableFlags(directory),
        livePath: live ? directory.path : nil)
    }
  }
}

/// Existing skill index formats remain skill-only. Artifact coordinates, not the mutable index,
/// identify the selected content for later retention and locked reconstruction.
package struct SnapshotIndexSkill: Sendable {
  package let name: String
  package let artifact: LockedArtifact
  package let files: [String: Data]
  package let executableFlags: [String: Bool]
}

extension SkillSnapshotReader {
  package static func index(
    _ source: SourceDeclaration, names: [String]? = nil, exclude: [String] = [],
    sourcePolicy: EffectiveSourcePolicy = .init(),
    sourceAccess: SourceAccessConfiguration = .init(),
    requireOrigin: (@Sendable (SourceOrigin) throws -> Void)? = nil
  ) throws -> [SnapshotIndexSkill] {
    try Task.checkCancellation()
    if sourcePolicy.isConfigured { try sourcePolicy.require(.http(source.location)) }
    let provider =
      requireOrigin.map {
        WellKnownProvider.guarded(
          sourcePolicy: sourcePolicy, sourceAccess: sourceAccess, requireOrigin: $0)
      } ?? WellKnownProvider(sourcePolicy: sourcePolicy, sourceAccess: sourceAccess)
    let result = try provider.fetchAllSkills(
      from: source.location, names: names, exclude: exclude
    ).map {
      SnapshotIndexSkill(
        name: $0.installName, artifact: $0.artifact, files: $0.files,
        executableFlags: $0.executableFlags)
    }
    try Task.checkCancellation()
    return result
  }
}
