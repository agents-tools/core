import Foundation

extension DeclarationCondition {
  /// Format readers supply strings; Core owns their meaning. Unknown values are errors.
  package static func restrictions(_ fields: [String: [String]]) throws -> Self {
    func values<T>(_ key: String, _ parse: (String) -> T?) throws -> [T]? {
      guard let names = fields[key] else { return nil }
      return try names.map {
        guard let value = parse($0) else {
          throw CoreError.invalidSource("invalid producer \(key) value: \($0)")
        }
        return value
      }
    }
    return try Self(
      agents: values("agents", AgentID.init(rawValue:)),
      scopes: values("scopes", InstallScope.init(rawValue:)),
      platforms: values("platforms", DeclarationPlatform.init(rawValue:)))
  }

  package func matches(scope: InstallScope, platform: DeclarationPlatform) -> Bool {
    (scopes?.contains(scope) ?? true) && (platforms?.contains(platform) ?? true)
  }

  package func intersecting(_ other: Self) -> Self {
    func intersection<T: Equatable>(_ lhs: [T]?, _ rhs: [T]?) -> [T]? {
      guard let lhs else { return rhs }
      guard let rhs else { return lhs }
      return lhs.filter { rhs.contains($0) }
    }
    return Self(
      agents: intersection(agents, other.agents),
      scopes: intersection(scopes, other.scopes),
      platforms: intersection(platforms, other.platforms))
  }

  package func recipients(
    requested: [AgentID], scope: InstallScope, platform: DeclarationPlatform
  ) -> Set<AgentID> {
    guard matches(scope: scope, platform: platform) else { return [] }
    return Set(requested.filter { agents?.contains($0) ?? true })
  }
}
