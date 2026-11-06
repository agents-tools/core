import AgentsCore
import AgentsInstructions
import Foundation

/// Borrowed trees are valid only inside the replay closure. Shared-file values are intentions;
/// physical ownership, secret binding and publication remain with the applying operation.
package struct ReplayedArtifact {
  package var name: String
  package var kind: LedgerArtifactDigest.Kind
  package var bytes: Data?
  package var tree: URL?
  package var values: LedgerValue?
  package var location: LedgerLocation?

  package init(
    name: String, kind: LedgerArtifactDigest.Kind, bytes: Data? = nil,
    tree: URL? = nil, values: LedgerValue? = nil, location: LedgerLocation? = nil
  ) {
    self.name = name
    self.kind = kind
    self.bytes = bytes
    self.tree = tree
    self.values = values
    self.location = location
  }

  package func digest(limits: LedgerLimits) throws -> LedgerArtifactDigest {
    let hash: String
    switch kind {
    case .link:
      guard let location, bytes == nil, tree == nil, values == nil else {
        throw CoreError.invalidState("invalid live link")
      }
      hash = try ResolvedLedgerCodec.digest(location)
    case .file, .registration:
      guard let bytes, tree == nil, values == nil else {
        throw CoreError.invalidState("invalid rendered file")
      }
      hash = "sha256:" + FileHash.sha256Hex(data: bytes)
    case .tree:
      guard let tree, bytes == nil, values == nil else {
        throw CoreError.invalidState("invalid rendered tree")
      }
      let captured = try LedgerResources.capture(tree, embed: false, limits: limits)
      hash = try ResolvedLedgerCodec.digest(
        TreeDigest(content: captured.hash, entries: captured.entries))
    case .ownedValues:
      guard let values, bytes == nil, tree == nil else {
        throw CoreError.invalidState("invalid owned values")
      }
      hash = try ResolvedLedgerCodec.digest(values)
    }
    return .init(name: name, kind: kind, hash: hash)
  }

  private struct TreeDigest: Encodable {
    let content: String
    let entries: [LedgerEntry]
  }
}

package typealias LedgerRenderer = (
  _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
) throws -> [ReplayedArtifact]

