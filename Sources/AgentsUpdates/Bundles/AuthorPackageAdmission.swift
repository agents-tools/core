import AgentsCore
import AgentsInstructions
import AgentsManifest
import Foundation

struct AuthorPackagePolicy {
  let source: SourcePolicySnapshot
  let organization: OrganizationPolicySnapshot
  let registrySchemas: [MCPRegistryServer]

  init(
    _ environment: RuntimeEnvironment, scope: InstallScope = .project,
    registrySchemas: [MCPRegistryServer] = []
  ) throws {
    let store = StateStore(scope: scope, environment: environment)
    source = try SourcePolicySnapshot(store: store)
    organization = try OrganizationPolicySnapshot(store: store)
    self.registrySchemas = registrySchemas
    try organization.admit()
  }

  @discardableResult
  func admit(_ package: BundlePackage) throws -> [OrganizationPolicyFinding] {
    try package.validate()
    let evaluator = organization.evaluator
    var findings = evaluator.packageIdentity(.localBundle(package.name), requireAllow: false)
    for dependency in package.dependencies ?? [] {
      if let catalog = dependency.catalog {
        let origin = try catalog.policyOrigin(environment: RuntimeEnvironment(environment: [:]))
        try source.effective.require(origin, reference: dependency.package)
        findings += evaluator.packageIdentity(
          .init(origin, suffix: dependency.package, root: catalog.policyPath),
          catalog: .init(origin, root: catalog.policyPath))
      } else {
        findings += evaluator.packageIdentity(.localBundle(dependency.package), requireAllow: false)
      }
    }
    try organization.admit(findings)
    return findings
  }

  func admitCatalog(_ url: URL, package: BundlePackage) throws {
    try AuthorPackageOperations.requireLocalFileURL(url)
    let origin = SourceOrigin.local(at: url)
    try source.effective.require(origin, reference: package.name)
    let evaluator = organization.evaluator
    let identity = OrganizationPolicyIdentity(origin, suffix: package.name)
    var findings = evaluator.packageIdentity(
      identity, catalog: .init(origin), requireAllow: false)
    for requirement in package.dependencies ?? [] where requirement.catalog == nil {
      findings += evaluator.packageIdentity(
        .init(origin, suffix: requirement.package), catalog: .init(origin))
    }
    try organization.admit(findings)
  }

  @discardableResult
  func admit(
    _ evidence: [BundleSourceEvidence], member: String
  ) throws -> [OrganizationPolicyFinding] {
    let evaluator = organization.evaluator
    var results: [OrganizationPolicyFinding] = []
    for source in evidence {
      let origin = source.policyOrigin
      try self.source.effective.require(origin, reference: member)
      results += evaluator.source(origin, root: source.root, path: [member])
      if source.packageName != nil {
        results += evaluator.recordedBundlePackage(source, path: [member])
      } else if origin.kind != .inline {
        results += evaluator.packageIdentity(
          .init(origin, root: source.root), path: [member], requireAllow: false)
      }
    }
    try organization.admit(results)
    return results
  }

  func admit(_ archive: BundleArchive) throws -> [OrganizationPolicyFinding] {
    var findings = try admit(archive.manifest.package)
    for item in archive.manifest.components {
      try Task.checkCancellation()
      try AuthorContentAudit.validatePaths(item.entries)
      try AuthorContentAudit.validateReferences(item, objects: archive.contentObjects)
      let sources = try item.installationSources()
      findings += try admit(sources, member: item.name)
      if item.kind == .mcpServer {
        let transport = try item.transport()
        guard try item.forSharing(registrySchemas: registrySchemas).omissions == 0 else {
          throw CoreError.invalidSource("archive includes MCP credential literals: " + item.name)
        }
        for origin in item.mcpRegistry?.origins ?? [] {
          try source.effective.require(origin, reference: item.name)
          findings += organization.evaluator.source(origin, path: [item.name])
        }
        let inline = sources.contains { $0.policyOrigin == .inline }
        let identity =
          item.mcpRegistry?.organizationPolicyIdentity
          ?? .init(inline ? .inline : sources[0].policyOrigin, suffix: item.name)
        findings += organization.evaluator.mcp(
          identity, transport: transport.organizationPolicyName, selfDefined: inline,
          transitive: !inline, path: [item.name],
          legacyRegistry: item.mcpRegistry.map { $0.invocationDigest == nil } ?? false)
      }
      if item.entries.contains(where: \.executable) {
        for origin in Set(sources.map(\.policyOrigin)).sorted(by: {
          $0.description < $1.description
        }) {
          findings += organization.evaluator.executable(.init(origin), name: item.name)
        }
      }
    }
    try organization.admit(findings)
    return organization.report(findings).findings
  }

  func validate() throws {
    try source.validate()
    try organization.validate()
  }
}

struct AuthorContentAudit {
  private(set) var findings: [ContentAuditFinding] = []

