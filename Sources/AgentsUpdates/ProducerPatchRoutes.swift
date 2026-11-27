import AgentsCore
import Components
import Foundation

struct ProducerPatchRoutes {
  struct Deployment {
    let record: LedgerDeployment
    let lowering: LockedLowering
    let path: URL
  }

  struct Copy {
    let resource: String
    let owners: [String]
    let target: URL
    let support: URL?
    let recipients: [AgentID]
  }

  let deployments: [Deployment]
  let skipped: [ProducerPatchSkip]
  let routes: Set<NativeTargetRoute>
  let installations: [String: SkillInstallationTarget]

  init(inputs: ProducerPatchInputs) throws {
    let ledger = inputs.ledger
    guard ledger.deployments.count <= ProducerPatchInputs.limits.entries else {
      throw CoreError.invalidState("producer patch deployment budget")
    }
    let lineage = ProducerPatchLineage(inputs)
    var byDeployment: [String: [LockedLowering]] = [:]
    for lowering in ledger.lowerings {
      for id in lowering.deployments { byDeployment[id, default: []].append(lowering) }
    }
    var deployments: [Deployment] = []
    var skipped: [ProducerPatchSkip] = []
    var routes = Set<NativeTargetRoute>()
    var installations: [String: SkillInstallationTarget] = [:]
    for record in ledger.deployments {
      let resolved = try record.target.resolve(roots: inputs.roots)
      func skip(_ reason: ProducerPatchSkip.Reason) {
        skipped.append(.init(path: resolved, reason: reason))
      }
      guard let lowerings = byDeployment[record.id], lowerings.count == 1,
        let lowering = lowerings.first
      else {
        skip(.ambiguousProducer)
        continue
      }
      let resources = lowering.resources.map { ledger.resources[$0]! }
      let sources =
        resources.isEmpty
        ? lowering.inputs.map { ledger.components[$0]!.source } : resources.map(\.source)
      if !sources.isEmpty, sources.allSatisfy(lineage.isLocallyOwned) {
        skip(.locallyOwned)
        continue
      }
      guard record.ownership == .generated, record.owners.count == 1 else {
        skip(.transformed)
        continue
      }
      let path: URL
      if lowering.format == "agents/skill@1" {
        guard lowering.layout.object?["mode"]?.text == InstallMode.copy.rawValue else {
          skip(.linkedDeployment)
          continue
        }
        guard let agent = record.recipients.first, record.recipients == [agent],
          record.target.kind == .registered, record.target.root == "skills-" + agent.rawValue,
          lowering.inputs == record.owners, lowering.resources.count == 1,
          let owner = ledger.components[record.owners[0]], owner.kind == "skills",
          owner.recipients.contains(agent), owner.resources == lowering.resources,
          owner.payload.object?["mode"]?.text == InstallMode.copy.rawValue,
          record.target.path == PathSafety.sanitizeName(owner.name),
          lowering.layout.object?["name"]?.text == lowering.artifacts.first?.name,
          lowering.artifacts.map(\.kind) == [.tree],
          record.expectedHash == resources[0].hash
        else {
          skip(.missingPathAttribution)
          continue
        }
        if let reason = lineage.unattributed(resources[0]) {
          skip(reason)
          continue
        }
        let target = try inputs.store.skillInstallationTarget(for: agent, named: record.target.path)
        installations[target.url.path] = target
        routes.formUnion(target.footprint)
        // The recorded loader spelling is read with no-follow even if it has a coordination alias.
        path = resolved
      } else {
        let route: NativeTargetRoute
        if lowering.format.hasSuffix("-generated-plugin@1") {
          route = try DeploymentConstruction.generatedRoute(lowering, ledger: ledger)
        } else if lowering.format.hasSuffix("-components@1"),
          lowering.artifacts.contains(where: { $0.kind == .tree }),
          let root = record.target.root, let registered = NativeTargetRoute.targetRoute(root)
        {
          route = registered
        } else {
          skip(.transformed)
          continue
        }
        guard record.target.kind == .registered, record.target.root == route.root,
          record.target.path.utf8.elementsEqual(route.basename.utf8),
          lowering.artifacts.first?.hash == record.expectedHash,
          !resources.contains(where: {
            $0.kind == .liveEdit || ($0.kind == .git && lineage.isLocallyOwned($0.source))
          })
        else {
          skip(.missingPathAttribution)
          continue
        }
        routes.insert(route)
        path = try route.logicalDirectory(inputs.store.environment)
          .appendingPathComponent(route.basename)
      }
      deployments.append(.init(record: record, lowering: lowering, path: path))
    }
    self.deployments = deployments
    self.skipped = skipped
    self.routes = routes
    self.installations = installations
  }

