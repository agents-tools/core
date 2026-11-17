import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Components
import Foundation

/// A logical identity independent of revision, resources and temporary extraction paths.
public struct ComponentSelection: Hashable, Sendable {
  public let identity: String
  /// An occurrence selection is checked against the inspection generation before use.
  public let occurrence: Int?
  public let generation: String
}

public struct ComponentInspection: Sendable {
  public let record: String
  public let sourceRecord: String
  public let declaringSourceRecord: String
  public let selection: ComponentSelection
  public let kind: DeclaredComponentKind
  public let name: String
  public let source: String
  public let declaringSource: String
  public let root: String
  public let group: String?
  public let revision: String?
  public let version: String?
  /// Frozen symbolic configuration. Binding slots are objects with `environment` or `secret` keys.
  public let configuration: NativeValue
  public let conditions: [DeclarationCondition]
  public let recipients: [AgentID]
  public let chatGPT: Bool
  public let resources: [String]
  public let occurrences: [OccurrenceInspection]
}

public struct OccurrenceInspection: Sendable {
  public let declaringSourceRecord: String
  public let dependencyRecords: [String]
  public let selection: ComponentSelection
  public let declaringSource: String
  public let manifestPath: String
  public let reference: Int?
  public let dependencies: [String]
  public let condition: DeclarationCondition
  public let recipients: [AgentID]
  public let consumerEditable: Bool
}

public struct SourceInspection: Sendable {
  public let record: String
  public let identity: String
  public let kind: SourceKind
  public let revision: String
  public let version: String?
  public let container: String?
  public let namespace: String?
  public let location: URL?
  public let uses: [SourceInspectionUse]
}

public struct SourceInspectionUse: Sendable {
  public let root: String
  public let requirement: SourceRequirement?
}

public struct GroupInspection: Sendable {
  public let sourceRecord: String
  public let id: Int
  public let parent: Int?
  public let source: String
  public let root: String
  public let name: String
  public let requirement: SourceRequirement?
  public let manifestHash: String
  public let children: [Int]
}

public struct ResourceInspection: Sendable {
  public let sourceRecord: String
  public let identity: String
  public let source: String
  public let path: String
  public let hash: String
  public let kind: String
  public let location: URL?
  public let entries: [ResourceEntryInspection]
  public let support: [ResourceEntryInspection]
}

public struct ResourceEntryInspection: Sendable {
  public let path: String
  public let kind: String
  public let executable: Bool
  public let link: String?
  public let byteCount: Int?
}

public struct DeploymentInspection: Sendable {
  public enum Status: String, Sendable { case current, missing, drifted, unverified }
  public let identity: String
  public let location: URL
  public let format: String
  public let owners: [String]
  public let ownerRecords: [String]
  public let recipients: [AgentID]
  public let ownership: String
  public let effectiveReaders: [AgentID]?
  public let privateMaterialization: Bool
  public let status: Status
  /// Fixed diagnostics never contain native sibling bytes or provider values.
  public let diagnostic: String?
}

public struct RecoveryInspection: Sendable {
  public let pending: Bool
  public let requiresOwner: Bool
  public let diagnostic: String?
}

/// One read generation. No native bytes, retained content objects, provider calls or recovery.
public struct ScopeInspection: Sendable {
  public let scope: InstallScope
  public let document: DeclarationDocument?
  public let declaration: Declaration?
  public let generation: String?
  public let sources: [SourceInspection]
  public let components: [ComponentInspection]
  public let groups: [GroupInspection]
  public let resources: [ResourceInspection]
  public let deployments: [DeploymentInspection]
  public let watch: WatchState?
  public let recovery: RecoveryInspection
  /// Actual state, source and deployment paths, including absent leaves for directory watching.
  public let readLocations: [URL]
}

