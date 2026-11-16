import AgentsCore
import AgentsManifest
import Foundation

/// Markdown delimiters select YAML bytes; YAML syntax and scalar admission remain in AgentsManifest.
/// Padding the opening delimiter preserves original UTF-8 offsets and line numbers.
enum ImportFrontmatter {
  static func inspect(
    _ bytes: Data, document: String, converted: Set<String>, profile: SourceImportProfile,
    limits: SourceImportLimits
  ) throws -> (diagnostics: [SourceImportDiagnostic], bindings: [ImportBindingRequirement]) {
    let parsed = try read(bytes, document: document, limits: limits)
    var diagnostics = ImportDiagnostics(proposal: .init(profile: profile))
    parsed.header?.unknown(converted, into: &diagnostics)
    return (diagnostics.proposal.diagnostics, diagnostics.proposal.bindings)
  }

  static func read(_ bytes: Data, document: String, limits: SourceImportLimits) throws
    -> (header: ImportYAML?, body: Data)
  {
    let source = Array(bytes)
    let bom = source.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    guard source.count >= bom + 4, Array(source[bom..<(bom + 3)]) == [45, 45, 45],
      [10, 13].contains(source[bom + 3])
    else { return (nil, bytes) }
    var index = bom + 3
    if source[index] == 13 { index += 1 }
    if index < source.count, source[index] == 10 { index += 1 }
    while index < source.count {
      try Task.checkCancellation()
      guard index <= min(limits.documentBytes, ManifestLimits.Input.bytes) else {
        throw ImportReadFailure.invalid
      }
      let start = index
      while index < source.count, ![10, 13].contains(source[index]) {
        guard index <= min(limits.documentBytes, ManifestLimits.Input.bytes) else {
          throw ImportReadFailure.invalid
        }
        index += 1
      }
      if Array(source[start..<index]) == [45, 45, 45] {
        var header = Array(source[..<start])
        header.replaceSubrange(bom..<(bom + 3), with: [32, 32, 32])
        let reader = try YAMLReader(bytes: header, identity: .init(document))
        let root = ImportYAML(reader: reader, node: reader.root, pointer: "/frontmatter")
        try ImportYAML.check(reader.root, limits: limits)
        guard root.pairs != nil else { throw ImportReadFailure.invalid }
        var bodyStart = index
        if bodyStart < source.count, source[bodyStart] == 13 { bodyStart += 1 }
        if bodyStart < source.count, source[bodyStart] == 10 { bodyStart += 1 }
        return (root, Data(source[bodyStart...]))
      }
      if index < source.count, source[index] == 13 { index += 1 }
      if index < source.count, source[index] == 10 { index += 1 }
    }
    throw ImportReadFailure.invalid
  }
}
