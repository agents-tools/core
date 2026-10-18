import AgentsCore
import Foundation

enum InstructionSourceDiagnostics {
  static func inspect(store: StateStore, declaration: Declaration, lock: ResolvedState)
    -> [InstructionDiagnostic]
  {
    var diagnostics: [InstructionDiagnostic] = []
    let cache = SourceCache(store: store)
    let sections = lock.instructions.sections + lock.instructions.chatgpt.values.flatMap(\.sections)
    for (id, source) in lock.sources.sorted(by: { $0.key < $1.key }) {
      let pins = sections.filter { $0.source == id }
      guard !pins.isEmpty else { continue }
      let root =
        source.kind == .local ? URL(fileURLWithPath: String(id.dropFirst("local:".count))) : nil
      do {
        let declared = try declaration.sources.values.first {
          try $0.identity(environment: store.environment) == id
        }
        let current = try cache.inspectRevision(
          declared ?? cache.declaration(sourceID: id, source: source))
        func differs(_ section: LockedSection) -> Bool {
          section.source == id
            && (section.revision != current.revision || section.version != current.version)
        }
        let outdated = pins.filter(differs)
        if !outdated.isEmpty {
          let previous = Set(
            outdated.map { pin in
              (pin.revision ?? "missing") + (pin.version.map { " (\($0))" } ?? "")
            }
          ).sorted().joined(separator: ", ")
          let selected = current.revision + (current.version.map { " (\($0))" } ?? "")
          let files = lock.instructions.sections.filter(differs).map(\.name).joined(separator: ", ")
          let prompts = lock.instructions.chatgpt.filter {
            $0.value.sections.contains(where: differs)
          }
          .keys.sorted().joined(separator: ", ")
          var message =
            "Matching source revision differs from locked pins: \(id): \(previous) -> \(selected)."
          if !files.isEmpty { message += " File sections: \(files)." }
          if !prompts.isEmpty { message += " ChatGPT prompt pins: \(prompts)." }
          diagnostics.append(
            InstructionDiagnostic(kind: .sourceUpdateAvailable, message: message, path: root))
        }
      } catch {
        diagnostics.append(
          InstructionDiagnostic(
            kind: .sourceResolutionFailed,
            message: "Cannot resolve instruction source \(id): \(error)",
            path: root))
      }
      if let root {
        do {
          let paths = Set(pins.map(\.path)).sorted()
          let output = try ProcessRunner.git(
            [
              "--no-optional-locks", "-C", root.path, "status", "--porcelain",
              "--untracked-files=all", "--",
            ] + paths, operation: "read the status of", source: root.path
          ).stdout
          if !output.isEmpty {
            diagnostics.append(
              InstructionDiagnostic(
                kind: .uncommittedSource,
                message: "Local source has uncommitted selected instructions: \(id)",
                path: root))
          }
        } catch {
          diagnostics.append(
            InstructionDiagnostic(
              kind: .stateUnavailable, message: "Cannot inspect local instruction source: \(error)",
              path: root))
        }
      }
    }
    return diagnostics
  }
}
