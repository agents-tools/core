import AgentsCore
import AgentsDescription
import Foundation

/// Declaration access for scope state. Core owns the file, its captured bytes, the missing
/// declaration rule and publication; this module parses, projects and plans edits. Parse, edit
/// and subset failures are `ManifestFailure` diagnostics identified by the declaration path.
extension StateStore {
  /// The deployable declaration, or an empty one when the scope has no state.
  package func readDeclaration(prepared: StatePrecondition? = nil) throws -> Declaration {
    guard let document = try declarationDocument(prepared: prepared) else { return Declaration() }
    return try ManifestProjection.declaration(of: document, environment: environment)
  }

  /// Plans `next` as an edit of the prepared document that `previous` was read from. Nil means
  /// no semantic change. A document that no longer projects to `previous` is a stale
  /// preparation.
  package func planDeclaration(
    _ next: Declaration, replacing previous: Declaration, prepared: StatePrecondition
  ) throws -> DeclarationChange? {
    let bytes = try declarationBytes(prepared: prepared)
    let output: [UInt8]?
    do {
      output = try DeclarationEditPlan.bytes(
        replacing: previous, with: next, in: bytes.map(Array.init), identity: declarationIdentity,
        environment: environment)
    } catch let failure as ManifestFailure
      where failure.diagnostics.contains(where: { $0.code == "manifest.edit.baseline" })
    {
      throw CoreError.invalidState("declaration changed during preparation: \(declarationURL.path)")
    }
    return output.map { DeclarationChange(bytes: Data($0)) }
  }

  /// Commits state through the scope journal. Omitting watch preserves its existing bytes. A
  /// scope without a declaration document receives one, so the saved lock is never orphaned.
  package func save(
    declaration: Declaration, resolved: ResolvedState, watch: WatchState? = nil
  ) throws {
    try withLock {
      try declaration.validate(environment: environment)
      try resolved.validate()
      try watch?.validate()
      let baseline = try StatePrecondition(store: self)
      let previous = try readDeclaration(prepared: baseline)
      _ = try readResolved(prepared: baseline)
      var change = try planDeclaration(declaration, replacing: previous, prepared: baseline)
      if change == nil, try declarationBytes(prepared: baseline) == nil {
        change = DeclarationChange(
          bytes: Data(
            try CanonicalPrinter().manifest(
              DeclarationConstruction.root(declaration).constructionValue)))
      }
      let transaction = FileTransaction(store: self)
      transaction.requireUnchanged(since: baseline)
      try stageDeclaration(change, in: transaction, prepared: baseline)
      try transaction.replace(
        resolvedURL, with: .data(Self.encodeState(resolved.normalized)),
        expecting: baseline.evidence(for: resolvedURL))
      if let watch {
        try transaction.replace(
          watchURL, with: .data(Self.encode(watch)), expecting: baseline.evidence(for: watchURL))
      }
      try transaction.commit()
    }
  }

  /// Reads the deployable declaration under a shared lock, without recovery or creating files.
  public func loadDeclaration() throws -> Declaration {
    try withReadLock { try readDeclaration() }
  }

  /// Reads the complete declaration document under a shared lock, without recovery, creating
  /// files or restricting it to the deployable subset. Nil means the scope has no state.
  public func loadManifest() throws -> DeclarationDocument? {
    try withReadLock { try declarationDocument(prepared: nil) }
  }

  private var declarationIdentity: DocumentIdentity { DocumentIdentity(declarationURL.path) }

  private func declarationDocument(prepared: StatePrecondition?) throws -> DeclarationDocument? {
    try declarationBytes(prepared: prepared).map {
      try DeclarationDocument(bytes: Array($0), identity: declarationIdentity)
    }
  }
}

extension DeclarationAccess {
  package static var manifest: Self {
    Self(
      read: { store, prepared in try store.readDeclaration(prepared: prepared) },
      plan: { store, previous, next, prepared in
        try store.planDeclaration(next, replacing: previous, prepared: prepared)
      })
  }
}

extension WatchOperations {
  public init(
    discoverSkills: @escaping @Sendable (URL) throws -> [WatchSkill],
    fetchArtifacts: @escaping @Sendable (String) throws -> [WatchArtifact]
  ) {
    self.init(
      discoverSkills: discoverSkills, fetchArtifacts: fetchArtifacts, declarations: .manifest)
  }
}
