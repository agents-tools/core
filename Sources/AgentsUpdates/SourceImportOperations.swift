import AgentsCore
import Components
import Foundation

public struct ImportSourceInspection: Sendable {
  public let alias: String
  public let document: String
  public let pointer: String
  public let declaration: SourceDeclaration?
  public let commit: String?
  public let version: String?
  public let integrityKind: String?
  public let integrity: String?
  public let requestedRef: String?
  public let resolvedRef: String?
  public let resolvedURL: String?
  public let developmentOnly: Bool
  public let producerPath: String?
  public let producerIdentity: String?
  public let registry: String?
}

public struct ImportComponentInspection: Sendable {
  public let document: String
  public let pointer: String
  public let declaration: ComponentDeclaration
}

public struct ImportDiagnosticInspection: Sendable {
  public let code: String
  public let document: String
  public let pointer: String
  public let span: SourceSpan?
  public let message: String
}

public struct ImportResourceInspection: Sendable {
  public let sourceAlias: String
  public let producerName: String
  public let path: String?
  public let hash: String?
  public let integrityKind: String?
  public let integrity: String?
  public let executableFlags: [String: Bool]
  public let requiresStandaloneSource: Bool
  public let selected: Bool
  public let requiresBindingRewrite: Bool
}

/// Producer claims remain evidence; they never grant ownership of an existing target.
public struct ImportDeploymentInspection: Sendable {
  public let document: String
  public let pointer: String
  public let sourceAlias: String?
  public let agent: String?
  public let scope: String?
  public let directory: String?
  public let files: [String]
}

public struct ImportBindingInspection: Sendable {
  public let document: String
  public let pointer: String
  public let reason: String
  public let environmentVariable: String?
  /// False means the explicit source/content must be corrected and inspected again.
  public let canResolveCanonicalSlot: Bool
}

public struct ImportSelectionInspection: Sendable {
  public let document: String
  public let pointer: String
  public let sourceAlias: String?
  public let kind: String
  public let values: [String]
  public let automatic: Bool
  public let developmentOnly: Bool
}

public struct ImportOrderedSourceInspection: Sendable {
  public let document: String
  public let pointer: String
  public let alias: String
  public let identity: String
  public let transport: String
  public let registry: String?
  public let requestedRef: String?
  public let skillsPath: String
  public let rulesPath: String
  public let skills: [String]?
  public let rules: [String]?
}

/// Handles are issued by one immutable inspection and cannot be constructed by consumers.
public struct ImportChoiceID: Hashable, Sendable {
  fileprivate let owner: UUID
  fileprivate let index: Int
}

public struct ImportInputID: Hashable, Sendable {
  fileprivate let owner: UUID
  fileprivate let index: Int
}

public struct ImportLocationInspection: Sendable {
  public let document: String
  public let pointer: String
  public let span: SourceSpan?
}

/// Effects from the adapter enumeration. Fixed contributions and unresolved inspection
/// requirements remain relevant when choosing any producer key.
public struct ImportSelectionEffects: Sendable {
  public let sources: [ImportSourceInspection]
  public let components: [ImportComponentInspection]
  public let resources: [ImportResourceInspection]
  public let diagnostics: [ImportDiagnosticInspection]
}

public struct ImportChoiceInspection: Sendable {
  public let id: ImportChoiceID
  public let label: String
  public let locations: [ImportLocationInspection]
  public let effects: ImportSelectionEffects
  /// Diagnostics emitted by this producer key. Fixed effects and global requirements also
  /// participate in admission; an empty list is not permission to publish preserved bytes.
  public var hasConversionDiagnostics: Bool { !effects.diagnostics.isEmpty }
}

public enum ImportInputKind: Sendable {
  case sourceCoordinates, explicitContent, bindingReference
}

/// A binding resolution carries a reference, never the credential value.
public enum ImportBindingReference: Sendable {
  case environment(String)
  case secret(String)
}

public struct ImportRequiredInput: Sendable {
  public let id: ImportInputID
  public let kind: ImportInputKind
  public let location: ImportLocationInspection
  public let suggestedReference: ImportBindingReference?
}

/// Source coordinates are accepted only for Git-coordinate requirements. Content paths
/// stay relative to the explicit input root and are re-read by the owning adapter.
public enum ImportInputValue: Sendable {
  case source(SourceDeclaration)
  case content(path: String)
  case binding(ImportBindingReference)
}

public struct ImportInputResolution: Sendable {
  public let id: ImportInputID
  public let value: ImportInputValue
  public init(id: ImportInputID, value: ImportInputValue) {
    self.id = id
    self.value = value
  }
}

private enum ImportResolutionTarget: Sendable {
  case adapter(ImportInputMetadata)
  case binding(String)
}