  static func requirePublishable(_ path: String) throws {
    for component in path.split(separator: "/") {
      let name = component.lowercased()
      if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".pem")
        || name.hasSuffix(".key") || ["id_rsa", "id_ed25519", ".netrc", ".npmrc"].contains(name)
      {
        throw CoreError.invalidSource("credential file refused: " + path)
      }
      if [".git", ".svn", ".hg", ".aws", ".ssh", ".gnupg", ".codex", ".claude"].contains(name) {
        throw CoreError.invalidSource("private state path refused: " + path)
      }
    }
  }

  static func validatePaths(_ entries: [LedgerEntry]) throws {
    var names: Set<String> = []
    for entry in entries {
      try Task.checkCancellation()
      try requirePublishable(entry.path)
      let path = entry.path.folding(
        options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
      ).precomposedStringWithCanonicalMapping
      guard names.insert(path).inserted else {
        throw CoreError.invalidSource("colliding portable output paths")
      }
    }
  }

  static func references(in text: String, at path: String, confinedTo root: String) throws
    -> [String]
  {
    let depth = root.split(separator: "/").count
    let directory = path.split(separator: "/").dropLast().map(String.init)
    return try Instructions.localLinks(in: text).map { link in
      guard let target = link.path, !target.isEmpty, !target.hasPrefix("/"),
        !link.destination.lowercased().hasPrefix("file:"),
        !target.contains("\\"), !target.utf8.contains(0)
      else { throw CoreError.unsafePath("nonportable reference in " + path) }
      var parts = directory
      var descended = false
      for part in target.split(separator: "/") {
        if part == ".." {
          guard !descended, parts.count > depth else {
            throw CoreError.unsafePath("reference escapes packaged content: " + path)
          }
          parts.removeLast()
        } else if part != "." {
          descended = true
          parts.append(String(part))
        }
      }
      return parts.joined(separator: "/")
    }
  }

  static func validateReferences(_ item: BundleItem, objects: [String: Data]) throws {
    guard let discovery = item.discovery else { return }
    let tree = Dictionary(uniqueKeysWithValues: item.entries.map { ($0.path, $0) })
    let candidates: [String]
    switch item.kind {
    case .skills: candidates = [discovery + "/SKILL.md"]
    case .instructions:
      candidates = ["instructions", ".agents/instructions"].map {
        discovery + "/" + $0 + "/" + item.name + ".md"
      }
    case .mcpServer: return
    }
    for path in candidates {
      guard let digest = tree[path]?.object, let bytes = objects[digest] else { continue }
      let text: String
      if item.kind == .instructions {
        text = try Instructions.validateSource(bytes, id: item.name, allowRestrictions: true)
          .content
      } else {
        guard let content = String(data: bytes, encoding: .utf8) else {
          throw CoreError.invalidSource("invalid UTF-8 in packaged skill: " + item.name)
        }
        text = content
      }
      for reference in try references(in: text, at: path, confinedTo: discovery) {
        guard tree[reference]?.path.utf8.elementsEqual(reference.utf8) == true else {
          throw CoreError.invalidSource("missing packaged resource referenced in " + path)
        }
      }
    }
  }

  mutating func scan(_ bytes: Data, path: String) throws {
    if let text = String(data: bytes, encoding: .utf8), !text.utf8.contains(0) {
      try scan(text, path: path, allowLeadingBOM: true)
    }
  }

  mutating func scan(_ text: String, path: String, allowLeadingBOM: Bool = false) throws {
    let matches = try ContentAuditUnicode.scan(text, leadingBOM: allowLeadingBOM)
    for match in matches {
      guard findings.count < ContentAuditUnicode.maximumFindings else {
        throw CoreError.invalidSource("package integrity finding limit exceeded")
      }
      findings.append(
        .init(
          severity: match.severity, reason: match.reason,
          location: .init(
            path: path, field: nil, line: match.line, column: match.column,
            promptLine: nil, promptColumn: nil),
          ownership: .untracked, codePoint: match.codePoint))
    }
  }

  mutating func scan(archive: BundleArchive) throws {
    let package = archive.manifest.package
    if let description = package.description {
      try scan(description, path: "package.description")
    }
    if let author = package.author { try scan(author, path: "package.author") }
    for member in archive.manifest.components {
      let prefix = member.kind.rawValue + "/" + member.name
      try scan(member.name, path: prefix)
      for entry in member.entries {
        try Task.checkCancellation()
        if let digest = entry.object, let data = archive.contentObjects[digest] {
          try scan(data, path: prefix + "/" + entry.path)
        }
        if let link = entry.link { try scan(link, path: prefix + "/" + entry.path) }
      }
      if let configuration = member.configuration {
        try scan(configuration, path: prefix + "/configuration")
      }
    }
  }

  private mutating func scan(_ value: LedgerValue, path: String) throws {
    if let text = value.text { try scan(text, path: path) }
    for child in value.array ?? [] { try scan(child, path: path) }
    for key in (value.object ?? [:]).keys.sorted() {
      try scan(key, path: path)
      try scan(value.object![key]!, path: path)
    }
  }
}
