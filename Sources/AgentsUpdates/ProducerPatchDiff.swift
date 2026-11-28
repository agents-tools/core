import AgentsCore
import Foundation

enum ProducerPatchDiff {
  static func files(for edits: [ProducerPatchPlan.Edit], in workspace: URL?) throws
    -> [ProducerPatchFile]
  {
    guard !edits.isEmpty else { return [] }
    guard let workspace else { throw CoreError.invalidState("missing producer patch workspace") }
    let before = workspace.appendingPathComponent("before")
    let after = workspace.appendingPathComponent("after")
    let scratch = try DirectoryHandle.readDirectory(at: workspace)
    var remaining = ProducerPatchInputs.limits.resourceBytes
    var names = Set<String>()
    var files: [ProducerPatchFile] = []
    for (producer, edits) in Dictionary(grouping: edits, by: \.producer) {
      let digest = try ResolvedLedgerCodec.digest(producer).dropFirst(7).prefix(32)
      let base: String
      let reference: String
      switch producer.base {
      case .git(let commit):
        base = "commit " + commit
        reference = String(commit.prefix(12))
      case .release(let version, let digest):
        base = "version " + version + " (" + digest + ")"
        reference = version
      }
      let label =
        producer.package
        ?? String(producer.source.split(separator: "/").last ?? "producer")
      let name = String(PathSafety.sanitizeName(label).prefix(80))
      let ref = String(PathSafety.sanitizeName(reference).prefix(32))
      let filename = "\(name)@\(ref)-\(digest).patch"
      guard names.insert(filename).inserted else {
        throw CoreError.invalidState("producer patch filename collision")
      }
      let sorted = edits.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
      let selectors = Array(Set(sorted.flatMap(\.selectors))).sorted()
      var patch = Data()
      func append(_ text: String) throws {
        guard text.utf8.count <= remaining else {
          throw CoreError.invalidState("producer patch output byte budget")
        }
        remaining -= text.utf8.count
        patch.append(contentsOf: text.utf8)
      }
      try append("# Source: " + header(producer.source) + "\n")
      if let package = producer.package { try append("# Package: " + header(package) + "\n") }
      try append("# Root: " + header(producer.root) + "\n# Base: " + header(base) + "\n")
      for selector in selectors { try append("# Selector: " + header(selector) + "\n") }
      try append("\n")
      for edit in sorted {
        try Task.checkCancellation()
        try edit.before.write(to: before)
        try edit.after.write(to: after)
        let diff = try ProcessRunner.isolatedGit(
          [
            "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
            "--text", "--diff-algorithm=myers", "--no-indent-heuristic", "--unified=3",
            "--output=diff", "--", "before", "after",
          ], in: workspace)
        guard diff.exitCode == 1 else {
          throw CoreError.invalidState("cannot generate producer patch")
        }
        // Git's fixed scratch names bound the preamble separately from the hunk budget.
        let bytes = try scratch.readRegularFile("diff", maximumBytes: remaining + 1024)
        guard let output = String(data: bytes, encoding: .utf8),
          let start = output.range(of: "\n@@ -", options: .literal)
        else { throw CoreError.invalidState("cannot generate producer patch hunks") }
        let a = quote("a/" + edit.path)
        let b = quote("b/" + edit.path)
        try append("diff --git \(a) \(b)\n--- \(a)\n+++ \(b)\n")
        try append(String(output[start.lowerBound...].dropFirst()))
      }
      files.append(
        .init(
          filename: filename, producer: producer, selectors: selectors,
          paths: sorted.map(\.path), content: String(decoding: patch, as: UTF8.self)))
    }
    return files.sorted { $0.filename < $1.filename }
  }

  private static func header(_ text: String) -> String {
    text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
      .joined()
  }

  private static func quote(_ path: String) -> String {
    var result = "\""
    for byte in path.utf8 {
      switch byte {
      case 34, 92: result += "\\" + String(UnicodeScalar(byte))
      case 32...126: result += String(UnicodeScalar(byte))
      default: result += String(format: "\\%03o", Int(byte))
      }
    }
    return result + "\""
  }
}
