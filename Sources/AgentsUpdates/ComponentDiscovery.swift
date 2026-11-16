import AgentsCore
import AgentsManifest
import Components
import Foundation

/// A complete explicit selection graph resolved in a temporary source session, before deployment.
public struct ComponentDiscovery: Sendable {
  public let components: [ComponentInspection]
  public let sourceRevisions: [String: [String]]
  public let fingerprint: String
  public let readLocations: [URL]
  private let declaration: Declaration
  private let declarationDigest: String

  /// Carries both the captured scope and exact discovered content into ordinary preparation.
  public func updateRequest() -> UpdateRequest {
    var request = UpdateRequest(
      operation: .declaration(declaration),
      expectedDeclarationDigest: declarationDigest)
    request.expectedDiscoveryFingerprint = fingerprint
    return request
  }

  init(
    components: [ComponentInspection], sourceRevisions: [String: [String]], fingerprint: String,
    readLocations: [URL], declaration: Declaration, declarationDigest: String
  ) {
    self.components = components
    self.sourceRevisions = sourceRevisions
    self.fingerprint = fingerprint
    self.readLocations = readLocations
    self.declaration = declaration
    self.declarationDigest = declarationDigest
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
    return try store.withReadLock {
      let baseline = try StatePrecondition(store: store)
      let previous = try store.readDeclaration(prepared: baseline)
      _ = try store.readLedger(prepared: baseline)
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
      return try ComponentLinker.withLinkedComponents(
        document: document, store: store, platform: platform
      ) { linked, session in
        let frozen = try LedgerFreeze.freezeWithSources(
          linked, session: session,
          locations: .init(
            sources: UpdatePlan.sourceLocations(linked, declaration: declaration, store: store)),
          limits: .standard)
        let ledger = frozen.ledger
        let fingerprint = try LedgerImpact.discoveryFingerprint(ledger, roots: store.ledgerRoots)
        let components = try componentInspections(
          ledger, roots: store.ledgerRoots,
          generation: ResolvedLedgerCodec.digest(ledger))
        var revisions: [String: [String]] = [:]
        var locations = [store.declarationURL, store.resolvedURL, store.watchURL]
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
          declaration: declaration, declarationDigest: original?.digest ?? "absent")
      }
    }
  }
}
