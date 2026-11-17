import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Components
import Foundation

struct RequiredRoutes: Error {
  let routes: Set<NativeTargetRoute>
  var installations: [String: SkillInstallationTarget] = [:]
}

/// The composition plan borrows both source/replay resources and the admitted writer scope.
final class UpdatePlan {
  func requireOwnership() throws { try aggregation.requireOwnership() }

  let report: CombinedUpdateReport
  private let store: StateStore
  private let baseline: StatePrecondition
  private let next: ResolvedLedger
  private let watch: WatchState
  private let declarationChange: DeclarationChange?
  private let aggregation: ArtifactAggregation
  private let checkpoint: (String) throws -> Void
  private let provider: any RuntimeBindingProvider
  private let inputs: UpdateInputs
  private let receipts: [InstallResult]

  static func withPlan<T>(
    request: UpdateRequest, store: StateStore, admitted: Set<NativeTargetRoute>,
    installations: [String: SkillInstallationTarget],
    checkpoint: @escaping (String) throws -> Void, provider: any RuntimeBindingProvider,
    _ body: (UpdatePlan) throws -> T
  ) throws -> T {
    var request = request
    let importInputs = try request.importPreparation?.capture() ?? []
    let baseline = try StatePrecondition(store: store)
    let previous = try store.readLedger(prepared: baseline)
    try resolveSelection(&request, ledger: previous, store: store, baseline: baseline)
    let restoringRequest: Bool
    if case .restore = request.operation {
      restoringRequest = true
    } else {
      restoringRequest = false
    }
    _ = try store.declarationBytes(prepared: baseline)
    let declaration =
      try restoringRequest ? Declaration() : store.readDeclaration(prepared: baseline)
    let watch = try store.readWatch(prepared: baseline)
    let original = try restoringRequest ? nil : store.declarationDocument(prepared: baseline)
    if let expected = request.expectedDeclarationDigest, expected != (original?.digest ?? "absent")
    {
      throw CoreError.invalidState("declaration changed during discovery; retry the command")
    }
    var candidate = declaration
    var change: DeclarationChange?
    let restoring: Bool
    switch request.operation {
    case .restore: restoring = true
    case .update: restoring = false
    case .edit(let edits):
      restoring = false
      guard let original else { throw CoreError.notFound("declaration document") }
      let edited = try original.preparing(edits)
      change = edited.bytes == original.bytes ? nil : DeclarationChange(bytes: Data(edited.bytes))
      candidate = try ManifestProjection.declaration(
        of: DeclarationDocument(
          bytes: edited.bytes, identity: DocumentIdentity(store.declarationURL.path)),
        environment: store.environment)
    case .declaration(let replacement):
      restoring = false
      candidate = replacement
      change = try store.planDeclaration(candidate, replacing: declaration, prepared: baseline)
    case .remove:
      restoring = false
      try LedgerImpact.requireEditable(
        previous, kinds: request.kinds ?? Set(DeclaredComponentKind.allCases),
        names: Set(request.names), roots: store.ledgerRoots,
        selectedIdentities: request.selectedIdentities)
      candidate = try removing(request, from: declaration, ledger: previous, store: store)
      change = try store.planDeclaration(candidate, replacing: declaration, prepared: baseline)
    }
    let retargetedInstructions: Set<String>
    if case .remove = request.operation, request.agents != nil,
      request.kinds?.contains(.instructions) ?? true
    {
      retargetedInstructions = try Set(
        previous.occurrences.filter { $0.consumerEditable }.compactMap {
          guard let component = previous.components[$0.component], component.kind == "instructions",
            component.group == nil
          else { return nil }
          return try LedgerImpact.identity(component, ledger: previous, roots: store.ledgerRoots)
        })
    } else {
      retargetedInstructions = []
    }
    if restoring {
      let routes = try DeploymentConstruction.routes(previous)
      let required = try SkillLifecycle.installationTargets(previous, store: store)
      guard routes.isSubset(of: admitted), Set(required.keys).isSubset(of: Set(installations.keys))
      else { throw RequiredRoutes(routes: routes, installations: required) }
      return try LedgerReplay.withLockedResources(
        previous, store: store, roots: store.ledgerRoots, limits: .standard
      ) { artifacts, resources, workspace in
        try body(
          UpdatePlan(
            request: request, store: store, baseline: baseline, previous: previous, next: previous,
            watch: watch, change: nil, artifacts: artifacts, resources: resources,
            workspace: workspace,
            decisionInputs: [], originalInputs: [],
            checkpoint: checkpoint, provider: provider, installations: Array(installations.values),
            retargetedInstructions: retargetedInstructions))
      }
    }
    var document: DeclarationDocument
    if let change {
      document = try DeclarationDocument(
        bytes: Array(change.bytes), identity: DocumentIdentity(store.declarationURL.path))
    } else if let original {
      document = original
    } else {
      document = try DeclarationDocument(
        bytes: Array("version: 1\n".utf8), identity: DocumentIdentity(store.declarationURL.path))
    }
    let updating: Bool
    if case .update = request.operation {
      updating = true
    } else {
      updating = request.expectedDiscoveryFingerprint != nil
    }
    let removing: Bool
    if case .remove = request.operation { removing = true } else { removing = false }
    if removing || (updating && !request.names.isEmpty), request.kinds?.contains(.skills) ?? true {
      var linkingDeclaration = candidate
      for index in linkingDeclaration.components.indices {
        guard case .skills(let alias, var selection) = linkingDeclaration.components[index],
          case .all = selection.select, let source = linkingDeclaration.sources[alias]
        else { continue }
        let identity = try source.identity(environment: store.environment)
        let existing = try previous.components.values.filter { component in
          guard component.kind == "skills", component.group == nil else { return false }
          return try previous.sourceIdentity(component.source, roots: store.ledgerRoots) == identity
        }.map { PathSafety.sanitizeName($0.name) }.sorted()
        let selected = request.names.filter { name in
          !previous.components.values.contains { $0.kind == "skills" && $0.name == name }
            || existing.contains(name)
        }
        selection.select = .names(
          removing
            ? existing.filter { !(selection.exclude ?? []).contains($0) }
            : Array(Set(existing + selected)).sorted())
        linkingDeclaration.components[index] = .skills(source: alias, selection)
      }
      if removing {
        linkingDeclaration.components.removeAll {
          if case .skills(_, let selection) = $0, case .names(let names) = selection.select {
            return names.isEmpty
          }
          return false
        }
      }
      if let bytes = try store.planDeclaration(
        linkingDeclaration, replacing: declaration, prepared: baseline)?.bytes
      {
        document = try DeclarationDocument(
          bytes: Array(bytes), identity: DocumentIdentity(store.declarationURL.path))
      }
    }
    let impact = try LedgerImpact(
      ledger: previous, roots: store.ledgerRoots,
      kinds: request.kinds ?? Set(DeclaredComponentKind.allCases), names: Set(request.names),
      updating: updating, selectedIdentities: request.selectedIdentities)
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    return try ComponentLinker.withLinkedComponents(
      document: document, store: store, platform: platform,
      preserving: impact.pins, directPins: impact.directPins, retaining: previous
    ) { linked, session in
      if let expected = request.automaticSkill {
        guard
          linked.components.contains(where: { component in
            if case .skill(let skill, _, _) = component.payload {
              return skill.name == expected.name && component.snapshot.source == expected.source
            }
            return false
          })
        else {
          throw CoreError.invalidState(
            "automatic skill selection changed during discovery; retry the command")
        }
      }
      let locations = try sourceLocations(linked, declaration: candidate, store: store)
      for component in linked.components {
        if case .skill(let skill, .copy, _) = component.payload {
          try DeploymentConstruction.validateCopiedSkill(
            session.resource(snapshot: component.snapshot, path: skill.path))
        }
      }
      let frozen = try LedgerFreeze.freezeWithSources(
        linked, session: session, locations: .init(sources: locations), limits: .standard)
      if let expected = request.expectedDiscoveryFingerprint,
        expected != (try LedgerImpact.discoveryFingerprint(frozen.ledger, roots: store.ledgerRoots))
      {
        throw CoreError.invalidState("discovered source content changed; refresh discovery")
      }
      let native = try DeploymentConstruction.lowerNative(
        linked: linked, frozen: frozen, scope: store.scope, platform: platform)
      let routes = try DeploymentConstruction.routes(native).union(
        DeploymentConstruction.routes(previous))
      guard routes.isSubset(of: admitted) else { throw RequiredRoutes(routes: routes) }
      if request.kinds != nil || !request.names.isEmpty || request.selectedIdentities != nil {
        let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
        try LedgerImpact.requireProtected(
          previous: previous, next: native, kinds: kinds, names: Set(request.names),
          roots: store.ledgerRoots, selectedIdentities: request.selectedIdentities,
          retargetedInstructions: retargetedInstructions)
      }
      let complete = try DeploymentConstruction.complete(
        native, linked: linked, store: store, previous: previous, platform: platform)
      let required = try SkillLifecycle.installationTargets(previous, store: store).merging(
        SkillLifecycle.installationTargets(complete.ledger, store: store),
        uniquingKeysWith: { _, next in next })
      guard Set(required.keys).isSubset(of: Set(installations.keys)) else {
        throw RequiredRoutes(routes: routes, installations: required)
      }
      let originals = try linked.components.flatMap { c -> [TargetPrecondition] in
        if case .skill(_, .edit, _) = c.payload { return [] }
        return try c.resources.filter { $0.snapshot.revision == "live" }.map {
          try TargetPrecondition(session.resource(snapshot: $0.snapshot, path: $0.path))
        }
      }
      try checkpoint("plan.skills")
      return try LedgerReplay.withPreparedLowerings(
        complete.ledger, store: store, roots: store.ledgerRoots, limits: .standard
      ) { next, artifacts, resources, workspace in
        try body(
          UpdatePlan(
            request: request, store: store, baseline: baseline, previous: previous, next: next,
            watch: watch, change: change, artifacts: artifacts, resources: resources,
            workspace: workspace,
            decisionInputs: complete.inputs, originalInputs: originals + importInputs,
            checkpoint: checkpoint, provider: provider, installations: Array(installations.values),
            retargetedInstructions: retargetedInstructions))
      }
    }
  }

