import AgentsCore
import Foundation

package struct SnapshotInstruction: Equatable, Sendable {
  package let name: String
  package let path: String
  package let bytes: Data
  package let section: InstructionSection
}

/// Reads conventional containers in an exact source view. It does not resolve, cache or render.
package enum InstructionSnapshotReader {
  /// Named own selection does not inspect unrelated authoring drafts or entries.
  package static func read(_ view: SourceSnapshot, own name: String) throws -> SnapshotInstruction?
  {
    guard Declaration.isInstructionName(name) else {
      throw CoreError.invalidSource("invalid instruction name: \(name)")
    }
    let root = try view.directory()
    let container =
      root.lastPathComponent == ".agent" ? "instructions" : InstructionSources.ownContainer
    let file = root.appendingPathComponent(container).appendingPathComponent(name + ".md")
    let path = try view.relativePath(file)
    try InstructionSources.requireNoLinks(file, below: view.root)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try read(view, name: name, path: path)
  }

  package static func read(_ view: SourceSnapshot, own: Bool = false) throws
    -> [SnapshotInstruction]
  {
    let root = try view.directory()
    let containers =
      own
      ? [root.lastPathComponent == ".agent" ? "instructions" : InstructionSources.ownContainer]
      : InstructionSources.containers
    var names = Set<String>()
    var result: [SnapshotInstruction] = []
    for container in containers {
      let directory = root.appendingPathComponent(container)
      for (name, file) in try InstructionSources.files(in: directory, tree: view.root) {
        try Task.checkCancellation()
        guard names.insert(name).inserted else {
          throw CoreError.invalidSource("duplicate instruction name: \(name)")
        }
        let path = try view.relativePath(file)
        result.append(try read(view, name: name, path: path))
      }
    }
    return result.sorted { $0.name < $1.name }
  }

  package static func searchRoots(of path: String, name: String) -> [String] {
    InstructionSources.containers.compactMap { container in
      let unit = container + "/" + name + ".md"
      if path == unit { return "." }
      if path.hasSuffix("/" + unit) { return String(path.dropLast(unit.count + 1)) }
      return nil
    }
  }

  package static func requireNoLinks(_ file: URL, in view: SourceSnapshot) throws {
    try InstructionSources.requireNoLinks(file, below: view.root)
  }

  private static func read(_ view: SourceSnapshot, name: String, path: String) throws
    -> SnapshotInstruction
  {
    let bytes = try FileSystem.read(at: view.resource(path))
    let section = try Instructions.validateSource(
      bytes, id: view.snapshot.source + ":" + name, allowRestrictions: true)
    return SnapshotInstruction(name: name, path: path, bytes: bytes, section: section)
  }
}
