import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation

/// An explicitly chosen adapter document, relative to the source's discovery root.
package struct SourceCatalogImport: Sendable {
  package let profile: SourceImportProfile
  package let document: String
  package var selection: Set<String>? = nil
  package init(profile: SourceImportProfile, document: String, selection: Set<String>? = nil) {
    self.profile = profile
    self.document = document
    self.selection = selection
  }
}

/// Temporary source enumeration, with stable coordinates and no borrowed resource URLs.
/// Destination composition and publication belong to the captured-addition owner.
package struct SourceCatalog: Sendable {
  package struct ID: Hashable, Sendable {
    fileprivate let owner: UUID
    fileprivate let index: Int
  }

  package enum Unit: Sendable {
    case skill(String)
    case instruction(String)
    case group(GroupUseDeclaration)
    case nativePlugin(ComponentDeclaration)
    case componentsPlugin(ComponentDeclaration)
    /// One member is representable through typed kind selection and sibling exclusions.
    case pluginMember(ComponentDeclaration, ComponentReferenceDeclaration)
    /// Metadata is issued by the adapter; its key is never derived from the display label.
    case importer(ImportChoiceMetadata)
  }

  package struct ImportEffects: Sendable {
    package let sources: [ImportedSource]
    package let components: [ImportedComponent]
    package let resources: [ImportResourceProposal]
    package let diagnostics: [SourceImportDiagnostic]
  }

  package struct Choice: Sendable {
    package let id: ID
    package let label: String
    package let origin: ImportLocation
    package let unit: Unit
    /// Actual linked closure, including restrictions, pins, resources and repeated occurrences.
    package let graph: LinkedComponents?
    package let imported: ImportEffects?
    package let artifact: LockedArtifact?
    package let unavailableReason: String?
  }

  package let alias: String
  package let source: SourceDeclaration
  package let snapshot: SourceSnapshotID
  package let root: String
  package let contentHash: String
  package let choices: [Choice]
  package let fixedEffects: ImportEffects?
  package let requiredInputs: [ImportInputMetadata]
  package let bindings: [ImportBindingRequirement]
  package let producerSelections: [ImportProducerSelection]
  package let importDocument: SourceCatalogImport?
  private let owner: UUID

  /// Empty catalog selection is no addition. This resolves handles to representable units only;
  /// it neither composes a declaration nor grants an unrestricted update capability.
  package func selected(_ ids: [ID]) throws -> [Choice]? {
    guard Set(ids).count == ids.count,
      ids.allSatisfy({ $0.owner == owner && choices.indices.contains($0.index) })
    else { throw CoreError.invalidState("source choices belong to another inspection") }
    guard !ids.isEmpty else { return nil }
    let selected = ids.map { choices[$0.index] }
    if let reason = selected.compactMap(\.unavailableReason).first {
      throw CoreError.invalidSource(reason)
    }
    return selected
  }

  package static func inspect(
    alias: String, source: SourceDeclaration, store: StateStore, platform: DeclarationPlatform,
    importing imported: SourceCatalogImport? = nil
  ) throws -> SourceCatalog {
    try Declaration(sources: [alias: source]).validate(environment: store.environment)
    let owner = UUID()
    let budget = LinkBudget()
    if source.kind == .wellKnown {
      guard imported == nil else {
        throw CoreError.invalidSource("skill indexes do not contain adapter documents")
      }
      let skills = try SkillSnapshotReader.index(source)
      let hash = FileHash.sha256Hex(
        data: try JSONEncoder().encode(skills.map { [$0.name, $0.artifact.digest] }))
      let snapshot = try SourceSnapshotID(
        source: source.identity(environment: store.environment), revision: "sha256:" + hash)
      try budget.snapshot(snapshot)
      let choices = try skills.enumerated().map { index, skill in
        try budget.contribution(chain: 0)
        try budget.snapshot(.init(source: snapshot.source, revision: skill.artifact.digest))
        return Choice(
          id: .init(owner: owner, index: index), label: label("Skill", skill.name),
          origin: .init(document: skill.name, pointer: ""), unit: .skill(skill.name),
          graph: nil, imported: nil, artifact: skill.artifact, unavailableReason: nil)
      }
      return .init(
        alias: alias, source: source, snapshot: snapshot, root: source.path ?? ".",
        contentHash: hash, choices: choices, fixedEffects: nil, requiredInputs: [], bindings: [],
        producerSelections: [], importDocument: nil, owner: owner)
    }
    return try SourceResolutionSession.withTemporaryRead(store: store) { session in
      let view: SourceSnapshot
      if try source.requirement != nil || session.isGitSource(source) {
        guard
          let pin = try session.candidates(
            for: source, requirements: [source.requirement], spending: budget.step
          ).first
        else { throw CoreError.invalidSource("source has no matching revision") }
        view = try session.snapshot(source, at: pin)
      } else {
        view = try session.localSnapshot(source)
      }
      try budget.snapshot(view.snapshot)
      let hash = try FileHash.folderHash(view.directory())
      func admitManifest(_ path: String) throws {
        let handle = try FileHandle(forReadingFrom: view.resource(path))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: SourceImportLimits().documentBytes + 1) ?? Data()
        try budget.manifest(view.snapshot, path: path, bytes: bytes.count)
      }
      var choices: [Choice] = []
      func issue(
        _ unit: Unit, label: String, origin: ImportLocation, graph: LinkedComponents? = nil,
        effects: ImportEffects? = nil, unavailable: String? = nil
      ) throws {
        try budget.contribution(chain: 0)
        choices.append(
          .init(
            id: .init(owner: owner, index: choices.count), label: label, origin: origin,
            unit: unit, graph: graph, imported: effects, artifact: nil,
            unavailableReason: unavailable))
      }
      func linked(_ component: ComponentDeclaration?, use: GroupUseDeclaration? = nil) throws
        -> LinkedComponents
      {
        let declaration = Declaration(
          sources: [alias: source], components: component.map { [$0] } ?? [],
          uses: use.map { [$0] } ?? [])
        let identity = DocumentIdentity("catalog/agents.yaml")
        let bytes =
          try DeclarationEditPlan.bytes(
            replacing: Declaration(), with: declaration, in: nil, identity: identity,
            environment: store.environment) ?? Array("version: 1\n".utf8)
        let linker = Linking(
          document: try DeclarationDocument(bytes: bytes, identity: identity), store: store,
          platform: platform, session: session, directPins: [:], retainedLedger: nil, budget: budget
        )
        return try linker.solve(preserving: view.pin.map { [view.snapshot.source: $0] } ?? [:])
      }
      func resolved(
        _ unit: Unit, component: ComponentDeclaration? = nil, use: GroupUseDeclaration? = nil,
        label: String, origin: ImportLocation, unavailable: String? = nil
      ) throws {
        do {
          try issue(
            unit, label: label, origin: origin, graph: linked(component, use: use),
            unavailable: unavailable)
        } catch is CancellationError { throw CancellationError() } catch let error as LinkError {
          if case .budget = error { throw error }
          try issue(unit, label: label, origin: origin, unavailable: diagnostic(error, view: view))
        } catch {
          try issue(unit, label: label, origin: origin, unavailable: diagnostic(error, view: view))
        }
      }
      if let imported {
        let document = try view.relativePath(
          PathSafety.resolvedChild(base: view.directory(), subpath: imported.document))
        var input = SourceImportInput(
          profile: imported.profile, root: view.root, document: document,
          selection: imported.selection)
        try admitManifest(document)
        let current = try SourceImport.preview(input)
        input.selection = nil
        input.enumerateChoices = true
        let proposal = try SourceImport.preview(input)
        func effects(
          _ components: [Int], _ sources: [Int], _ resources: [Int], _ diagnostics: [Int]
        )
          -> ImportEffects
        {
          .init(
            sources: sources.map { stable(proposal.sources[$0], view: view) },
            components: components.map { proposal.components[$0] },
            resources: resources.map { proposal.resources[$0] },
            diagnostics: diagnostics.map { proposal.diagnostics[$0] })
        }
        for (index, choice) in proposal.choices.enumerated() {
          try issue(
            .importer(choice), label: "Producer selection \(index + 1)",
            origin: choice.locations.first ?? .init(document: document, pointer: ""),
            effects: effects(
              choice.components, choice.sources, choice.resources, choice.diagnostics))
        }
        let components = Set(proposal.choices.flatMap(\.components))
        let sources = Set(proposal.choices.flatMap(\.sources))
        let resources = Set(proposal.choices.flatMap(\.resources))
        let diagnostics = Set(proposal.choices.flatMap(\.diagnostics))
        let fixed = effects(
          proposal.components.indices.filter { !components.contains($0) },
          proposal.sources.indices.filter { !sources.contains($0) },
          proposal.resources.indices.filter { !resources.contains($0) },
          proposal.diagnostics.indices.filter { !diagnostics.contains($0) })
        return .init(
          alias: alias, source: source, snapshot: view.snapshot, root: view.discoveryPath,
          contentHash: hash, choices: choices, fixedEffects: fixed,
          requiredInputs: proposal.requiredInputs, bindings: proposal.bindings,
          producerSelections: current.selections, importDocument: imported, owner: owner)
      }
      for skill in try SkillSnapshotReader.read(view) {
        try resolved(
          .skill(skill.name),
          component: .skills(source: alias, .init(select: .names([skill.name]))),
          label: label("Skill", skill.name), origin: .init(document: skill.path, pointer: ""))
      }
      for instruction in try InstructionSnapshotReader.read(view) {
        let component = ComponentDeclaration.instructions(
          .init(sections: [alias + ":" + instruction.name]))
        try resolved(
          .instruction(instruction.name), component: component,
          label: label("Instruction", instruction.name),
          origin: .init(document: instruction.path, pointer: ""))
      }
      let manifest = try view.relativePath(
        view.directory().appendingPathComponent(
          view.directory().lastPathComponent == ".agent" ? "agents.yaml" : ".agent/agents.yaml"))
      if FileManager.default.fileExists(atPath: try view.resource(manifest).path) {
        let document = try DeclarationDocument(
          bytes: Array("version: 1\n".utf8), identity: .init("catalog/agents.yaml"))
        let linker = Linking(
          document: document, store: store, platform: platform, session: session,
          directPins: [:], retainedLedger: nil, budget: budget)
        let producer = try linker.producer(view, chain: [])
        for name in producer.declaration.exports {
          let use = GroupUseDeclaration(name: name, source: alias)
          try resolved(
            .group(use), use: use, label: label("Group", name),
            origin: .init(document: manifest, pointer: "/exports"))
        }
      }
      var nativeBindings: [ImportBindingRequirement] = []
      var nativeInputs: [ImportInputMetadata] = []
      var nativeSelections: [ImportProducerSelection] = []
      for (profile, suffix, agent) in [
        (SourceImportProfile.claudePluginV1, ".claude-plugin/plugin.json", AgentID.claudeCode),
        (.cursorPluginV1, ".cursor-plugin/plugin.json", .cursor),
        (.geminiExtensionV1, "gemini-extension.json", .geminiCLI),
      ] {
        let document = try view.relativePath(
          PathSafety.resolvedChild(base: view.directory(), subpath: suffix))
        guard FileManager.default.fileExists(atPath: try view.resource(document).path) else {
          continue
        }
        try admitManifest(document)
        let proposal = try SourceImport.preview(
          .init(profile: profile, root: view.root, document: document))
        let nativeName = proposal.packageMetadata?.name
        let native = ComponentDeclaration.plugin(
          name: nativeName ?? alias, path: ".", source: alias, mode: .native, agents: [agent])
        try resolved(
          .nativePlugin(native), component: native, label: "Native \(agent.rawValue) registration",
          origin: proposal.packageMetadata?.nameLocation ?? .init(document: document, pointer: ""),
          unavailable: nativeName == nil
            ? "native registration requires adapter-issued container name metadata" : nil)
        nativeBindings += proposal.bindings
        nativeInputs += proposal.requiredInputs
        nativeSelections += proposal.selections
        let whole = ComponentDeclaration.plugin(
          name: alias, path: ".", source: alias, mode: .components, agents: [agent])
        try resolved(
          .componentsPlugin(whole), component: whole,
          label: "Components \(agent.rawValue) container",
          origin: .init(document: document, pointer: ""))
        for member in proposal.components {
          guard let selector = member.member?.selector else { continue }
          let identity = try ResolvedLedgerCodec.bytes(LedgerPayload.reference(selector))
          try budget.step(proposal.components.count)
          let siblings = proposal.components.filter {
            $0.declaration.kind == member.declaration.kind
          }.compactMap(\.member?.selector)
          let exclusions = try siblings.filter {
            try ResolvedLedgerCodec.bytes(LedgerPayload.reference($0)) != identity
          }
          let component = ComponentDeclaration.plugin(
            name: alias, path: ".", source: alias, mode: .components,
            select: [member.declaration.kind], exclude: exclusions, agents: [agent])
          try resolved(
            .pluginMember(component, selector), component: component,
            label: label(member.declaration.kind.rawValue, member.declaration.name ?? "member"),
            origin: member.origin)
        }
      }
      return .init(
        alias: alias, source: source, snapshot: view.snapshot, root: view.discoveryPath,
        contentHash: hash, choices: choices, fixedEffects: nil, requiredInputs: nativeInputs,
        bindings: nativeBindings, producerSelections: nativeSelections, importDocument: nil,
        owner: owner)
    }
  }

  private static func label(_ kind: String, _ name: String) -> String {
    kind + " "
      + String(
        String.UnicodeScalarView(
          name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(0xfffd)! : $0
          }))
  }

  private static func diagnostic(_ error: any Error, view: SourceSnapshot) -> String {
    String(describing: error)
      .replacingOccurrences(of: view.root.path, with: view.snapshot.source)
      .replacingOccurrences(
        of: view.root.resolvingSymlinksInPath().path, with: view.snapshot.source)
  }

  /// Relative imported coordinates remain anchored to the catalog snapshot, never its borrowed URL.
  private static func stable(_ value: ImportedSource, view: SourceSnapshot) -> ImportedSource {
    func relative(_ path: String?) -> String? {
      guard let path, path.hasPrefix("/"),
        PathSafety.isContained(URL(fileURLWithPath: path), in: view.root)
      else { return path }
      return PathSafety.relativePath(path, to: view.root.path)
    }
    var declaration = value.declaration
    if let location = declaration?.location, declaration?.kind == .local,
      location.hasPrefix("/"),
      PathSafety.isContained(URL(fileURLWithPath: location), in: view.root)
    {
      declaration?.location = PathSafety.relativePath(location, to: view.root.path)
    }
    declaration?.environment = nil
    return .init(
      alias: value.alias, origin: value.origin, declaration: declaration, pin: value.pin,
      requestedRef: value.requestedRef, producerPath: relative(value.producerPath),
      producerIdentity: value.producerIdentity, registry: value.registry,
      resolvedRef: value.resolvedRef,
      resolvedURL: value.resolvedURL, developmentOnly: value.developmentOnly)
  }
}
