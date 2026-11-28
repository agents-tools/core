import AgentsCore
import AgentsManifest
import Foundation

struct OrganizationInstallEvaluation {
  private struct DeclaredPackage {
    let identity: OrganizationPolicyIdentity
    let reference: String
    let requirement: SourceRequirement?
    let catalog: OrganizationPolicyIdentity?
  }

  private struct DeclaredMCP {
    let identity: OrganizationPolicyIdentity
    let transport: String?
    let registry: MCPRegistryEvidence?
    let reference: String
  }

  let policy: OrganizationPolicySnapshot
  let store: StateStore
  let declaration: Declaration
  private let manifestFields: Set<String>
  private let authored: [DeclaredPackage]
  private let authoredMCP: [DeclaredMCP]
  private let components: [ComponentDeclaration]
  var evaluator: OrganizationPolicyEvaluator { policy.evaluator }

  init(
    policy: OrganizationPolicySnapshot, store: StateStore, declaration: Declaration, bytes: Data?
  ) throws {
    self.policy = policy
    self.store = store
    self.declaration = declaration
    guard policy.evaluator.active else {
      manifestFields = []
      authored = []
      authoredMCP = []
      components = []
      return
    }
    if let bytes {
      let reader = try YAMLReader(bytes: Array(bytes), identity: .init(store.declarationURL.path))
      manifestFields = Set(reader.root.pairs?.compactMap { $0.key.text } ?? [])
    } else {
      manifestFields = []
    }

    let directSources = try declaration.sourceDeclarations.compactMap { entry -> DeclaredPackage? in
      let source = entry.source
      if source.kind == .local,
        BundleSourceLocation.container(
          of: source.localURL(environment: store.environment), in: store) != nil
      {
        return nil
      }
      let origin = try SourceOrigin.declared(source, in: store.environment)
      return DeclaredPackage(
        identity: .init(origin, root: source.path), reference: entry.name,
        requirement: source.requirement, catalog: nil)
    }
    let graphRoots = try declaration.marketplaceRoots.map { root in
      let origin = try root.catalog.policyOrigin(environment: store.marketplaceEnvironment)
      return DeclaredPackage(
        identity: .init(origin, suffix: root.package, root: root.catalog.policyPath),
        reference: root.name, requirement: root.requirement,
        catalog: .init(origin, root: root.catalog.policyPath))
    }
    let legacy = try declaration.packages.map { package in
      let origin = try package.catalog.policyOrigin(environment: store.marketplaceEnvironment)
      return DeclaredPackage(
        identity: .init(
          origin, suffix: package.coordinate.package, root: package.catalog.policyPath),
        reference: package.name, requirement: .exact(package.coordinate.version),
        catalog: .init(origin, root: package.catalog.policyPath))
    }
    authored = directSources + graphRoots + legacy
    let groups = Dictionary(uniqueKeysWithValues: declaration.groups.map { ($0.name, $0) })
    var pending = declaration.uses.filter { $0.source == nil || $0.source == "." }.map(\.name)
    var visited = Set<String>()
    var rootComponents = declaration.components
    while let name = pending.popLast() {
      guard visited.insert(name).inserted, let group = groups[name] else { continue }
      rootComponents += group.components
      pending += group.uses.filter { $0.source == nil || $0.source == "." }.map(\.name)
    }
    components = rootComponents
    authoredMCP = rootComponents.compactMap { component in
      guard case .mcpServer(let name, let transport, _, _, _, let registry) = component else {
        return nil
      }
      return DeclaredMCP(
        identity: registry?.organizationPolicyIdentity ?? .init(.inline, suffix: name),
        transport: transport.organizationPolicyName, registry: registry, reference: name)
    }
  }

