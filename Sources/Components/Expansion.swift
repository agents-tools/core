import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation

final class Expansion {
  let linking: Linking
  let choices: [String: SourceRevision]
  let emit: Bool
  var constraints: [String: [SourceConstraint]] = [:]
  var components: [LinkedComponent] = []
  var references: [LinkedReference] = []
  var active: [GroupIdentity] = []
  var nextOccurrence = 0
  var referenceParent: Int?
  var indexes: [String: [SnapshotIndexSkill]] = [:]
  var values = ManifestExpansionBudget()

  init(linking: Linking, choices: [String: SourceRevision], emit: Bool) {
    self.linking = linking
    self.choices = choices
    self.emit = emit
  }

  func expandRoot(_ root: LinkingDocument) throws {
    try expand(
      root.declaration.components, records: root.document.declaration.components,
      in: root, group: nil, pointer: "/components",
      condition: DeclarationCondition(), chain: [], dependencies: [], parent: nil)
    for (index, use) in root.declaration.uses.enumerated() {
      try expand(
        use, in: root, pointer: "/uses/\(index)", condition: DeclarationCondition(),
        chain: [], dependencies: [], parent: nil)
    }
    for (id, requirements) in constraints {
      if let selected = choices[id] {
        let candidates = try linking.session.candidates(
          for: linking.addresses[id]!.source!,
          requirements: requirements.map(\.requirement), spending: linking.budget.step)
        try linking.budget.step(candidates.count)
        guard candidates.contains(where: { $0.revision == selected.revision }) else {
          throw RequirementSearch(constraints: requirements)
        }
      }
    }
  }

  private struct Use {
    let declaration: GroupUseDeclaration
    let document: LinkingDocument
    let pointer: String
    let condition: DeclarationCondition
    let chain: [SourceSpan]
    let dependencies: [SourceSnapshotID]
    let parent: Int?
  }

  private enum Walk {
    case enter(Use)
    case leave
  }

  private func expand(
    _ use: GroupUseDeclaration, in context: LinkingDocument, pointer: String,
    condition: DeclarationCondition, chain: [SourceSpan], dependencies: [SourceSnapshotID],
    parent: Int?
  ) throws {
    var pending: [Walk] = [
      .enter(
        Use(
          declaration: use, document: context, pointer: pointer,
          condition: condition, chain: chain, dependencies: dependencies, parent: parent))
    ]
    while let step = pending.popLast() {
      switch step {
      case .leave:
        try linking.budget.step()
        active.removeLast()
      case .enter(let use): try enter(use, pending: &pending)
      }
    }
  }

  private func enter(_ reference: Use, pending: inout [Walk]) throws {
    let use = reference.declaration
    let context = reference.document
    let pointer = reference.pointer
    var condition = reference.condition
    var chain = reference.chain
    var dependencies = reference.dependencies
    let parent = reference.parent
    try linking.budget.step(chain.count + 1)
    guard active.count < 64 else { throw LinkError.budget("active references") }
    let location = try linking.position(at: pointer, in: context)
    chain += (location.map { [$0.span] + $0.origins } ?? [])
    let address = try linking.address(use.source, in: context, chain: chain)
    var target = context
    var constraint: SourceConstraint?
    if use.source != nil, use.source != "." {
      guard address.source?.kind != .wellKnown else {
        throw LinkError.invalid("skill indexes do not define an immutable export package", chain)
      }
      let initial = try linking.view(address, pin: choices[address.id])
      if let source = address.source, !linking.nonGit.contains(address.id) {
        let entry = SourceConstraint(
          source: address.id, root: address.root,
          requirement: source.requirement, referenceChain: chain)
        constraints[address.id, default: []].append(entry)
        constraint = entry
      }
      guard let view = initial else { return }
      target = try linking.producer(view, chain: chain)
      guard target.declaration.exports.contains(use.name) else {
        throw LinkError.missing("explicit export '\(use.name)'", chain)
      }
    }
    guard let index = target.declaration.groups.firstIndex(where: { $0.name == use.name }) else {
      throw LinkError.missing("group '\(use.name)'", chain)
    }
    let group = target.declaration.groups[index]
    let key = GroupIdentity(
      snapshot: target.view.snapshot, root: target.view.discoveryPath, name: group.name)
    guard !active.contains(key) else {
      throw LinkError.cycle((active + [key]).map(\.name), chain)
    }
    active.append(key)
    pending.append(.leave)
    let occurrence = nextOccurrence
    nextOccurrence += 1
    dependencies += [target.view.snapshot]
    condition = condition.intersecting(use.condition ?? DeclarationCondition())
      .intersecting(group.condition ?? DeclarationCondition())
    if emit {
      references.append(
        LinkedReference(
          occurrence: occurrence, parent: parent,
          group: group.name, snapshot: target.view.snapshot, root: target.view.discoveryPath,
          constraint: constraint, referenceChain: chain))
    }
    try expand(
      group.components,
      records: target.document.declaration.groups[index]["components"]!.elements!.map {
        $0.record!
      },
      in: target, group: group.name,
      pointer: "/groups/\(index)/components", condition: condition, chain: chain,
      dependencies: dependencies, parent: occurrence)
    for (useIndex, nested) in group.uses.enumerated().reversed() {
      pending.append(
        .enter(
          Use(
            declaration: nested, document: target,
            pointer: "/groups/\(index)/uses/\(useIndex)", condition: condition, chain: chain,
            dependencies: dependencies, parent: occurrence)))
    }
  }

