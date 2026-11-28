import AgentsCore
import AgentsManifest
import Foundation

/// Links symbolic declarations to exact, ordered contributions. The caller owns the read lock
/// and consumes borrowed resources inside `withLinkedComponents`; no state is published here.
package enum ComponentLinker {
  package static func withLinkedComponents<T>(
    document: DeclarationDocument, store: StateStore, platform: DeclarationPlatform,
    preserving pins: [String: SourceRevision] = [:],
    directPins: [ComponentKey: SourceRevision] = [:],
    retaining ledger: ResolvedLedger? = nil, sourcePolicy: EffectiveSourcePolicy = .init(),
    organization: OrganizationPolicyEvaluator = .init(chains: []),
    admitOrganization: @escaping @Sendable ([OrganizationPolicyFinding]) throws -> Void = { _ in },
    stagedLocalSources: [String: URL] = [:], acquisitions: GitAcquisitionCaptures? = nil,
    instructionsOnly: Bool = false,
    _ body: (LinkedComponents, SourceResolutionSession) throws -> T
  ) throws -> T {
    if let ledger {
      try ResolvedLedgerCodec.checkModel(ledger, limits: .standard)
      try ledger.validate()
    }
    return try SourceResolutionSession.withTemporaryRead(
      store: store, sourcePolicy: sourcePolicy,
      requireRecordedTransport: organization.requiresRecordedGitOrigin,
      stagedLocalSources: stagedLocalSources, acquisitions: acquisitions
    ) { session in
      let linker = Linking(
        document: document, store: store, platform: platform,
        session: session, directPins: directPins, retainedLedger: ledger,
        organization: organization, admitOrganization: admitOrganization,
        instructionsOnly: instructionsOnly)
      let graph = try linker.solve(preserving: pins)
      return try body(graph, session)
    }
  }
}

struct LinkingDocument {
  let declaration: Declaration
  let document: DeclarationDocument
  let view: SourceSnapshot
  let manifestPath: String
  let producer: Bool
  var importedSources: [String: SourceSnapshot] = [:]

}

struct SourceAddress {
  let id: String
  let source: SourceDeclaration?
  let contained: SourceSnapshot?
  let root: String
}

struct GroupIdentity: Hashable {
  let snapshot: SourceSnapshotID
  let root: String
  let name: String
}

struct RequirementSearch: Error {
  let constraints: [SourceConstraint]
}

final class Linking {
  let document: DeclarationDocument
  let store: StateStore
  let platform: DeclarationPlatform
  let instructionsOnly: Bool
  let session: SourceResolutionSession
  let directPins: [ComponentKey: SourceRevision]
  let retainedLedger: ResolvedLedger?
  let budget: LinkBudget
  let organization: OrganizationPolicyEvaluator
  let admitOrganization: @Sendable ([OrganizationPolicyFinding]) throws -> Void
  var documents: [GroupIdentity: LinkingDocument] = [:]
  var nonGit = Set<String>()
  var git = Set<String>()
  var addresses: [String: SourceAddress] = [:]
  var sourceUses: [LinkedSourceUse] = []
  private var componentMaps: [GroupIdentity: [String: [SourceMapEntry]]] = [:]
  private var positions: [GroupIdentity: [String: SourceMapEntry]] = [:]

  init(
    document: DeclarationDocument, store: StateStore, platform: DeclarationPlatform,
    session: SourceResolutionSession, directPins: [ComponentKey: SourceRevision],
    retainedLedger: ResolvedLedger?, organization: OrganizationPolicyEvaluator = .init(chains: []),
    admitOrganization: @escaping @Sendable ([OrganizationPolicyFinding]) throws -> Void = { _ in },
    instructionsOnly: Bool = false,
    budget: LinkBudget = LinkBudget()
  ) {
    self.document = document
    self.store = store
    self.platform = platform
    self.instructionsOnly = instructionsOnly
    self.session = session
    self.directPins = directPins
    self.retainedLedger = retainedLedger
    self.organization = organization
    self.admitOrganization = admitOrganization
    self.budget = budget
  }

  /// An implicit selection admits only members owned by its recorded index. The component key
  /// identifies the declaring context; resource lookup still verifies the applicable exact pin.
  func artifactBelongsToIndex(key: ComponentKey, source: String) throws -> Bool {
    guard let pin = directPins[key], pin.revision.hasPrefix("sha256:") else { return false }
    guard let ledger = retainedLedger else {
      throw CoreError.invalidState("missing pinned artifact closure")
    }
    var recorded = false
    for component in ledger.components.sorted(by: { $0.key < $1.key }).map(\.value) {
      try budget.step()
      guard component.kind == key.kind.rawValue, component.root == key.root,
        component.group == key.group, PathSafety.sanitizeName(component.name) == key.name,
        try retainedSourceIdentity(component.declaringSource, ledger: ledger) == key.source
      else { continue }
      recorded = true
      if try retainedSourceIdentity(component.source, ledger: ledger) == source { return true }
    }
    guard recorded else { throw CoreError.invalidState("missing pinned artifact component") }
    return false
  }

