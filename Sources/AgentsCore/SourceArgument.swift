import Foundation

/// A source argument: a location followed by optional typed selectors, such as
/// `owner/repo@branch:main@path:skills@skill:pdf`.
package struct SourceArgument: Equatable, Sendable {
  /// A declared alias, local path, Git URL or shorthand, or well-known URL.
  package var location: String
  package var requirement: SourceRequirement?
  package var path: String?
  package var name: String?

  private static let requirementLabels: Set = [
    "branch", "revision", "ref", "exact", "from", "minor",
  ]
  private static let labels = requirementLabels.union(["path", "skill"])

  /// Selectors start at the first `@` followed by a known label and `:`, so SSH
  /// locations such as `git@host:owner/repo` keep their `@`. Values are
  /// percent-decoded.
  package init(_ input: String) throws {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = Self.selectorStart(in: input) else {
      location = input
      return
    }
    location = String(input[..<start])
    for segment in input[input.index(after: start)...].split(separator: "@") {
      guard let colon = segment.firstIndex(of: ":"), Self.labels.contains(String(segment[..<colon]))
      else { throw CoreError.invalidSource("unknown source selector '@\(segment)'") }
      let label = String(segment[..<colon])
      let raw = String(segment[segment.index(after: colon)...])
      let value = raw.removingPercentEncoding ?? raw
      guard !value.isEmpty else {
        throw CoreError.invalidSource("empty source selector '@\(label):'")
      }
      switch label {
      case "path":
        guard path == nil else { throw CoreError.invalidSource("more than one @path: selector") }
        path = try PathSafety.sanitizeSubpath(value)
      case "skill":
        guard name == nil else { throw CoreError.invalidSource("more than one @skill: selector") }
        name = value
      default:
        guard requirement == nil else {
          throw CoreError.invalidSource("more than one source requirement selector")
        }
        let parsed: SourceRequirement =
          switch label {
          case "branch": .branch(value)
          // A ref names any branch, tag or commit; Git resolves it like a revision.
          case "revision", "ref": .revision(value)
          case "exact": .exact(value)
          case "from": .upToNextMajor(from: value)
          default: .upToNextMinor(from: value)
          }
        try parsed.validate()
        requirement = parsed
      }
    }
    guard !location.isEmpty else { throw CoreError.invalidSource("empty or invalid source") }
  }

  /// Resolves the location to a declared alias or a parsed source. Selectors and explicit
  /// options must agree with each other; they replace the branch and path that a hosted
  /// tree URL implies.
  package func selection(
    in declaration: Declaration, requirement explicitRequirement: SourceRequirement?,
    path explicitPath: String?, environment: RuntimeEnvironment
  ) throws -> SourceSelection {
    let requirements = [requirement, explicitRequirement].compactMap { $0 }
    let paths = try [path, explicitPath.map(PathSafety.sanitizeSubpath)].compactMap { $0 }
    guard requirements.allSatisfy({ $0 == requirements.first }) else {
      throw CoreError.invalidSource("the source selector and option give different requirements")
    }
    guard paths.allSatisfy({ $0 == paths.first }) else {
      throw CoreError.invalidSource("the source selector and option give different paths")
    }
    if let declared = declaration.sources[location] {
      return SourceSelection(source: declared, requirement: requirements.first, path: paths.first)
    }
    let parsed = try SourceParser.parse(
      location, currentDirectory: environment.projectDirectory,
      homeDirectory: environment.homeDirectory)
    return SourceSelection(
      source: SourceDeclaration(kind: parsed.type, location: parsed.localPath ?? parsed.url),
      requirement: requirements.first ?? parsed.requirement, path: paths.first ?? parsed.subpath)
  }

  private static func selectorStart(in input: String) -> String.Index? {
    var index = input.startIndex
    while let at = input[index...].firstIndex(of: "@") {
      let rest = input[input.index(after: at)...]
      if let colon = rest.firstIndex(of: ":"), labels.contains(String(rest[..<colon])) {
        return at
      }
      index = input.index(after: at)
    }
    return nil
  }
}

/// The source an argument names, with the requirement and path the command gives for it.
package struct SourceSelection: Equatable, Sendable {
  /// The declared alias's source, or the parsed location without requirement or path.
  package var source: SourceDeclaration
  package var requirement: SourceRequirement?
  package var path: String?

  /// `declared` with the command's requirement and path replacing its own.
  package func applied(to declared: SourceDeclaration) -> SourceDeclaration {
    var result = declared
    if let requirement { result.requirement = requirement }
    if let path { result.path = path }
    return result
  }
}
