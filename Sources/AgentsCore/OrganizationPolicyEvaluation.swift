import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

package struct OrganizationPolicyLayer: Sendable {
  package let rules: OrganizationRules
  package let evidence: OrganizationPolicyDocumentEvidence

  package init(rules: OrganizationRules, evidence: OrganizationPolicyDocumentEvidence) {
    self.rules = rules
    self.evidence = evidence
  }
}

package struct OrganizationPolicyChain: Sendable {
  package let scope: InstallScope
  package let layers: [OrganizationPolicyLayer]
  package var mode: OrganizationPolicyMode { layers.map(\.rules.enforcement).max() ?? .off }

  package init(scope: InstallScope, layers: [OrganizationPolicyLayer]) {
    self.scope = scope
    self.layers = layers
  }

  var resolution: OrganizationRules.Resolution {
    let order: [OrganizationRules.Resolution] = [.block, .policyWins, .projectWins]
    return order.first { value in layers.contains { $0.rules.resolution == value } } ?? .projectWins
  }
}

package struct OrganizationPolicyIdentity: Equatable, Sendable {
  package let origin: SourceOrigin
  package let suffix: String?
  package let root: String?
  let spelling: String

  package init(_ origin: SourceOrigin, suffix: String? = nil, root: String? = nil) {
    self.origin = origin
    self.suffix = suffix
    self.root = root
    let location: String
    switch origin.kind {
    case .git:
      location = (origin.identity ?? "missing").components(separatedBy: "://").last!
    case .http:
      location = (origin.identity ?? "missing").components(separatedBy: "://").last!
    case .local:
      location = origin.identity.map { "local:" + $0 } ?? "local"
    case .inline: location = "inline"
    case .missing: location = "missing"
    }
    let subpath = root.flatMap { $0 == "." ? nil : $0 }.map { "/" + $0 } ?? ""
    let member = suffix.map { origin.kind == .inline ? "/" + $0 : "#" + $0 } ?? ""
    spelling = location + subpath + member
  }

  package init(_ node: MarketplaceNodeID) {
    self.init(node.catalog.origin, suffix: node.package, root: node.catalog.policyPath)
  }

  private init(spelling: String) {
    origin = .local
    suffix = nil
    root = nil
    self.spelling = spelling
  }

  package static func localBundle(_ name: String) -> Self { .init(spelling: "_local/" + name) }
  package var description: String { spelling }
  package var hasKnownOrigin: Bool { origin != .missing }

  package func matches(_ raw: String, exact: Bool = false, deny: Bool = false) -> Bool {
    if origin.kind == .local && raw == "local" { return !exact }
    var value = spelling
    var pattern = raw
    if origin.kind == .git || origin.kind == .http {
      pattern = raw.components(separatedBy: "://").last!
      let first = pattern.prefix(while: { $0 != "/" && $0 != "#" })
      let qualified = first.contains(".") || first.contains(":")
      let authority = value.prefix(while: { $0 != "/" && $0 != "#" })
      let host =
        authority.first == "["
        ? authority.split(separator: "]")[0] + "]"
        : Substring(authority.split(separator: ":").first ?? authority)
      if deny {
        if host != authority { value = String(host) + value.dropFirst(authority.count) }
        if qualified, let colon = first.lastIndex(of: ":"),
          first[first.index(after: colon)...].allSatisfy(\.isNumber)
        {
          pattern = String(first[..<colon]) + pattern.dropFirst(first.count)
        }
      }
      if origin.kind == .http, let schemeEnd = raw.range(of: "://"),
        !origin.identity!.hasPrefix(raw[..<schemeEnd.upperBound].lowercased())
      {
        return false
      }
      if origin.kind == .git {
        if exact && !qualified { pattern = "github.com/" + pattern }
        if !exact && !qualified {
          value = String(value.drop(while: { $0 != "/" }).dropFirst())
        }
        if host == "github.com" {
          var parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
          for index in parts.indices.prefix(qualified || exact ? 3 : 2) {
            if parts[index].contains("**") { break }
            let member = parts[index].split(
              separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let normalized =
              (member.first ?? "").lowercased() + (member.count == 2 ? "#" + member[1] : "")
            parts[index] = Substring(normalized)
          }
          pattern = parts.joined(separator: "/")
        }
      }
      if origin.kind == .http, !exact, !pattern.contains("/"), !pattern.contains("#") {
        value = String(value.prefix { $0 != "/" && $0 != "#" })
      }
      if qualified, let slash = pattern.firstIndex(of: "/") {
        pattern = pattern[..<slash].lowercased() + pattern[slash...]
      }
    }
    if exact { return value == pattern }
    return OrganizationPolicyEvaluator.glob(pattern, matches: value)
  }
}

/// Evaluation consumes admitted coordinates and facts and performs no I/O.
package struct OrganizationPolicyEvaluator: Sendable {
  package let chains: [OrganizationPolicyChain]
  package var active: Bool { chains.contains { $0.mode != .off } }
  package var blocksUnknownHTTPOrigins: Bool {
    chains.contains { chain in
      chain.mode == .block
        && chain.layers.contains {
          $0.rules.sourceAllow != nil || !$0.rules.sourceDeny.isEmpty
        }
    }
  }

  package var requiresRecordedGitOrigin: Bool {
    chains.contains { chain in
      chain.mode == .block
        && chain.layers.contains { layer in
          let rules = layer.rules
          return rules.sourceAllow != nil || !rules.sourceDeny.isEmpty
            || rules.dependencyAllow != nil || !rules.dependencyDeny.isEmpty
            || !rules.dependencyRequire.isEmpty || rules.marketplaceAllow != nil
            || rules.executableDenyAll || !rules.executableDeny.isEmpty
            || rules.mcpAllow != nil || !rules.mcpDeny.isEmpty
        }
    }
  }

  package init(chains: [OrganizationPolicyChain]) { self.chains = chains }

  package func findings(
    _ build: (OrganizationRules, Rules) -> [OrganizationPolicyFinding]
  ) -> [OrganizationPolicyFinding] {
    chains.flatMap { chain -> [OrganizationPolicyFinding] in
      guard chain.mode != .off else { return [] }
      return chain.layers.flatMap { layer in
        build(layer.rules, Rules(chain: chain, layer: layer))
      }
    }
  }

  package struct Rules {
    package let chain: OrganizationPolicyChain
    let layer: OrganizationPolicyLayer

    package func finding(
      _ subject: OrganizationPolicyFinding.Subject, _ identity: String, _ rule: String,
      _ message: String, pattern: String? = nil, path: [String] = [], advisory: Bool = false
    ) -> OrganizationPolicyFinding {
      .init(
        subject: subject, identity: identity, rule: rule, matchedPattern: pattern,
        dependencyPath: path, authority: chain.scope, document: layer.evidence.url,
        documentDigest: layer.evidence.digest, outcome: advisory ? .warn : chain.mode,
        message: message)
    }

    func admission(
      _ identity: OrganizationPolicyIdentity, subject: OrganizationPolicyFinding.Subject,
      allow: [String]?, deny: [String], path: [String]
    ) -> [OrganizationPolicyFinding] {
      if let pattern = deny.first(where: { identity.matches($0, deny: true) }) {
        return [
          finding(
            subject, identity.description, "\(subject.rawValue)-deny",
            "Matches a denied identity.", pattern: pattern, path: path)
        ]
      }
      if !identity.hasKnownOrigin && (allow != nil || !deny.isEmpty) {
        return [
          finding(
            subject, identity.description, "\(subject.rawValue)-unknown",
            "Origin is unavailable to verify the admission rule.", path: path)
        ]
      }
      if let allow, !allow.contains(where: { identity.matches($0) }) {
        return [
          finding(
            subject, identity.description, "\(subject.rawValue)-allow",
            "Does not match the document’s allow list.", path: path)
        ]
      }
      return []
    }
  }

  package func artifactOriginCheck(
    _ admit: @escaping @Sendable ([OrganizationPolicyFinding]) throws -> Void
  ) -> (@Sendable (SourceOrigin) throws -> Void)? {
    guard blocksUnknownHTTPOrigins else { return nil }
    return { origin in try admit(source(origin)) }
  }

  package func directSource(
    _ origin: SourceOrigin, root: String?, requirement: SourceRequirement?, reference: String
  ) -> [OrganizationPolicyFinding] {
    let identity = OrganizationPolicyIdentity(origin, root: root)
    let path = [reference]
    var result = source(origin, root: root, path: path) + packageIdentity(identity, path: path)
    if origin.kind == .git {
      let name = identity.description.split(separator: "/").last.map(String.init) ?? reference
      result += pinned(requirement, identity: identity, name: name, path: path)
    }
    return result
  }

  package func source(
    _ origin: SourceOrigin, root: String? = nil, path: [String] = []
  ) -> [OrganizationPolicyFinding] {
    let identity = OrganizationPolicyIdentity(origin, root: root)
    return findings { rules, context in
      context.admission(
        identity, subject: .source, allow: rules.sourceAllow, deny: rules.sourceDeny, path: path)
    }
  }

  package func packageIdentity(
    _ identity: OrganizationPolicyIdentity, catalog: OrganizationPolicyIdentity? = nil,
    path: [String] = [], requireAllow: Bool = true
  ) -> [OrganizationPolicyFinding] {
    let packageFindings = findings { rules, context in
      context.admission(
        identity, subject: .package, allow: requireAllow ? rules.dependencyAllow : nil,
        deny: rules.dependencyDeny, path: path)
    }
    return packageFindings + (catalog.map { catalogAdmission($0, for: identity, path: path) } ?? [])
  }

  package func catalogAdmission(
    _ catalog: OrganizationPolicyIdentity, for package: OrganizationPolicyIdentity? = nil,
    path: [String] = []
  ) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      var results: [OrganizationPolicyFinding] = []
      if let allow = rules.marketplaceAllow, !allow.contains(where: { catalog.matches($0) }) {
        results.append(
          context.finding(
            package == nil ? .source : .package, (package ?? catalog).description,
            "marketplace-allow",
            "Catalog does not match the document’s allow list.", path: path))
      }
      return results
        + context.admission(
          catalog, subject: .source, allow: rules.sourceAllow, deny: rules.sourceDeny, path: path)
    }
  }

  package func marketplace(
    _ id: MarketplaceNodeID, path: [String] = []
  ) -> [OrganizationPolicyFinding] {
    packageIdentity(
      .init(id), catalog: .init(id.catalog.origin, root: id.catalog.policyPath), path: path)
  }

  package func recordedBundlePackage(
    _ source: PortableSourceEvidence, path: [String]
  ) -> [OrganizationPolicyFinding] {
    guard let name = source.packageName else { return [] }
    let origin = source.policyOrigin
    let identity =
      origin == .local
      ? OrganizationPolicyIdentity.localBundle(name)
      : .init(origin, suffix: name, root: source.root)
    var findings = packageIdentity(
      identity, catalog: .init(origin, root: source.root), path: path)
    if origin.kind == .local, origin.identity != nil {
      findings += packageIdentity(.localBundle(name), path: path, requireAllow: false)
    }
    return findings
  }

  package func depth(_ depth: Int, path: [String]) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      guard let limit = rules.maximumDepth, depth > limit else { return [] }
      return [
        context.finding(
          .package, path.last ?? "dependency graph", "dependency-depth",
          "Dependency depth \(depth) exceeds \(limit).", path: path)
      ]
    }
  }

  package func pinned(
    _ requirement: SourceRequirement?, identity: OrganizationPolicyIdentity, name: String,
    path: [String] = []
  ) -> [OrganizationPolicyFinding] {
    if let requirement, requirement.isPolicyBounded(packageName: name) { return [] }
    return findings { rules, context in
      guard rules.pinnedConstraint else { return [] }
      return [
        context.finding(
          .package, identity.description, "dependency-pinned-constraint",
          "The authored constraint does not bound the selected version.", path: path)
      ]
    }
  }

  package func mcp(
    _ identity: OrganizationPolicyIdentity, transport: String?, selfDefined: Bool,
    transitive: Bool, path: [String] = [], legacyRegistry: Bool = false
  ) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      var results = context.admission(
        identity, subject: .mcp, allow: rules.mcpAllow, deny: rules.mcpDeny, path: path)
      if transitive, rules.mcpTrustTransitive == false,
        !(rules.mcpAllow?.contains(where: { identity.matches($0) }) ?? false)
      {
        results.append(
          context.finding(
            .mcp, identity.description, "mcp-transitive",
            "Transitive server needs an explicit allow rule.", path: path))
      }
      if let allowed = rules.mcpTransportAllow, !(transport.map(allowed.contains) ?? false) {
        results.append(
          context.finding(
            .mcp, identity.description, "mcp-transport",
            transport.map { "Transport \($0) is outside the allow list." }
              ?? "Effective transport is unavailable.", path: path))
      }
      if legacyRegistry,
        rules.mcpAllow?.contains(where: { identity.matches($0) }) == true
          || rules.mcpRequire.contains(where: { identity.matches($0, exact: true) })
          || rules.mcpSelfDefined == .deny
      {
        results.append(
          context.finding(
            .mcp, identity.description, "mcp-registry-evidence",
            MCPRegistryEvidence.reselectionMessage, path: path))
      } else if selfDefined || legacyRegistry, let action = rules.mcpSelfDefined, action != .allow {
        results.append(
          context.finding(
            .mcp, identity.description, "mcp-self-defined",
            legacyRegistry ? MCPRegistryEvidence.reselectionMessage : "The server is self-defined.",
            path: path, advisory: action == .warn))
      }
      return results
    }
  }

  package func unverifiedMCP(
    in identity: OrganizationPolicyIdentity, component: String
  ) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      guard
        rules.mcpAllow != nil || !rules.mcpDeny.isEmpty || rules.mcpTransportAllow != nil
          || rules.mcpTrustTransitive == false || rules.mcpSelfDefined == .deny
      else { return [] }
      return [
        context.finding(
          .mcp, identity.description, "mcp-opaque",
          "The lock cannot verify servers within native plugin \(component).")
      ]
    }
  }

  package func executable(
    _ identity: OrganizationPolicyIdentity, name: String, unknown: Bool = false,
    legacyRegistry: Bool = false
  ) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      let match = rules.executableDeny.first { identity.matches($0, deny: true) }
      let unknownOrigin = !identity.hasKnownOrigin && !rules.executableDeny.isEmpty
      guard rules.executableDenyAll || match != nil || unknownOrigin else { return [] }
      return [
        context.finding(
          .executable, identity.description, "executables-deny",
          legacyRegistry
            ? MCPRegistryEvidence.reselectionMessage
            : unknown || unknownOrigin
              ? "Executable contents or origin of \(name) cannot be verified."
              : "Executable deployment of \(name) exceeds the organization ceiling.",
          pattern: match)
      ]
    }
  }

  /// A policy override narrows catalog candidates. A preview and locked audit retain the
  /// authored constraint and use the same comparison to detect a conflict.
  package func version(
    _ version: String?, identity: OrganizationPolicyIdentity, authored: [SourceRequirement],
    available: Bool = true, path: [String] = []
  ) -> [OrganizationPolicyFinding] {
    findings { rules, context in
      guard context.chain.resolution != .projectWins || authored.isEmpty else { return [] }
      return rules.dependencyRequire.compactMap { requirement in
        guard identity.matches(requirement.identity, exact: true),
          let constraint = requirement.version,
          !available || !(version.map(constraint.admitsMarketplaceVersion) ?? false)
        else { return nil }
        return context.finding(
          .package, identity.description, "dependency-required-version",
          available
            ? "Selected version must satisfy \(constraint.marketplaceDescription)."
            : "No eligible version satisfies \(constraint.marketplaceDescription).",
          pattern: requirement.identity, path: path)
      }
    }
  }

  package func marketplaceRequirements(
    for id: MarketplaceNodeID
  ) -> (constraints: [SourceRequirement], overrides: Bool) {
    requirements(for: .init(id))
  }

  package func requirements(
    for identity: OrganizationPolicyIdentity
  ) -> (constraints: [SourceRequirement], overrides: Bool) {
    var constraints: [SourceRequirement] = []
    var overrides = false
    var forbidsOverride = false
    for chain in chains where chain.mode == .block && chain.resolution != .projectWins {
      let matches = chain.layers.flatMap(\.rules.dependencyRequire).compactMap {
        identity.matches($0.identity, exact: true) ? $0.version : nil
      }
      if !matches.isEmpty {
        constraints += matches.filter { !constraints.contains($0) }
        overrides = overrides || chain.resolution == .policyWins
        forbidsOverride = forbidsOverride || chain.resolution == .block
      }
    }
    return (constraints, overrides && !forbidsOverride)
  }

  package static func glob(_ pattern: String, matches value: String) -> Bool {
    let rule = pattern.split(separator: "/", omittingEmptySubsequences: false)
    let path = value.split(separator: "/", omittingEmptySubsequences: false)
    var ends: Set<Int> = [0]
    for segment in rule {
      if segment == "**" {
        guard let first = ends.min() else { return false }
        ends = Set(first...path.count)
      } else {
        ends = Set(
          ends.compactMap { index in
            guard index < path.count, fnmatch(String(segment), String(path[index]), 0) == 0
            else { return nil }
            return index + 1
          })
      }
      if ends.isEmpty { return false }
    }
    return ends.contains(path.count)
  }
}