  private init(
    request: UpdateRequest, store: StateStore, baseline: StatePrecondition,
    previous: ResolvedLedger, next: ResolvedLedger, watch: WatchState,
    change: DeclarationChange?, artifacts: [ReplayedArtifact], resources: [String: URL],
    workspace: URL,
    decisionInputs: [TargetPrecondition], originalInputs: [TargetPrecondition],
    checkpoint: @escaping (String) throws -> Void, provider: any RuntimeBindingProvider,
    installations: [SkillInstallationTarget], retargetedInstructions: Set<String>
  ) throws {
    self.store = store
    self.baseline = baseline
    self.watch = watch
    declarationChange = change
    self.checkpoint = checkpoint
    self.provider = provider
    inputs = try UpdateInputs(
      ledger: next, resources: resources, decisions: decisionInputs, originals: originalInputs)
    aggregation = try ArtifactAggregation(
      ledger: next, previous: previous, artifacts: artifacts,
      resources: resources, workspace: workspace, store: store, replace: request.replace,
      changingAccess: request.changingAccess, kinds: request.kinds,
      names: Set(request.names), selectedIdentities: request.selectedIdentities,
      installations: installations, retargetedInstructions: retargetedInstructions)
    if let imported = request.importPreparation {
      for resource in imported.proposal.resources
      where resource.selected && resource.requiresStandaloneSource {
        guard
          let source = imported.proposal.sources.first(where: { $0.alias == resource.sourceAlias })?
            .declaration,
          source.kind == .local
        else { continue }
        let sourceEnvironment = source.environment?.runtime ?? store.environment
        let identity = try source.identity(environment: sourceEnvironment)
        let root = URL(fileURLWithPath: String(identity.dropFirst(6)))
        if aggregation.changes.contains(where: {
          PathSafety.isContained(root, in: $0.url) || PathSafety.isContained($0.url, in: root)
        }) {
          throw CoreError.invalidState(
            "import requires an independent authoring source before replacing its installed content"
          )
        }
      }
    }
    self.next = aggregation.ledger
    try self.next.validate()
    let lockMissing = try baseline.bytes(for: store.resolvedURL) == nil
    let before = try previous.domainProjection(roots: store.ledgerRoots)
    let after = try self.next.domainProjection(roots: store.ledgerRoots)
    let allResults = try UpdateReporting.skills(
      previous: previous, next: self.next, resources: resources,
      changes: aggregation.changes, store: store, lockMissing: lockMissing,
      included: request.kinds == nil || request.kinds!.contains(.skills),
      selectedIdentities: request.selectedIdentities, names: Set(request.names))
    let results =
      request.names.isEmpty ? allResults : allResults.filter { request.names.contains($0.skill) }
    receipts = results.flatMap(\.installed)
    let publicResults = results.map {
      var result = $0
      result.installed = []
      return result
    }
    func instructionArtifacts(_ ledger: ResolvedLedger) -> [String: String] {
      var result: [String: String] = [:]
      for lowering in ledger.lowerings
      where ["agents/instructions@1", "agents/claude-import@1", "agents/chatgpt@1"].contains(
        lowering.format)
      {
        for artifact in lowering.artifacts {
          result[lowering.format + ":" + artifact.name] = artifact.hash
        }
      }
      return result
    }
    let instructions = try UpdateReporting.instructions(
      before: before.instructions, after: after.instructions,
      changes: aggregation.changes, lockMissing: lockMissing,
      included: request.kinds == nil || request.kinds!.contains(.instructions), store: store,
      stateChanged: instructionArtifacts(previous) != instructionArtifacts(self.next)
        || (change != nil && request.kinds == [.instructions]))
    let operation: String
    switch request.operation {
    case .update: operation = "update"
    case .restore: operation = "restore"
    case .remove: operation = "remove"
    case .edit, .declaration: operation = "edit"
    }
    struct Fingerprint: Encodable {
      let version = 1
      let operation: String
      let scope: InstallScope
      let kinds: [String]?
      let names: [String]
      let selectedIdentities: [String]?
      let replace: Bool
      let changingAccess: Bool
      let candidate: ResolvedLedger
      let baseline: ResolvedLedger
      let declaration: String?
      let targets: [String]
    }
    var semanticCandidate = self.next
    semanticCandidate.nativeAuthorities = nil
    var semanticBaseline = previous
    semanticBaseline.nativeAuthorities = nil
    let fingerprint = try ResolvedLedgerCodec.digest(
      Fingerprint(
        operation: operation, scope: store.scope, kinds: request.kinds?.map(\.rawValue).sorted(),
        names: request.names.sorted(), selectedIdentities: request.selectedIdentities?.sorted(),
        replace: request.replace,
        changingAccess: request.changingAccess,
        candidate: semanticCandidate, baseline: semanticBaseline,
        declaration: try (change?.bytes ?? baseline.bytes(for: store.declarationURL)).map {
          "sha256:" + FileHash.sha256Hex(data: $0)
        },
        targets: (aggregation.fingerprints
          + (try decisionInputs.map { try $0.displayEvidence(includeContent: false) })).sorted()))
    var readDeclarations: [Declaration] = []
    if case .restore = request.operation {
    } else {
      readDeclarations.append(try store.readDeclaration(prepared: baseline))
    }
    if let change {
      readDeclarations.append(
        try ManifestProjection.declaration(
          of: DeclarationDocument(
            bytes: Array(change.bytes), identity: DocumentIdentity(store.declarationURL.path)),
          environment: store.environment))
    }
    let readPaths =
      try UpdateOperations.readLocations(
        declarations: readDeclarations, ledgers: [previous, self.next], store: store)
      + decisionInputs.map(\.url) + installations.map(\.url)
    let finalNext = self.next
    report = CombinedUpdateReport(
      scope: store.scope, skills: publicResults, instructions: instructions,
      lockMissing: lockMissing,
      hasChanges: self.next != previous || change != nil
        || aggregation.changes.contains(where: \.changed),
      displayedFingerprint: fingerprint,
      readLocations: Set(readPaths.map(\.path)).sorted().map {
        URL(fileURLWithPath: $0, isDirectory: false)
      },
      components: try aggregation.changes.filter { change in
        guard change.native else { return false }
        guard let identities = request.selectedIdentities else { return true }
        return try change.deployment.owners.contains { owner in
          let ledger = finalNext.components[owner] == nil ? previous : finalNext
          return try identities.contains(
            LedgerImpact.identity(
              ledger.components[owner]!, ledger: ledger, roots: store.ledgerRoots))
        }
      }.map { change in
        let owner = change.deployment.owners[0]
        let ledger = finalNext.components[owner] == nil ? previous : finalNext
        let component = ledger.components[owner]!
        return ComponentUpdateChange(
          sourceIdentity: try ledger.sourceIdentity(component.source, roots: store.ledgerRoots),
          revision: component.revision, version: component.version,
          format: change.deployment.route, ownership: change.deployment.ownership.rawValue,
          resources: component.resources.compactMap { ledger.resources[$0] }.map { resource in
            ComponentResourceInfo(
              path: resource.path, hash: resource.hash,
              executableFiles: Dictionary(
                uniqueKeysWithValues: resource.entries.filter { $0.kind == .file }.map {
                  ($0.path, $0.executable)
                }))
          }, requiredBindings: change.requiredBindings, effectiveReaders: change.effectiveReaders,
          privateMaterialization: change.privateMaterialization,
          permissionChange: change.accessChange.map { access in
            ComponentPermissionChange(
              beforeOwner: access.before.owner, beforeGroup: access.before.group,
              beforeMode: UInt32(access.before.mode), afterOwner: access.owner,
              afterMode: access.mode, ownerOnly: true,
              members: change.memberAccessChanges.map {
                ComponentMemberPermissionChange(
                  path: $0.path, beforeOwner: $0.before.owner, beforeGroup: $0.before.group,
                  beforeMode: UInt32($0.before.mode), afterOwner: $0.owner, afterMode: $0.mode)
              })
          },
          symbolicBefore: try change.symbolicBefore.map {
            try UpdateOperations.symbolicConfigurationText($0)
          },
          symbolicAfter: try change.symbolicAfter.map {
            try UpdateOperations.symbolicConfigurationText($0)
          },
          kind: component.kind, name: component.name, path: change.url.path,
          agents: change.deployment.recipients, changed: change.changed)
      })
    try baseline.validate()
  }