  func withPlan<Result>(
    inputs: ProducerPatchInputs, revalidating: Bool,
    _ body: (ProducerPatchPlan, URL?) throws -> Result
  ) throws -> Result {
    guard !deployments.isEmpty else {
      return try body(.init(skipped: skipped), nil)
    }
    let ledger = inputs.ledger
    let lineage = ProducerPatchLineage(inputs)
    let lowerings = Set(deployments.map(\.lowering.id))
    let resources = Set(deployments.flatMap(\.lowering.resources))
    let extra = lineage.hostedProducerResources(for: resources)
    var entered = false
    do {
      return try LedgerReplay.withLockedResources(
        ledger, store: inputs.store, roots: inputs.roots, limits: ProducerPatchInputs.limits,
        lowerings: lowerings, offline: true, sourcePolicy: inputs.sourcePolicy.effective,
        requireRecordedTransport: true, additionalResources: extra, anchorLockedGit: true
      ) { artifacts, resources, workspace in
        let outputs = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0) })
        var plan = ProducerPatchPlan(skipped: skipped)
        for deployment in deployments {
          try Task.checkCancellation()
          for copy in try copies(deployment, outputs: outputs, ledger: ledger, plan: &plan) {
            try plan.compare(copy, resources: resources, lineage: lineage)
          }
        }
        plan.coalesce()
        entered = true
        return try body(plan, workspace)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as SourcePolicyFailure {
      throw error
    } catch let error as OrganizationPolicyFailure {
      throw error
    } catch {
      if entered { throw error }
      throw revalidating ? ProducerPatchError.stale : ProducerPatchError.lockedInputUnavailable
    }
  }

  private func copies(
    _ deployment: Deployment, outputs: [String: ReplayedArtifact],
    ledger: ResolvedLedger, plan: inout ProducerPatchPlan
  ) throws -> [Copy] {
    let record = deployment.record
    let lowering = deployment.lowering
    let artifacts = lowering.artifacts.map { outputs[$0.name]! }
    if lowering.format == "agents/skill@1" {
      guard artifacts.first?.tree != nil else { throw ProducerPatchError.lockedInputUnavailable }
      return [
        .init(
          resource: lowering.resources[0], owners: record.owners,
          target: deployment.path, support: nil, recipients: record.recipients)
      ]
    }
    if lowering.format.hasSuffix("-generated-plugin@1") {
      let plugin = try NativeGeneratedPluginContribution.decode(
        lowering, ledger: ledger, artifacts: artifacts, limits: ProducerPatchInputs.limits)
      try plan.skip(deployment.path.appendingPathComponent(plugin.manifestPath), .transformed)
      let owners = Dictionary(
        grouping: plugin.members.flatMap { member in
          ledger.components[member.component]!.resources.map { ($0, member.component) }
        }, by: { $0.0 })
      return plugin.resourcePlacements.compactMap { placement in
        guard let resource = plugin.resources[placement.resource],
          let records = owners[placement.resource]?.map({ $0.1 })
        else { return nil }
        let primary = ArtifactAggregation.generatedResourcePath(placement, resource: resource)
        let supporting = ArtifactAggregation.generatedResourceBase(placement, resource: resource)
        return .init(
          resource: placement.resource, owners: records,
          target: deployment.path.appendingPathComponent(primary),
          support: resource.support.isEmpty
            ? nil : deployment.path.appendingPathComponent(supporting),
          recipients: record.recipients)
      }
    }
    let contribution = try NativeComponentLayoutsV1.contribution(
      lowering, ledger: ledger, artifacts: artifacts, limits: ProducerPatchInputs.limits)
    for (index, output) in contribution.outputs.enumerated()
    where record.id == lowering.id + ":" + String(index) {
      guard case .nativePlugin(_, let resource, _) = output.content else { break }
      let route = try DeploymentConstruction.route(output, request: contribution.request)
      guard route.root == record.target.root, route.basename == record.target.path,
        record.owners == [contribution.component], record.recipients == contribution.recipients
      else { break }
      return [
        .init(
          resource: resource, owners: record.owners, target: deployment.path,
          support: nil, recipients: record.recipients)
      ]
    }
    try plan.skip(deployment.path, .missingPathAttribution)
    return []
  }
}