  private func expand(
    _ declarations: [ComponentDeclaration], records: [DeclarationRecord],
    in context: LinkingDocument, group: String?,
    pointer: String, condition: DeclarationCondition, chain: [SourceSpan],
    dependencies: [SourceSnapshotID], parent: Int?
  ) throws {
    let previousParent = referenceParent
    referenceParent = parent
    defer { referenceParent = previousParent }
    for (index, component) in declarations.enumerated() {
      try linking.budget.step(chain.count + 1)
      let pointer = pointer + "/\(index)"
      let position = try linking.position(at: pointer, in: context)
      do {
        try values.consume(
          records[index], origins: chain,
          locations: linking.componentLocations(at: pointer, in: context),
          spending: linking.budget.step)
      } catch is ManifestExpansionBudget.Failure {
        throw LinkError.budget("expanded manifest values")
      }
      for resource in component.resources {
        try constrainResource(
          resource, in: context, chain: chain + (position.map { [$0.span] + $0.origins } ?? []))
      }
      guard emit else { continue }
      let effective = condition.intersecting(component.condition ?? DeclarationCondition())
      do {
        switch component {
        case .skills(let alias, let selection):
          try skills(
            selection, alias: alias, context: context, group: group,
            condition: effective, chain: chain, position: position, dependencies: dependencies)
        case .instructions(let selection):
          for (index, section) in selection.sectionReferences.enumerated() {
            try instruction(
              section, prompt: nil, selection: selection, context: context, group: group,
              condition: effective, chain: chain,
              position: linking.position(at: pointer + "/sections/\(index)", in: context)
                ?? position,
              dependencies: dependencies)
          }
          for prompt in selection.prompts {
            let promptCondition = effective.intersecting(
              prompt.prompt.condition ?? DeclarationCondition())
            for section in prompt.prompt.sectionReferences {
              try instruction(
                section, prompt: prompt.name, selection: selection, context: context,
                group: group, condition: promptCondition, chain: chain, position: position,
                dependencies: dependencies, append: prompt.prompt.append)
            }
          }
        default:
          let resources = try component.resources.map {
            try resource($0, context: context, chain: chain)
          }
          try append(
            key: key(component.name!, kind: component.kind, context: context, group: group),
            snapshot: context.view.snapshot, pin: context.view.pin,
            payload: .declaration(component),
            context: context,
            group: group, condition: effective,
            recipients: effective.recipients(
              requested: component.agents ?? context.declaration.defaultAgents,
              scope: linking.store.scope, platform: linking.platform), chatGPT: false,
            resources: resources, chain: chain, position: position,
            dependencies: dependencies + resources.map(\.snapshot))
        }
      } catch let error as LinkError { throw error } catch {
        throw LinkError.invalid(
          String(describing: error), chain + (position.map { [$0.span] + $0.origins } ?? []))
      }
    }
  }

  private func key(
    _ name: String, kind: DeclaredComponentKind, context: LinkingDocument, group: String?
  ) -> ComponentKey {
    ComponentKey(
      source: context.view.snapshot.source, root: context.view.discoveryPath,
      group: group, kind: kind, name: name)
  }