package enum LedgerReplay {
  /// Only formats with implemented production semantics are registered here. Tests explicitly
  /// supply their own renderer table; a format is never selected by agent or current version.
  package static var compatibilityRenderers: [String: LedgerRenderer] {
    [
      "agents/skill@1": skill, "agents/instructions@1": instructions,
      "agents/claude-import@1": forwarding, "agents/chatgpt@1": chatGPT,
    ]
  }

  package static func withReplay<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer] = compatibilityRenderers,
    _ body: ([ReplayedArtifact]) throws -> T
  ) throws -> T {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: renderers,
      recording: false
    ) { artifacts, _ in try body(artifacts) }
  }

  /// Seals renderer output identities into a candidate before encoding or publication.
  package static func prepareLowerings(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer] = compatibilityRenderers
  ) throws -> ResolvedLedger {
    try run(
      ledger, store: store, roots: roots, limits: limits, renderers: renderers,
      recording: true
    ) { _, lowerings in
      var candidate = ledger
      candidate.lowerings = lowerings
      try candidate.validate()
      return candidate
    }
  }

  private static func run<T>(
    _ ledger: ResolvedLedger, store: StateStore, roots: [String: URL], limits: LedgerLimits,
    renderers: [String: LedgerRenderer], recording: Bool,
    _ body: ([ReplayedArtifact], [LockedLowering]) throws -> T
  ) throws -> T {
    try ResolvedLedgerCodec.checkModel(ledger, limits: limits)
    try ledger.validate()
    try Task.checkCancellation()
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    #if os(macOS)
      let current = "macos"
    #else
      let current = "linux"
    #endif
    for lowering in ledger.lowerings {
      guard renderers[lowering.format] != nil else {
        throw CoreError.invalidState("unknown renderer format")
      }
      guard lowering.platform == current else {
        throw CoreError.invalidState("locked lowering is incompatible with platform: " + platform)
      }
    }
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-ledger-" + UUID().uuidString)
    try FileSystem.createDirectory(at: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }
    return try SourceResolutionSession.withTemporaryRead(store: store) { session in
      var acquired: [String: URL] = [:]
      for (id, resource) in ledger.resources.sorted(by: { $0.key < $1.key }) {
        try Task.checkCancellation()
        let file: URL
        if resource.kind == .liveEdit {
          guard let location = resource.location else {
            throw CoreError.invalidState("missing live location")
          }
          file = try location.resolve(roots: roots)
          var directory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory),
            directory.boolValue
          else {
            throw CoreError.notFound("live edit skill source")
          }
        } else if resource.kind == .embedded || resource.kind == .artifact {
          let destination = workspace.appendingPathComponent(UUID().uuidString)
          file =
            resource.support.isEmpty
            ? destination
            : try PathSafety.resolvedChild(base: destination, subpath: resource.path)
          var embedded = resource
          embedded.kind = .embedded
          try LedgerResources.materialize(embedded, objects: ledger.contentObjects, at: destination)
        } else {
          var source = ledger.sources[resource.source]!
          while let container = source.container { source = ledger.sources[container]! }
          let declaration: SourceDeclaration
          if let transport = source.transport {
            declaration = SourceDeclaration(
              kind: .git, location: transport, requirement: .revision(source.revision))
          } else if let location = source.location {
            declaration = SourceDeclaration(
              kind: .local, location: try location.resolve(roots: roots).path,
              requirement: .revision(source.revision))
          } else {
            throw CoreError.invalidState("missing pinned source coordinates")
          }
          let view = try session.snapshot(
            declaration, at: SourceRevision(revision: source.revision))
          file = try view.resource(resource.path)
        }
        if resource.kind != .liveEdit {
          let captured = try LedgerResources.capture(file, embed: false, limits: limits)
          let expected = resource.entries.map { entry -> LedgerEntry in
            var entry = entry
            entry.object = nil
            return entry
          }
          guard captured.hash == resource.hash, captured.entries == expected else {
            throw CoreError.invalidState("locked resource content or execute bits changed")
          }
        }
        acquired[id] = file
      }
      var result: [ReplayedArtifact] = []
      var sealed: [LockedLowering] = []
      var names = Set<String>()
      for lowering in ledger.lowerings {
        try Task.checkCancellation()
        let rendered = try renderers[lowering.format]!(lowering, ledger, acquired)
        let digests = try rendered.map { try $0.digest(limits: limits) }
        guard recording || digests == lowering.artifacts else {
          throw CoreError.invalidState("locked renderer output hash mismatch")
        }
        for artifact in rendered {
          guard names.insert(artifact.name).inserted else {
            throw CoreError.invalidState("overlapping rendered artifacts")
          }
        }
        var locked = lowering
        locked.artifacts = digests
        sealed.append(locked)
        result += rendered
      }
      return try body(result, sealed)
    }
  }

  private static func skill(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    guard lowering.resources.count == 1, let resource = lowering.resources.first,
      let tree = resources[resource], let name = lowering.layout.object?["name"]?.text
    else {
      throw CoreError.invalidState("invalid skill lowering")
    }
    if let record = ledger.resources[resource], record.kind == .liveEdit {
      return [.init(name: name, kind: .link, location: record.location)]
    }
    return [.init(name: name, kind: .tree, tree: tree)]
  }

  private static func instructions(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    let bytes = try lowering.resources.map { id in
      guard let resource = resources[id] else {
        throw CoreError.invalidState("missing instruction input")
      }
      return try FileSystem.read(at: resource)
    }
    guard let name = lowering.layout.object?["name"]?.text,
      lowering.layout.object?["headingOffset"]?.integer ?? 0 == 0
    else {
      throw CoreError.invalidState("unsupported instruction layout")
    }
    return [
      .init(
        name: name, kind: .file,
        bytes: try InstructionCompatibility.renderSections(bytes, ids: lowering.resources))
    ]
  }

  private static func chatGPT(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    guard let count = lowering.layout.object?["sectionCount"]?.integer, count > 0,
      count <= lowering.resources.count, lowering.resources.count <= count + 1,
      let name = lowering.layout.object?["name"]?.text
    else { throw CoreError.invalidState("invalid prompt layout") }
    let sections = try lowering.resources.prefix(count).map { id in
      guard let file = resources[id] else { throw CoreError.invalidState("missing prompt section") }
      return try FileSystem.read(at: file)
    }
    let append = try lowering.resources.dropFirst(count).first.map { id in
      guard let file = resources[id] else { throw CoreError.invalidState("missing prompt append") }
      return try FileSystem.read(at: file)
    }
    return [
      .init(
        name: name, kind: .file,
        bytes: try InstructionCompatibility.renderPrompt(
          sections, ids: Array(lowering.resources.prefix(count)), append: append))
    ]
  }

  private static func forwarding(
    _ lowering: LockedLowering, _ ledger: ResolvedLedger, _ resources: [String: URL]
  ) throws -> [ReplayedArtifact] {
    guard let name = lowering.layout.object?["name"]?.text,
      let path = ClaudeInstructionPath(rawValue: name)
    else { throw CoreError.invalidState("invalid forwarding layout") }
    return [
      .init(name: name, kind: .file, bytes: Data(ClaudeForwarding.renderBlock(for: path).utf8))
    ]
  }
}
