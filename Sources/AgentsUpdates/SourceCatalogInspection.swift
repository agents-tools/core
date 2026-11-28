import AgentsCore
import AgentsManifest
import Components
import Foundation

/// A handle from one immutable source inspection; labels are never selection keys.
public struct SourceCatalogChoiceID: Hashable, Sendable {
  fileprivate let owner: UUID
  fileprivate let index: Int
}

public struct SourceCatalogInputID: Hashable, Sendable {
  fileprivate let owner: UUID
  fileprivate let index: Int
}

public enum SourceCatalogUnit: Sendable {
  case skill, instruction, group, nativePlugin, componentsPlugin
  case pluginMember(ComponentReferenceDeclaration)
  case importer
}

public struct SourceCatalogOccurrenceEffect: Sendable {
  public let provenance: SourceProvenance
  public let condition: DeclarationCondition
  public let recipients: [AgentID]
  public let dependencies: [String]
}

public struct SourceCatalogConstraintInspection: Sendable {
  public let source: String
  public let root: String
  public let requirement: SourceRequirement?
  public let referenceChain: [SourceSpan]
}

public struct SourceCatalogEffect: Sendable {
  public let kind: DeclaredComponentKind
  public let name: String
  public let source: String
  public let revision: String
  public let conditions: [DeclarationCondition]
  public let recipients: [AgentID]
  public let chatGPT: Bool
  public let resources: [String]
  public let declaration: ComponentDeclaration?
  public let occurrences: [SourceCatalogOccurrenceEffect]
}

public struct SourceCatalogChoiceInspection: Sendable {
  public let id: SourceCatalogChoiceID
  public let label: String
  public let origin: ImportLocationInspection
  public let unit: SourceCatalogUnit
  public let effects: [SourceCatalogEffect]
  public let importedEffects: ImportSelectionEffects?
  public let constraints: [SourceCatalogConstraintInspection]
  public let artifactDigest: String?
  public let unavailableReason: String?
}

public struct SourceCatalogRequiredInput: Sendable {
  public let id: SourceCatalogInputID
  public let kind: ImportInputKind
  public let location: ImportLocationInspection
  public let suggestedReference: ImportBindingReference?
}

public struct SourceCatalogInputResolution: Sendable {
  public let id: SourceCatalogInputID
  public let value: ImportInputValue
  public init(id: SourceCatalogInputID, value: ImportInputValue) {
    self.id = id
    self.value = value
  }
}

/// The explicit adapter and document within the selected discovery root. Omission and an
/// empty producer selection retain their adapter-defined meanings during inspection.
public struct SourceCatalogImportOptions: Sendable {
  public let format: String
  public let document: String
  public let selection: Set<String>?
  public init(format: String, document: String, selection: Set<String>? = nil) {
    self.format = format
    self.document = document
    self.selection = selection
  }
}

public struct SourceCatalogSelectionOptions: Sendable {
  public var agents: [AgentID]?
  public var condition: DeclarationCondition?
  public var skillMode: InstallMode?
  public init(
    agents: [AgentID]? = nil, condition: DeclarationCondition? = nil, skillMode: InstallMode? = nil
  ) {
    self.agents = agents
    self.condition = condition
    self.skillMode = skillMode
  }
}

/// Explicit source choices and their full linked or adapter-issued effects. Source sessions and
/// private freshness observations are retained only as opaque preparation authority.
public struct SourceCatalogInspection: Sendable, CustomReflectable {
  public let alias: String
  public let sourceIdentity: String
  public let revision: String
  public let availableChoices: [SourceCatalogChoiceInspection]
  public let fixedEffects: ImportSelectionEffects?
  public let requiredInputs: [SourceCatalogRequiredInput]
  public let bindings: [ImportBindingInspection]
  public let producerSelections: [ImportSelectionInspection]
  private let capture: CatalogCapture
  public var customMirror: Mirror {
    Mirror(self, children: ["alias": alias, "choices": availableChoices])
  }