  private func retainedSourceIdentity(_ id: String, ledger: ResolvedLedger) throws -> String {
    try budget.step()
    guard let source = ledger.sources[id] else {
      throw CoreError.invalidState("missing retained source")
    }
    if let container = source.container {
      return try retainedSourceIdentity(container, ledger: ledger) + (source.namespace ?? "")
    }
    let location: String
    if let authored = source.location {
      location = try authored.resolve(roots: [
        "project": store.environment.projectDirectory, "home": store.environment.homeDirectory,
        "state": store.directory,
      ]).path
    } else if let transport = source.transport {
      location = transport
    } else {
      throw CoreError.invalidState("missing retained source coordinates")
    }
    return try SourceDeclaration(kind: source.kind, location: location).identity(
      environment: store.environment)
  }

  /// Direct artifact pins use the artifact digest, independently of every other index member.
  /// The caller supplies the admitted ledger closure; absence never means refresh the index.
  func retainedArtifact(key: ComponentKey, source: String) throws -> LedgerResource? {
    guard let pin = directPins[key], pin.revision.hasPrefix("sha256:") else { return nil }
    guard let ledger = retainedLedger else {
      throw CoreError.invalidState("missing pinned artifact closure")
    }
    for resource in ledger.resources.sorted(by: { $0.key < $1.key }).map(\.value) {
      try budget.step()
      guard resource.kind == .artifact, resource.artifact?.digest == pin.revision,
        let origin = ledger.sources[resource.source], origin.kind == .wellKnown,
        origin.revision == pin.revision, let transport = origin.transport,
        try SourceDeclaration(kind: .wellKnown, location: transport).transportIdentity() == source
      else { continue }
      return resource
    }
    throw CoreError.invalidState("missing pinned artifact resource for source")
  }

  func solve(preserving pins: [String: SourceRevision]) throws -> LinkedComponents {
    try budget.step(document.metrics.evaluationSteps)
    // Recorded commits preserve local Git provenance independently of current working-tree metadata.
    if let ledger = retainedLedger {
      for id in ledger.sources.keys.sorted() {
        try budget.step()
        let source = ledger.sources[id]!
        if source.kind == .local, SourceCache.isObjectID(source.revision) {
          git.insert(try retainedSourceIdentity(id, ledger: ledger))
        }
      }
    }
    let declaration = try ManifestProjection.declaration(
      of: document, environment: store.environment)
    let packageRoot =
      store.scope == .user ? store.directory : store.environment.projectDirectory
    let root = try SourceSnapshot(
      snapshot: SourceSnapshotID(
        source: "local:" + packageRoot.path,
        revision: "live"), pin: nil,
      root: packageRoot,
      localEnvironment: SourceEnvironment(
        projectDirectory: packageRoot, homeDirectory: store.environment.homeDirectory),
      liveRoot: packageRoot)
    session.register(root)
    let context = LinkingDocument(
      declaration: declaration, document: document, view: root,
      manifestPath: store.scope == .user ? "agents.yaml" : ".agent/agents.yaml",
      producer: false)
    try budget.manifest(root.snapshot, path: context.manifestPath, bytes: document.bytes.count)
    guard let result = try search(root: context, choices: pins) else {
      throw LinkError.incompatible(lastFailure)
    }
    return result
  }

  var lastFailure: [SourceConstraint] = []

  func componentLocations(at pointer: String, in context: LinkingDocument) throws
    -> [SourceMapEntry]
  {
    let key = GroupIdentity(
      snapshot: context.view.snapshot, root: context.view.discoveryPath, name: "")
    if componentMaps[key] == nil {
      var locations: [String: [SourceMapEntry]] = [:]
      var firstPositions: [String: SourceMapEntry] = [:]
      for entry in context.document.sourceMap.entries {
        try budget.step()
        if firstPositions[entry.pointer] == nil { firstPositions[entry.pointer] = entry }
        let path = entry.pointer.split(separator: "/")
        let prefix: Int
        if path.first == "components", path.count >= 2 {
          prefix = 2
        } else if path.first == "groups", path.count >= 4, path[2] == "components" {
          prefix = 4
        } else {
          continue
        }
        locations["/" + path.prefix(prefix).joined(separator: "/"), default: []].append(entry)
      }
      componentMaps[key] = locations
      positions[key] = firstPositions
    }
    return componentMaps[key]?[pointer] ?? []
  }

