import Foundation

package enum ResolvedLedgerCodec {
  package static func decode(_ data: Data, limits: LedgerLimits) throws -> ResolvedLedger {
    try LedgerAdmission.check(data, limits: limits)
    let ledger = try JSONDecoder().decode(ResolvedLedger.self, from: data)
    try checkModel(ledger, limits: limits)
    try ledger.validate()
    guard ledger.resources.values.reduce(0, { $0 + $1.entries.count }) <= limits.entries else {
      throw CoreError.invalidState("ledger entry budget")
    }
    // Admission bounds these allocations. Comparing against the wire shape also refuses fields
    // a Codable decoder would discard, including unknown fields whose value is null.
    let input = try JSONSerialization.jsonObject(with: data)
    let encoded = try JSONSerialization.jsonObject(with: bytes(ledger))
    try fields(input, encoded, shape: .ledger)
    return ledger
  }

  package static func encode(_ ledger: ResolvedLedger, limits: LedgerLimits) throws -> Data {
    try checkModel(ledger, limits: limits)
    try ledger.validate()
    let result = try bytes(ledger)
    _ = try decode(result, limits: limits)
    return result
  }

  /// Nil means the caller must retain the original bytes, including their layout.
  package static func replacement(
    _ ledger: ResolvedLedger, existing: Data?, limits: LedgerLimits
  ) throws -> Data? {
    try checkModel(ledger, limits: limits)
    try ledger.validate()
    if let existing {
      let original = try decode(existing, limits: limits)
      try LedgerAdmission.check(bytes(ledger), limits: limits)
      var comparison = ledger
      for index in 0..<min(comparison.sourceUses.count, original.sourceUses.count) {
        comparison.sourceUses[index].requirement = comparisonRequirement(
          comparison.sourceUses[index].requirement, original: original.sourceUses[index].requirement
        )
      }
      for index in 0..<min(comparison.groups.count, original.groups.count) {
        comparison.groups[index].requirement = comparisonRequirement(
          comparison.groups[index].requirement, original: original.groups[index].requirement)
      }
      if try bytes(original) == bytes(comparison) { return nil }
    }
    return try encode(ledger, limits: limits)
  }

  /// Only typed version intent ignores spelling. Git ref names and every other wire value
  /// retain byte identity; comparison never changes the ledger that will be published.
  private static func comparisonRequirement(
    _ requirement: SourceRequirement?, original: SourceRequirement?
  ) -> SourceRequirement? {
    guard let requirement, let original, requirement.isVersionRequirement,
      requirement.declarationEquivalent(to: original)
    else { return requirement }
    return original
  }

  package static func checkModel(_ ledger: ResolvedLedger, limits: LedgerLimits) throws {
    if let pending = ledger.pendingDeployment {
      guard pending.storedLedger.pendingDeployment == nil else {
        throw CoreError.invalidState("nested pending marketplace deployment")
      }
      try checkModel(pending.desired(in: ledger), limits: limits)
    }
    var bytes = 0
    for object in ledger.contentObjects.values {
      guard object.count <= limits.objectBytes - bytes else {
        throw CoreError.invalidState("ledger content byte budget")
      }
      bytes += object.count
    }
    var entries = 0
    var expanded = 0
    for resource in ledger.resources.values {
      guard resource.entries.count + resource.support.count <= limits.entries - entries else {
        throw CoreError.invalidState("ledger entry budget")
      }
      entries += resource.entries.count + resource.support.count
      for entry in resource.entries + resource.support where entry.kind == .file {
        guard let count = entry.byteCount, count >= 0, count <= limits.resourceBytes - expanded
        else {
          throw CoreError.invalidState("ledger expanded resource budget")
        }
        expanded += count
      }
    }
    var pending =
      ledger.components.values.map { ($0.payload, 0) }
      + ledger.lowerings.map { ($0.layout, 0) }
    var nodes = ledger.occurrences.count + ledger.groups.count
    let ordered = ledger.occurrences.sorted { $0.id < $1.id }
    var pluginDepth: [Int: Int] = [:]
    for occurrence in ordered {
      if let member = occurrence.pluginMember {
        let depth = (pluginDepth[member.parent] ?? 0) + 1
        guard depth < limits.depth else {
          throw CoreError.invalidState("ledger plugin depth budget")
        }
        pluginDepth[occurrence.id] = depth
      }
      nodes += occurrence.pluginExpansion?.children.count ?? 0
      guard nodes <= limits.nodes else { throw CoreError.invalidState("ledger relation budget") }
    }
    for authority in ledger.nativeAuthorities ?? [] {
      func charge(_ count: Int) throws {
        guard count <= limits.nodes - nodes else {
          throw CoreError.invalidState("ledger authority budget")
        }
        nodes += count
      }
      try charge(1)
      for (deployments, path) in authority.regions.map({ ($0.deployments, $0.path) })
        + authority.createdContainers.map({ ($0.deployments, $0.path) })
      {
        guard path.count < limits.depth else {
          throw CoreError.invalidState("ledger native path depth budget")
        }
        try charge(1)
        try charge(deployments.count)
        try charge(path.count)
        for step in path {
          if case .position = step { try charge(1) }
        }
      }
    }
    while let (value, depth) = pending.popLast() {
      nodes += 1
      guard depth < limits.depth / 2, nodes <= limits.nodes else {
        throw CoreError.invalidState("ledger value budget")
      }
      pending += (value.array ?? []).map { ($0, depth + 1) }
      pending += (value.object?.values ?? [String: LedgerValue]().values).map { ($0, depth + 1) }
    }
  }

  package static func digest<T: Encodable>(_ value: T) throws -> String {
    "sha256:" + FileHash.sha256Hex(data: try bytes(value))
  }

  package static func bytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = try encoder.encode(value)
    bytes.append(10)
    return bytes
  }

  /// Nullable members belong to their wire record, not to a spelling used elsewhere in JSON.
  private indirect enum WireShape {
    case ledger, pendingDeployment, source, location, sourceUse, component, condition, occurrence
    case group
    case resource, entry, deployment, lowering, value, artifact, requirement, scalar
    case pluginMember, input, pluginExpansion
    case nativeAuthority, nativeRegion, nativeContainer, nativeStep, nativeEvidence
    case map(WireShape)
    case list(WireShape)

    var nullable: Set<String> {
      switch self {
      case .ledger:
        [
          "nativeAuthorities", "marketplacePackages", "marketplaceGraph",
          "pendingMarketplaceDeployment",
        ]
      case .source: ["transport", "location", "version", "container", "namespace"]
      case .location: ["root"]
      case .sourceUse: ["requirement"]
      case .requirement: ["to"]
      case .component: ["group", "revision", "version", "containerRoot"]
      case .condition: ["agents", "scopes", "platforms"]
      case .occurrence: ["reference", "pluginMember", "input", "pluginExpansion"]
      case .input: ["pointer"]
      case .group: ["parent", "requirement"]
      case .resource: ["artifact", "location"]
      case .entry: ["object", "link", "byteCount"]
      case .deployment: ["importReference", "headingOffset"]
      case .value: ["text", "integer", "boolean", "array", "object"]
      case .artifact: ["files"]
      default: []
      }
    }

    func member(_ key: String) -> Self {
      switch (self, key) {
      case (.ledger, "pendingMarketplaceDeployment"): .pendingDeployment
      case (.pendingDeployment, "ledger"): .ledger
      case (.ledger, "nativeAuthorities"): .list(.nativeAuthority)
      case (.nativeAuthority, "target"): .location
      case (.nativeAuthority, "regions"): .list(.nativeRegion)
      case (.nativeAuthority, "createdContainers"): .list(.nativeContainer)
      case (.nativeRegion, "path"), (.nativeContainer, "path"): .list(.nativeStep)
      case (.nativeStep, "evidence"): .nativeEvidence
      case (.ledger, "sources"): .map(.source)
      case (.ledger, "sourceUses"): .list(.sourceUse)
      case (.ledger, "components"): .map(.component)
      case (.ledger, "occurrences"): .list(.occurrence)
      case (.ledger, "groups"): .list(.group)
      case (.ledger, "resources"): .map(.resource)
      case (.ledger, "deployments"): .list(.deployment)
      case (.ledger, "lowerings"): .list(.lowering)
      case (.source, "location"), (.resource, "location"), (.deployment, "target"): .location
      case (.sourceUse, "requirement"), (.group, "requirement"): .requirement
      case (.component, "payload"), (.lowering, "layout"): .value
      case (.component, "conditions"): .list(.condition)
      case (.occurrence, "condition"): .condition
      case (.occurrence, "pluginMember"): .pluginMember
      case (.occurrence, "input"), (.pluginExpansion, "input"): .input
      case (.occurrence, "pluginExpansion"): .pluginExpansion
      case (.resource, "entries"), (.resource, "support"): .list(.entry)
      case (.resource, "artifact"): .artifact
      case (.value, "array"): .list(.value)
      case (.value, "object"): .map(.value)
      case (.map(let element), _): element
      default: .scalar
      }
    }

    var element: Self {
      if case .list(let element) = self { return element }
      return .scalar
    }
  }

  private static func fields(_ input: Any, _ encoded: Any, shape: WireShape) throws {
    if let input = input as? [String: Any], let encoded = encoded as? [String: Any] {
      for (key, value) in input {
        guard let counterpart = encoded[key] else {
          if value is NSNull, shape.nullable.contains(key) { continue }
          throw CoreError.invalidState("unknown ledger field")
        }
        try fields(value, counterpart, shape: shape.member(key))
      }
    } else if let input = input as? [Any], let encoded = encoded as? [Any] {
      guard input.count == encoded.count else { throw CoreError.invalidState("ledger array shape") }
      for (value, counterpart) in zip(input, encoded) {
        try fields(value, counterpart, shape: shape.element)
      }
    }
  }
}