  func apply(outcome: TransactionOutcome) throws -> UpdateApplyResult {
    try baseline.validate()
    try aggregation.validate()
    try aggregation.requireOwnership()
    try inputs.validate()
    if report.hasChanges {
      var references = try RetentionReferences(ledger: next, roots: store.ledgerRoots)
      try references.include(watch: watch)
      let cache = SourceCache(store: store, checkpoint: checkpoint)
      try cache.retain(references: references)
      try checkpoint("apply.retained")
      try baseline.validate()
      try aggregation.validate()
      try inputs.validate()
      let transaction = FileTransaction(store: store, outcome: outcome, checkpoint: checkpoint)
      transaction.requireUnchanged(since: baseline, aggregation, inputs)
      try aggregation.stage(transaction: transaction, provider: provider)
      try store.stageDeclaration(declarationChange, in: transaction, prepared: baseline)
      // Empty scopes need no lock file; a declaration edit always accompanies first deployment.
      if try store.declarationBytes(prepared: baseline) != nil || declarationChange != nil {
        try store.stageLedger(
          producing: { self.aggregation.ledger }, limits: .standard, transaction: transaction,
          prepared: baseline)
      }
      try cache.prune(references: references, transaction: transaction)
      try transaction.commit()
    }
    return UpdateApplyResult(report: report, installedSkills: receipts)
  }

