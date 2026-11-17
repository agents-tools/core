import AgentsCore
import Foundation

/// Fixed input formats grounded in upstream source revisions or producer documentation.
package enum SourceImportProfile: String, Sendable {
  case rulesyncSourcesV1, rulesyncNpmV1, vercelProjectV2, vercelUserV3
  case apmManifest, apmLock, rulesyncConfig, rulesyncGitHubV1, rulesyncAPMV1
  case claudeSettingsV1, codexConfigV1, cursorMCPV1, geminiSettingsV1, openCodeConfigV2
  case claudePluginV1, cursorPluginV1, geminiExtensionV1, claudeMarketplaceV1
  case claudeCommandV1, claudeAgentV1, geminiCommandV1, geminiAgentV1
  case openCodeCommandV2, openCodeAgentV2, cursorCommandV1, cursorAgentV1
  case geminiIgnoreV1, cursorIgnoreV1

  package var specificationStatus: String {
    switch self {
    case .apmManifest, .apmLock: "APM working-draft profile; schema amendments are unratified"
    case .rulesyncSourcesV1, .rulesyncNpmV1, .rulesyncConfig, .rulesyncGitHubV1, .rulesyncAPMV1,
      .vercelProjectV2, .vercelUserV3:
      "Pinned producer implementation format"
    case .codexConfigV1: "Pinned Codex source format"
    case .geminiSettingsV1, .geminiExtensionV1, .geminiCommandV1, .geminiAgentV1, .geminiIgnoreV1:
      "Pinned Gemini CLI source format"
    case .openCodeConfigV2, .openCodeCommandV2, .openCodeAgentV2:
      "Pinned OpenCode source format"
    case .claudeSettingsV1, .claudePluginV1, .claudeMarketplaceV1, .claudeCommandV1, .claudeAgentV1:
      "Documented Claude Code format (https://code.claude.com/docs); upstream source revision unavailable"
    case .cursorMCPV1, .cursorPluginV1, .cursorCommandV1, .cursorAgentV1, .cursorIgnoreV1:
      "Documented Cursor format (https://cursor.com/docs); upstream source revision unavailable"
    }
  }

  /// Exact upstream source revision when available. Documentation-only profiles have no commit.
  package var producerRevision: String? {
    switch self {
    case .rulesyncSourcesV1, .rulesyncNpmV1, .rulesyncConfig, .rulesyncGitHubV1, .rulesyncAPMV1:
      "fbe4fe58334cab4e84b87f20d730d6450a35e0f7"
    case .apmManifest, .apmLock:
      "787a97cc52fbbcc344374e1567b2a1e5b8adf441"
    case .vercelProjectV2, .vercelUserV3:
      "e781cb4d07433dfe1d19e924ed45cc61738c55ec"
    case .codexConfigV1:
      "092d3acd6bec3e3a14bdc7e7a2810ab628ab759d"
    case .geminiSettingsV1, .geminiExtensionV1, .geminiCommandV1, .geminiAgentV1, .geminiIgnoreV1:
      "5a5c7180ff3f0a02511f54b54db7f228d4982a30"
    case .openCodeConfigV2, .openCodeCommandV2, .openCodeAgentV2:
      "fedc6f208aa2bd54c1019227214568083f6380ad"
    case .claudeSettingsV1, .claudePluginV1, .claudeMarketplaceV1, .claudeCommandV1, .claudeAgentV1,
      .cursorMCPV1, .cursorPluginV1, .cursorCommandV1, .cursorAgentV1, .cursorIgnoreV1:
      nil
    }
  }
}

package struct ImportLocation: Hashable, Sendable {
  package let document: String
  /// Object-map entries use sorted member ordinals, so credential-bearing keys are never echoed.
  package let pointer: String
  package var span: SourceSpan? = nil

  func appending(_ field: String) -> Self {
    .init(document: document, pointer: pointer + "/" + field, span: span)
  }
}

package struct SourceImportDiagnostic: Equatable, Sendable {
  package enum Code: String, Sendable {
    case invalidInput, unsupportedVersion, unconverted, incompletePin, ambiguousSource
    case unsafePath, credentialBinding, integrityMismatch, missingResource
  }
  package let code: Code
  package let location: ImportLocation
  /// Messages describe fields and semantics; they never interpolate imported values.
  package let message: String
}

