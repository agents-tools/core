import AgentsCore
import Foundation

/// Selects the content provider after generic source parsing and watch resolution.
enum SkillSourceResolver {
  static func resolve(
    _ input: String, environment: RuntimeEnvironment,
    requirement: SourceRequirement? = nil, scope: InstallScope = .project
  ) throws -> ResolvedSource {
    let parsed = try SourceResolver.parse(input, environment: environment, requirement: requirement)
    guard parsed.type == .wellKnown else {
      return try SourceResolver.resolve(parsed, environment: environment, scope: scope)
    }
    let provider = WellKnownProvider()
    let skills = try provider.fetchAllSkills(from: parsed.url)
    let checkout = AgentRegistry.wellKnownCacheDirectory(scope: scope, environment: environment)
      .appendingPathComponent(PathSafety.sanitizeName(provider.sourceIdentifier(for: parsed.url)))
    try provider.materialize(skills, into: checkout)
    return ResolvedSource(
      parsed: parsed,
      identity: "wellknown/\(provider.sourceIdentifier(for: parsed.url))",
      checkoutURL: checkout,
      revision: skills.compactMap(\.digest).sorted().joined(separator: ",").nilIfEmpty,
      requestedRef: nil
    )
  }

  static func resolveSourceOrWatch(
    _ input: String, path: String? = nil, requirement: SourceRequirement? = nil,
    scope: InstallScope = .project, environment: RuntimeEnvironment
  ) throws -> ResolvedSource {
    if let source = try SourceResolver.resolveWatch(
      input, path: path, requirement: requirement, environment: environment,
      watches: SkillOperations.watches)
    {
      return source
    }
    return try resolve(input, environment: environment, requirement: requirement, scope: scope)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
