import Foundation

/// A failed Git operation. Consumers can display the description and supply their own remedy.
public struct GitError: Error, CustomStringConvertible, Equatable, Sendable {
  /// The user-facing action, including any preposition connecting it to the source.
  public let operation: String
  /// The source location or URL, independent of its cached representation.
  public let source: String
  /// Git's diagnostic lines with progress removed and internal paths replaced by the source.
  public let stderr: String
  /// The executable and each argument, unmodified, for debugging rather than user presentation.
  public let command: [String]
  public let exitCode: Int32

  init(
    operation: String, source: String, stderr: String, command: [String], exitCode: Int32,
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
    let summary = "Git could not \(operation) \(source)."
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
