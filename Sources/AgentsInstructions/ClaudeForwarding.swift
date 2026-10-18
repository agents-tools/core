import Foundation

public enum ClaudeInstructionPath: String, Sendable, CaseIterable {
  case root = "CLAUDE.md"
  case directory = ".claude/CLAUDE.md"
  case local = "CLAUDE.local.md"

  public var importLine: String { self == .directory ? "@../AGENTS.md" : "@AGENTS.md" }
}

/// Metadata for an existing project file; the caller resolves symbolic links and reads bytes.
public struct ClaudeInstructionFile: Sendable {
  public let path: ClaudeInstructionPath
  public let bytes: Data
  public let isSymbolicLinkToAgents: Bool

  public init(
    path: ClaudeInstructionPath, bytes: Data = Data(), isSymbolicLinkToAgents: Bool = false
  ) {
    self.path = path
    self.bytes = bytes
    self.isSymbolicLinkToAgents = isSymbolicLinkToAgents
  }
}

public enum ClaudeForwarding: Sendable, Equatable {
  /// No project Claude file exists. Ancestor-file warnings are the caller's responsibility.
  case automatic
  case forwarding(ClaudeInstructionPath)
  case needsImport(ClaudeInstructionPath)

  public static func renderBlock(for path: ClaudeInstructionPath) -> String {
    MarkdownDocument.begin + "\n" + path.importLine + "\n" + MarkdownDocument.end + "\n"
  }

  /// Recognizes standalone imports inside or outside a managed block, excluding code blocks.
  public static func containsImport(in bytes: Data, at path: ClaudeInstructionPath) throws -> Bool {
    let document = try MarkdownDocument(bytes: bytes)
    _ = try document.managedBlock()
    for index in document.structuralLines {
      let line = document.lines[index].trimmed
      guard line.hasPrefix("@") else { continue }
      var reference = String(line.dropFirst())
      if reference.hasPrefix("\""), reference.hasSuffix("\""), reference.count >= 2 {
        reference = String(reference.dropFirst().dropLast())
      }
      if reference.hasPrefix("/") { continue }
      var components = path == .directory ? [".claude"] : []
      for part in reference.split(separator: "/") where part != "." {
        if part == "..", let last = components.last, last != ".." {
          components.removeLast()
        } else {
          components.append(String(part))
        }
      }
      if components == ["AGENTS.md"] { return true }
    }
    return false
  }

  /// Uses root, directory, local precedence regardless of input order. A root symlink wins.
  /// An equivalent import in any project Claude file already provides forwarding.
  public static func classify(_ files: [ClaudeInstructionFile]) throws -> ClaudeForwarding {
    if files.contains(where: { $0.path == .root && $0.isSymbolicLinkToAgents }) {
      return .forwarding(.root)
    }
    let ordered = ClaudeInstructionPath.allCases.flatMap { path in files.filter { $0.path == path }
    }
    for file in ordered {
      if try containsImport(in: file.bytes, at: file.path) { return .forwarding(file.path) }
    }
    return ordered.first.map { .needsImport($0.path) } ?? .automatic
  }
}
