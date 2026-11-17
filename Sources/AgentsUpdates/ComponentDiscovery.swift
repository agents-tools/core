import AgentsCore
import AgentsManifest
import Components
import Foundation

/// A linked authored graph or finite addition resolved in a temporary source session before deployment.
public struct ComponentDiscovery: Sendable {
  package var catalogPreparation: CatalogPreparation? = nil
  public let components: [ComponentInspection]
  public let sourceRevisions: [String: [String]]
  public let fingerprint: String
  public let readLocations: [URL]
  private let declaration: Declaration
  private let declarationDigest: String
  private let addition: CapturedAddition?

  /// Carries the captured declaration and exact discovered content into ordinary preparation.
  public func updateRequest() -> UpdateRequest {
    var request = UpdateRequest(
      operation: .declaration(declaration),
      expectedDeclarationDigest: declarationDigest)
    request.expectedDiscoveryFingerprint = fingerprint
    request.catalogPreparation = catalogPreparation
    request.capturedAddition = addition
    request.selectedIdentities = addition?.selectedIdentities
    request.importPreparation = addition?.importPreparation
    return request
  }

  init(
    components: [ComponentInspection], sourceRevisions: [String: [String]], fingerprint: String,
    readLocations: [URL], declaration: Declaration, declarationDigest: String,
    addition: CapturedAddition? = nil
  ) {
    self.components = components
    self.sourceRevisions = sourceRevisions
    self.fingerprint = fingerprint
    self.readLocations = readLocations
    self.declaration = declaration
    self.declarationDigest = declarationDigest
    self.addition = addition
  }
}