  func beforeAcquisition() -> [OrganizationPolicyFinding] {
    var findings = authored.flatMap { item in
      guard let catalog = item.catalog else {
        return evaluator.directSource(
          item.identity.origin, root: item.identity.root, requirement: item.requirement,
          reference: item.reference)
      }
      let path = [item.reference]
      return evaluator.packageIdentity(item.identity, catalog: catalog, path: path)
        + evaluator.pinned(
          item.requirement, identity: item.identity, name: item.identity.suffix ?? item.reference,
          path: path)
    }
    for mcp in authoredMCP {
      findings += evaluator.mcp(
        mcp.identity, transport: mcp.transport, selfDefined: mcp.registry == nil,
        transitive: false, path: [mcp.reference],
        legacyRegistry: mcp.registry.map { $0.invocationDigest == nil } ?? false)
      for origin in mcp.registry?.origins ?? [] {
        findings += evaluator.source(origin, path: [mcp.reference])
      }
    }
    findings += evaluator.findings { rules, context in
      var results: [OrganizationPolicyFinding] = []
      for field in rules.requiredFields where !manifestFields.contains(field) {
        results.append(
          context.finding(
            .manifest, field, "manifest-required-field",
            "The consumer manifest does not declare this field."))
      }
      if rules.scriptsDenied, manifestFields.contains("scripts") || declaration.lifecycle != nil {
        results.append(
          context.finding(
            .manifest, "scripts", "manifest-scripts", "The consumer manifest declares scripts."))
      }
      if rules.explicitIncludes {
        for case .skills(let alias, let selection) in components {
          if case .all = selection.select {
            results.append(
              context.finding(
                .manifest, alias, "manifest-explicit-includes",
                "Skill selection needs explicit names."))
          }
        }
      }
      for required in rules.dependencyRequire
      where !authored.contains(where: { $0.identity.matches(required.identity, exact: true) }) {
        results.append(
          context.finding(
            .package, required.identity, "dependency-required-declaration",
            "Required package is absent from the consumer declaration.", pattern: required.identity)
        )
      }
      for required in rules.mcpRequire
      where !authoredMCP.contains(where: { $0.identity.matches(required, exact: true) })
        && !declaration.marketplaceRoots.contains(where: { root in
          root.selections.contains { $0.member.kind == .mcpServer }
        }) && !declaration.uses.contains(where: { $0.source != nil && $0.source != "." })
      {
        results.append(
          context.finding(
            .mcp, required, "mcp-required-declaration",
            "Required MCP server is absent from the consumer declaration.", pattern: required))
      }
      return results
    }
    return findings
  }

  func closure(_ ledger: ResolvedLedger?, roots: [String: URL]) throws
    -> [OrganizationPolicyFinding]
  {
    guard let ledger else {
      return evaluator.findings { rules, context in
        guard needsClosure(rules),
          !authored.isEmpty || !components.isEmpty
            || !declaration.uses.isEmpty || !rules.dependencyRequire.isEmpty
            || !rules.mcpRequire.isEmpty || !rules.executableRequire.isEmpty
        else { return [] }
        return [
          context.finding(
            .package, "agents.resolved", "dependency-closure-unavailable",
            "No resolved lock is available to verify mandatory deployment evidence.")
        ]
      }
    }
    let findings = try evaluateClosure(ledger, roots: roots)
    return findings.content + findings.workspaceRequirements
  }

  func instructionPreviewClosure(
    _ candidate: ResolvedLedger, previous: ResolvedLedger, roots: [String: URL]
  ) throws -> [OrganizationPolicyFinding] {
    let candidateFindings = try evaluateClosure(candidate, roots: roots)
    let deployedFindings = try evaluateClosure(previous, roots: roots)
    return candidateFindings.content + deployedFindings.workspaceRequirements
  }

