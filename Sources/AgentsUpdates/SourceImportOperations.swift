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

public struct SourceImportInspection: Sendable {
  public let format: String
  public let producerRevision: String
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
  private let preparation: ImportPreparation

  /// Merges selected canonical intent into the same captured full declaration. Unconverted
  /// semantics and required bindings must be resolved by another explicit input selection.
  public func updateRequest(in inspection: ScopeInspection) throws -> UpdateRequest {
    guard !inspection.recovery.pending, var declaration = inspection.declaration else {
      throw CoreError.invalidState("inspect the committed scope before preparing an import")
    }
    guard diagnostics.isEmpty, bindings.isEmpty else {
      throw CoreError.invalidState(
        "import has unresolved conversion diagnostics or binding requirements")
    }
    guard
      !preparation.proposal.resources.contains(where: {
        $0.selected && $0.producerIntegrity != nil && $0.observedHash == nil
      })
    else {
      throw CoreError.invalidState(
        "import requires verified captured content for the producer integrity claim")
    }
    for source in preparation.proposal.sources {
      guard let imported = source.declaration else {
        throw CoreError.invalidState("import lacks exact canonical source coordinates")
      }
      if let existing = declaration.sources[source.alias], existing != imported {
        throw CoreError.invalidState(
          "import source alias conflicts with the captured declaration: " + source.alias)
      }
      declaration.sources[source.alias] = imported
    }
    for component in preparation.proposal.components
    where !declaration.components.contains(component.declaration) {
      declaration.components.append(component.declaration)
    }
    var request = UpdateRequest(
      operation: .declaration(declaration),
      expectedDeclarationDigest: inspection.document?.digest ?? "absent")
    request.importPreparation = preparation
    return request
  }

  init(_ proposal: SourceImportProposal, preparation: ImportPreparation) {
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
        selected: $0.selected)
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
        pointer: $0.location.pointer, reason: $0.reason, environmentVariable: $0.environmentVariable
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
  }
}

package struct ImportPreparation: Sendable {
  let input: SourceImportInput
  let proposal: SourceImportProposal
  let documentFingerprint: String
  let locations: [URL]

  func capture() throws -> [TargetPrecondition] {
    let document = try PathSafety.resolvedChild(base: input.root, subpath: input.document)
    let evidence = try TargetPrecondition(document)
    let inputs = try locations.map { try TargetPrecondition($0) }
    guard try evidence.displayEvidence(includeContent: true) == documentFingerprint,
      try SourceImport.preview(input) == proposal
    else { throw CoreError.invalidState("import inputs changed; refresh the import inspection") }
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
    let url = try PathSafety.resolvedChild(base: root, subpath: document)
    let evidence = try TargetPrecondition(url)
    let fingerprint = try evidence.displayEvidence(includeContent: true)
    let proposal = try SourceImport.preview(input)
    var locations = [url]
    for path in installedSkills.values {
      locations.append(try PathSafety.resolvedChild(base: root, subpath: path))
    }
    for source in proposal.sources.compactMap(\.declaration) where source.kind == .local {
      let environment =
        source.environment?.runtime ?? RuntimeEnvironment(projectDirectory: root, environment: [:])
      let identity = try source.identity(environment: environment)
      if identity.hasPrefix("local:") {
        locations.append(URL(fileURLWithPath: String(identity.dropFirst(6))))
      }
    }
    let preparation = ImportPreparation(
      input: input, proposal: proposal,
      documentFingerprint: fingerprint,
      locations: Array(Set(locations)).sorted { $0.path < $1.path })
    _ = try preparation.capture()
    return SourceImportInspection(proposal, preparation: preparation)
  }
}
