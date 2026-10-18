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
    let replacements = Set(
      paths.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
    ).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    self.stderr = stderr.components(separatedBy: .newlines).compactMap { line -> String? in
      var line = line.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !Self.isProgress(line) else { return nil }
      for path in replacements {
        line = line.replacingOccurrences(of: path, with: source)
      }
      return line
    }.joined(separator: "\n")
  }

  public var description: String {
    let summary = "Git could not \(operation) \(source)."
    return stderr.isEmpty ? summary : summary + "\n" + stderr
  }

  private static func isProgress(_ line: String) -> Bool {
    if line.hasPrefix("Cloning into ") { return true }
    let progress = line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line
    if progress.range(of: #"^[0-9]+%(?:\s|$)"#, options: .regularExpression) != nil { return true }
    if line.hasPrefix("remote: Total "),
      progress.range(of: #"^Total [0-9]+ \(delta [0-9]+\)"#, options: .regularExpression) != nil
    {
      return true
    }
    return progress.range(
      of:
        #"^(?:(?:Counting|Compressing|Enumerating|Receiving|Writing) objects|Resolving deltas|Updating files|Checking out files|Filtering content|Checking connectivity|Updating the index):\s+(?:[0-9]+(?:%|, done\.|$)|done\.)"#,
      options: .regularExpression) != nil
  }
}
