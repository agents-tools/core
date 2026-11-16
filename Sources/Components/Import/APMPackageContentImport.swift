import AgentsCore
import Foundation

/// APM-native authoring content is authoritative when .apm exists. Plugin-native layouts need
/// their verified container adapter; absence of .apm never selects an arbitrary fallback tree.
enum APMPackageContentImport {
  static func read(
    input: SourceImportInput, origin: ImportLocation, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    let parent = (input.document as NSString).deletingLastPathComponent
    let path = parent.isEmpty ? ".apm" : parent + "/.apm"
    let view = try ImportInput.snapshot(input.root)
    let directory = try view.resource(path)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      diagnostics.add(.unsafePath, origin, "APM source layout is not an admitted directory.")
      return
    }
    var remaining = limits.resourceEntries
    func children(_ path: String) throws -> [String] {
      let directory = try view.resource(path)
      guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
      guard
        let iterator = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
      else { throw ImportReadFailure.invalid }
      var result: [String] = []
      for case let child as URL in iterator {
        try Task.checkCancellation()
        guard remaining > 0 else { throw ImportReadFailure.invalid }
        remaining -= 1
        result.append(child.lastPathComponent)
      }
      return result.sorted()
    }
    for (index, name) in try children(path).enumerated() where name != "skills" {
      diagnostics.add(
        .unconverted, origin.appending("layout/member[\(index)]"),
        "APM primitive requires its component semantics adapter; no native container fallback is selected."
      )
    }
    for (index, name) in try children(path + "/skills").enumerated() {
      let location = origin.appending("skills/member[\(index)]")
      guard ImportInput.name(name) else {
        diagnostics.add(.unsafePath, location, "Invalid APM skill resource name.")
        continue
      }
      let skillPath = path + "/skills/" + name
      do {
        let gitBoundary = try view.resource(skillPath + "/.git")
        if FileManager.default.fileExists(atPath: gitBoundary.path) {
          diagnostics.add(
            .unconverted, location, "Nested Git checkout is outside APM authoring discovery.")
          continue
        }
        let content = try ImportSkillContent.read(skillPath, input: input, limits: limits)
        diagnostics.proposal.diagnostics += content.diagnostics
        diagnostics.proposal.bindings += content.bindings
        let alias = "apm-local-skill-\(index)"
        diagnostics.proposal.sources.append(
          .init(
            alias: alias, origin: location,
            declaration: .init(
              kind: .local, location: content.path,
              environment: .init(projectDirectory: input.root, homeDirectory: input.root)),
            pin: .init(), requestedRef: nil, producerPath: nil))
        diagnostics.proposal.resources.append(
          .init(
            origin: location, sourceAlias: alias, producerName: name, path: ".",
            producerIntegrity: nil, observedHash: content.hash, executableFlags: content.flags,
            requiresStandaloneSource: true, kind: .skills))
        diagnostics.proposal.components.append(
          .init(
            origin: location,
            declaration: .skills(
              source: alias,
              .init(select: .names([content.skill.name]), condition: content.skill.condition))))
      } catch is CancellationError { throw CancellationError() } catch CoreError.unsafePath {
        diagnostics.add(
          .unsafePath, location, "APM skill resource escapes its explicit source boundary.")
      } catch {
        diagnostics.add(
          .unconverted, location,
          "APM skill resource is missing, malformed or exceeds content bounds.")
      }
    }
  }
}
