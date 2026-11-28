import AgentsCore
import Foundation

/// The standalone version 1 install policy. Parsing performs no filesystem or network reads.
public enum SourcePolicyDocument {
  public static func parse(_ bytes: Data, identity: DocumentIdentity) throws -> SourcePolicyRules {
    let reader: YAMLReader
    do {
      reader = try YAMLReader(bytes: Array(bytes), identity: identity)
    } catch let error as YAMLReadFailure {
      throw ManifestFailure(
        .init(code: "source-policy.yaml", message: "Invalid policy YAML.", span: error.span))
    }
    func failure(_ node: YAMLNode, _ message: String) -> ManifestFailure {
      ManifestFailure(
        .init(code: "source-policy.field", message: message, span: reader.span(of: node)))
    }
    func string(_ node: YAMLNode) -> String? {
      guard let scalar = node.scalar, !scalar.decimalTag,
        scalar.quoted || YAMLScalar.classify(scalar.text) == .string
      else { return nil }
      return scalar.text
    }
    func rules(_ node: YAMLNode) throws -> [SourceOrigin] {
      guard let items = node.items else { throw failure(node, "Expected a sequence of origins.") }
      return try items.map { item in
        if let name = string(item) {
          switch name {
          case "local": return .local
          case "inline": return .inline
          case "missing": return .missing
          default: throw failure(item, "Unknown source origin.")
          }
        }
        guard let pairs = item.pairs, pairs.count == 1,
          let kind = string(pairs[0].key), let value = string(pairs[0].value)
        else { throw failure(item, "Expected one Git, HTTP or local origin.") }
        switch kind {
        case "git":
          guard let origin = try? SourceOrigin.git(value) else {
            throw failure(pairs[0].value, "Invalid Git repository origin.")
          }
          return origin
        case "http":
          guard let origin = try? SourceOrigin.http(value) else {
            throw failure(pairs[0].value, "Invalid HTTP origin.")
          }
          return origin
        case "local":
          guard value.hasPrefix("/"), !value.contains("\0") else {
            throw failure(pairs[0].value, "Expected an absolute local path.")
          }
          return .local(path: value)
        default: throw failure(pairs[0].key, "Unknown source origin kind.")
        }
      }
    }
    guard let pairs = reader.root.pairs else {
      throw failure(reader.root, "Expected a policy mapping.")
    }
    var allow: [SourceOrigin]?
    var deny: [SourceOrigin] = []
    var hasVersion = false
    for (key, value) in pairs {
      switch string(key) {
      case "version":
        guard let scalar = value.scalar, !scalar.quoted, !scalar.decimalTag,
          YAMLScalar.integer(scalar.text) == 1
        else { throw failure(value, "Expected policy version 1.") }
        hasVersion = true
      case "allow": allow = try rules(value)
      case "deny": deny = try rules(value)
      default: throw failure(key, "Unknown source policy field.")
      }
    }
    guard hasVersion else { throw failure(reader.root, "Missing policy version.") }
    return SourcePolicyRules(allow: allow, deny: deny)
  }

  /// Produces a complete policy document for a caller-owned save operation.
  public static func bytes(for rules: SourcePolicyRules) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func list(_ label: String, _ origins: [SourceOrigin]) throws -> String {
      guard !origins.isEmpty else { return label + ": []\n" }
      return try label + ":\n"
        + origins.map { origin in
          if let locator = origin.policyLocator {
            let quoted = String(decoding: try encoder.encode(locator), as: UTF8.self)
            return "  - \(origin.kind.rawValue): \(quoted)\n"
          }
          return "  - \(origin.kind.rawValue)\n"
        }.joined()
    }
    var document = "version: 1\n"
    if let allow = rules.allow { document += try list("allow", allow) }
    if !rules.deny.isEmpty { document += try list("deny", rules.deny) }
    return Data(document.utf8)
  }
}

/// Captures the same bytes used for admission and publication, including absent scope policies.
package struct SourcePolicySnapshot: PreparedEvidence {
  package let effective: EffectiveSourcePolicy
  package let readDependencies: [ReadDependency]
  package let fingerprint: String
  private let inputs: [TargetPrecondition]
  private let sourceAccess: SourceAccessConfiguration

  package var isConfigured: Bool {
    effective.isConfigured || sourceAccess.settingsFingerprint != nil
  }

  package static func policyURL(in store: StateStore) -> URL {
    store.directory.appendingPathComponent(StateStore.sourcePolicyFileName)
  }

  package static func locations(in store: StateStore) -> [(SourcePolicyLayer.Scope, URL)] {
    let user = StateStore(scope: .user, environment: store.environment)
    var paths: [(SourcePolicyLayer.Scope, URL)] = [(.user, policyURL(in: user))]
    if store.scope == .project { paths.append((.project, policyURL(in: store))) }
    if let organization = store.environment.organizationSourcePolicyURL {
      paths.append((.organization, organization))
    }
    return paths
  }

  package init(store: StateStore) throws {
    sourceAccess = try store.environment.resolvedSourceAccess()
    var layers: [SourcePolicyLayer] = []
    var evidence: [TargetPrecondition] = []
    var records: [String: String] = [:]
    for (scope, url) in Self.locations(in: store) {
      guard url.isFileURL else { throw CoreError.invalidState("source policy requires a file URL") }
      let url = url.standardizedFileURL
      let captured = try TargetPrecondition.readingFile(url)
      evidence.append(captured.evidence)
      if let bytes = captured.bytes {
        let rules = try SourcePolicyDocument.parse(bytes, identity: DocumentIdentity(url.path))
        layers.append(.init(scope: scope, url: url, rules: rules))
        records[scope.rawValue + "\0" + url.path] = FileHash.sha256Hex(data: bytes)
      } else if scope == .organization {
        throw CoreError.notFound("organization source policy at " + url.path)
      }
    }
    inputs = evidence
    effective = EffectiveSourcePolicy(layers: layers)
    readDependencies =
      evidence.map { .entry($0.url) }
      + (sourceAccess.settingsURL.map { [.entry($0)] } ?? [])
    records["user-source-access"] = sourceAccess.settingsFingerprint
    fingerprint = try ResolvedLedgerCodec.digest(records)
    try validate()
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    try sourceAccess.requireCurrentSettings()
    // Source policy is an input even if a caller includes its path in a publication footprint.
    for input in inputs {
      if targets.isEmpty {
        try input.validate()
      } else {
        try input.validateDuringPublication()
      }
    }
  }
}
