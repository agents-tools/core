import Foundation

/// Shared selection policy for fetched and advertised Git references.
struct SourceReference {
  let name: String
  let version: String?

  init(requirement: SourceRequirement?, tags names: [String]) throws {
    try requirement?.validate()
    let tags = names.compactMap { name -> (String, SemanticVersion)? in
      SemanticVersion(name).map { (name, $0) }
    }
    .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    if let requirement {
      switch requirement {
      case .branch(let branch):
        name = "refs/heads/" + branch
        version = nil
        return
      case .revision(let revision):
        name = revision
        version = nil
        return
      default: break
      }
      guard let lower = SemanticVersion(requirement.value) else {
        throw CoreError.invalidSource("invalid semantic version")
      }
      let candidates: [(String, SemanticVersion)]
      if requirement.kind == "exact" {
        candidates = tags.filter { $0.1.description == lower.description }
      } else {
        let upper: SemanticVersion
        switch requirement {
        case .upToNextMajor: upper = SemanticVersion(major: lower.major + 1, minor: 0, patch: 0)
        case .upToNextMinor:
          upper = SemanticVersion(major: lower.major, minor: lower.minor + 1, patch: 0)
        default:
          guard let bound = requirement.upperBound, let parsed = SemanticVersion(bound) else {
            throw CoreError.invalidSource("missing version upper bound")
          }
          upper = parsed
        }
        candidates = tags.filter { $0.1.isInRange(from: lower, to: upper) }
      }
      guard let selected = candidates.last else {
        throw CoreError.notFound("no tag matches source requirement")
      }
      name = "refs/tags/" + selected.0
      version = selected.1.description
    } else if let selected = tags.last {
      name = "refs/tags/" + selected.0
      version = selected.1.description
    } else {
      name = "HEAD"
      version = nil
    }
  }
}