  func position(at pointer: String, in context: LinkingDocument) throws -> SourceMapEntry? {
    _ = try componentLocations(at: pointer, in: context)
    return positions[
      GroupIdentity(snapshot: context.view.snapshot, root: context.view.discoveryPath, name: "")
    ]?[pointer]
  }

  private func search(root: LinkingDocument, choices initial: [String: SourceRevision]) throws
    -> LinkedComponents?
  {
    struct Decision {
      let source: String
      let candidates: [SourceRevision]
      var next: Int
    }
    var choices = initial
    var decisions: [Decision] = []
    func backtrack() throws -> Bool {
      while var decision = decisions.popLast() {
        try budget.step()
        choices.removeValue(forKey: decision.source)
        if decision.next < decision.candidates.count {
          choices[decision.source] = decision.candidates[decision.next]
          decision.next += 1
          decisions.append(decision)
          return true
        }
      }
      return false
    }
    while true {
      try budget.step()
      let pass = Expansion(linking: self, choices: choices, emit: false)
      do { try pass.expandRoot(root) } catch let error as RequirementSearch {
        lastFailure = error.constraints
        if try backtrack() { continue }
        return nil
      }
      if let next = pass.constraints.keys.filter({ choices[$0] == nil }).sorted().first {
        let requirements = pass.constraints[next]!
        let candidates = try candidates(for: addresses[next]!.source!, requirements: requirements)
        try budget.step(candidates.count)
        guard let candidate = candidates.first else {
          lastFailure = requirements
          if try backtrack() { continue }
          return nil
        }
        decisions.append(Decision(source: next, candidates: candidates, next: 1))
        choices[next] = candidate
        continue
      }
      sourceUses.removeAll()
      let final = Expansion(linking: self, choices: choices, emit: true)
      do { try final.expandRoot(root) } catch let error as RequirementSearch {
        lastFailure = error.constraints
        if try backtrack() { continue }
        return nil
      }
      return try final.result()
    }
  }

  func address(_ alias: String?, in context: LinkingDocument, chain: [SourceSpan]) throws
    -> SourceAddress
  {
    try budget.step(chain.count + 1)
    guard let alias, alias != "." else {
      return SourceAddress(
        id: context.view.snapshot.source, source: nil,
        contained: context.view, root: context.view.discoveryPath)
    }
    if let view = context.importedSources[alias] {
      return SourceAddress(
        id: view.snapshot.source, source: nil, contained: view,
        root: view.discoveryPath)
    }
    guard let source = context.declaration.sources[alias] else {
      throw LinkError.missing("source alias '\(alias)'", chain)
    }
    if context.producer, context.view.localEnvironment == nil, source.kind == .local {
      let raw = source.location
      guard !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.contains("\\") else {
        throw LinkError.invalid("producer-local source must stay inside its package", chain)
      }
      let relative = try PathSafety.sanitizeSubpath(raw)
      let directory = try context.view.directory().appendingPathComponent(relative)
        .standardizedFileURL
      let path = try context.view.relativePath(directory)
      let sourceID =
        path == "."
        ? context.view.packageIdentity
        : context.view.packageIdentity + ":contained:" + String(path.utf8.count) + ":" + path
      let discoveryPath = try PathSafety.sanitizeSubpath(path + "/" + (source.path ?? "."))
      let view = try SourceSnapshot(
        snapshot: SourceSnapshotID(source: sourceID, revision: context.view.snapshot.revision),
        pin: context.view.pin, root: context.view.root, discoveryPath: discoveryPath,
        packageIdentity: context.view.packageIdentity)
      guard source.requirement == nil else {
        throw LinkError.invalid("contained sources inherit their producer snapshot", chain)
      }
      try budget.snapshot(view.snapshot)
      session.register(view)
      return SourceAddress(id: sourceID, source: nil, contained: view, root: view.discoveryPath)
    }
    try session.requireSource(source)
    let id = try source.identity(environment: store.environment)
    let root = try PathSafety.sanitizeSubpath(source.path ?? ".")
    var override: [SourceRequirement]?
    if organization.active,
      source.kind != .local
        || BundleSourceLocation.container(
          of: source.localURL(environment: store.environment), in: store) == nil
    {
      let origin = try SourceOrigin.declared(source, in: store.environment)
      let identity = OrganizationPolicyIdentity(origin, root: root)
      try admitOrganization(
        organization.source(origin, root: root, path: [alias])
          + organization.packageIdentity(identity, path: [alias]))
      let required = organization.requirements(for: identity)
      if source.kind != .wellKnown, required.overrides { override = required.constraints }
    }
    let result = SourceAddress(id: id, source: source, contained: nil, root: root)
    addresses[id] = result
    let use = LinkedSourceUse(
      source: id, root: root, requirement: source.requirement, organizationRequirements: override)
    if !sourceUses.contains(use) { sourceUses.append(use) }
    return result
  }

