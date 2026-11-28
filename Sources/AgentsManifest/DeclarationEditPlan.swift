import AgentsCore

package enum DeclarationEditPlan {
  package static func bytes(
    replacing previous: Declaration, with next: Declaration, in bytes: [UInt8]?,
    identity: DocumentIdentity, environment: RuntimeEnvironment
  ) throws -> [UInt8]? {
    try next.validate(environment: environment)
    guard let bytes else {
      if ManifestProjection.equivalent(previous, next, environment: environment) { return nil }
      let ir = YAMLConstruction.root(next)
      try validateIRBudget(IRTree.root(ir), source: SourceText([], identity: identity))
      let output = YAMLWriter.manifest(ir)
      let document = try DeclarationDocument(bytes: output, identity: identity)
      guard
        ManifestProjection.equivalent(
          try ManifestProjection.declaration(of: document, environment: environment), next,
          environment: environment)
      else {
        throw document.source.failure(
          "manifest.edit.mismatch", "constructed declaration differs from intended domain", 0)
      }
      return output
    }
    let original = try DeclarationDocument(bytes: bytes, identity: identity)
    let current = try ManifestProjection.declaration(of: original, environment: environment)
    guard ManifestProjection.equivalent(current, previous, environment: environment) else {
      throw original.source.failure(
        "manifest.edit.baseline", "declaration changed during preparation", 0)
    }
    if ManifestProjection.equivalent(current, next, environment: environment) { return nil }
    var target = next
    // Retained sources preserve their spelling and comments when identity, requirement and
    // subpath agree in their declaring environments. Their authored order still participates.
    for index in target.sourceDeclarations.indices {
      if let old = current.sourceDeclarations.first(where: {
        $0.name == target.sourceDeclarations[index].name
      }),
        ManifestProjection.equivalent(
          old.source, target.sourceDeclarations[index].source, environment: environment)
      {
        target.sourceDeclarations[index].source = old.source
      }
    }
    let intended = IRTree.root(YAMLConstruction.root(target))
    let initial = IRTree.root(original.declaration)
    var diff = IRDiff()
    try diff.compare(initial, intended)
    return try compose(
      diff.edits, original: original, intended: intended, next: next, environment: environment)
  }

  static func compose(
    _ edits: [IREdit], original: DeclarationDocument, intended: DeclarationValue, next: Declaration,
    environment: RuntimeEnvironment
  ) throws -> [UInt8] {
    let initial = IRTree.root(original.declaration)
    // The direct script fixes target positions/fields once. Its length is bounded by the two
    // admitted IR structures, independently of how batches are sized or sources transition.
    let peakNodes = IRTree.count(initial) + IRTree.count(intended)
    let maximum = 2 * peakNodes
    guard edits.count <= maximum else {
      throw original.source.failure("manifest.limit", "edit composition bound", 0)
    }
    var currentDocument = original
    var offset = 0
    while offset < edits.count {
      let cost = 2 * peakNodes + 2 * ManifestLimits.Syntax.nodes
      let count = min(
        ManifestLimits.Editing.requests, max(1, ManifestLimits.Editing.steps / max(1, cost)))
      let end = min(edits.count, offset + count)
      currentDocument = try DocumentEditor.draft(Array(edits[offset..<end]), in: currentDocument)
        .document
      offset = end
    }
    let final = try DeclarationDocument(
      bytes: currentDocument.bytes, identity: original.source.identity)
    guard IRTree.equivalent(IRTree.root(final.declaration), intended),
      ManifestProjection.equivalent(
        try ManifestProjection.declaration(of: final, environment: environment), next,
        environment: environment)
    else {
      throw original.source.failure(
        "manifest.edit.mismatch", "final declaration differs from full intended IR/domain", 0)
    }
    return final.bytes
  }
}
