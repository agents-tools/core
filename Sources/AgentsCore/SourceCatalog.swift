import Foundation

/// Frozen Git reference evidence for a resolution session. Tags at the same version retain
/// the existing lexical tie break; branches and revision expressions must name one commit.
struct SourceCatalog {
  var tags: [String: String]
  var references: [String: String]

  func candidates(
    requirements: [SourceRequirement?], spending: (Int) throws -> Void = { _ in }
  ) throws -> [SourceRevision] {
    for requirement in requirements {
      try spending(1)
      try requirement?.validate()
    }
    let constraints = requirements.compactMap { $0 }
    let fixed = constraints.compactMap { requirement -> String? in
      switch requirement {
      case .branch(let name): return references["refs/heads/" + name]
      case .revision(let name): return references[name]
      default: return nil
      }
    }
    let fixedCount = constraints.filter { !$0.isVersionRequirement }.count
    guard fixed.count == fixedCount, Set(fixed).count <= 1 else { return [] }
    let versions = constraints.filter(\.isVersionRequirement)
    let ordered = try tags.compactMap { name, commit -> (String, SemanticVersion, String)? in
      try spending(1)
      return SemanticVersion(name).map { (name, $0, commit) }
    }.sorted {
      try spending(1)
      return $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1
    }
    if let commit = fixed.first, versions.isEmpty {
      return [SourceRevision(revision: commit)]
    }
    var seen = Set<String>()
    let candidates = try ordered.filter { entry in
      try spending(versions.count + 1)
      return
        (fixed.first == nil || fixed.first == entry.2)
        && versions.allSatisfy { $0.matches(version: entry.1) }
        && seen.insert(entry.2).inserted
    }.map { SourceRevision(revision: $0.2, version: $0.1.description) }
    if !candidates.isEmpty || !versions.isEmpty || !ordered.isEmpty { return candidates }
    return references["HEAD"].map { [SourceRevision(revision: $0)] } ?? []
  }
}

extension SourceRequirement {
  func matches(version: SemanticVersion) -> Bool {
    guard let lower = SemanticVersion(value) else { return false }
    switch self {
    case .exact: return version.description == lower.description
    case .upToNextMajor:
      return version.isInRange(
        from: lower, to: SemanticVersion(major: lower.major + 1, minor: 0, patch: 0))
    case .upToNextMinor:
      return version.isInRange(
        from: lower, to: SemanticVersion(major: lower.major, minor: lower.minor + 1, patch: 0))
    case .range(_, let upper):
      return SemanticVersion(upper).map { version.isInRange(from: lower, to: $0) } ?? false
    case .branch, .revision: return false
    }
  }
}