  var requireArtifactOrigin: (@Sendable (SourceOrigin) throws -> Void)? {
    organization.artifactOriginCheck(admitOrganization)
  }

  func candidates(
    for source: SourceDeclaration, requirements: [SourceConstraint]
  ) throws -> [SourceRevision] {
    guard organization.active else {
      return try session.candidates(
        for: source, requirements: requirements.map(\.requirement), spending: budget.step)
    }
    let origin = try SourceOrigin.declared(source, in: store.environment)
    let admissions = requirements.map { constraint in
      let identity = OrganizationPolicyIdentity(origin, root: constraint.root)
      return (constraint, identity, organization.requirements(for: identity))
    }
    let effective = admissions.flatMap { constraint, _, admission -> [SourceRequirement?] in
      (admission.overrides ? [] : [constraint.requirement])
        + admission.constraints.map(Optional.some)
    }
    let candidates = try session.candidates(
      for: source, requirements: effective, spending: budget.step)
    if candidates.isEmpty {
      let findings = admissions.flatMap { constraint, identity, admission in
        admission.constraints.isEmpty
          ? []
          : organization.version(
            nil, identity: identity, authored: [constraint.requirement].compactMap { $0 },
            available: false)
      }
      try admitOrganization(findings)
    }
    return candidates
  }

  func admits(_ pin: SourceRevision, for source: SourceDeclaration) throws -> Bool {
    guard organization.active else { return true }
    let origin = try SourceOrigin.declared(source, in: store.environment)
    let identity = OrganizationPolicyIdentity(origin, root: source.path)
    return organization.requirements(for: identity).constraints.allSatisfy { requirement in
      pin.version.map(requirement.admitsMarketplaceVersion) ?? false
    }
  }

  func view(_ address: SourceAddress, pin: SourceRevision? = nil) throws -> SourceSnapshot? {
    if let contained = address.contained { return contained }
    let source = address.source!
    guard source.kind != .wellKnown else {
      throw LinkError.invalid("skill indexes cannot supply package resources", [])
    }
    if let pin, pin.archive?.admits(source.requirement, version: pin.version) != false,
      try admits(pin, for: source)
    {
      let view = try session.snapshot(source, at: pin)
      try budget.snapshot(view.snapshot)
      return view
    }
    if source.requirement != nil || source.kind == .git {
      git.insert(address.id)
      return nil
    }
    if try nonGit.contains(address.id)
      || (!git.contains(address.id) && !session.isGitSource(source))
    {
      nonGit.insert(address.id)
      let view = try session.localSnapshot(source)
      try budget.snapshot(view.snapshot)
      return view
    }
    git.insert(address.id)
    return nil
  }

  func producer(_ view: SourceSnapshot, chain: [SourceSpan]) throws -> LinkingDocument {
    let key = GroupIdentity(snapshot: view.snapshot, root: view.discoveryPath, name: "")
    if let existing = documents[key] { return existing }
    let root = try view.directory()
    let file = root.appendingPathComponent(
      root.lastPathComponent == ".agent" ? "agents.yaml" : ".agent/agents.yaml")
    let relative = try view.relativePath(file)
    let handle = try FileHandle(forReadingFrom: view.resource(relative))
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: ManifestLimits.Input.bytes + 1) ?? Data()
    guard bytes.count <= ManifestLimits.Input.bytes else {
      throw LinkError.budget("manifest input bytes")
    }
    try budget.manifest(
      view.snapshot, path: relative, bytes: bytes.count)
    let coordinates = try JSONEncoder().encode([view.snapshot.source, view.discoveryPath, relative])
    let identity = DocumentIdentity("source:" + String(decoding: coordinates, as: UTF8.self))
    let document = try DeclarationDocument(bytes: Array(bytes), identity: identity)
    let environment = RuntimeEnvironment(
      projectDirectory: view.localEnvironment.map {
        $0.projectDirectory.appendingPathComponent(view.discoveryPath)
      } ?? root,
      homeDirectory: view.localEnvironment?.homeDirectory ?? store.environment.homeDirectory,
      environment: [:])
    try budget.step(document.metrics.evaluationSteps)
    let declaration = try ManifestProjection.declaration(of: document, environment: environment)
    let result = LinkingDocument(
      declaration: declaration, document: document, view: view,
      manifestPath: relative, producer: true)
    documents[key] = result
    return result
  }
}