  private func evaluateClosure(_ ledger: ResolvedLedger, roots: [String: URL]) throws
    -> (content: [OrganizationPolicyFinding], workspaceRequirements: [OrganizationPolicyFinding])
  {
    let graph = ledger.marketplaceGraph
    var results = try checkOverrides(ledger, roots: roots)
    guard evaluator.active else { return (results, []) }
    let deployed = Set(ledger.deployments.flatMap(\.owners))
    let copyInputs = Set(
      ledger.lowerings.filter { $0.instructionCopyRecipient != nil }.flatMap(\.inputs))
    let selectedComponents = deployed.union(
      ledger.components.compactMap { $0.value.chatGPT ? $0.key : nil })
    let deployedSources = Set(selectedComponents.compactMap { ledger.components[$0]?.source })
      .union(selectedComponents.compactMap { ledger.components[$0]?.declaringSource })
      .union(
        ledger.occurrences.filter { selectedComponents.contains($0.component) }.flatMap(
          \.dependencies))
    let graphPaths = graph?.policyPaths() ?? [:]
    var packageIdentities: [(OrganizationPolicyIdentity, String?)] = []
    var marketplaceByComponent: [String: MarketplaceNodeID] = [:]
    for node in graph?.nodes ?? [] {
      let path = (graphPaths[node.id] ?? [node.id]).map {
        OrganizationPolicyIdentity($0).description
      }
      results += evaluator.marketplace(node.id, path: path)
      for request in node.hostedEvidence?.requests ?? [] {
        let location = try HostedMarketplaceLocation(request.absoluteString)
        results += evaluator.source(location.origin, root: location.policyPath, path: path)
      }
      results += evaluator.depth(path.count, path: path)
      let incoming =
        (graph?.roots.filter { $0.node == node.id }.map(\.intent.requirement) ?? [])
        + (graph?.incoming(to: node.id).map(\.requirement.requirement) ?? [])
      results += evaluator.version(
        node.coordinate.version, identity: .init(node.id), authored: incoming, path: path)
      if node.componentRecords.contains(where: selectedComponents.contains) {
        packageIdentities.append((.init(node.id), node.coordinate.version))
      }
      for component in node.componentRecords { marketplaceByComponent[component] = node.id }
    }
    var legacyByComponent: [String: OrganizationPolicyIdentity] = [:]
    var catalogProducerSources = Set(
      marketplaceByComponent.keys.compactMap { ledger.components[$0]?.declaringSource })
    for pin in ledger.marketplacePackages ?? [] {
      let origin = try pin.policyOrigin(environment: store.marketplaceEnvironment)
      let identity = OrganizationPolicyIdentity(
        origin, suffix: pin.dependency.coordinate.package, root: pin.dependency.catalog.policyPath)
      if pin.componentRecords.contains(where: selectedComponents.contains) {
        packageIdentities.append((identity, pin.dependency.coordinate.version))
      }
      results += evaluator.packageIdentity(
        identity, catalog: .init(origin, root: pin.dependency.catalog.policyPath),
        path: [pin.dependency.name])
      results += evaluator.version(
        pin.dependency.coordinate.version, identity: identity,
        authored: [.exact(pin.dependency.coordinate.version)], path: [pin.dependency.name])
      for component in pin.componentRecords {
        legacyByComponent[component] = identity
        if let source = ledger.components[component]?.declaringSource {
          catalogProducerSources.insert(source)
        }
      }
    }

    let origins = try ledger.sources.mapValues { source -> SourceOrigin in
      switch source.kind {
      case .git: return source.transport.flatMap { try? .git($0) } ?? .missing
      case .wellKnown: return source.transport.flatMap { try? .http($0) } ?? .missing
      case .local:
        guard let location = source.location else { return .missing }
        return .local(at: try location.resolve(roots: roots))
      }
    }
    let implicitRoot = LedgerLocation(
      kind: .registered, root: store.scope == .project ? "project" : "state", path: ".")
    func sourceIdentity(_ id: String, root: String? = nil) -> OrganizationPolicyIdentity {
      var current = id
      while let parent = ledger.sources[current]?.container { current = parent }
      return .init(origins[current] ?? .missing, root: root)
    }
    for use in ledger.sourceUses {
      let identity = sourceIdentity(use.source, root: use.root)
      if let bundle = ledger.sources[use.source]?.bundleSources {
        let standalone = !catalogProducerSources.contains(use.source)
        if standalone {
          let bundleIdentity =
            ledger.sources[use.source]?.bundlePackageName.map(
              OrganizationPolicyIdentity.localBundle)
            ?? .init(.missing)
          results += evaluator.packageIdentity(
            bundleIdentity, path: [use.source], requireAllow: false)
        }
        for evidence in bundle {
          results += evaluator.source(
            evidence.policyOrigin, root: evidence.root, path: [use.source])
          if evidence.packageName != nil {
            results += evaluator.recordedBundlePackage(evidence, path: [use.source])
          } else if standalone, evidence.policyOrigin != .inline {
            results += evaluator.packageIdentity(
              .init(evidence.policyOrigin, root: evidence.root), path: [use.source])
          }
        }
      } else if let source = ledger.sources[use.source], source.location != implicitRoot {
        results += evaluator.source(identity.origin, root: identity.root, path: [use.source])
        results += evaluator.packageIdentity(identity, path: [use.source])
        if deployedSources.contains(use.source) {
          packageIdentities.append((identity, source.version))
        }
        results += evaluator.version(
          source.version, identity: identity, authored: [use.requirement].compactMap { $0 },
          path: [use.source])
      }
    }
    var groupPaths: [Int: [String]] = [:]
    var groupSources: [Int: String] = [:]
    for group in ledger.groups {
      var path = group.parent.flatMap { groupPaths[$0] } ?? []
      let previous = group.parent.flatMap { groupSources[$0] }
      if group.source != previous, ledger.sources[group.source]?.location != implicitRoot,
        ledger.sources[group.source]?.bundleSources == nil,
        ledger.sources[group.source]?.container == nil
      {
        path.append(sourceIdentity(group.source, root: group.root).description)
        results += evaluator.depth(path.count, path: path)
      }
      groupPaths[group.id] = path
      groupSources[group.id] = group.source
    }
    for resource in ledger.resources.sorted(by: { $0.key < $1.key }).map(\.value) {
      if let artifact = resource.artifact {
        for origin in EffectiveSourcePolicy.artifactOrigins(artifact) {
          results += evaluator.source(origin, path: [resource.path])
        }
      }
    }

    let authoredRoots = Set(
      (graph?.roots ?? []).filter { declaration.marketplaceRoots.contains($0.intent) }
        .map(\.intent.name))
    var declaredMCP = authoredMCP.map(\.identity)
    var deployedMCP: [OrganizationPolicyIdentity] = []
    var deployedExecutables: [OrganizationPolicyIdentity] = []
    for (id, component) in ledger.components.sorted(by: { $0.key < $1.key }) {
      let node = marketplaceByComponent[id]
      let registry = component.mcpRegistry
      let legacyRegistry = registry.map { $0.invocationDigest == nil } ?? false
      let declaringSource = ledger.sources[component.declaringSource]
      let identity =
        node.map(OrganizationPolicyIdentity.init) ?? legacyByComponent[id]
        ?? declaringSource?.bundlePackageName.map(OrganizationPolicyIdentity.localBundle)
        ?? (declaringSource?.location == implicitRoot
          ? .init(.inline, suffix: component.name)
          : sourceIdentity(component.declaringSource, root: component.root))
      if component.kind == DeclaredComponentKind.mcpServer.rawValue {
        let origin =
          ledger.sources[component.declaringSource]?.location == implicitRoot
          ? SourceOrigin.inline : identity.origin
        let suffix =
          origin == .inline
          ? component.name
          : identity.suffix.map { $0 + "/" + component.name } ?? component.name
        let server =
          registry?.organizationPolicyIdentity
          ?? .init(origin, suffix: suffix, root: identity.root)
        if let node, let graph {
          let member = MarketplaceMemberKey(kind: .mcpServer, name: component.name)
          let owners = graph.recipientsByRoot(for: member, in: node).keys
          if owners.contains(where: authoredRoots.contains) { declaredMCP.append(server) }
        } else if let identity = legacyByComponent[id],
          authored.contains(where: { $0.identity == identity })
        {
          declaredMCP.append(server)
        } else if component.group != nil, origin != .inline,
          authored.contains(where: { $0.catalog == nil && $0.identity.origin == origin })
        {
          declaredMCP.append(server)
        }
        let transport = component.payload.object?["transport"]?.object?["kind"]?.text
        results += evaluator.mcp(
          server, transport: transport == "streamableHTTP" ? "streamable-http" : transport,
          selfDefined: registry == nil,
          transitive: node.map { node in !(graph?.roots.contains { $0.node == node } ?? false) }
            ?? (component.group != nil && origin != .inline), path: [component.name],
          legacyRegistry: legacyRegistry)
        if deployed.contains(id) { deployedMCP.append(server) }
        for origin in registry?.origins ?? [] {
          results += evaluator.source(origin, path: [component.name])
        }
      }
      if deployed.contains(id) || copyInputs.contains(id) {
        results += evaluator.findings { rules, context in
          guard let allow = rules.contentTypes, !allow.contains(component.kind) else { return [] }
          return [
            context.finding(
              .manifest, component.name, "manifest-content-types",
              "Component type \(component.kind) is outside the allow list.")
          ]
        }
      }
      guard deployed.contains(id) else { continue }
      let entries = component.resources.compactMap { ledger.resources[$0] }.flatMap(\.entries)
      let plugin =
        component.kind == DeclaredComponentKind.plugin.rawValue
        && component.payload.object?["mode"]?.text == PluginModeDeclaration.native.rawValue
      let executable =
        component.kind == DeclaredComponentKind.hook.rawValue
        || component.kind == DeclaredComponentKind.lspServer.rawValue
        || (component.kind == DeclaredComponentKind.mcpServer.rawValue
          && (registry == nil || (legacyRegistry && registry?.package != nil)))
        || entries.contains { entry in
          entry.executable
            || (plugin && [".mcp.json", ".lsp.json", "hooks/hooks.json"].contains(entry.path))
        }
      if executable {
        if !legacyRegistry { deployedExecutables.append(identity) }
        results += evaluator.executable(
          identity, name: component.name, legacyRegistry: legacyRegistry)
      } else if plugin
        || component.resources.contains(where: { ledger.resources[$0]?.kind == .liveEdit })
      {
        results += evaluator.executable(identity, name: component.name, unknown: true)
      }
    }
    results += evaluator.findings { rules, context in
      guard rules.requireHashes else { return [] }
      return ledger.resources.values.compactMap { resource in
        guard resource.kind != .liveEdit, !resource.hash.hasPrefix("sha256:") else { return nil }
        return context.finding(
          .package, resource.path, "integrity-required-hash", "The resource has no content hash.")
      }
    }
    let workspaceRequirements = evaluator.findings { rules, context in
      var findings: [OrganizationPolicyFinding] = []
      for required in rules.dependencyRequire
      where !packageIdentities.contains(where: { $0.0.matches(required.identity, exact: true) }) {
        findings.append(
          context.finding(
            .package, required.identity, "dependency-required-deployment",
            "Required package is absent from the resolved deployment.", pattern: required.identity))
      }
      for required in rules.mcpRequire {
        if !declaredMCP.contains(where: { $0.matches(required, exact: true) }) {
          findings.append(
            context.finding(
              .mcp, required, "mcp-required-declaration",
              "Required MCP server is absent from the consumer declaration.", pattern: required))
        }
        if !deployedMCP.contains(where: { $0.matches(required, exact: true) }) {
          findings.append(
            context.finding(
              .mcp, required, "mcp-required-deployment",
              "Required MCP server is absent from the resolved deployment.", pattern: required))
        }
      }
      for required in rules.executableRequire
      where !deployedExecutables.contains(where: { $0.matches(required, exact: true) }) {
        findings.append(
          context.finding(
            .executable, required, "executables-required-deployment",
            "No admitted executable deployment is recorded for the required package.",
            pattern: required))
      }
      return findings
    }
    return (results, workspaceRequirements)
  }