  func recover(outcome: TransactionOutcome) {
    do { _ = try FileTransaction.recover(store: store, outcome: outcome) } catch {
      outcome.disposition = .recoveryRequired
    }
  }

  static func sourceLocations(
    _ linked: LinkedComponents, declaration: Declaration, store: StateStore
  ) throws -> [String: LedgerLocation] {
    var locations: [String: LedgerLocation] = [:]
    let packageRoot =
      store.scope == .project ? store.environment.projectDirectory : store.directory
    for evidence in linked.sourceSnapshots + linked.declaringSnapshots
    where evidence.container == nil && evidence.snapshot.source.hasPrefix("local:") {
      let path = String(evidence.snapshot.source.dropFirst(6))
      if path == packageRoot.path {
        locations[evidence.snapshot.source] = .init(
          kind: .registered, root: store.scope == .project ? "project" : "state", path: ".")
      } else if let authored = try declaration.sources.values.first(where: {
        try $0.identity(environment: store.environment) == evidence.snapshot.source
      }),
        !authored.location.hasPrefix("/")
      {
        if authored.location == "~" || authored.location.hasPrefix("~/") {
          locations[evidence.snapshot.source] = .init(
            kind: .authoringRelative, root: "home",
            path: authored.location == "~" ? "." : String(authored.location.dropFirst(2)))
        } else if authored.environment?.projectDirectory.path
          == store.environment.projectDirectory.path || authored.environment == nil
        {
          locations[evidence.snapshot.source] = .init(
            kind: .authoringRelative, root: "project", path: authored.location)
        } else {
          locations[evidence.snapshot.source] = .init(kind: .absolute, path: path)
        }
      } else {
        locations[evidence.snapshot.source] = .init(kind: .absolute, path: path)
      }
    }
    return locations
  }