extension UpdateOperations {
  public static func inspect(
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ScopeInspection {
    let store = StateStore(scope: scope, environment: environment)
    var admitted = Set<NativeTargetRoute>()
    var installations: [String: SkillInstallationTarget] = [:]
    let stateLocations = [store.declarationURL, store.resolvedURL, store.watchURL]
    while true {
      do {
        return try store.withReadLock(
          onPendingRecovery: {
            let diagnostic = FileTransaction.recoveryDiagnostic(store: store)
            return ScopeInspection(
              scope: scope, document: nil, declaration: nil, generation: nil,
              sources: [], components: [], groups: [], resources: [], deployments: [], watch: nil,
              recovery: .init(
                pending: true, requiresOwner: diagnostic.requiresOwner,
                diagnostic: diagnostic.message),
              readLocations: stateLocations)
          }, footprint: admitted, installations: Array(installations.values),
          {
            let baseline = try StatePrecondition(store: store)
            let document = try store.declarationDocument(prepared: baseline)
            let declaration = try store.readDeclaration(prepared: baseline)
            let ledger = try store.readLedger(prepared: baseline)
            let routes = try DeploymentConstruction.routes(ledger)
            let required = try SkillLifecycle.installationTargets(ledger, store: store)
            guard routes.isSubset(of: admitted),
              Set(required.keys).isSubset(of: Set(installations.keys))
            else { throw RequiredRoutes(routes: routes, installations: required) }
            let watch = try store.readWatch(prepared: baseline)
            let generation = try ResolvedLedgerCodec.digest([
              ResolvedLedgerCodec.digest(ledger), document?.digest ?? "absent",
            ])
            let roots = store.ledgerRoots
            func source(_ id: String) throws -> String {
              try ledger.sourceIdentity(id, roots: roots)
            }
            let sources = try ledger.sources.keys.sorted().map { id in
              let s = ledger.sources[id]!
              return SourceInspection(
                record: id, identity: try source(id), kind: s.kind, revision: s.revision,
                version: s.version,
                container: try s.container.map(source), namespace: s.namespace,
                location: try s.location?.resolve(roots: roots),
                uses: ledger.sourceUses.filter { $0.source == id }.map {
                  .init(root: $0.root, requirement: $0.requirement)
                })
            }
            let components = try componentInspections(ledger, roots: roots, generation: generation)
            func entry(_ e: LedgerEntry) -> ResourceEntryInspection {
              .init(
                path: e.path, kind: e.kind.rawValue, executable: e.executable,
                link: e.link, byteCount: e.byteCount)
            }
            let resources = try ledger.resources.keys.sorted().map { id in
              let r = ledger.resources[id]!
              return ResourceInspection(
                sourceRecord: r.source, identity: id, source: try source(r.source), path: r.path,
                hash: r.hash,
                kind: r.kind.rawValue,
                location: try ArtifactAggregation.resourceDestination(
                  id, ledger: ledger, store: store),
                entries: r.entries.map(entry), support: r.support.map(entry))
            }
            let deployments = try ledger.deployments.map { d in
              let url = try d.target.resolve(roots: roots)
              let observed = try ArtifactAggregation.inspectDeployment(
                d, ledger: ledger, store: store)
              let exposure = try ArtifactAggregation.nativeExposure(d, ledger: ledger, store: store)
              return DeploymentInspection(
                identity: d.id, location: url, format: d.route,
                owners: try d.owners.map {
                  try LedgerImpact.identity(ledger.components[$0]!, ledger: ledger, roots: roots)
                },
                ownerRecords: d.owners, recipients: d.recipients, ownership: d.ownership.rawValue,
                effectiveReaders: exposure.readers, privateMaterialization: exposure.sensitive,
                status: DeploymentInspection.Status(rawValue: observed.status)!,
                diagnostic: observed.diagnostic)
            }
            let groups = try ledger.groups.map { g in
              GroupInspection(
                sourceRecord: g.source, id: g.id, parent: g.parent, source: try source(g.source),
                root: g.root,
                name: g.name, requirement: g.requirement, manifestHash: g.manifestHash,
                children: g.children)
            }
            let paths =
              try readLocations(
                declarations: [declaration], ledgers: [ledger], store: store)
              + installations.values.map(\.url)
            try baseline.validate()
            return ScopeInspection(
              scope: scope, document: document, declaration: declaration, generation: generation,
              sources: sources, components: components, groups: groups, resources: resources,
              deployments: deployments, watch: watch,
              recovery: .init(pending: false, requiresOwner: false, diagnostic: nil),
              readLocations: Array(Set(paths)).sorted { $0.path < $1.path })
          })
      } catch let required as RequiredRoutes {
        admitted.formUnion(required.routes)
        installations.merge(required.installations, uniquingKeysWith: { _, next in next })
      }
    }
  }

  static func componentInspections(
    _ ledger: ResolvedLedger, roots: [String: URL], generation: String
  ) throws -> [ComponentInspection] {
    func source(_ id: String) throws -> String { try ledger.sourceIdentity(id, roots: roots) }
    func condition(_ c: LedgerCondition) -> DeclarationCondition {
      .init(
        agents: c.agents, scopes: c.scopes,
        platforms: c.platforms?.compactMap(DeclarationPlatform.init(rawValue:)))
    }
    return try ledger.components.keys.sorted().map { id in
      let c = ledger.components[id]!
      let identity = try LedgerImpact.identity(c, ledger: ledger, roots: roots)
      return ComponentInspection(
        record: id, sourceRecord: c.source, declaringSourceRecord: c.declaringSource,
        selection: .init(identity: identity, occurrence: nil, generation: generation),
        kind: DeclaredComponentKind(rawValue: c.kind)!, name: c.name,
        source: try source(c.source), declaringSource: try source(c.declaringSource),
        root: c.root, group: c.group, revision: c.revision, version: c.version,
        configuration: symbolicValue(c.payload), conditions: c.conditions.map(condition),
        recipients: c.recipients, chatGPT: c.chatGPT, resources: c.resources,
        occurrences: try ledger.occurrences.filter { $0.component == id }.map { o in
          .init(
            declaringSourceRecord: o.declaringSource, dependencyRecords: o.dependencies,
            selection: .init(identity: identity, occurrence: o.id, generation: generation),
            declaringSource: try source(o.declaringSource), manifestPath: o.manifestPath,
            reference: o.reference, dependencies: try o.dependencies.map(source),
            condition: condition(o.condition), recipients: o.recipients,
            consumerEditable: o.consumerEditable)
        })
    }
  }

  static func symbolicValue(_ value: LedgerValue) -> NativeValue {
    switch value.kind {
    case .environment: return .object(["environment": .string(value.text!)])
    case .secret: return .object(["secret": .string(value.text!)])
    case .string, .literal: return .string(value.text!)
    case .integer: return .integer(value.integer!)
    case .decimal: return .decimal(value.text!)
    case .boolean: return .boolean(value.boolean!)
    case .null: return .null
    case .array: return .array(value.array!.map(symbolicValue))
    case .object: return .object(value.object!.mapValues(symbolicValue))
    }
  }
}
