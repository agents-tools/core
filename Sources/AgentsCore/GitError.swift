import Foundation

/// A failed Git operation. Consumers can display the description and supply their own remedy.
public struct GitError: Error, CustomStringConvertible, Equatable, Sendable {
  /// The kind of Git work that failed, for consumers to select an appropriate remedy.
  public enum Operation: CustomStringConvertible, Equatable, Sendable {
    case clone
    case fetch
    case listRemoteReferences
    case listTags
    /// Resolves a requested reference or object ID to a commit, before Git's commit peeling suffix.
    case resolveRevision(revision: String)
    case countCommits
    case listReferences
    /// Retains a revision through a reference owned by core.
    case updateReference
    /// Releases a revision retained by a reference owned by core.
    case deleteReference
    case extractRevision
    case updateDefaultBranch
    case readOrigin
    case findRepositoryRoot
    case readStatus

    /// The user-facing phrase, including the preposition connecting it to the source.
    public var description: String {
      switch self {
      case .clone: "clone"
      case .fetch: "fetch"
      case .listRemoteReferences: "list remote refs for"
      case .listTags: "list tags for"
      case .resolveRevision: "read a revision from"
      case .countCommits: "count commits in"
      case .listReferences: "list references for"
      case .updateReference: "retain a revision for"
      case .deleteReference: "release a revision for"
      case .extractRevision: "extract a revision from"
      case .updateDefaultBranch: "update the default branch for"
      case .readOrigin: "read the origin of"
      case .findRepositoryRoot: "find the repository root for"
      case .readStatus: "read the status of"
      }
    }
  }

  /// The typed action consumers use to classify the failure.
  public let operation: Operation
  /// The source location or URL, independent of its cached representation.
  public let source: String
  /// Git's diagnostic lines with progress removed and internal paths replaced by the source.
  public let stderr: String
  /// The executable and each argument, unmodified, for debugging only. Classify with `operation`.
  public let command: [String]
  /// Git's exit status, for debugging only. Classify with `operation`.
  public let exitCode: Int32

  init(
    operation: Operation, source: String, stderr: String, command: [String], exitCode: Int32,
    replacingPaths paths: [URL] = []
  ) {
    self.operation = operation
    self.source = source
    self.command = command
    self.exitCode = exitCode
    // Git renders carriage returns as question marks in some diagnostics.
    let replacements = Set(
      paths.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        .flatMap { [$0, $0.replacingOccurrences(of: "\r", with: "?")] }
    ).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    var diagnostic = stderr
    for path in replacements {
      diagnostic = diagnostic.replacingOccurrences(of: path, with: source)
    }
    self.stderr = diagnostic.components(separatedBy: .newlines).compactMap { line -> String? in
      let line = line.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !Self.isProgress(line) else { return nil }
      return line
    }.joined(separator: "\n")
  }

  public var description: String {
    let summary = "Git could not \(operation.description) \(source)."
    return stderr.isEmpty ? summary : summary + "\n" + stderr
  }

  private static func isProgress(_ line: String) -> Bool {
    if line.range(
      of: #"^Cloning into (?:bare repository )?'.*'\.\.\.$"#, options: .regularExpression)
      != nil
    {
      return true
    }
    let progress = line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line
    let bytes = #"[0-9]+(?:\.[0-9]+)? (?:bytes|[KMGTPE]iB)"#
    let percentage =
      #"[0-9]+%\s+\([0-9]+/[0-9]+\)(?:, \#(bytes)(?: \| \#(bytes)/s)?)?(?:, done\.)?"#
    let phase =
      #"(?:Counting|Compressing|Enumerating|Receiving|Writing) objects|Resolving deltas|Updating files|Checking out files|Filtering content|Checking connectivity|Updating the index"#
    let patterns = [
      #"^\#(percentage)$"#,
      #"^(?:\#(phase)):\s+(?:\#(percentage)|[0-9]+(?:, done\.)?|done\.)$"#,
      #"^Total [0-9]+ \(delta [0-9]+\), reused [0-9]+ \(delta [0-9]+\), pack-reused [0-9]+(?: \(from [0-9]+\))?$"#,
    ]
    return patterns.contains { progress.range(of: $0, options: .regularExpression) != nil }
  }
}
