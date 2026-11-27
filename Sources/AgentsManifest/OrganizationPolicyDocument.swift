import AgentsCore
import Foundation

package enum OrganizationPolicyDocument {
  package static func parse(_ bytes: Data, url: URL) throws -> OrganizationRules {
    let reader = try YAMLReader(bytes: Array(bytes), identity: .init(url.absoluteString))
    let root = try Fields(reader.root, reader: reader)
    var rules = OrganizationRules()
    rules.name = try root.text("name")
    rules.version = try root.text("version")
    rules.parent = try root.text("extends")
    rules.enforcement = try root.choice("enforcement", [.off, .warn, .block]) ?? .warn
    rules.fetchFailure = try root.choice("fetch_failure", [.warn, .block]) ?? .warn
    if let cache = try root.object("cache") {
      try cache.requireKeys(["ttl"])
      rules.ttl = min(86_400, try cache.positive("ttl") ?? 3600)
    }
    if let sources = try root.object("sources") {
      try sources.requireKeys(["allow", "deny"])
      rules.sourceAllow = try sources.list("allow")
      rules.sourceDeny = try sources.list("deny") ?? []
    }
    if let deps = try root.object("dependencies") {
      try deps.requireKeys([
        "allow", "deny", "require", "require_resolution", "max_depth", "require_pinned_constraint",
      ])
      rules.dependencyAllow = try deps.list("allow")
      rules.dependencyDeny = try deps.list("deny") ?? []
      rules.dependencyRequire = try deps.packages()
      rules.resolution = try deps.choice(
        "require_resolution", OrganizationRules.Resolution.allCases)
      rules.maximumDepth = try deps.positive("max_depth")
      rules.pinnedConstraint = try deps.flag("require_pinned_constraint") ?? false
    }
    if let marketplace = try root.object("marketplace") {
      try marketplace.requireKeys(["allow"])
      rules.marketplaceAllow = try marketplace.list("allow")
    }
    if let mcp = try root.object("mcp") {
      try mcp.requireKeys([
        "allow", "deny", "require", "transport", "self_defined", "trust_transitive",
      ])
      rules.mcpAllow = try mcp.list("allow")
      rules.mcpDeny = try mcp.list("deny") ?? []
      rules.mcpRequire = try mcp.exactList("require")
      rules.mcpSelfDefined = try mcp.choice("self_defined", OrganizationRules.SelfDefined.allCases)
      rules.mcpTrustTransitive = try mcp.flag("trust_transitive")
      if let transport = try mcp.object("transport") {
        try transport.requireKeys(["allow"])
        rules.mcpTransportAllow = try transport.list("allow")?.map { value in
          switch value {
          case "stdio", "sse", "streamable-http": return value
          case "http": return "streamable-http"
          default: throw transport.failure(transport.node, "Unknown MCP transport.")
          }
        }
      }
    }
    if let executable = try root.object("executables") {
      try executable.requireKeys(["deny_all", "deny", "require", "recommend", "enforce"])
      rules.executableDenyAll = try executable.flag("deny_all") ?? false
      rules.executableDeny = try executable.list("deny") ?? []
      rules.executableRequire = try executable.exactList("require")
      for key in ["recommend", "enforce"] where try executable.exactList(key).isEmpty == false {
        rules.warnings.append("executables.\(key) does not grant execution or installation trust.")
      }
    }
    if let manifest = try root.object("manifest") {
      try manifest.requireKeys([
        "required_fields", "require_explicit_includes", "content_types", "scripts",
      ])
      rules.requiredFields = try manifest.exactList("required_fields")
      rules.explicitIncludes = try manifest.flag("require_explicit_includes") ?? false
      rules.scriptsDenied = try manifest.enumeration("scripts", ["allow", "deny"]) == "deny"
      if let types = try manifest.object("content_types") {
        try types.requireKeys(["allow"])
        rules.contentTypes = try types.list("allow")
      }
    }
    if let security = try root.object("security") {
      try security.requireKeys(["integrity", "audit"])
      if let integrity = try security.object("integrity") {
        try integrity.requireKeys(["require_hashes"])
        rules.requireHashes = try integrity.flag("require_hashes") ?? false
      }
      if let audit = try security.object("audit") {
        try audit.requireKeys(["fail_on_drift"])
        rules.failOnDrift = try audit.flag("fail_on_drift") ?? false
      }
    }
    if let unmanaged = try root.object("unmanaged_files") {
      try unmanaged.requireKeys(["action", "directories", "exclude"])
      rules.unmanagedAction =
        try unmanaged.choice("action", OrganizationRules.Action.allCases) ?? .ignore
      rules.unmanagedDirectories = try unmanaged.exactList("directories")
      for path in rules.unmanagedDirectories where path == "." || (try? ledgerPath(path)) == nil {
        throw unmanaged.failure(
          unmanaged.node, "Unmanaged directories must be relative workspace paths.")
      }
      rules.unmanagedExclude = try unmanaged.list("exclude") ?? []
    }
    let accepted: Set<String> = [
      "name", "version", "extends", "enforcement", "fetch_failure", "cache", "sources",
      "dependencies", "marketplace", "mcp", "executables", "manifest", "security",
      "unmanaged_files",
    ]
    rules.warnings += root.fields.keys.sorted().filter { !accepted.contains($0) }.map {
      "Unsupported organization policy field: \($0)."
    }
    return rules
  }

  private struct Fields {
    let node: YAMLNode
    let reader: YAMLReader
    let fields: [String: YAMLNode]

    init(_ node: YAMLNode, reader: YAMLReader) throws {
      self.node = node
      self.reader = reader
      guard let pairs = node.pairs else {
        throw ManifestFailure(
          .init(
            code: "org-policy.field", message: "Expected a mapping.", span: reader.span(of: node)))
      }
      var values: [String: YAMLNode] = [:]
      for (key, value) in pairs {
        guard let name = Self.string(key), values[name] == nil,
          name.utf8.count <= 128, !name.isEmpty
        else {
          throw ManifestFailure(
            .init(
              code: "org-policy.field", message: "Invalid field name.", span: reader.span(of: key)))
        }
        values[name] = value
      }
      fields = values
    }

    func failure(_ value: YAMLNode, _ message: String) -> ManifestFailure {
      ManifestFailure(
        .init(code: "org-policy.field", message: message, span: reader.span(of: value)))
    }

    func requireKeys(_ keys: Set<String>) throws {
      if let key = fields.keys.sorted().first(where: { !keys.contains($0) }) {
        throw failure(fields[key]!, "Unsupported organization policy rule.")
      }
    }

    private static func kind(_ node: YAMLNode) -> YAMLScalar? {
      guard let scalar = node.scalar, !scalar.decimalTag else { return nil }
      return scalar.quoted ? .string : YAMLScalar.classify(scalar.text)
    }

    private static func string(_ node: YAMLNode) -> String? {
      kind(node) == .string ? node.text : nil
    }

    private func value(_ key: String) -> YAMLNode? {
      fields[key].flatMap { Self.kind($0) == .null ? nil : $0 }
    }

    func object(_ key: String) throws -> Self? {
      try value(key).map { try Self($0, reader: reader) }
    }

    private func text(_ value: YAMLNode) throws -> String {
      guard let string = Self.string(value), !string.isEmpty, string.utf8.count <= 4096,
        string.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
      else { throw failure(value, "Expected a nonempty string.") }
      return string
    }

    func text(_ key: String) throws -> String? { try value(key).map(text) }

    func flag(_ key: String) throws -> Bool? {
      guard let value = fields[key] else { return nil }
      guard Self.kind(value) == .boolean else { throw failure(value, "Expected a boolean.") }
      return value.text?.lowercased() == "true"
    }

    func positive(_ key: String) throws -> Int? {
      guard let value = fields[key] else { return nil }
      guard Self.kind(value) == .integer, let number = value.text.flatMap(YAMLScalar.integer),
        number > 0
      else { throw failure(value, "Expected a positive integer.") }
      return number
    }

    func enumeration(_ key: String, _ choices: [String]) throws -> String? {
      guard let value = fields[key] else { return nil }
      let raw = try text(value)
      guard choices.contains(raw) else { throw failure(value, "Unsupported rule value.") }
      return raw
    }

    func choice<T: RawRepresentable>(_ key: String, _ choices: [T]) throws -> T?
    where T.RawValue == String {
      try enumeration(key, choices.map(\.rawValue)).flatMap(T.init(rawValue:))
    }

    func list(_ key: String) throws -> [String]? {
      guard let value = value(key) else { return nil }
      guard let items = value.items, items.count <= 256 else {
        throw failure(value, "Expected a list of at most 256 entries.")
      }
      return try items.map(text)
    }

    func exactList(_ key: String) throws -> [String] {
      let values = try list(key) ?? []
      if values.contains(where: { $0.contains(where: { "*?[]".contains($0) }) }) {
        throw failure(fields[key]!, "Expected exact identities or field names.")
      }
      return values
    }

    func packages() throws -> [OrganizationRules.RequiredPackage] {
      guard let value = value("require") else { return [] }
      guard let items = value.items, items.count <= 256 else {
        throw failure(value, "Expected a list of at most 256 requirements.")
      }
      return try items.map { item in
        let identity: String
        let requirement: SourceRequirement?
        if item.pairs != nil {
          let entry = try Self(item, reader: reader)
          try entry.requireKeys(["identity", "exact", "from", "upToNextMinor", "to"])
          guard let raw = try entry.text("identity") else {
            throw failure(item, "A package requirement needs an identity.")
          }
          identity = raw
          let exact = try entry.text("exact")
          let from = try entry.text("from")
          let minor = try entry.text("upToNextMinor")
          let to = try entry.text("to")
          guard [exact, from, minor].compactMap({ $0 }).count <= 1, to == nil || from != nil else {
            throw failure(item, "Conflicting version constraints.")
          }
          if let exact {
            requirement = .exact(exact)
          } else if let from {
            requirement = to.map { .range(from: from, to: $0) } ?? .upToNextMajor(from: from)
          } else {
            requirement = minor.map(SourceRequirement.upToNextMinor)
          }
        } else {
          identity = try text(item)
          requirement = nil
        }
        guard identity.contains("/"),
          !identity.contains(where: { "*?[]".contains($0) }),
          requirement == nil || (try? requirement?.canonicalized()) != nil
        else { throw failure(item, "Invalid exact package identity or version constraint.") }
        return .init(identity: identity, version: try requirement?.canonicalized())
      }
    }
  }
}