  private func selectedView(_ address: SourceAddress, key: ComponentKey?, live: Bool = false) throws
    -> SourceSnapshot
  {
    if let contained = address.contained {
      if live, let root = contained.liveRoot {
        return try linking.session.liveSnapshot(
          SourceDeclaration(
            kind: .local, location: root.path,
            path: contained.discoveryPath))
      }
      return contained
    }
    let source = address.source!
    if live { return try linking.session.liveSnapshot(source) }
    if let key, let preserved = linking.directPins[key] {
      return try linking.view(address, pin: preserved)!
    }
    if let view = try linking.view(address) { return view }
    let pin: SourceRevision
    do {
      guard
        let candidate = try linking.session.candidates(
          for: source, requirements: [source.requirement], spending: linking.budget.step
        ).first
      else {
        throw LinkError.incompatible([
          SourceConstraint(
            source: address.id, root: address.root,
            requirement: source.requirement, referenceChain: [])
        ])
      }
      pin = candidate
    }
    return try linking.view(address, pin: pin)!
  }

  private func skills(
    _ selection: SkillDeclaration, alias: String,
    context: LinkingDocument, group: String?, condition: DeclarationCondition,
    chain: [SourceSpan], position: SourceMapEntry?, dependencies: [SourceSnapshotID]
  ) throws {
    let location = chain + (position.map { [$0.span] + $0.origins } ?? [])
    var address = try linking.address(alias, in: context, chain: location)
    if alias == ".", !context.producer {
      let source = SourceDeclaration(kind: .local, location: context.view.root.path)
      address = SourceAddress(
        id: context.view.snapshot.source, source: source, contained: nil,
        root: context.view.discoveryPath)
    }
    if let source = address.source, source.kind == .wellKnown {
      try indexSkills(
        selection, address: address, source: source, context: context, group: group,
        condition: condition, chain: chain, position: position, dependencies: dependencies)
      return
    }
    let requestedNames: [String]?
    switch selection.select {
    case .all: requestedNames = nil
    case .names(let names): requestedNames = names
    }
    // Each direct member may retain a different pin even when it shares an alias with exports.
    let names: [String]
    if let requestedNames {
      names = requestedNames
    } else {
      let live = selection.mode == .edit
      names = try SkillSnapshotReader.read(selectedView(address, key: nil, live: live), live: live)
        .map(\.name)
    }
    for name in names where !(selection.exclude ?? []).contains(name) {
      let componentKey = key(name, kind: .skills, context: context, group: group)
      let override = selection.overrides?[name]
      let mode = override?.mode ?? selection.mode ?? .link
      let view = try selectedView(address, key: componentKey, live: mode == .edit)
      if mode == .edit, view.liveRoot == nil {
        throw LinkError.invalid("edit requires an actual local skill with no requirement", location)
      }
      let matches = try SkillSnapshotReader.read(view, live: mode == .edit).filter {
        $0.name == name || PathSafety.sanitizeName($0.name) == name
          || URL(fileURLWithPath: $0.path).lastPathComponent == name
      }
      guard matches.count == 1, let skill = matches.first else {
        throw LinkError.missing("skill '\(name)'", location)
      }
      let effective = condition.intersecting(skill.condition)
      let resource = LinkedResource(
        snapshot: view.snapshot, path: skill.path,
        hash: skill.hash, executableFlags: skill.executableFlags)
      try append(
        key: componentKey, snapshot: view.snapshot, pin: view.pin,
        payload: .skill(skill, mode: mode, native: selection.native), context: context,
        group: group,
        condition: effective,
        recipients: effective.recipients(
          requested: override?.agents ?? selection.agents ?? context.declaration.defaultAgents,
          scope: linking.store.scope, platform: linking.platform), chatGPT: false,
        resources: [resource], chain: chain, position: position,
        dependencies: dependencies + [view.snapshot])
    }
  }

