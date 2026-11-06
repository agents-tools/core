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
        let bytes = try FileSystem.read(at: view.resource(path))
        let id = view.snapshot.source + ":" + name
        let section = try Instructions.validateSource(bytes, id: id, allowRestrictions: true)
        result.append(
          SnapshotInstruction(
            name: name, path: path, bytes: bytes,
            section: section))
      }
    }
    return result.sorted { $0.name < $1.name }
  }
}