extension SourceRequirement {
  fileprivate func isPolicyBounded(packageName: String) -> Bool {
    switch self {
    case .branch: return false
    case .revision(let raw):
      if SourceCache.isObjectID(raw) || SemanticVersion(raw) != nil { return true }
      let tag = raw.hasPrefix("refs/tags/") ? String(raw.dropFirst(10)) : raw
      if SemanticVersion(tag) != nil { return true }
      for prefix in [packageName + "-v", packageName + "--v"] where tag.hasPrefix(prefix) {
        if SemanticVersion(String(tag.dropFirst(prefix.count))) != nil { return true }
      }
      guard let separator = tag.lastIndex(of: "@"), separator != tag.startIndex else {
        return false
      }
      let name = tag[..<separator]
      let segments = name.split(separator: "/", omittingEmptySubsequences: false)
      return
        (segments.count == 1 && !name.hasPrefix("@")
        || segments.count == 2 && name.hasPrefix("@") && segments[0].count > 1
          && !segments[1].isEmpty)
        && !name.dropFirst().contains("@")
        && SemanticVersion(String(tag[tag.index(after: separator)...])) != nil
    default:
      return (try? validate()) != nil
    }
  }
}

extension MCPTransportDeclaration {
  package var organizationPolicyName: String {
    switch self {
    case .stdio: "stdio"
    case .streamableHTTP: "streamable-http"
    case .sse: "sse"
    }
  }
}

extension MCPRegistryEvidence {
  package var organizationPolicyIdentity: OrganizationPolicyIdentity {
    let location = URLComponents(string: registry)?.path
    let root = location.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    return .init(
      (try? .http(registry)) ?? .missing, suffix: server, root: root?.isEmpty == false ? root : nil)
  }
}