  private static func resolveSelection(
    _ request: inout UpdateRequest, ledger: ResolvedLedger, store: StateStore,
    baseline: StatePrecondition
  ) throws {
    let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
    func name(_ c: LedgerComponent) -> String {
      c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name
    }
    if request.selections.isEmpty {
      for requested in request.names {
        let matches = try ledger.components.values.filter {
          kinds.contains(DeclaredComponentKind(rawValue: $0.kind)!) && name($0) == requested
        }.map { try LedgerImpact.identity($0, ledger: ledger, roots: store.ledgerRoots) }
        guard Set(matches).count <= 1 else {
          throw CoreError.invalidState(
            "component name is ambiguous; select a component from inspection: " + requested)
        }
      }
      return
    }
    guard request.names.isEmpty else {
      throw CoreError.invalidState("use names or precise selections, not both")
    }
    switch request.operation {
    case .update, .remove: break
    default: throw CoreError.invalidState("precise selection applies to update or removal")
    }
    let documentDigest =
      try baseline.bytes(for: store.declarationURL).map { "sha256:" + FileHash.sha256Hex(data: $0) }
      ?? "absent"
    let generation = try ResolvedLedgerCodec.digest([
      ResolvedLedgerCodec.digest(ledger), documentDigest,
    ])
    var selected = Set<String>()
    var names = Set<String>()
    var selectedKinds = Set<DeclaredComponentKind>()
    for selection in request.selections {
      guard selection.generation == generation else {
        throw CoreError.invalidState("inspection changed; refresh component selection")
      }
      let entries = try ledger.components.filter {
        try LedgerImpact.identity($0.value, ledger: ledger, roots: store.ledgerRoots)
          == selection.identity
      }
      guard let entry = entries.first,
        kinds.contains(DeclaredComponentKind(rawValue: entry.value.kind)!)
      else {
        throw CoreError.notFound("selected component")
      }
      if let occurrence = selection.occurrence {
        let occurrences = ledger.occurrences.filter { entries[$0.component] != nil }
        guard occurrences.contains(where: { $0.id == occurrence }) else {
          throw CoreError.notFound("selected occurrence")
        }
        guard occurrences.count == 1 else {
          throw CoreError.invalidState(
            "this component has multiple contributions; select the complete component or edit its declaration reference"
          )
        }
      }
      selected.insert(selection.identity)
      names.insert(name(entry.value))
      selectedKinds.insert(DeclaredComponentKind(rawValue: entry.value.kind)!)
    }
    request.selectedIdentities = selected
    request.names = names.sorted()
    request.kinds = selectedKinds
  }