  private func indexSkills(
    _ selection: SkillDeclaration, address: SourceAddress, source: SourceDeclaration,
    context: LinkingDocument, group: String?, condition: DeclarationCondition,
    chain: [SourceSpan], position: SourceMapEntry?, dependencies: [SourceSnapshotID]
  ) throws {
    if indexes[address.id] == nil { indexes[address.id] = try SkillSnapshotReader.index(source) }
    let available = indexes[address.id]!
    let names: [String]
    switch selection.select {
    case .all: names = available.map(\.name)
    case .names(let requested): names = requested
    }
    for name in names where !(selection.exclude ?? []).contains(name) {
      let location = chain + (position.map { [$0.span] + $0.origins } ?? [])
      guard let artifact = available.first(where: { $0.name == name }) else {
        throw LinkError.missing("skill '\(name)'", location)
      }
      let override = selection.overrides?[name]
      let mode = override?.mode ?? selection.mode ?? .link
      guard mode != .edit else {
        throw LinkError.invalid("edit requires an actual local skill with no requirement", location)
      }
      let view = try linking.session.fileSnapshot(
        source: address.id, revision: artifact.artifact.digest,
        files: artifact.files)
      try linking.budget.snapshot(view.snapshot)
      guard let skill = try SkillSnapshotReader.read(view).first,
        PathSafety.sanitizeName(skill.name) == name
      else {
        throw LinkError.missing("skill '\(name)'", location)
      }
      let effective = condition.intersecting(skill.condition)
      try append(
        key: key(name, kind: .skills, context: context, group: group), snapshot: view.snapshot,
        pin: view.pin,
        payload: .skill(skill, mode: mode, native: selection.native), context: context,
        group: group,
        condition: effective,
        recipients: effective.recipients(
          requested: override?.agents ?? selection.agents ?? context.declaration.defaultAgents,
          scope: linking.store.scope, platform: linking.platform), chatGPT: false,
        resources: [
          LinkedResource(
            snapshot: view.snapshot, path: skill.path, hash: skill.hash,
            executableFlags: skill.executableFlags, artifact: artifact.artifact)
        ],
        chain: chain, position: position, dependencies: dependencies + [view.snapshot])
    }
  }

  private func instruction(
    _ section: SectionDeclaration, prompt: String?, selection: InstructionsDeclaration,
    context: LinkingDocument, group: String?, condition: DeclarationCondition, chain: [SourceSpan],
    position: SourceMapEntry?, dependencies: [SourceSnapshotID], append appendPath: String? = nil
  ) throws {
    let location = chain + (position.map { [$0.span] + $0.origins } ?? [])
    let own = section.source == nil || section.source == "."
    guard context.producer || linking.store.scope != .user || !own else {
      throw LinkError.invalid("root user instructions require a named source", location)
    }
    let address = try linking.address(section.source, in: context, chain: location)
    let componentKey = key(section.name, kind: .instructions, context: context, group: group)
    let view = try selectedView(address, key: componentKey)
    guard
      let unit = try InstructionSnapshotReader.read(view, own: own).first(where: {
        $0.name == section.name
      })
    else {
      throw LinkError.missing("instruction '\(section.name)'", location)
    }
    let effective = condition.intersecting(section.condition ?? DeclarationCondition())
      .intersecting(unit.section.condition)
    var resources = [
      LinkedResource(
        snapshot: view.snapshot, path: unit.path,
        hash: unit.section.hash, executableFlags: [:])
    ]
    if let appendPath {
      if linking.store.scope == .user {
        let home = linking.store.environment.homeDirectory
        let view = try SourceSnapshot(
          snapshot: SourceSnapshotID(source: "local:" + home.path, revision: "live"),
          pin: nil, root: home,
          localEnvironment: SourceEnvironment(projectDirectory: home, homeDirectory: home),
          liveRoot: home)
        try linking.budget.snapshot(view.snapshot)
        linking.session.register(view)
        resources.append(try resource(appendPath, in: view, chain: location))
      } else {
        resources.append(
          try resource(ResourceDeclaration(path: appendPath), context: context, chain: location))
      }
    }
    let recipients =
      prompt == nil
      ? effective.recipients(
        requested: selection.agents ?? context.declaration.defaultAgents,
        scope: linking.store.scope, platform: linking.platform) : []
    try self.append(
      key: componentKey, snapshot: view.snapshot, pin: view.pin,
      payload: .instruction(unit, prompt: prompt, native: selection.native), context: context,
      group: group, condition: effective, recipients: recipients,
      chatGPT: prompt != nil
        && effective.matches(scope: linking.store.scope, platform: linking.platform),
      resources: resources, chain: chain, position: position,
      dependencies: dependencies + resources.map(\.snapshot))
  }

  private func constrainResource(
    _ resource: ResourceDeclaration, in context: LinkingDocument,
    chain: [SourceSpan]
  ) throws {
    let address = try linking.address(resource.source, in: context, chain: chain)
    guard let source = address.source else { return }
    guard source.kind != .wellKnown else {
      throw LinkError.invalid("skill indexes cannot supply package resources", chain)
    }
    _ = try linking.view(address, pin: choices[address.id])
    if !linking.nonGit.contains(address.id) {
      constraints[address.id, default: []].append(
        SourceConstraint(
          source: address.id,
          root: address.root, requirement: source.requirement, referenceChain: chain))
    }
  }