package struct ImportBindingRequirement: Equatable, Sendable {
  package let location: ImportLocation
  package let reason: String
  /// Symbolic producer binding only; the process environment is never read.
  package var environmentVariable: String? = nil
  /// Identifier used by RuntimeBinding.secret; the literal remains outside the proposal.
  package var key: String? = nil
  package var canonicalSlot = false
}

package struct ImportPin: Equatable, Sendable {
  package enum IntegrityKind: String, Sendable {
    case rulesyncSHA256, npmSRI, vercelInstalledSHA256, githubTree, apmDigest
  }
  package struct Integrity: Equatable, Sendable {
    package let kind: IntegrityKind
    package let value: String

    package init(kind: IntegrityKind, value: String) {
      self.kind = kind
      self.value = value
    }
  }
  package var commit: String?
  package var version: String?
  package var integrity: Integrity?
}

package struct ImportedSource: Equatable, Sendable {
  package let alias: String
  package let origin: ImportLocation
  package let declaration: SourceDeclaration?
  package let pin: ImportPin
  package let requestedRef: String?
  package let resolvedRef: String?
  package let resolvedURL: String?
  package let developmentOnly: Bool
  package let producerPath: String?
  package let producerIdentity: String?
  package let registry: String?

  init(
    alias: String, origin: ImportLocation, declaration: SourceDeclaration?, pin: ImportPin,
    requestedRef: String?, producerPath: String?, producerIdentity: String? = nil,
    registry: String? = nil, resolvedRef: String? = nil, resolvedURL: String? = nil,
    developmentOnly: Bool = false
  ) {
    self.alias = alias
    self.origin = origin
    self.declaration = declaration
    self.pin = pin
    self.requestedRef = requestedRef
    self.resolvedRef = resolvedRef
    self.resolvedURL = resolvedURL
    self.developmentOnly = developmentOnly
    self.producerPath = producerPath
    self.producerIdentity = producerIdentity
    self.registry = registry
  }
}

package struct ImportMemberCoordinate: Equatable, Sendable {
  package let containerRoot: String
  package let selector: ComponentReferenceDeclaration
  package let profile: SourceImportProfile
  package let formatVersion: Int

  /// Producer identifiers are byte identities, including canonically equivalent Unicode names.
  package static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.containerRoot.utf8.elementsEqual(rhs.containerRoot.utf8),
      lhs.profile == rhs.profile, lhs.formatVersion == rhs.formatVersion
    else { return false }
    switch (lhs.selector, rhs.selector) {
    case (.skill(let left), .skill(let right)),
      (.instruction(let left), .instruction(let right)),
      (.mcpServer(let left), .mcpServer(let right)),
      (.hook(let left), .hook(let right)),
      (.subagent(let left), .subagent(let right)),
      (.command(let left), .command(let right)),
      (.lspServer(let left), .lspServer(let right)),
      (.permissions(let left), .permissions(let right)),
      (.ignore(let left), .ignore(let right)),
      (.plugin(let left), .plugin(let right)):
      return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }
}

package struct ImportedComponent: Equatable, Sendable {
  /// The original producer document, including inline declarations and referenced files.
  package let origin: ImportLocation
  package let declaration: ComponentDeclaration
  package var member: ImportMemberCoordinate? = nil
}

/// This is a preservation intention, not a retained object or an adoption receipt. E must freeze
/// independent authoring content before any target containing these bytes can be overwritten.
package struct ImportResourceProposal: Equatable, Sendable {
  package let origin: ImportLocation
  package let sourceAlias: String
  package let producerName: String
  /// Relative to the corresponding source root. Nil means exact producer coordinates are absent.
  package let path: String?
  package let producerIntegrity: ImportPin.Integrity?
  package var observedHash: String?
  package let executableFlags: [String: Bool]
  package let requiresStandaloneSource: Bool
  package var kind: DeclaredComponentKind? = nil
  package var selected = true
  /// E must reconstruct symbolic fields and keep the original freshness preimage private.
  package var requiresBindingRewrite = false
}