  private static func removing(
    _ request: UpdateRequest, from declaration: Declaration, ledger: ResolvedLedger,
    store: StateStore
  ) throws -> Declaration {
    var result = declaration
    let names = Set(request.names)
    let kinds = request.kinds ?? Set(DeclaredComponentKind.allCases)
    let references = Set(
      declaration.components.flatMap { component -> [String] in
        if case .instructions(let value) = component {
          return value.sectionReferences.map(\.reference)
            + value.prompts.flatMap { $0.prompt.sectionReferences.map(\.reference) }
        }
        return []
      })
    var instructionReferences = Set<String>()
    if kinds.contains(.instructions), let identities = request.selectedIdentities {
      let sections = declaration.components.flatMap { component -> [SectionDeclaration] in
        guard case .instructions(let selection) = component else { return [] }
        return selection.sectionReferences
          + selection.prompts.flatMap { $0.prompt.sectionReferences }
      }
      for section in sections {
        let source: String
        if let alias = section.source, alias != "." {
          guard let declaration = declaration.sources[alias] else { continue }
          source = try declaration.identity(environment: store.environment)
        } else {
          source = "local:" + store.environment.projectDirectory.resolvingSymlinksInPath().path
        }
        if try ledger.components.values.contains(where: { c in
          try c.kind == "instructions" && c.name == section.name
            && ledger.sourceIdentity(c.source, roots: store.ledgerRoots) == source
            && identities.contains(
              LedgerImpact.identity(c, ledger: ledger, roots: store.ledgerRoots))
        }) {
          instructionReferences.insert(section.reference)
        }
      }
    } else if kinds.contains(.instructions) {
      for name in names {
        let exact = references.filter { $0 == name }
        let matches =
          exact.isEmpty
          ? references.filter { $0.split(separator: ":").last.map(String.init) == name } : exact
        guard matches.count == 1, let reference = matches.first else {
          throw CoreError.notFound("instruction name is missing or ambiguous: " + name)
        }
        instructionReferences.insert(reference)
      }
    }
    result.components = declaration.components.compactMap { component in
      switch component {
      case .skills(let alias, var selection) where kinds.contains(.skills):
        if let identities = request.selectedIdentities {
          let source = try? declaration.sources[alias]?.identity(environment: store.environment)
          let matches = ledger.components.values.contains { c in
            c.kind == "skills"
              && (try? ledger.sourceIdentity(c.source, roots: store.ledgerRoots)) == source
              && (try? LedgerImpact.identity(c, ledger: ledger, roots: store.ledgerRoots)).map(
                identities.contains) == true
          }
          if !matches { return component }
        }
        if case .all = selection.select {
          selection.exclude = Array(Set(selection.exclude ?? []).union(names)).sorted()
        } else if case .names(let selected) = selection.select {
          selection.select = .names(selected.filter { !names.contains($0) })
        }
        if request.agents == nil {
          selection.overrides = selection.overrides?.filter { !names.contains($0.key) }
        }
        if let agents = request.agents {
          selection = {
            var original = selection
            for name in names {
              let current = ledger.components.values.first {
                $0.kind == "skills" && PathSafety.sanitizeName($0.name) == name
                  && (try? ledger.sourceIdentity($0.source, roots: store.ledgerRoots))
                    == (try? declaration.sources[alias]?.identity(environment: store.environment))
              }
              var overrides = original.overrides ?? [:]
              overrides[name] = SkillOverride(
                agents: current?.recipients.filter { !agents.contains($0) } ?? [],
                mode: original.overrides?[name]?.mode)
              original.overrides = overrides
            }
            return original
          }()
          if let prior = declaration.components.first(where: {
            if case .skills(let a, _) = $0 { a == alias } else { false }
          }), case .skills(_, let original) = prior {
            selection.select = original.select
            selection.exclude = original.exclude
          }
        }
        return .skills(source: alias, selection)
      case .instructions(var selection) where kinds.contains(.instructions):
        selection.sectionReferences.removeAll {
          instructionReferences.contains($0.reference)
        }
        for index in selection.prompts.indices {
          selection.prompts[index].prompt.sectionReferences.removeAll {
            instructionReferences.contains($0.reference)
          }
        }
        selection.prompts.removeAll { $0.prompt.sectionReferences.isEmpty }
        if let agents = request.agents { selection.agents = agents }
        return .instructions(selection)
      default:
        guard kinds.contains(component.kind), names.contains(component.name ?? "") else {
          return component
        }
        if let agents = request.agents {
          let recipients = (component.selectedAgents ?? declaration.defaultAgents).filter {
            !agents.contains($0)
          }
          return component.replacingAgents(recipients)
        }
        return nil
      }
    }
    return result
  }
}