public struct SourceImportInspection: Sendable {
  public let format: String
  public let producerRevision: String?
  public let specificationStatus: String
  public let sources: [ImportSourceInspection]
  public let components: [ImportComponentInspection]
  public let diagnostics: [ImportDiagnosticInspection]
  public let resources: [ImportResourceInspection]
  public let deployments: [ImportDeploymentInspection]
  public let bindings: [ImportBindingInspection]
  public let selections: [ImportSelectionInspection]
  public let orderedSources: [ImportOrderedSourceInspection]
  public let readLocations: [URL]
  /// Actual adapter selection units; several component families can share one choice.
  public let availableChoices: [ImportChoiceInspection]
  /// Only supported missing inputs receive handles. Other requirements remain in bindings
  /// or diagnostics and require a corrected explicit input, followed by reinspection.
  public let requiredInputs: [ImportRequiredInput]
  /// Contributions emitted independently of the adapter selection, including preserved inputs.
  public let fixedEffects: ImportSelectionEffects
  private let owner: UUID
  private let choiceKeys: [String]
  private let resolutionTargets: [ImportResolutionTarget]
  private let preparation: ImportPreparation

  /// Merges selected canonical intent into the same captured full declaration. Unconverted
  /// semantics and required bindings must be resolved through supported inputs. Preserved
  /// resources requiring a binding rewrite need corrected content, even after slot resolution.
  public func updateRequest(in inspection: ScopeInspection) throws -> UpdateRequest {
    try preparation.validateConversion()
    var additions = Declaration()
    for source in preparation.proposal.sources {
      guard var imported = source.declaration else {
        throw CoreError.invalidState("import lacks exact canonical source coordinates")
      }
      if imported.kind == .local {
        let identity = try imported.identity(
          environment: RuntimeEnvironment(
            projectDirectory: preparation.input.root, homeDirectory: preparation.input.root,
            environment: [:]))
        imported.location = String(identity.dropFirst("local:".count))
        imported.environment = nil
      }
      additions.sourceDeclarations.append(.init(name: source.alias, source: imported))
    }
    additions.components = preparation.proposal.components.map(\.declaration)
    guard
      let discovery = try UpdateOperations.captureAddition(
        additions, in: inspection, importPreparation: preparation)
    else { throw CoreError.invalidState("import selection contains no new additions") }
    return discovery.updateRequest()
  }

  /// Revalidates the captured inputs, then reruns the same adapter with owner-issued choices.
  /// Nil choices preserve the current selection; an empty list uses the adapter's empty semantics.
  public func resolving(
    choices: [ImportChoiceID]? = nil, inputs: [ImportInputResolution] = []
  ) throws -> SourceImportInspection {
    _ = try preparation.capture(admitConversion: false)
    var input = preparation.input
    if let choices {
      guard Set(choices).count == choices.count,
        choices.allSatisfy({ $0.owner == owner && choiceKeys.indices.contains($0.index) })
      else { throw CoreError.invalidState("import choices belong to another inspection") }
      input.selection = Set(choices.map { choiceKeys[$0.index] })
    }
    guard Set(inputs.map(\.id)).count == inputs.count else {
      throw CoreError.invalidState("import input was supplied more than once")
    }
    for resolution in inputs {
      guard resolution.id.owner == owner, resolutionTargets.indices.contains(resolution.id.index)
      else { throw CoreError.invalidState("import input belongs to another inspection") }
      switch (resolutionTargets[resolution.id.index], resolution.value) {
      case (.adapter(let requirement), .source(let declaration))
      where requirement.kind == .gitSource:
        guard SourceImport.admitsSourceCoordinates(declaration) else {
          throw CoreError.invalidSource("import requires Git source coordinates")
        }
        input.sourceDeclarations[requirement.key] = declaration
      case (.adapter(let requirement), .content(let path))
      where requirement.kind == .installedContent:
        _ = try PathSafety.resolvedChild(base: input.root, subpath: path)
        input.installedSkills[requirement.key] = path
      case (.binding(let key), .binding(let reference)):
        let value: RuntimeBinding
        switch reference {
        case .environment(let name):
          guard !name.isEmpty,
            name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
          else { throw CoreError.invalidState("invalid symbolic environment reference") }
          value = .environment(name)
        case .secret(let name):
          guard !name.isEmpty,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
          else { throw CoreError.invalidState("invalid symbolic secret reference") }
          value = .secret(name)
        }
        input.bindingReferences[key] = value
      default: throw CoreError.invalidState("import input value has the wrong supported kind")
      }
    }
    return try SourceImportOperations.inspect(input)
  }