/// Producer package identity is provenance, not a component, source pin or deployment choice.
package struct ImportPackageMetadata: Equatable, Sendable {
  package let name: String
  package let version: String
  package let nameLocation: ImportLocation
  package let versionLocation: ImportLocation
}

/// Canonical intent and evidence only. Raw documents and literal credentials never escape parsing.
/// Application, target ownership and adoption belong to the shared import lifecycle.
package struct SourceImportProposal: Equatable, Sendable {
  package let profile: SourceImportProfile
  package var packageMetadata: ImportPackageMetadata? = nil
  package var sources: [ImportedSource] = []
  package var components: [ImportedComponent] = []
  package var resources: [ImportResourceProposal] = []
  package var diagnostics: [SourceImportDiagnostic] = []
  package var bindings: [ImportBindingRequirement] = []
  package var selections: [ImportProducerSelection] = []
  package var deployments: [ImportDeploymentEvidence] = []
  package var orderedSources: [ImportOrderedSource] = []
  package var choices: [ImportChoiceMetadata] = []
  package var requiredInputs: [ImportInputMetadata] = []
  package var preservationBindings: [ImportLocation] = []
}

package struct SourceImportInput: Sendable {
  package let profile: SourceImportProfile
  /// Caller-selected read boundary. Consuming preparation owns source stability and freshness.
  package let root: URL
  package let document: String
  /// Nil selects every entry; empty selects none. JSON maps use producer keys, YAML lists use
  /// decimal ordinals, and rulesync config sources use their explicit source selector.
  package var selection: Set<String>? = nil
  package var enumerateChoices = false
  package var bindingReferences: [String: RuntimeBinding] = [:]
  /// Source lock keys do not reliably identify a transport/provider. These are explicit input,
  /// normally supplied by the config adapter, and never inferred from a normalized lock key.
  package var sourceDeclarations: [String: SourceDeclaration] = [:]
  /// Actual content is read only from these explicitly supplied, input-root-relative paths.
  package var installedSkills: [String: String] = [:]

  package init(
    profile: SourceImportProfile, root: URL, document: String, selection: Set<String>? = nil,
    sourceDeclarations: [String: SourceDeclaration] = [:], installedSkills: [String: String] = [:]
  ) {
    self.profile = profile
    self.root = root
    self.document = document
    self.selection = selection
    self.sourceDeclarations = sourceDeclarations
    self.installedSkills = installedSkills
  }
}

package struct SourceImportLimits: Sendable {
  package var documentBytes = 16 * 1024 * 1024
  package var nodes = 200_000
  package var depth = 64
  package var resourceBytes = 64 * 1024 * 1024
  package var resourceEntries = 20_000
  package init() {}
}

/// Producer intent is retained independently of canonical installation conditions.
package struct ImportProducerSelection: Equatable, Sendable {
  package enum Kind: String, Sendable { case includes, targets, skills, rules }
  package let origin: ImportLocation
  package let sourceAlias: String?
  package let kind: Kind
  package let values: [String]
  package let automatic: Bool
  package let developmentOnly: Bool
}

/// These are third-party deployment claims, never canonical ownership or adoption receipts.
package struct ImportDeploymentEvidence: Equatable, Sendable {
  package let origin: ImportLocation
  package let sourceAlias: String?
  package let agent: String?
  package let scope: String?
  package let installDirectory: String?
  package let files: [String]
}

/// Declaration order governs remote source collisions, independently of lock-map order.
package struct ImportOrderedSource: Equatable, Sendable {
  package let origin: ImportLocation
  package let alias: String
  package let identity: String
  package let transport: String
  package let registry: String?
  package let requestedRef: String?
  package let skillsPath: String
  package let rulesPath: String
  package let skills: [String]?
  package let rules: [String]?
}

package struct ImportChoiceMetadata: Equatable, Sendable {
  package let key: String
  package var locations: [ImportLocation]
  package var components: [Int] = []
  package var sources: [Int] = []
  package var resources: [Int] = []
  package var diagnostics: [Int] = []
}

package struct ImportInputMetadata: Equatable, Sendable {
  package enum Kind: String, Sendable { case gitSource, installedContent }
  package let kind: Kind
  package let key: String
  package let location: ImportLocation
}