extension ComponentDeclaration {
  fileprivate var selectedAgents: [AgentID]? {
    switch self {
    case .skills(_, let s): s.agents
    case .instructions(let s): s.agents
    case .mcpServer(_, _, let a, _, _), .hook(_, _, _, _, _, let a, _, _),
      .subagent(_, _, _, _, _, let a, _, _), .command(_, _, _, _, let a, _, _),
      .lspServer(_, _, _, _, let a, _, _), .permissions(_, _, let a, _, _),
      .ignore(_, _, _, let a, _, _), .plugin(_, _, _, _, _, _, let a, _, _):
      a
    }
  }

  fileprivate func replacingAgents(_ agents: [AgentID]) -> ComponentDeclaration {
    switch self {
    case .skills(let source, var value):
      value.agents = agents
      return .skills(source: source, value)
    case .instructions(var value):
      value.agents = agents
      return .instructions(value)
    case .mcpServer(let n, let t, _, let c, let v):
      return .mcpServer(name: n, transport: t, agents: agents, condition: c, native: v)
    case .hook(let n, let e, let r, let m, let t, _, let c, let v):
      return .hook(
        name: n, event: e, run: r, matcher: m, timeoutSeconds: t, agents: agents, condition: c,
        native: v)
    case .subagent(let n, let d, let p, let m, let t, _, let c, let v):
      return .subagent(
        name: n, description: d, prompt: p, model: m, tools: t, agents: agents, condition: c,
        native: v)
    case .command(let n, let d, let p, let args, _, let c, let v):
      return .command(
        name: n, description: d, prompt: p, parameters: args, agents: agents, condition: c,
        native: v)
    case .lspServer(let n, let r, let l, let o, _, let c, let v):
      return .lspServer(
        name: n, run: r, languages: l, initializationOptions: o, agents: agents, condition: c,
        native: v)
    case .permissions(let n, let r, _, let c, let v):
      return .permissions(name: n, rules: r, agents: agents, condition: c, native: v)
    case .ignore(let n, let p, let u, _, let c, let v):
      return .ignore(name: n, patterns: p, purpose: u, agents: agents, condition: c, native: v)
    case .plugin(let n, let p, let s, let m, let select, let exclude, _, let c, let v):
      return .plugin(
        name: n, path: p, source: s, mode: m, select: select, exclude: exclude, agents: agents,
        condition: c, native: v)
    }
  }
}
