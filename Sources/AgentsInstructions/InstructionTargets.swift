import AgentsCore
import Foundation

struct InstructionTargets {
  let store: StateStore

  func plan(
    sections: [InstructionSection], agents: [AgentID], previous: LockedInstructions,
    replace: Bool, restoring: Bool = false
  ) throws -> (targets: [String: LockedTarget], changes: [InstructionTargetChange]) {
    var targets: [String: LockedTarget] = [:]
    if restoring {
      targets = previous.targets
    } else if !sections.isEmpty {
      for agent in Set(agents) {
        guard
          let logical = InstructionLocations.file(
            for: agent, scope: store.scope, environment: store.environment)
        else { continue }
        let file = logical.resolvingSymlinksInPath()
        let key = InstructionLocations.key(for: file, store: store)
        _ = try InstructionLocations.file(for: key, store: store)
        if targets[key] != nil {
          targets[key]?.agents.append(agent)
        } else {
          targets[key] = LockedTarget(
            agents: [agent], headingOffset: 0, blockHash: "", created: false)
        }
      }
      if store.scope == .project, agents.contains(.claudeCode) {
        let files = try claudeFiles()
        let forwarding = try ClaudeForwarding.classify(files)
        let path: ClaudeInstructionPath?
        switch forwarding {
        case .automatic: path = nil
        case .needsImport(let candidate): path = candidate
        case .forwarding(let candidate):
          let file = files.first { $0.path == candidate }
          let managed =
            try file.map { try MarkdownDocument(bytes: $0.bytes).managedBlock() != nil } ?? false
          path = file?.isSymbolicLinkToAgents == true || !managed ? nil : candidate
        }
        if let path {
          let file = store.environment.projectDirectory.appendingPathComponent(path.rawValue)
          let key = InstructionLocations.key(for: InstructionLocations.physical(file), store: store)
          guard targets[key] == nil else {
            throw CoreError.invalidState("forwarding overlaps a section target")
          }
          targets[key] = LockedTarget(
            agents: [.claudeCode], import: String(path.importLine.dropFirst()), blockHash: "",
            created: false)
        }
      }
    }
    var changes: [InstructionTargetChange] = []
    for key in Set(previous.targets.keys).union(targets.keys).sorted() {
      let file = try InstructionLocations.file(for: key, store: store)
      let before = try Self.read(file)
      let old = previous.targets[key]
      let drift = try old.map {
        try Instructions.detectDrift(in: before ?? Data(), lockedBlockHash: $0.blockHash)
      }
      let assembly: InstructionAssembly
      if let target = targets[key] {
        if let reference = target.import {
          guard store.scope == .project,
            let path = ClaudeInstructionPath(rawValue: key),
            reference == String(path.importLine.dropFirst())
          else { throw CoreError.invalidState("invalid Claude forwarding target") }
          assembly = try Self.importBlock(in: before ?? Data(), at: path)
        } else {
          guard !sections.isEmpty else {
            throw CoreError.invalidState("instruction target has no locked sections")
          }
          assembly = try Instructions.assemble(
            before ?? Data(), sections: sections,
            options: InstructionOptions(
              headingOffset: restoring ? target.headingOffset : nil, replaceConflicts: replace))
        }
        guard let blockHash = assembly.blockHash else { throw InstructionError.invalidAssembly }
        if restoring, blockHash != target.blockHash { throw InstructionError.invalidLockedBlock }
        targets[key]?.blockHash = blockHash
        targets[key]?.headingOffset = target.import == nil ? assembly.headingOffset : nil
        targets[key]?.created = old?.created ?? (before == nil)
        targets[key]?.agents.sort { $0.rawValue < $1.rawValue }
      } else {
        assembly = try Instructions.remove(from: before ?? Data())
      }
      let delete = targets[key] == nil && old?.created == true && !assembly.hasCustomContent
      let after = delete || (before == nil && targets[key] == nil) ? nil : assembly.bytes
      changes.append(
        InstructionTargetChange(
          target: key, url: file, before: before, after: after,
          beforeAgents: old?.agents.sorted { $0.rawValue < $1.rawValue },
          afterAgents: targets[key]?.agents ?? [], assembly: assembly, drift: drift))
    }
    return (targets, changes)
  }

  func claudeFiles() throws -> [ClaudeInstructionFile] {
    let agents = store.environment.projectDirectory.appendingPathComponent("AGENTS.md")
      .resolvingSymlinksInPath()
    return try ClaudeInstructionPath.allCases.compactMap { path in
      let file = store.environment.projectDirectory.appendingPathComponent(path.rawValue)
      let link = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)
      guard link != nil || FileManager.default.fileExists(atPath: file.path) else { return nil }
      if let link,
        URL(fileURLWithPath: link, relativeTo: file.deletingLastPathComponent())
          .standardizedFileURL.resolvingSymlinksInPath() == agents
      {
        return ClaudeInstructionFile(path: path, isSymbolicLinkToAgents: true)
      }
      return ClaudeInstructionFile(path: path, bytes: try Self.read(file) ?? Data())
    }
  }

  static func validateSourceDirectories(
    _ changes: [InstructionTargetChange], sources: [String: LockedSource]
  ) throws {
    for source in sources where source.value.kind == .local {
      let root = URL(fileURLWithPath: String(source.key.dropFirst("local:".count)))
      let search = try PathSafety.resolvedChild(base: root, subpath: source.value.path ?? ".")
      for container in ["instructions", ".agents/instructions"] {
        let directory = search.appendingPathComponent(container).resolvingSymlinksInPath()
        guard !changes.contains(where: { $0.url.deletingLastPathComponent() == directory })
        else {
          throw CoreError.unsafePath(
            "a source instructions directory cannot be an instruction target")
        }
      }
    }
  }

  static func read(_ file: URL) throws -> Data? {
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
      throw CoreError.unsafePath("instruction target is a symbolic link: \(file.path)")
    }
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw CoreError.unsafePath("instruction target is not a regular file: \(file.path)")
    }
    return try Data(contentsOf: file)
  }

  private static func importBlock(in bytes: Data, at path: ClaudeInstructionPath) throws
    -> InstructionAssembly
  {
    let document = try MarkdownDocument(bytes: bytes)
    let old = try document.managedBlock()
    var prefix = old.map { Array(document.lines[..<$0.lowerBound]) } ?? []
    var suffix = old.map { Array(document.lines[$0.upperBound...]) } ?? document.lines
    if prefix.last?.isBlank == true { prefix.removeLast() }
    if suffix.first?.isBlank == true { suffix.removeFirst() }
    let before = prefix.map(\.raw).joined()
    let after = suffix.map(\.raw).joined()
    let block = ClaudeForwarding.renderBlock(for: path)
    let output = Instructions.separatedPrefix(before) + block + (after.isEmpty ? "" : "\n" + after)
    try Instructions.validateAssembly(output, expected: block)
    let previous = old.map { document.normalized($0) }
    return InstructionAssembly(
      bytes: document.byteOrderMark + Data(output.utf8), headingOffset: 0,
      block: block, blockHash: Instructions.hash(Data(block.utf8)), adoptedSections: [],
      conflicts: [],
      blockDifference: previous.flatMap {
        $0 == block ? nil : Instructions.difference(from: $0, to: block)
      },
      hasCustomContent: !before.isEmpty || !after.isEmpty)
  }
}