extension UpdateOperations {
  /// Resolves authored selections and exported groups for every linked family. It neither lowers
  /// native output nor executes source code, calls a binding provider, retains caches or recovers.
  public static func discover(
    _ declaration: Declaration, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ComponentDiscovery {
    let store = StateStore(scope: scope, environment: environment)
    return try discover(declaration, store: store, destination: nil, importPreparation: nil)
  }

  private static func discover(
    _ declaration: Declaration, store: StateStore, destination: AdditionDestination?,
    importPreparation: ImportPreparation?, allowNewIdentities: Bool = true
  ) throws -> ComponentDiscovery {
    return try store.withReadLock {
      try destination?.validate(in: store)
      _ = try importPreparation?.capture()
      let baseline = try StatePrecondition(store: store)
      let previous = try store.readDeclaration(prepared: baseline)
      let previousLedger = try store.readLedger(prepared: baseline)
      _ = try store.readWatch(prepared: baseline)
      let original = try store.declarationDocument(prepared: baseline)
      let change = try store.planDeclaration(declaration, replacing: previous, prepared: baseline)
      let document = try DeclarationDocument(
        bytes: change.map { Array($0.bytes) } ?? original?.bytes ?? Array("version: 1\n".utf8),
        identity: DocumentIdentity(store.declarationURL.path))
      #if os(macOS)
        let platform = DeclarationPlatform.macOS
      #else
        let platform = DeclarationPlatform.linux
      #endif
      let impact = try LedgerImpact(
        ledger: previousLedger, roots: store.ledgerRoots, kinds: [], names: [], updating: false)
      return try ComponentLinker.withLinkedComponents(
        document: document, store: store, platform: platform,
        preserving: destination == nil ? [:] : impact.pins,
        directPins: destination == nil ? [:] : impact.directPins,
        retaining: destination == nil ? nil : previousLedger
      ) { linked, session in
        let frozen = try LedgerFreeze.freezeWithSources(
          linked, session: session,
          locations: .init(
            sources: UpdatePlan.sourceLocations(linked, declaration: declaration, store: store)),
          limits: .standard)
        let ledger = frozen.ledger
        let fingerprint = try LedgerImpact.discoveryFingerprint(ledger, roots: store.ledgerRoots)
        let introduced = try Set(
          ledger.components.values.map {
            try LedgerImpact.identity($0, ledger: ledger, roots: store.ledgerRoots)
          }
        ).subtracting(
          previousLedger.components.values.map {
            try LedgerImpact.identity($0, ledger: previousLedger, roots: store.ledgerRoots)
          })
        let selected = allowNewIdentities ? introduced : Set<String>()
        if destination != nil {
          try LedgerImpact.requireProtected(
            previous: previousLedger, next: ledger, kinds: [], roots: store.ledgerRoots,
            selectedIdentities: selected)
        }
        let components = try componentInspections(
          ledger, roots: store.ledgerRoots,
          generation: ResolvedLedgerCodec.digest(ledger))
        var revisions: [String: [String]] = [:]
        var locations = try readLocations(
          declarations: [previous, declaration], ledgers: [ledger], store: store)
        for id in ledger.sources.keys.sorted() {
          let identity = try ledger.sourceIdentity(id, roots: store.ledgerRoots)
          revisions[identity, default: []].append(ledger.sources[id]!.revision)
          if let location = ledger.sources[id]!.location {
            locations.append(try location.resolve(roots: store.ledgerRoots))
          }
        }
        for key in revisions.keys { revisions[key] = Array(Set(revisions[key]!)).sorted() }
        try baseline.validate()
        return ComponentDiscovery(
          components: components, sourceRevisions: revisions,
          fingerprint: fingerprint,
          readLocations: Array(Set(locations)).sorted { $0.path < $1.path },
          declaration: declaration, declarationDigest: original?.digest ?? "absent",
          addition: destination.map {
            CapturedAddition(
              destination: $0, declaration: declaration, fingerprint: fingerprint,
              selectedIdentities: selected, importPreparation: importPreparation)
          })
      }
    }
  }
}

/// Immutable observations only; no source session, descriptor or borrowed resource is retained.
/// Core evidence types do not declare Sendable, but validate never mutates their captured values.
package final class AdditionDestination: @unchecked Sendable, CustomReflectable {
  package var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
  let store: StateStore
  let declaration: Declaration
  private let state: [TargetPrecondition]
  private let roots: [String: String]
  private let identities: [PathIdentity]

  init(store: StateStore, declaration: Declaration, baseline: StatePrecondition) throws {
    self.store = store
    self.declaration = declaration
    state = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      try baseline.evidence(for: $0)
    }
    roots = store.ledgerRoots.mapValues { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    identities = try [store.environment.projectDirectory, store.environment.homeDirectory].map {
      try PathIdentity($0)
    }
  }

  func validate(in current: StateStore) throws {
    guard current.scope == store.scope,
      current.directory.standardizedFileURL.path == store.directory.standardizedFileURL.path
    else { throw CoreError.invalidState("captured addition belongs to another destination") }
    for identity in identities { try identity.validate() }
    for evidence in state { try evidence.validate() }
    let currentRoots = current.ledgerRoots.mapValues {
      $0.standardizedFileURL.resolvingSymlinksInPath().path
    }
    // New named target roots are admitted separately by Core's closed-route coordination.
    guard roots.allSatisfy({ currentRoots[$0.key] == $0.value }) else {
      throw CoreError.invalidState("captured addition destination roots changed")
    }
  }
}

package struct CapturedAddition: Sendable {
  let destination: AdditionDestination
  let declaration: Declaration
  let fingerprint: String
  let selectedIdentities: Set<String>
  let importPreparation: ImportPreparation?

  func validate(_ request: UpdateRequest, in store: StateStore) throws {
    try destination.validate(in: store)
    guard case .declaration(let candidate) = request.operation, candidate == declaration,
      request.kinds == nil, request.names.isEmpty, request.selections.isEmpty,
      request.agents == nil,
      request.selectedIdentities == selectedIdentities,
      request.expectedDiscoveryFingerprint == fingerprint
    else { throw CoreError.invalidState("captured addition was modified; refresh selection") }
  }
}

extension UpdateOperations {
  /// Composes finite root additions without refreshing any recorded component. Empty effects
  /// return nil, including a source-only selection, and never initialize destination state.
  package static func captureAddition(
    _ additions: Declaration, in inspection: ScopeInspection,
    importPreparation: ImportPreparation? = nil
  ) throws -> ComponentDiscovery? {
    guard !additions.components.isEmpty || !additions.groups.isEmpty || !additions.uses.isEmpty
    else { return nil }
    guard !inspection.recovery.pending, let destination = inspection.additionDestination else {
      throw CoreError.invalidState("inspect the committed destination before selecting additions")
    }
    guard additions.agents == nil, additions.watch == nil, additions.exports.isEmpty else {
      throw CoreError.invalidState("finite additions cannot replace scope defaults or exports")
    }
    try destination.validate(in: destination.store)
    // Existing authored intent must already match its lock; selection cannot publish pending
    // authoring changes merely because they happen to appear in the composed graph.
    _ = try discover(
      destination.declaration, store: destination.store, destination: destination,
      importPreparation: nil, allowNewIdentities: false)
    var candidate = destination.declaration
    for entry in additions.sourceDeclarations {
      if let existing = candidate.sources[entry.name] {
        guard existing.kind == entry.source.kind, existing.requirement == entry.source.requirement,
          existing.path == entry.source.path,
          try existing.identity(environment: destination.store.environment)
            == entry.source.identity(environment: destination.store.environment)
        else {
          throw CoreError.invalidState("source alias conflicts with the destination: " + entry.name)
        }
      } else {
        candidate.sourceDeclarations.append(entry)
      }
    }
    for group in additions.groups {
      if let existing = candidate.groups.first(where: { $0.name == group.name }) {
        guard existing == group else {
          throw CoreError.invalidState("group conflicts with the destination: " + group.name)
        }
      } else {
        candidate.groups.append(group)
      }
    }
    for component in additions.components where !candidate.components.contains(component) {
      candidate.components.append(component)
    }
    for use in additions.uses where !candidate.uses.contains(use) { candidate.uses.append(use) }
    return try discover(
      candidate, store: destination.store, destination: destination,
      importPreparation: importPreparation)
  }
}
