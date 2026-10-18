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

  /// Recognizes unquoted @path tokens, including prose, outside code spans and code blocks.
  public static func containsImport(in bytes: Data, at path: ClaudeInstructionPath) throws -> Bool {
    let document = try MarkdownDocument(bytes: bytes)
    _ = try document.managedBlock()
    let input = Array(bytes)
    let delimiters = Set(" \t\r\n\"'`<>[](){};,".utf8)
    var cursor = 0
    var codeIndex = 0
    while cursor < input.count {
      while codeIndex < document.codeByteRanges.count,
        document.codeByteRanges[codeIndex].upperBound <= cursor
      {
        codeIndex += 1
      }
      if codeIndex < document.codeByteRanges.count,
        document.codeByteRanges[codeIndex].contains(cursor)
      {
        cursor = document.codeByteRanges[codeIndex].upperBound
        continue
      }
      let position = cursor
      cursor += 1
      guard input[position] == 64 else { continue }
      if position > 0 {
        let previous = input[position - 1]
        if !delimiters.contains(previous) || previous == 34 || previous == 39 { continue }
      }
      var reference: [UInt8] = []
      while cursor < input.count {
        let byte = input[cursor]
        if byte == 92, cursor + 1 < input.count, input[cursor + 1] == 32 {
          reference.append(32)
          cursor += 2
        } else if delimiters.contains(byte) {
          break
        } else {
          reference.append(byte)
          cursor += 1
        }
      }
      guard !reference.isEmpty, reference.first != 47, reference.last != 47 else { continue }
      let name = String(decoding: reference, as: UTF8.self)
      var components = path == .directory ? [".claude"] : []
      for part in name.split(separator: "/") where part != "." {
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
