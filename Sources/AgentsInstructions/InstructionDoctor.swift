import AgentsCore
import Foundation

extension InstructionOperations {
  /// Audits disk, state and upstream refs without fetching objects, creating locks or recovering transactions.
  /// Supply Codex's effective settings to include trusted project, profile or policy overrides.
  /// Without them, discovery uses top-level user configuration and defaults.
  public static func doctor(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment(),
    codexConfiguration: CodexInstructionConfiguration? = nil
  ) throws -> InstructionDoctorReport {
    let store = StateStore(scope: scope, environment: environment)
    let other = StateStore(scope: scope == .project ? .user : .project, environment: environment)
    let otherSections = try operate(other, apply: false) { _, lock in lock.instructions.sections }
    return try operate(store, apply: false) { declaration, lock in
      var diagnostics: [InstructionDiagnostic] = []
      func report(_ kind: InstructionDiagnostic.Kind, _ message: String, _ path: URL? = nil) {
        diagnostics.append(InstructionDiagnostic(kind: kind, message: message, path: path))
      }
      if !FileManager.default.fileExists(atPath: store.resolvedURL.path),
        !(declaration.instructions?.sections.isEmpty ?? true)
          || !(declaration.instructions?.chatgpt?.isEmpty ?? true)
      {
        report(
          .missingLock, "Instruction declaration has no lock; update can reconstruct it.",
          store.resolvedURL)
      }
      let sources = InstructionSources(store: store)
      for (key, target) in lock.instructions.targets.sorted(by: { $0.key < $1.key }) {
        do {
          let file = try InstructionLocations.file(for: key, store: store)
          let bytes = try InstructionTargets.read(file) ?? Data()
          let drift = try Instructions.detectDrift(in: bytes, lockedBlockHash: target.blockHash)
          switch drift {
          case .clean: break
          case .missingBlock: report(.missingBlock, "Managed instruction block is missing.", file)
          case .drifted: report(.drift, "Managed instruction block differs from its lock.", file)
          }
          if target.import == nil {
            let sections = try sources.restore(
              lock.instructions.sections, sources: lock.sources, cachedOnly: true)
            let assembly = try Instructions.assemble(
              bytes, sections: sections.map(\.section),
              options: InstructionOptions(
                headingOffset: target.headingOffset, replaceConflicts: true))
            for section in assembly.adoptedSections {
              report(.adoption, "Custom section can be adopted: \(section)", file)
            }
            for conflict in assembly.conflicts {
              report(.conflict, "\(conflict.sectionID):\n\(conflict.difference)", file)
            }
          }
        } catch {
          report(.invalidTarget, "\(key): \(error)")
        }
      }
      let duplicates = Instructions.sectionsInBothScopes(
        user: (scope == .user ? lock.instructions.sections : otherSections).map(
          InstructionSources.identity),
        project: (scope == .project ? lock.instructions.sections : otherSections).map(
          InstructionSources.identity))
      for id in duplicates { report(.duplicateScope, "Section is installed at both scopes: \(id)") }
      let agents = Set(lock.instructions.targets.values.flatMap(\.agents))
        .union(declaration.instructions?.agents ?? declaration.defaultAgents)
      if scope == .project, agents.contains(.claudeCode) {
        do {
          if case .needsImport(let path) = try ClaudeForwarding.classify(
            InstructionTargets(store: store).claudeFiles())
          {
            report(
              .claudeForwarding, "Claude file does not forward to the project's AGENTS.md.",
              environment.projectDirectory.appendingPathComponent(path.rawValue))
          }
        } catch { report(.claudeForwarding, "Cannot inspect Claude forwarding: \(error)") }
        let userClaude = InstructionLocations.file(
          for: .claudeCode, scope: .user, environment: environment)?.resolvingSymlinksInPath()
        for directory in InstructionDoctor.ancestors(of: environment.projectDirectory) {
          for path in ClaudeInstructionPath.allCases {
            let file = directory.appendingPathComponent(path.rawValue)
            if file.resolvingSymlinksInPath() != userClaude,
              FileManager.default.fileExists(atPath: file.path)
            {
              report(
                .claudeAncestor,
                "Ancestor Claude file can hide project AGENTS.md; it is outside this scope.", file)
            }
          }
        }
      }
      if agents.contains(.codex) {
        diagnostics += InstructionDoctor.codex(
          scope: scope, environment: environment, lock: lock, configuration: codexConfiguration)
      }
      diagnostics += InstructionSourceDiagnostics.inspect(
        store: store, declaration: declaration, lock: lock)
      return InstructionDoctorReport(
        root: scope == .project ? environment.projectDirectory : environment.homeDirectory,
        diagnostics: diagnostics)
    }
  }