  init(
    _ proposal: SourceImportProposal, preparation: ImportPreparation,
    catalog: SourceImportProposal? = nil
  ) {
    self.preparation = preparation
    format = proposal.profile.rawValue
    producerRevision = proposal.profile.producerRevision
    specificationStatus = proposal.profile.specificationStatus
    sources = proposal.sources.map { s in
      .init(
        alias: s.alias, document: s.origin.document, pointer: s.origin.pointer,
        declaration: s.declaration, commit: s.pin.commit, version: s.pin.version,
        integrityKind: s.pin.integrity?.kind.rawValue, integrity: s.pin.integrity?.value,
        requestedRef: s.requestedRef, resolvedRef: s.resolvedRef, resolvedURL: s.resolvedURL,
        developmentOnly: s.developmentOnly, producerPath: s.producerPath,
        producerIdentity: s.producerIdentity, registry: s.registry)
    }
    components = proposal.components.map {
      .init(
        document: $0.origin.document,
        pointer: $0.origin.pointer, declaration: $0.declaration)
    }
    diagnostics = proposal.diagnostics.map {
      .init(
        code: $0.code.rawValue,
        document: $0.location.document, pointer: $0.location.pointer, span: $0.location.span,
        message: $0.message)
    }
    resources = proposal.resources.map {
      .init(
        sourceAlias: $0.sourceAlias,
        producerName: $0.producerName, path: $0.path, hash: $0.observedHash,
        integrityKind: $0.producerIntegrity?.kind.rawValue, integrity: $0.producerIntegrity?.value,
        executableFlags: $0.executableFlags, requiresStandaloneSource: $0.requiresStandaloneSource,
        selected: $0.selected, requiresBindingRewrite: $0.requiresBindingRewrite)
    }
    deployments = proposal.deployments.map {
      .init(
        document: $0.origin.document,
        pointer: $0.origin.pointer, sourceAlias: $0.sourceAlias, agent: $0.agent, scope: $0.scope,
        directory: $0.installDirectory, files: $0.files)
    }
    bindings = proposal.bindings.map {
      .init(
        document: $0.location.document,
        pointer: $0.location.pointer, reason: $0.reason,
        environmentVariable: $0.environmentVariable,
        canResolveCanonicalSlot: $0.canonicalSlot
      )
    }
    selections = proposal.selections.map {
      .init(
        document: $0.origin.document,
        pointer: $0.origin.pointer, sourceAlias: $0.sourceAlias, kind: $0.kind.rawValue,
        values: $0.values, automatic: $0.automatic, developmentOnly: $0.developmentOnly)
    }
    orderedSources = proposal.orderedSources.map {
      .init(
        document: $0.origin.document,
        pointer: $0.origin.pointer, alias: $0.alias, identity: $0.identity, transport: $0.transport,
        registry: $0.registry, requestedRef: $0.requestedRef, skillsPath: $0.skillsPath,
        rulesPath: $0.rulesPath, skills: $0.skills, rules: $0.rules)
    }
    readLocations = preparation.locations
    let issued = UUID()
    owner = issued
    choiceKeys = catalog?.choices.map(\.key) ?? []
    var targets: [ImportResolutionTarget] = []
    var requirements: [ImportRequiredInput] = []
    for item in proposal.requiredInputs {
      let index = targets.count
      targets.append(.adapter(item))
      requirements.append(
        .init(
          id: .init(owner: issued, index: index),
          kind: item.kind == .gitSource ? .sourceCoordinates : .explicitContent,
          location: .init(
            document: item.location.document, pointer: item.location.pointer,
            span: item.location.span),
          suggestedReference: nil))
    }
    for item in proposal.bindings {
      guard item.canonicalSlot, let key = item.key else { continue }
      let index = targets.count
      targets.append(.binding(key))
      requirements.append(
        .init(
          id: .init(owner: issued, index: index), kind: .bindingReference,
          location: .init(
            document: item.location.document, pointer: item.location.pointer,
            span: item.location.span),
          suggestedReference: item.environmentVariable.map(ImportBindingReference.environment)))
    }
    resolutionTargets = targets
    requiredInputs = requirements
    if let catalog {
      let view = SourceImportInspection(catalog, preparation: preparation)
      func effects(_ component: [Int], _ source: [Int], _ resource: [Int], _ diagnostic: [Int])
        -> ImportSelectionEffects
      {
        .init(
          sources: source.map { view.sources[$0] },
          components: component.map { view.components[$0] },
          resources: resource.map { view.resources[$0] },
          diagnostics: diagnostic.map { view.diagnostics[$0] })
      }
      availableChoices = catalog.choices.enumerated().map { index, choice in
        .init(
          id: .init(owner: issued, index: index), label: "Producer selection \(index + 1)",
          locations: choice.locations.map {
            .init(document: $0.document, pointer: $0.pointer, span: $0.span)
          },
          effects: effects(choice.components, choice.sources, choice.resources, choice.diagnostics))
      }
      let assignedComponents = Set(catalog.choices.flatMap(\.components))
      let assignedSources = Set(catalog.choices.flatMap(\.sources))
      let assignedResources = Set(catalog.choices.flatMap(\.resources))
      let assignedDiagnostics = Set(catalog.choices.flatMap(\.diagnostics))
      fixedEffects = effects(
        catalog.components.indices.filter { !assignedComponents.contains($0) },
        catalog.sources.indices.filter { !assignedSources.contains($0) },
        catalog.resources.indices.filter { !assignedResources.contains($0) },
        catalog.diagnostics.indices.filter { !assignedDiagnostics.contains($0) })
    } else {
      availableChoices = []
      fixedEffects = .init(
        sources: sources, components: components, resources: resources, diagnostics: diagnostics)
    }
  }
}

