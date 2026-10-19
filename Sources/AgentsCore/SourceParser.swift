import Foundation

public struct ParsedSource: Equatable, Sendable {
  public var type: SourceKind
  public var url: String
  public var localPath: String?
  public var requirement: SourceRequirement?
  public var subpath: String?

  public init(
    type: SourceKind, url: String, localPath: String? = nil, requirement: SourceRequirement? = nil,
    subpath: String? = nil
  ) {
    self.type = type
    self.url = url
    self.localPath = localPath
    self.requirement = requirement
    self.subpath = subpath
  }
}

public enum SourceParser {
  /// Parses local paths, Git URLs, host-qualified repositories and HTTP indexes.
  public static func parse(
    _ rawInput: String,
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> ParsedSource {
    let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, !input.contains("\0") else {
      throw CoreError.invalidSource("empty or invalid source")
    }
    if input == "." || input == ".." || input.hasPrefix("/") || input.hasPrefix("./")
      || input.hasPrefix("../") || input == "~" || input.hasPrefix("~/")
    {
      let expanded =
        input == "~"
        ? homeDirectory.path
        : input.hasPrefix("~/")
          ? homeDirectory.appendingPathComponent(String(input.dropFirst(2))).path : input
      let path = URL(
        fileURLWithPath: expanded,
        relativeTo: URL(fileURLWithPath: currentDirectory.path, isDirectory: true)
      ).standardizedFileURL
        .path
      return ParsedSource(type: .local, url: path, localPath: path)
    }
    guard !input.contains("#") else {
      throw CoreError.invalidSource("pass source requirements and skill names separately")
    }
    if input.hasPrefix("ssh://")
      || input.range(of: #"^[^/@]+@[^/:]+:.+$"#, options: .regularExpression) != nil
    {
      _ = try SourceDeclaration(kind: .git, location: input).identity(
        environment: RuntimeEnvironment())
      return ParsedSource(type: .git, url: input)
    }
    if !input.contains("://") {
      guard !input.contains("@") else {
        throw CoreError.invalidSource(
          "pass skill names separately or use a typed selector such as @branch:main")
      }
      let parts = input.split(separator: "/")
      guard parts.count >= 2 else {
        throw CoreError.invalidSource("expected a local path or repository URL")
      }
      let hostQualified = parts[0].contains(".") || parts[0].contains(":")
      let url = hostQualified ? "https://" + input : "https://github.com/" + input
      _ = try SourceDeclaration(kind: .git, location: url).identity(
        environment: RuntimeEnvironment())
      return ParsedSource(type: .git, url: url)
    }
    guard let url = URL(string: input), ["http", "https"].contains(url.scheme), let host = url.host
    else { throw CoreError.invalidSource("unsupported source URL") }
    let parts = url.path.split(separator: "/").map(String.init)
    if let marker = parts.firstIndex(of: "tree"), marker + 1 < parts.count,
      host.lowercased() == "github.com" || (marker > 0 && parts[marker - 1] == "-")
    {
      let end = host.lowercased() == "github.com" ? marker : marker - 1
      let repository = parts[..<end].joined(separator: "/")
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.path = "/" + repository
      let path = parts.dropFirst(marker + 2).joined(separator: "/")
      return ParsedSource(
        type: .git, url: components.string!, requirement: .branch(parts[marker + 1]),
        subpath: path.isEmpty ? nil : try PathSafety.sanitizeSubpath(path))
    }
    let kind: SourceKind =
      ["github.com", "gitlab.com", "huggingface.co", "raw.githubusercontent.com"].contains(
        host.lowercased()) || url.path.hasSuffix(".git")
      ? .git : .wellKnown
    return ParsedSource(type: kind, url: input)
  }

  public static func identity(for source: ParsedSource) throws -> String {
    try SourceDeclaration(
      kind: source.type,
      location: source.localPath ?? source.url
    ).identity(environment: RuntimeEnvironment())
  }
}
