import Foundation

public struct InstructionSection: Sendable, Equatable {
  /// Caller-owned, source-qualified identity, used in reports and scope comparisons.
  public let id: String
  public let heading: String
  /// SHA-256 of the original source bytes, including their line endings.
  public let hash: String
  let content: String
  let document: MarkdownDocument

}

public struct InstructionOptions: Sendable {
  /// Nil recomputes from the title; install passes the locked value (zero or one).
  public var headingOffset: Int?
  /// Applies only to matching custom sections. Existing managed content is rendered anew.
  public var replaceConflicts: Bool

  public init(headingOffset: Int? = nil, replaceConflicts: Bool = false) {
    self.headingOffset = headingOffset
    self.replaceConflicts = replaceConflicts
  }
}

public struct InstructionConflict: Sendable, Equatable {
  public let sectionID: String
  public let existing: String
  public let proposed: String
  public let difference: String
}

public struct InstructionAssembly: Sendable, Equatable {
  public let bytes: Data
  public let headingOffset: Int
  /// Includes both marker lines and a final LF; nil after removing the block.
  public let block: String?
  public let blockHash: String?
  public let adoptedSections: [String]
  public let conflicts: [InstructionConflict]
  /// Difference from the previous managed block, independent of custom-section conflicts.
  public let blockDifference: String?
  /// The caller combines this with its locked `created` flag before deleting a file.
  public let hasCustomContent: Bool
}

public enum InstructionDrift: Sendable, Equatable {
  case clean
  /// A hash cannot reconstruct text. Difference is nil unless the caller supplies the locked block.
  case drifted(actualBlock: String, difference: String?)
  case missingBlock
}

public enum InstructionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  case invalidUTF8
  case invalidSource(id: String, reason: String)
  case invalidHeadingOffset(Int)
  case headingOverflow(sectionID: String, level: Int, offset: Int)
  case duplicateHeading(heading: String, sectionIDs: [String])
  case ambiguousMatch(sectionID: String, lines: [Int])
  case conflictingSections([InstructionConflict])
  case unpairedMarker(line: Int)
  case nestedMarker(line: Int)
  case multipleBlocks
  case invalidAssembly
  case invalidLockedBlock
  case emptyPrompt

  public var description: String {
    switch self {
    case .invalidUTF8:
      return "Instructions must be valid UTF-8."
    case .invalidSource(let id, let reason):
      return "Invalid instructions source '\(id)': \(reason)"
    case .invalidHeadingOffset(let offset):
      return "Heading offset must be 0 or 1; got \(offset)."
    case .headingOverflow(let id, let level, let offset):
      return
        "Section '\(id)' has a level-\(level) heading that exceeds level 6 with offset \(offset)."
    case .duplicateHeading(let heading, let ids):
      return "Selected sections have the same heading '\(heading)': \(ids.joined(separator: ", "))."
    case .ambiguousMatch(let id, let lines):
      return
        "Section '\(id)' matches multiple headings at lines \(lines.map(String.init).joined(separator: ", "))."
    case .conflictingSections(let conflicts):
      return conflicts.map { "Conflicting section '\($0.sectionID)':\n\($0.difference)" }
        .joined(separator: "\n")
    case .unpairedMarker(let line):
      return "Unpaired managed marker at line \(line)."
    case .nestedMarker(let line):
      return "Nested managed BEGIN marker at line \(line)."
    case .multipleBlocks:
      return "The target contains more than one managed block."
    case .invalidAssembly:
      return "The assembled Markdown does not contain exactly the expected managed block."
    case .invalidLockedBlock:
      return "The supplied locked block does not match its hash or managed-block structure."
    case .emptyPrompt:
      return "A ChatGPT prompt must have at least one locked section."
    }
  }

  public var errorDescription: String? { description }
}
