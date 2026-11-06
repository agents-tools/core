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
      let candidates = tags.filter { requirement.matches(version: $0.1) }
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