  /// Audits explicit project roots independently. An unreadable scope becomes a diagnostic;
  /// no project is repaired and no source cache is populated.
  public static func doctor(
    projectRoots: [URL], environment: RuntimeEnvironment = RuntimeEnvironment(),
    codexConfiguration: ((URL) throws -> CodexInstructionConfiguration)? = nil
  ) -> [InstructionDoctorReport] {
    var seen = Set<String>()
    return projectRoots.compactMap { root in
      let root = root.standardizedFileURL
      guard seen.insert(root.path).inserted else { return nil }
      var runtime = environment
      runtime.projectDirectory = root
      do {
        return try doctor(
          scope: .project, environment: runtime, codexConfiguration: codexConfiguration?(root))
      } catch {
        return InstructionDoctorReport(
          root: root,
          diagnostics: [
            InstructionDiagnostic(
              kind: .stateUnavailable, message: String(describing: error), path: root)
          ])
      }
    }
  }
}

private enum InstructionDoctor {
  static func ancestors(of root: URL) -> [URL] {
    var result: [URL] = []
    var cursor = root.resolvingSymlinksInPath()
    while cursor.path != "/" {
      cursor.deleteLastPathComponent()
      result.append(cursor)
    }
    return result
  }

  static func codex(
    scope: InstallScope, environment: RuntimeEnvironment, lock: ResolvedState,
    configuration supplied: CodexInstructionConfiguration?
  ) -> [InstructionDiagnostic] {
    var result: [InstructionDiagnostic] = []
    let user = InstructionLocations.file(for: .codex, scope: .user, environment: environment)!
    let config = user.deletingLastPathComponent().appendingPathComponent("config.toml")
    var configuration = supplied ?? CodexInstructionConfiguration()
    do {
      if supplied == nil, FileManager.default.fileExists(atPath: config.path) {
        configuration = try CodexInstructionConfiguration(Data(contentsOf: config))
      }
    } catch {
      result.append(
        InstructionDiagnostic(
          kind: .invalidConfiguration,
          message: "Cannot read instruction discovery configuration: \(error)",
          path: config))
    }
    var directories = [user.deletingLastPathComponent()]
    if scope == .project {
      let cwd = environment.projectDirectory.resolvingSymlinksInPath()
      let candidates = [cwd] + ancestors(of: cwd)
      if let index = candidates.firstIndex(where: {
        directory in
        configuration.rootMarkers.contains {
          FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
      }) {
        directories += candidates[...index].reversed()
      } else {
        directories.append(cwd)
      }
    }
    var loaded: [(URL, Int)] = []
    for (index, directory) in directories.enumerated() {
      let override = directory.appendingPathComponent("AGENTS.override.md")
      let normal = directory.appendingPathComponent("AGENTS.md")
      let overriding = (try? Data(contentsOf: override)).flatMap { $0.isEmpty ? nil : $0 }
      if overriding != nil {
        let managed =
          lock.instructions.targets.contains { key, value in
            guard value.agents.contains(.codex) else { return false }
            return
              (try? InstructionLocations.file(
                for: key, store: StateStore(scope: scope, environment: environment)))
              == InstructionLocations.physical(normal)
          }
          || ((try? Data(contentsOf: normal)).flatMap {
            try? MarkdownDocument(bytes: $0).managedBlock()
          } != nil)
        if managed {
          result.append(
            InstructionDiagnostic(
              kind: .codexOverride, message: "AGENTS.override.md hides a managed AGENTS.md.",
              path: override))
        }
      }
      let names =
        ["AGENTS.override.md", "AGENTS.md"] + (index == 0 ? [] : configuration.fallbackNames)
      for name in names {
        let file = directory.appendingPathComponent(name)
        if let bytes = try? Data(contentsOf: file), !bytes.isEmpty {
          loaded.append((file, bytes.count))
          break
        }
      }
    }
    let bytes = loaded.reduce(0) { $0 + $1.1 } + max(0, loaded.count - 1) * 2
    if bytes > configuration.maxBytes {
      result.append(
        InstructionDiagnostic(
          kind: .codexSize,
          message:
            "Codex instruction chain is \(bytes) bytes, exceeding project_doc_max_bytes (\(configuration.maxBytes)): \(loaded.map { $0.0.path }.joined(separator: ", "))",
          path: environment.projectDirectory))
    }
    return result
  }

}