  private func needsClosure(_ rules: OrganizationRules) -> Bool {
    rules.dependencyAllow != nil || !rules.dependencyDeny.isEmpty
      || !rules.dependencyRequire.isEmpty
      || rules.maximumDepth != nil || rules.mcpAllow != nil || !rules.mcpDeny.isEmpty
      || !rules.mcpRequire.isEmpty || rules.mcpTransportAllow != nil || rules.mcpSelfDefined != nil
      || rules.mcpTrustTransitive == false || rules.executableDenyAll
      || !rules.executableDeny.isEmpty
      || !rules.executableRequire.isEmpty || rules.sourceAllow != nil || !rules.sourceDeny.isEmpty
      || rules.marketplaceAllow != nil || rules.requireHashes || rules.contentTypes != nil
      || rules.failOnDrift || rules.unmanagedAction != .ignore
  }

  private func checkOverrides(_ ledger: ResolvedLedger, roots: [String: URL]) throws
    -> [OrganizationPolicyFinding]
  {
    let chain = policy.chains.first(where: { $0.mode == .block })
    func finding(_ identity: OrganizationPolicyIdentity) -> OrganizationPolicyFinding {
      .init(
        subject: .package, identity: identity.description, rule: "dependency-policy-override",
        authority: chain?.scope ?? store.scope, document: chain?.layers.last?.evidence.url,
        documentDigest: chain?.layers.last?.evidence.digest, outcome: .block,
        message: "The lock’s version override needs matching active organization policy.")
    }
    var findings: [OrganizationPolicyFinding] = []
    for node in ledger.marketplaceGraph?.nodes ?? [] {
      guard let stored = node.organizationRequirements else { continue }
      let required = evaluator.marketplaceRequirements(for: node.id)
      if !required.overrides || stored != required.constraints {
        findings.append(finding(.init(node.id)))
      }
    }
    for use in ledger.sourceUses {
      guard let stored = use.organizationRequirements else { continue }
      let source = ledger.sources[use.source]
      let origin: SourceOrigin
      if source?.kind == .local, let location = source?.location {
        origin = .local(at: try location.resolve(roots: roots))
      } else {
        origin = source?.transport.flatMap { try? SourceOrigin.git($0) } ?? .missing
      }
      let identity = OrganizationPolicyIdentity(origin, root: use.root)
      let required = evaluator.requirements(for: identity)
      if !required.overrides || stored != required.constraints {
        findings.append(finding(identity))
      }
    }
    return findings
  }
}