  private func resource(
    _ resource: ResourceDeclaration, context: LinkingDocument, chain: [SourceSpan]
  ) throws -> LinkedResource {
    let address = try linking.address(resource.source, in: context, chain: chain)
    guard let view = try linking.view(address, pin: choices[address.id]) else {
      throw LinkError.invalid("resource source has no exact selection", chain)
    }
    return try self.resource(resource.path, in: view, chain: chain)
  }

  private func resource(_ resourcePath: String, in view: SourceSnapshot, chain: [SourceSpan]) throws
    -> LinkedResource
  {
    let root = try view.directory()
    let file = try PathSafety.resolvedChild(base: root, subpath: resourcePath)
    let path = try view.relativePath(file)
    let target = try view.resource(path)
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) else {
      throw LinkError.missing("resource '\(resourcePath)'", chain)
    }
    if directory.boolValue {
      try view.validateResourceTree(target)
      return try LinkedResource(
        snapshot: view.snapshot, path: path,
        hash: "sha256:" + FileHash.folderHash(target),
        executableFlags: FileHash.executableFlags(target))
    }
    let info = try FileManager.default.attributesOfItem(atPath: target.path)
    return try LinkedResource(
      snapshot: view.snapshot, path: path,
      hash: "sha256:" + FileHash.sha256Hex(file: target),
      executableFlags: [path: ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0])
  }

  private func append(
    key: ComponentKey, snapshot: SourceSnapshotID, pin: SourceRevision? = nil,
    payload: LinkedPayload, context: LinkingDocument,
    group: String?, condition: DeclarationCondition, recipients: Set<AgentID>, chatGPT: Bool,
    resources: [LinkedResource], chain: [SourceSpan], position: SourceMapEntry?,
    dependencies: [SourceSnapshotID]
  ) throws {
    try linking.budget.contribution(chain: chain.count + (position?.origins.count ?? 0))
    let occurrence = nextOccurrence
    nextOccurrence += 1
    let provenance = SourceProvenance(
      sourceIdentity: context.view.snapshot.source,
      revision: context.view.pin?.revision,
      artifactDigest: context.view.snapshot.revision.hasPrefix("sha256:")
        ? context.view.snapshot.revision : nil,
      relativePath: context.manifestPath, format: "Agents.swift", adapterVersion: "1.0",
      group: group, referenceChain: chain)
    let origin = ContributionOrigin(
      occurrence: occurrence, provenance: provenance,
      declaration: position?.span, sourceOrigins: position?.origins ?? [],
      reference: referenceParent, condition: condition,
      recipients: recipients, dependencies: dependencies, consumerEditable: !context.producer)
    components.append(
      LinkedComponent(
        key: key, snapshot: snapshot, pin: pin, payload: payload,
        conditions: [condition], recipients: recipients, chatGPT: chatGPT, resources: resources,
        origins: [origin]))
  }

  func result() throws -> LinkedComponents {
    var result: [LinkedComponent] = []
    var byKey: [ComponentKey: [Int]] = [:]
    for component in components {
      try linking.budget.step()
      if component.key.kind != .instructions {
        var coalesced = false
        for index in byKey[component.key] ?? [] {
          try linking.budget.step()
          let prior = result[index]
          let same =
            prior.payload.sameContent(as: component.payload)
            && prior.resources == component.resources
            && prior.snapshot == component.snapshot && prior.pin == component.pin
          if same, [.hook, .permissions].contains(component.key.kind) {
            result[index].origins += component.origins
            result[index].recipients.formUnion(component.recipients)
            for condition in component.conditions
            where !result[index].conditions.contains(condition) {
              result[index].conditions.append(condition)
            }
            coalesced = true
            break
          }
          if !same,
            !prior.recipients.isDisjoint(with: component.recipients)
              || (prior.chatGPT && component.chatGPT)
          {
            throw LinkError.conflict(component.key, prior.origins + component.origins)
          }
        }
        if coalesced { continue }
      }
      byKey[component.key, default: []].append(result.count)
      result.append(component)
    }
    let snapshots = Set(
      result.flatMap { component in
        [component.snapshot] + component.resources.map(\.snapshot)
          + component.origins.flatMap(\.dependencies)
      } + references.map(\.snapshot))
    return LinkedComponents(
      components: result, references: references,
      constraints: constraints.keys.sorted().flatMap { constraints[$0]! },
      selections: choices.filter { constraints[$0.key] != nil },
      sourceSnapshots: linking.session.sourceEvidence(for: snapshots))
  }
}
