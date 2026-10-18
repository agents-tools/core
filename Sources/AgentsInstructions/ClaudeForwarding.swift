import Foundation
import Markdown

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

  /// Recognizes a complete, unformatted import line outside code/HTML, including a managed block.
  /// Inline mentions do not suppress the caller's managed import, even if Claude could load them.
  public static func containsImport(in bytes: Data, at path: ClaudeInstructionPath) throws -> Bool {
    let document = try MarkdownDocument(bytes: bytes)
    _ = try document.managedBlock()
    var prefix = "agents-forwarding-line-"
    let original = document.lines.map(\.raw).joined()
    while original.contains(prefix) { prefix += "x" }
    var candidates: Set<String> = []
    let probe = document.lines.enumerated().map { index, line in
      guard isEquivalentImport(line.text, at: path) else { return line.raw }
      let token = prefix + String(index)
      candidates.insert(token)
      let indentation = line.text.prefix { $0 == " " || $0 == "\t" }
      let trailing = line.text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
      return String(indentation) + token + String(trailing) + line.ending
    }.joined()
    guard !candidates.isEmpty else { return false }
    // Replacing whole candidate lines preserves their Markdown context. Only a plain paragraph
    // text node can establish forwarding; multiline code, HTML, and formatting absorb the token.
    let parsed = Document(parsing: probe, options: [.disableSmartOpts])
    return parsed.children.contains { block in
      guard let paragraph = block as? Paragraph else { return false }
      return paragraph.children.contains { node in
        guard let text = node as? Text else { return false }
        return candidates.contains(text.string.trimmingCharacters(in: .whitespaces))
      }
    }
  }

  private static func isEquivalentImport(_ line: String, at path: ClaudeInstructionPath) -> Bool {
    let input = Array(line.trimmingCharacters(in: .whitespaces).utf8)
    guard input.first == 64 else { return false }
    var reference: [UInt8] = []
    var cursor = 1
    let forbidden = Set(" \t\r\n\"'`<>[](){};,*_".utf8)
    while cursor < input.count {
      let byte = input[cursor]
      if byte == 92, cursor + 1 < input.count, input[cursor + 1] == 32 {
        reference.append(32)
        cursor += 2
      } else {
        guard !forbidden.contains(byte) else { return false }
        reference.append(byte)
        cursor += 1
      }
    }
    guard !reference.isEmpty, reference.first != 47, reference.last != 47 else { return false }
    let name = String(decoding: reference, as: UTF8.self)
    var components = path == .directory ? [".claude"] : []
    for part in name.split(separator: "/") where part != "." {
      if part == "..", let last = components.last, last != ".." {
        components.removeLast()
      } else {
        components.append(String(part))
      }
    }
    return components == ["AGENTS.md"]
  }

  /// Uses root, directory, local precedence regardless of input order. A root symlink wins.
  /// A standalone equivalent import in any project Claude file already provides forwarding.
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
