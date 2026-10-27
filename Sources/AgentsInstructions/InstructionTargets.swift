import AgentsCore
import Foundation

struct InstructionTargets {
  let store: StateStore

  /// Plans every generated target from `sections` in declared order, the Claude import, and the
  /// removal of targets that no longer receive sections. `restoring` keeps the locked targets,
  /// recipients and Claude imports, and requires each rendering to match its locked hash.
  func plan(
    sections: [InstructionSection], agents: [AgentID], previous: LockedInstructions,
    restoring: Bool = false
  ) throws -> (targets: [String: LockedTarget], changes: [InstructionTargetChange]) {
    var targets: [String: LockedTarget] = [:]
    var rendered: [String: String] = [:]
    if !sections.isEmpty {
      let recipients =
        restoring
        ? Array(Set(previous.targets.values.filter { $0.import == nil }.flatMap(\.agents)))
        : Array(Set(agents))
      var groups: [String: [InstructionSection]] = [:]
      var order: [String] = []
      for section in sections {
        let directory = store.scope == .project ? section.directory : ""
        if groups[directory] == nil { order.append(directory) }
        groups[directory, default: []].append(section)
      }
      for directory in order {
        if !directory.isEmpty { try validateNested(directory) }
        let text = try Instructions.render(groups[directory]!)
        for agent in recipients.sorted(by: { $0.rawValue < $1.rawValue }) {
          guard let file = try location(for: agent, directory: directory) else { continue }
          let key = InstructionLocations.key(for: file, store: store)
          _ = try InstructionLocations.file(for: key, store: store)
          if targets[key] != nil {
            targets[key]?.agents.append(agent)
          } else {
            rendered[key] = text
            targets[key] = LockedTarget(
              agents: [agent], headingOffset: 0, blockHash: Instructions.hash(Data(text.utf8)),
              created: false)
          }
        }
      }
      if !restoring, store.scope == .project, recipients.contains(.claudeCode),
        targets["AGENTS.md"] != nil, let path = try forwardingPath()
      {
        let file = store.environment.projectDirectory.appendingPathComponent(path.rawValue)
        let key = InstructionLocations.key(for: InstructionLocations.physical(file), store: store)
        guard targets[key] == nil else {
          throw CoreError.invalidState("forwarding overlaps an instruction target")
        }
        targets[key] = LockedTarget(
          agents: [.claudeCode], import: String(path.importLine.dropFirst()), blockHash: "",
          created: false)
      }
    }
    if restoring {
      guard
        Set(targets.keys) == Set(previous.targets.filter { $0.value.import == nil }.keys)
      else { throw InstructionError.invalidLockedBlock }
      for (key, target) in previous.targets where target.import != nil { targets[key] = target }
    }
    var changes: [InstructionTargetChange] = []
    var problems: [InstructionLinkProblem] = []
    for key in Set(previous.targets.keys).union(targets.keys).sorted() {
      let file = try InstructionLocations.file(for: key, store: store)
      let before = try Self.read(file)
      let old = previous.targets[key]
      var after: Data?
      var foreign = false
      if let target = targets[key], let reference = target.import {
        guard store.scope == .project, let path = ClaudeInstructionPath(rawValue: key),
          reference == String(path.importLine.dropFirst())
        else { throw CoreError.invalidState("invalid Claude forwarding target") }
        if restoring, before == nil {
          // The owner deleted the Claude file; install does not recreate it.
          after = nil
        } else {
          let edit = try Self.importBlock(in: before ?? Data(), at: path)
          after = edit.bytes
          targets[key]?.blockHash = edit.blockHash
          targets[key]?.created = old?.created ?? (before == nil)
        }
      } else if let text = rendered[key] {
        guard store.scope == .user || directoryExists(of: file) else {
          throw CoreError.notFound("the directory of instruction target \(key)")
        }
        after = Data(text.utf8)
        foreign = before.map { $0 != after && !Instructions.isOwned($0) } ?? false
        if restoring, targets[key]?.blockHash != old?.blockHash {
          throw InstructionError.invalidLockedBlock
        }
        problems += linkProblems(in: text, file: file, key: key)
      } else if let old, old.import != nil {
        let edit = try Instructions.removeBlock(from: before ?? Data())
        let delete = old.created && !edit.hasCustomContent
        after = delete || before == nil ? nil : edit.bytes
      } else if let old, let before {
        // A target that no longer receives sections is deleted only while it is the locked
        // rendering; a drifted file is kept for its owner to resolve.
        after = Instructions.hash(before) == old.blockHash ? nil : before
      }
      let drift = try old.map { old -> InstructionDrift in
        guard let before else { return .missing }
        if old.import != nil {
          return try Instructions.detectDrift(in: before, lockedBlockHash: old.blockHash)
        }
        return Instructions.hash(before) == old.blockHash ? .clean : .drifted
      }
      targets[key]?.agents.sort { $0.rawValue < $1.rawValue }
      changes.append(
        InstructionTargetChange(
          target: key, url: file, before: before, after: after,
          beforeAgents: old?.agents.sorted { $0.rawValue < $1.rawValue },
          afterAgents: targets[key]?.agents ?? [], drift: drift, foreign: foreign))
    }
    guard problems.isEmpty else { throw InstructionError.invalidLinks(problems) }
    return (targets, changes)
  }