  /// Empty selection returns nil before opening sources or initializing a request. Every other
  /// selection revalidates this inspection and composes only the selected finite additions.
  public func select(
    _ choices: [SourceCatalogChoiceID], options: SourceCatalogSelectionOptions = .init(),
    inputs: [SourceCatalogInputResolution] = []
  ) throws -> ComponentDiscovery? {
    guard !choices.isEmpty else { return nil }
    guard Set(choices).count == choices.count,
      choices.allSatisfy({
        $0.owner == capture.owner && capture.catalog.choices.indices.contains($0.index)
      }),
      Set(inputs.map(\.id)).count == inputs.count,
      inputs.allSatisfy({
        $0.id.owner == capture.owner && capture.targets.indices.contains($0.id.index)
      })
    else { throw CoreError.invalidState("catalog handles belong to another inspection") }
    let preparation = CatalogPreparation(
      capture: capture, choices: choices.map(\.index), options: options, inputs: inputs)
    let additions = try preparation.additions()
    guard
      var discovery = try UpdateOperations.captureAddition(
        additions, in: capture.destination, catalogExpectation: preparation.compositionExpectation)
    else { return nil }
    discovery.catalogPreparation = preparation
    return discovery
  }

  fileprivate init(capture: CatalogCapture) {
    self.capture = capture
    let catalog = capture.catalog
    alias = catalog.alias
    sourceIdentity = catalog.snapshot.source
    revision = catalog.snapshot.revision
    availableChoices = catalog.choices.enumerated().map { index, choice in
      let unit: SourceCatalogUnit
      switch choice.unit {
      case .skill: unit = .skill
      case .instruction: unit = .instruction
      case .group: unit = .group
      case .nativePlugin: unit = .nativePlugin
      case .componentsPlugin: unit = .componentsPlugin
      case .pluginMember(_, let selector): unit = .pluginMember(selector)
      case .importer: unit = .importer
      }
      return .init(
        id: .init(owner: capture.owner, index: index), label: choice.label,
        origin: location(choice.origin), unit: unit,
        effects: choice.graph?.components.map { component in
          .init(
            kind: component.key.kind, name: component.key.name, source: component.snapshot.source,
            revision: component.snapshot.revision, conditions: component.conditions,
            recipients: component.recipients.sorted { $0.rawValue < $1.rawValue },
            chatGPT: component.chatGPT,
            resources: component.resources.map(\.path),
            declaration: {
              if case .declaration(let declaration) = component.payload { return declaration }
              return nil
            }(),
            occurrences: component.origins.map { origin in
              .init(
                provenance: origin.provenance,
                condition: origin.condition,
                recipients: origin.recipients.sorted { $0.rawValue < $1.rawValue },
                dependencies: origin.dependencies.map { $0.source + "@" + $0.revision })
            })
        } ?? [], importedEffects: choice.imported.map(effects),
        constraints: choice.graph?.constraints.map {
          .init(
            source: $0.source, root: $0.root, requirement: $0.requirement,
            referenceChain: $0.referenceChain)
        } ?? [],
        artifactDigest: choice.artifact?.digest, unavailableReason: choice.unavailableReason)
    }
    fixedEffects = catalog.fixedEffects.map(effects)
    requiredInputs = capture.targets.enumerated().map { index, target in
      let kind: ImportInputKind
      let origin: ImportLocation
      let suggested: ImportBindingReference?
      switch target {
      case .adapter(let input):
        kind = input.kind == .gitSource ? .sourceCoordinates : .explicitContent
        origin = input.location
        suggested = nil
      case .binding(let binding):
        kind = .bindingReference
        origin = binding.location
        suggested = binding.environmentVariable.map(ImportBindingReference.environment)
      }
      return .init(
        id: .init(owner: capture.owner, index: index), kind: kind,
        location: location(origin), suggestedReference: suggested)
    }
    bindings = catalog.bindings.map {
      .init(
        document: $0.location.document, pointer: $0.location.pointer,
        reason: $0.reason, environmentVariable: $0.environmentVariable,
        canResolveCanonicalSlot: $0.canonicalSlot)
    }
    producerSelections = catalog.producerSelections.map {
      .init(
        document: $0.origin.document, pointer: $0.origin.pointer,
        sourceAlias: $0.sourceAlias, kind: $0.kind.rawValue, values: $0.values,
        automatic: $0.automatic,
        developmentOnly: $0.developmentOnly)
    }
  }
}