package struct ImportPreparation: Sendable {
  let input: SourceImportInput
  let proposal: SourceImportProposal
  let catalog: SourceImportProposal
  let documentFingerprint: String
  let locations: [URL]

  func validateConversion() throws {
    guard proposal.diagnostics.isEmpty, proposal.bindings.isEmpty else {
      throw CoreError.invalidState(
        "import has unresolved conversion diagnostics or binding requirements")
    }
    guard !proposal.resources.contains(where: { $0.selected && $0.requiresBindingRewrite }) else {
      throw CoreError.invalidState(
        "import preserved resources require corrected explicit content before publication")
    }
    guard
      !proposal.resources.contains(where: {
        $0.selected && $0.producerIntegrity != nil && $0.observedHash == nil
      })
    else {
      throw CoreError.invalidState(
        "import requires verified captured content for the producer integrity claim")
    }
  }

  func capture(admitConversion: Bool = true) throws -> [TargetPrecondition] {
    let document = try PathSafety.resolvedChild(base: input.root, subpath: input.document)
    let evidence = try TargetPrecondition(document)
    let inputs = try locations.map { try TargetPrecondition($0) }
    var enumeration = input
    enumeration.enumerateChoices = true
    enumeration.selection = nil
    guard try evidence.displayEvidence(includeContent: true) == documentFingerprint,
      try SourceImport.preview(input) == proposal, try SourceImport.preview(enumeration) == catalog
    else { throw CoreError.invalidState("import inputs changed; refresh the import inspection") }
    if admitConversion { try validateConversion() }
    try evidence.validate()
    for input in inputs { try input.validate() }
    return inputs
  }
}

public enum SourceImportOperations {
  /// Explicit pinned profile names are the importer owner's existing raw values. No ambient
  /// config discovery, execution, network access, deployment adoption or write occurs.
  public static func inspect(
    format: String, root: URL, document: String, selection: Set<String>? = nil,
    sourceDeclarations: [String: SourceDeclaration] = [:], installedSkills: [String: String] = [:]
  ) throws -> SourceImportInspection {
    guard let profile = SourceImportProfile(rawValue: format) else {
      throw CoreError.invalidSource("unknown source import profile")
    }
    let input = SourceImportInput(
      profile: profile, root: root, document: document,
      selection: selection, sourceDeclarations: sourceDeclarations, installedSkills: installedSkills
    )
    return try inspect(input)
  }

  static func inspect(_ input: SourceImportInput) throws -> SourceImportInspection {
    guard input.sourceDeclarations.values.allSatisfy(SourceImport.admitsSourceCoordinates) else {
      throw CoreError.invalidSource("import source coordinates are not admitted")
    }
    let root = input.root
    let document = input.document
    let installedSkills = input.installedSkills
    let url = try PathSafety.resolvedChild(base: root, subpath: document)
    let evidence = try TargetPrecondition(url)
    let fingerprint = try evidence.displayEvidence(includeContent: true)
    let proposal = try SourceImport.preview(input)
    var enumeration = input
    enumeration.selection = nil
    enumeration.enumerateChoices = true
    let catalog = try SourceImport.preview(enumeration)
    var locations = [url]
    for path in installedSkills.values {
      locations.append(try PathSafety.resolvedChild(base: root, subpath: path))
    }
    for source in (proposal.sources + catalog.sources).compactMap(\.declaration)
    where source.kind == .local {
      let environment =
        source.environment?.runtime ?? RuntimeEnvironment(projectDirectory: root, environment: [:])
      let identity = try source.identity(environment: environment)
      if identity.hasPrefix("local:") {
        locations.append(URL(fileURLWithPath: String(identity.dropFirst(6))))
      }
    }
    let preparation = ImportPreparation(
      input: input, proposal: proposal, catalog: catalog,
      documentFingerprint: fingerprint,
      locations: Array(Set(locations)).sorted { $0.path < $1.path })
    _ = try preparation.capture(admitConversion: false)
    return SourceImportInspection(proposal, preparation: preparation, catalog: catalog)
  }
}