  /// The file an agent reads for sections placed in `directory`, or nil when the agent has no file.
  private func location(for agent: AgentID, directory: String) throws -> URL? {
    guard
      let root = InstructionLocations.file(
        for: agent, scope: store.scope, environment: store.environment)
    else { return nil }
    let file =
      store.scope == .project && !directory.isEmpty
      ? store.environment.projectDirectory.appendingPathComponent(directory)
        .appendingPathComponent(root.lastPathComponent)
      : root
    return InstructionLocations.physical(file)
  }

  /// A nested target's directory is a real directory of this checkout: no component is a symbolic
  /// link or `.git`, and none holds another repository or worktree.
  private func validateNested(_ directory: String) throws {
    var cursor = store.environment.projectDirectory.resolvingSymlinksInPath()
    for component in directory.split(separator: "/").map(String.init) {
      cursor.appendPathComponent(component)
      if component == ".git"
        || (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil
      {
        throw CoreError.unsafePath(
          "an instruction target directory cannot be a symbolic link or Git metadata: \(directory)")
      }
      if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
        throw CoreError.unsafePath(
          "an instruction target directory cannot be inside another repository: \(directory)")
      }
    }
  }

  private func directoryExists(of file: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: file.deletingLastPathComponent().path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The Claude file that needs a managed import of `AGENTS.md`, or nil when Claude Code already
  /// reads it: no project Claude file, a symbolic link to `AGENTS.md`, or a standalone import.
  private func forwardingPath() throws -> ClaudeInstructionPath? {
    let files = try claudeFiles()
    switch try ClaudeForwarding.classify(files) {
    case .automatic: return nil
    case .needsImport(let candidate): return candidate
    case .forwarding(let candidate):
      let file = files.first { $0.path == candidate }
      let managed =
        try file.map { try MarkdownDocument(bytes: $0.bytes).managedBlock() != nil } ?? false
      return file?.isSymbolicLinkToAgents == true || !managed ? nil : candidate
    }
  }

  /// Links in a rendered target that do not resolve, from the target file, to a regular file in
  /// the checkout being written. User targets belong to no checkout, so every local link fails.
  func linkProblems(in text: String, file: URL, key: String) -> [InstructionLinkProblem] {
    var problems: [InstructionLinkProblem] = []
    let root =
      Self.realPath(store.environment.projectDirectory.path)
      ?? store.environment.projectDirectory.resolvingSymlinksInPath()
    for link in Instructions.localLinks(in: text) {
      func problem(_ reason: String) {
        problems.append(
          InstructionLinkProblem(target: key, destination: link.destination, reason: reason))
      }
      guard link.kind != .html else {
        problem("is a raw HTML link; use a Markdown link")
        continue
      }
      guard let path = link.path, !path.isEmpty else {
        problem("has an empty destination")
        continue
      }
      guard store.scope == .project else {
        problem("points to a local file; user instructions cannot link to local files")
        continue
      }
      let destination =
        path.hasPrefix("/") ? path : file.deletingLastPathComponent().path + "/" + path
      guard let resolved = Self.realPath(destination) else {
        let lexical = URL(fileURLWithPath: destination).standardizedFileURL
        let project = store.environment.projectDirectory
        let inside = [root, project.standardizedFileURL, project.resolvingSymlinksInPath()]
          .contains { PathSafety.isContained(lexical, in: $0) }
        problem(
          inside
            ? "does not resolve to an existing file" : "points outside the checkout being written")
        continue
      }
      guard PathSafety.isContained(resolved, in: root), resolved != root else {
        problem("points outside the checkout being written")
        continue
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        problem("does not resolve to an existing file")
        continue
      }
      var cursor = resolved.deletingLastPathComponent()
      while cursor.path.count > root.path.count {
        if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
          problem("points into another repository or worktree")
          break
        }
        cursor.deleteLastPathComponent()
      }
    }
    return problems
  }

  /// The path with each symbolic link resolved before a following `..`, as the kernel resolves it
  /// for a reader, or nil when it does not exist.
  private static func realPath(_ path: String) -> URL? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real))
  }

  /// The Claude files in `directory`, the project root by default, beside its `AGENTS.md`.
  func claudeFiles(in directory: URL? = nil) throws -> [ClaudeInstructionFile] {
    let directory = directory ?? store.environment.projectDirectory
    let agents = directory.appendingPathComponent("AGENTS.md").resolvingSymlinksInPath()
    return try ClaudeInstructionPath.allCases.compactMap { path in
      let file = directory.appendingPathComponent(path.rawValue)
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

  /// Rejects targets inside an instructions container of a local source.
  static func validateSourceDirectories(
    _ changes: [InstructionTargetChange], sources: [String: LockedSource]
  ) throws {
    for source in sources where source.value.kind == .local {
      let root = URL(fileURLWithPath: String(source.key.dropFirst("local:".count)))
      let search = try PathSafety.resolvedChild(base: root, subpath: source.value.path ?? ".")
      for container in InstructionSources.containers {
        let directory = search.appendingPathComponent(container).resolvingSymlinksInPath()
        guard
          !changes.contains(where: {
            PathSafety.isContained($0.url.resolvingSymlinksInPath(), in: directory)
          })
        else {
          throw CoreError.unsafePath(
            "a source instructions container cannot hold an instruction target")
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
    -> (bytes: Data, blockHash: String)
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
    return (document.byteOrderMark + Data(output.utf8), Instructions.hash(Data(block.utf8)))
  }
}
