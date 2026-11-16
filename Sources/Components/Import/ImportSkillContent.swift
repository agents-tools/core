import AgentsCore
import AgentsSkills
import Foundation

struct ImportSkillContent {
  let path: String
  let hash: String
  let flags: [String: Bool]
  let skill: SnapshotSkill
  let files: [(String, Data)]
  let diagnostics: [SourceImportDiagnostic]
  let bindings: [ImportBindingRequirement]

  static func read(_ path: String, input: SourceImportInput, limits: SourceImportLimits) throws
    -> Self
  {
    let path = try ImportInput.path(path)
    let source = try ImportInput.snapshot(input.root)
    let directory = try source.resource(path)
    // Admit the finite tree before readers that sort directory entries or recursively discover.
    // This capture profile refuses links rather than changing their producer hash semantics.
    guard limits.resourceEntries > 0, limits.resourceBytes >= 0, limits.depth > 0,
      let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { throw ImportReadFailure.invalid }
    var entries = 1
    var total = 0
    for case let entry as URL in iterator {
      try Task.checkCancellation()
      entries += 1
      guard entries <= limits.resourceEntries else { throw ImportReadFailure.invalid }
      let relative = try source.relativePath(entry)
      let depth =
        relative.split(separator: "/").count - (path == "." ? 0 : path.split(separator: "/").count)
      guard depth <= limits.depth else { throw ImportReadFailure.invalid }
      let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
      let type = attributes[.type] as? FileAttributeType
      guard type == .typeDirectory || type == .typeRegular else { throw ImportReadFailure.invalid }
      if type == .typeRegular {
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
          size >= 0, size <= limits.resourceBytes - total
        else { throw ImportReadFailure.invalid }
        total += size
      }
    }
    let frozen = try LedgerResources.capture(
      directory, embed: true,
      limits: .init(
        encodedBytes: limits.resourceBytes, depth: limits.depth, nodes: limits.nodes,
        objectBytes: limits.resourceBytes, entries: limits.resourceEntries,
        keyBytes: limits.resourceBytes,
        resourceBytes: limits.resourceBytes), sourceRoot: directory)
    // Link identity and link-following producer hashes are different contracts. This bounded
    // capture supports regular content; linked trees need explicit conversion before import.
    guard frozen.entries.allSatisfy({ $0.kind != .symlink }), frozen.support.isEmpty else {
      throw ImportReadFailure.invalid
    }
    let files = try frozen.entries.filter { $0.kind == .file }.map { entry -> (String, Data) in
      guard let object = entry.object, let bytes = frozen.objects[object] else {
        throw ImportReadFailure.invalid
      }
      return (entry.path, bytes)
    }
    guard files.contains(where: { $0.0 == "SKILL.md" }) else { throw ImportReadFailure.invalid }
    var semanticDiagnostics: [SourceImportDiagnostic] = []
    var bindings: [ImportBindingRequirement] = []
    // Validate captured skill YAML before existing discovery, then compare its observed tree
    // with the capture. The consuming preparation owns the stable source view and freshness.
    for (name, bytes) in files where name == "SKILL.md" || name.hasSuffix("/SKILL.md") {
      let semantics = try ImportFrontmatter.inspect(
        bytes, document: path + "/" + name,
        converted: ["name", "description", "agents", "platforms", "scopes"], profile: input.profile,
        limits: limits)
      semanticDiagnostics += semantics.diagnostics
      bindings += semantics.bindings
    }
    let selected = try SourceSnapshot(
      snapshot: source.snapshot, pin: nil, root: input.root, discoveryPath: path)
    let skills = try SkillSnapshotReader.read(selected)
    guard let skill = skills.first(where: { $0.path == path }) else {
      throw ImportReadFailure.invalid
    }
    guard skill.hash == frozen.hash else { throw ImportReadFailure.invalid }
    return .init(
      path: path, hash: frozen.hash, flags: frozen.flags, skill: skill, files: files,
      diagnostics: semanticDiagnostics, bindings: bindings)
  }

  /// Vercel skills 1.8.1 src/skill-hash.ts: byte-sorted paths, NUL-framed lengths,
  /// CRLF normalization for nonbinary files, and the installer's excluded names.
  static func vercelHash(_ content: Self) -> String {
    var framed = Data()
    let files = content.files.map { ($0.0.replacingOccurrences(of: "\\", with: "/"), $0.1) }
    for (path, bytes) in files.sorted(by: { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
    ) {
      let parts = path.split(separator: "/")
      if parts.contains("metadata.json")
        || parts.dropLast().contains(where: {
          [".git", "__pycache__", "__pypackages__"].contains($0)
        })
      {
        continue
      }
      var normalized = Data()
      if bytes.contains(0) {
        normalized = bytes
      } else {
        var index = 0
        while index < bytes.count {
          if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
          normalized.append(bytes[index])
          index += 1
        }
      }
      framed.append(Data((path + "\0" + String(normalized.count) + "\0").utf8))
      framed.append(normalized)
    }
    return FileHash.sha256Hex(data: framed)
  }
}
