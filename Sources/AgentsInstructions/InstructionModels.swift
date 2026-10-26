import Foundation

public struct InstructionSection: Sendable, Equatable {
  /// Caller-owned, source-qualified identity, used in reports and scope comparisons.
  public let id: String
  /// Level of the body's first heading.
  public let level: Int
  /// The first heading's Markdown plain text, with whitespace trimmed and collapsed.
  public let heading: String
  public let description: String
  /// Project-relative glob patterns that scope the section, in source order.
  public let paths: [String]
  /// SHA-256 of the original source bytes, including their line endings and any byte order mark.
  public let hash: String
  /// The body as written into targets: no front matter, LF endings, no leading or trailing
  /// blank lines, and the `paths` line after the first heading.
  let content: String

  /// The project-relative directory whose `AGENTS.md` receives the section; empty for the root.
  public var directory: String { Instructions.directory(for: paths) }
}

public enum InstructionDrift: Sendable, Equatable {
  case clean
  case drifted
  case missing
}

/// A Markdown destination that needs a filesystem check, or a raw HTML link.
public struct InstructionLink: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case link
    case image
    case definition
    case html
  }

  public let kind: Kind
  /// The destination as written; for `html`, the HTML text.
  public let destination: String
  /// The decoded local path without query or fragment; nil for `html`.
  public let path: String?
}

public struct InstructionLinkProblem: Sendable, Equatable {
  public let target: String
  public let destination: String
  public let reason: String
}

public enum InstructionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  case invalidUTF8
  case invalidSource(id: String, reason: String)
  case duplicateHeading(heading: String, sectionIDs: [String])
  case unpairedMarker(line: Int)
  case nestedMarker(line: Int)
  case multipleBlocks
  case invalidAssembly
  case invalidLockedBlock
  case invalidLinks([InstructionLinkProblem])
  case unownedTargets([String])
  case ownChanged(name: String)
  case emptyPrompt

  public var description: String {
    switch self {
    case .invalidUTF8:
      return "Instructions must be valid UTF-8."
    case .invalidSource(let id, let reason):
      return "Invalid instructions file '\(id)': \(reason)"
    case .duplicateHeading(let heading, let ids):
      return
        "Sections in one target have the same heading '\(heading)': \(ids.joined(separator: ", "))."
    case .unpairedMarker(let line):
      return "Unpaired managed marker at line \(line)."
    case .nestedMarker(let line):
      return "Nested managed BEGIN marker at line \(line)."
    case .multipleBlocks:
      return "The file contains more than one managed block."
    case .invalidAssembly:
      return "The assembled Markdown does not have the expected structure."
    case .invalidLockedBlock:
      return "The locked content does not match its recorded hash."
    case .invalidLinks(let problems):
      return problems.map { "\($0.target): link '\($0.destination)' \($0.reason)" }
        .joined(separator: "\n")
    case .unownedTargets(let targets):
      return
        "Files that agents did not generate are in the way: \(targets.joined(separator: ", "))."
    case .ownChanged(let name):
      return "Own instructions file '\(name)' changed since the lock."
    case .emptyPrompt:
      return "A ChatGPT prompt must have at least one locked section."
    }
  }

  public var errorDescription: String? { description }
}