extension UpdateOperations {
  /// Enumerates only the explicit source/root. Inspection neither publishes state nor retains
  /// a source extraction. Selection remains bound to this destination and source generation.
  public static func inspectSource(
    alias: String, source: SourceDeclaration, importing: SourceCatalogImportOptions? = nil,
    scope: InstallScope = .project, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> SourceCatalogInspection {
    let store = StateStore(scope: scope, environment: environment)
    let policy = try SourcePolicySnapshot(store: store)
    try policy.effective.require(source, environment: environment)
    let organization = try OrganizationPolicySnapshot(store: store)
    try organization.requireSource(source, reference: alias, in: store)
    let destination = try inspect(scope: scope, environment: environment)
    let imported: SourceCatalogImport?
    if let importing {
      guard let profile = SourceImportProfile(rawValue: importing.format) else {
        throw CoreError.invalidSource("unknown source import profile")
      }
      imported = .init(
        profile: profile, document: importing.document, selection: importing.selection)
    } else {
      imported = nil
    }
    #if os(macOS)
      let platform = DeclarationPlatform.macOS
    #else
      let platform = DeclarationPlatform.linux
    #endif
    let localGit =
      try source.kind == .local
      && SourceResolutionSession.withTemporaryRead(store: store) { try $0.isGitSource(source) }
    let original =
      try source.kind == .local && !localGit
      ? TargetPrecondition(source.localURL(environment: environment)) : nil
    let catalog = try SourceCatalog.inspect(
      alias: alias, source: source, store: store, platform: platform, importing: imported,
      sourcePolicy: policy.effective, organization: organization.evaluator,
      admitOrganization: { try organization.admit($0) })
    let liveOriginal = catalog.snapshot.revision.hasPrefix("sha256:") ? original : nil
    try liveOriginal?.validate()
    try policy.validate()
    try organization.validate()
    return SourceCatalogInspection(
      capture: .init(
        catalog: catalog, store: store,
        destination: destination, platform: platform, original: liveOriginal))
  }
}

private enum CatalogInputTarget: Sendable {
  case adapter(ImportInputMetadata)
  case binding(ImportBindingRequirement)
}

private final class CatalogCapture: @unchecked Sendable, CustomReflectable {
  let owner = UUID()
  let catalog: SourceCatalog
  let store: StateStore
  let destination: ScopeInspection
  let platform: DeclarationPlatform
  let original: TargetPrecondition?
  let targets: [CatalogInputTarget]
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
  init(
    catalog: SourceCatalog, store: StateStore, destination: ScopeInspection,
    platform: DeclarationPlatform, original: TargetPrecondition?
  ) {
    self.catalog = catalog
    self.store = store
    self.destination = destination
    self.platform = platform
    self.original = original
    targets =
      catalog.requiredInputs.map(CatalogInputTarget.adapter)
      + catalog.bindings.filter { $0.canonicalSlot && $0.key != nil }.map(
        CatalogInputTarget.binding)
  }
}

/// Concrete catalog evidence, rechecked at selection and ordinary request preparation.
package final class CatalogPreparation: @unchecked Sendable, CustomReflectable {
  private let capture: CatalogCapture
  private let choices: [Int]
  private let options: SourceCatalogSelectionOptions
  private let inputs: [SourceCatalogInputResolution]
  package var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
  fileprivate init(
    capture: CatalogCapture, choices: [Int], options: SourceCatalogSelectionOptions,
    inputs: [SourceCatalogInputResolution]
  ) {
    self.capture = capture
    self.choices = choices
    self.options = options
    self.inputs = inputs
  }
  package func validate() throws -> [TargetPrecondition] {
    _ = try additions()
    return capture.original.map { [$0] } ?? []
  }
  package func validateStandalone(replacing targets: [URL]) throws {
    guard capture.catalog.importDocument != nil else { return }
    let (_, proposal) = try conversion()
    for resource in proposal.resources where resource.selected && resource.requiresStandaloneSource
    {
      guard
        let source = proposal.sources.first(where: { $0.alias == resource.sourceAlias })?
          .declaration,
        source.kind == .local
      else { continue }
      let root = source.localURL(environment: capture.store.environment)
      if targets.contains(where: {
        PathSafety.isContained(root, in: $0) || PathSafety.isContained($0, in: root)
      }) {
        throw CoreError.invalidState(
          "import requires an independent authoring source before replacing its installed content")
      }
    }
  }
  fileprivate func additions() throws -> Declaration {
    let policy = try SourcePolicySnapshot(store: capture.store)
    try capture.original?.validate()
    let catalog = capture.catalog
    let organization = try OrganizationPolicySnapshot(store: capture.store)
    try organization.requireSource(catalog.source, reference: catalog.alias, in: capture.store)
    let fresh = try SourceCatalog.inspect(
      alias: catalog.alias, source: catalog.source, store: capture.store,
      platform: capture.platform, importing: catalog.importDocument,
      sourcePolicy: policy.effective, organization: organization.evaluator,
      admitOrganization: { try organization.admit($0) })
    guard fresh.snapshot == catalog.snapshot, fresh.root.utf8.elementsEqual(catalog.root.utf8),
      fresh.contentHash == catalog.contentHash
    else { throw CoreError.invalidState("catalog source changed; refresh inspection") }
    for index in choices {
      guard fresh.choices.indices.contains(index),
        fresh.choices[index].graph == catalog.choices[index].graph,
        fresh.choices[index].artifact == catalog.choices[index].artifact,
        fresh.choices[index].unavailableReason == catalog.choices[index].unavailableReason
      else { throw CoreError.invalidState("catalog dependency changed; refresh inspection") }
    }
    try capture.original?.validate()
    try policy.validate()
    try organization.validate()
    let selected = try catalog.selected(choices.map { catalog.choices[$0].id }) ?? []
    if catalog.importDocument == nil {
      guard inputs.isEmpty else { throw CoreError.invalidState("catalog has no adapter input") }
      return try catalog.additions(
        selected.map(\.id), agents: options.agents, condition: options.condition,
        mode: options.skillMode)
    }
    guard options.agents == nil, options.condition == nil, options.skillMode == nil else {
      throw CoreError.invalidState(
        "import recipients and restrictions belong to the adapter conversion")
    }
    return try conversion().0
  }
  fileprivate var compositionExpectation: CatalogCompositionExpectation {
    .init(
      choices: choices.map { capture.catalog.choices[$0] }, skillMode: options.skillMode)
  }

  private func conversion() throws -> (Declaration, SourceImportProposal) {
    let catalog = capture.catalog
    let selected = try catalog.selected(choices.map { catalog.choices[$0].id }) ?? []
    var bindings: [String: RuntimeBinding] = [:]
    var sources: [String: SourceDeclaration] = [:]
    var content: [String: String] = [:]
    for input in inputs {
      switch (capture.targets[input.id.index], input.value) {
      case (.adapter(let target), .source(let source)) where target.kind == .gitSource:
        guard SourceImport.admitsSourceCoordinates(source) else {
          throw CoreError.invalidSource("import requires Git coordinates")
        }
        sources[target.key] = source
      case (.adapter(let target), .content(let path)) where target.kind == .installedContent:
        _ = try PathSafety.sanitizeSubpath(path)
        content[target.key] = path
      case (.binding(let target), .binding(let reference)):
        switch reference {
        case .environment(let name):
          guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
          else { throw CoreError.invalidState("invalid symbolic environment reference") }
          bindings[target.key!] = .environment(name)
        case .secret(let name):
          guard !name.isEmpty,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
          else { throw CoreError.invalidState("invalid symbolic secret reference") }
          bindings[target.key!] = .secret(name)
        }
      default: throw CoreError.invalidState("wrong catalog input kind")
      }
    }
    let keys = Set(
      selected.compactMap { choice -> String? in
        if case .importer(let metadata) = choice.unit { return metadata.key }
        return nil
      })
    let result = try catalog.conversion(
      keys: keys, bindings: bindings, sources: sources, content: content, store: capture.store)
    try capture.original?.validate()
    return result
  }
}

private func location(_ value: ImportLocation) -> ImportLocationInspection {
  .init(document: value.document, pointer: value.pointer, span: value.span)
}

private func effects(_ value: SourceCatalog.ImportEffects) -> ImportSelectionEffects {
  .init(
    sources: value.sources.map { s in
      .init(
        alias: s.alias, document: s.origin.document, pointer: s.origin.pointer,
        declaration: s.declaration, commit: s.pin.commit, version: s.pin.version,
        integrityKind: s.pin.integrity?.kind.rawValue, integrity: s.pin.integrity?.value,
        requestedRef: s.requestedRef, resolvedRef: s.resolvedRef, resolvedURL: s.resolvedURL,
        developmentOnly: s.developmentOnly, producerPath: s.producerPath,
        producerIdentity: s.producerIdentity, registry: s.registry)
    },
    components: value.components.map {
      .init(document: $0.origin.document, pointer: $0.origin.pointer, declaration: $0.declaration)
    },
    resources: value.resources.map {
      .init(
        sourceAlias: $0.sourceAlias, producerName: $0.producerName, path: $0.path,
        hash: $0.observedHash, integrityKind: $0.producerIntegrity?.kind.rawValue,
        integrity: $0.producerIntegrity?.value,
        executableFlags: $0.executableFlags, requiresStandaloneSource: $0.requiresStandaloneSource,
        selected: $0.selected, requiresBindingRewrite: $0.requiresBindingRewrite)
    },
    diagnostics: value.diagnostics.map {
      .init(
        code: $0.code.rawValue, document: $0.location.document,
        pointer: $0.location.pointer, span: $0.location.span, message: $0.message)
    })
}

/// Selected producer evidence is checked against the composed graph before it is frozen.
/// Consumer restrictions, recipients, modes and container filters remain authored composition.
package struct CatalogCompositionExpectation {
  private let components: [LinkedComponent]
  private let references: [LinkedReference]
  private let liveEditKeys: Set<ComponentKey>

  init(choices: [SourceCatalog.Choice], skillMode: InstallMode?) {
    components = choices.flatMap { $0.graph?.components ?? [] }
    references = choices.flatMap { $0.graph?.references ?? [] }
    liveEditKeys = Set(
      choices.flatMap { choice -> [ComponentKey] in
        guard skillMode == .edit, case .skill = choice.unit else { return [] }
        return choice.graph?.components.map(\.key) ?? []
      })
  }

  func validate(_ linked: LinkedComponents) throws {
    for reference in references {
      let candidates = linked.references.filter {
        $0.group.utf8.elementsEqual(reference.group.utf8)
          && $0.root.utf8.elementsEqual(reference.root.utf8)
          && $0.snapshot.source.utf8.elementsEqual(reference.snapshot.source.utf8)
      }
      guard !candidates.isEmpty,
        candidates.allSatisfy({
          $0.snapshot.revision.utf8.elementsEqual(reference.snapshot.revision.utf8)
            && $0.manifestHash.utf8.elementsEqual(reference.manifestHash.utf8)
        })
      else { throw CoreError.invalidState("catalog group changed dependency; refresh inspection") }
    }
    let expected = Dictionary(grouping: components, by: \.key)
    let actual = Dictionary(grouping: linked.components, by: \.key)
    for (key, requirements) in expected {
      let candidates = actual[key] ?? []
      if liveEditKeys.contains(key) {
        guard
          candidates.allSatisfy({
            if case .skill(_, .edit, _) = $0.payload { return true }
            return false
          })
        else {
          throw CoreError.invalidState("catalog live edit changed mode; refresh inspection")
        }
      }
      // Choosing Antigravity can derive additional inputs from the captured section snapshot.
      // The composed discovery fingerprint binds those inputs for preview and publication.
      let allowsDerivedIncludes = requirements.allSatisfy {
        !$0.resources.contains(where: \.antigravityInclude)
      }
      guard !candidates.isEmpty,
        try Set(requirements.map { try evidence($0) })
          == Set(
            candidates.map {
              try evidence($0, allowsDerivedIncludes: allowsDerivedIncludes)
            })
      else {
        throw CoreError.invalidState("catalog addition changed dependency; refresh inspection")
      }
    }
  }

  private func evidence(
    _ component: LinkedComponent, allowsDerivedIncludes: Bool = false
  ) throws -> Data {
    let editing = liveEditKeys.contains(component.key)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func snapshot(_ value: SourceSnapshotID) throws -> Data {
      try encoder.encode([
        value.source,
        editing && value.source.utf8.elementsEqual(component.snapshot.source.utf8)
          ? "live" : value.revision,
      ])
    }
    var fields = try [snapshot(component.snapshot), snapshot(component.declaringSnapshot)]
    for resource in component.resources {
      if allowsDerivedIncludes, resource.antigravityInclude,
        case .instruction(_, nil, _) = component.payload,
        component.recipients.contains(.antigravity), resource.snapshot == component.snapshot
      {
        continue
      }
      fields.append(
        try encoder.encode([
          snapshot(resource.snapshot), Data(resource.path.utf8), Data(resource.hash.utf8),
          encoder.encode(resource.executableFlags), encoder.encode(resource.artifact),
        ]))
    }
    // Root occurrence numbers and declaration positions differ after finite composition.
    // Complete producer dependency clauses remain distinct; their collection order is incidental.
    let dependencies = try Set(
      component.origins.map { origin in
        try encoder.encode(
          Set(
            origin.dependencies.filter {
              $0.revision != "live"
                && !(editing && $0.source.utf8.elementsEqual(component.snapshot.source.utf8))
            }.map(snapshot)
          ).sorted { $0.lexicographicallyPrecedes($1) })
      })
    fields.append(try encoder.encode(dependencies.sorted { $0.lexicographicallyPrecedes($1) }))
    return try encoder.encode(fields)
  }
}
