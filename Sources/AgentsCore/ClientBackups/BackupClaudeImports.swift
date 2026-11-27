import Foundation
import Markdown

enum BackupClaudeImports {
  static let archivePrefix = "claude-import:"

  struct File: Hashable {
    let root: String
    let path: String

    init(root: String, path: String) {
      self.root = root.hasPrefix(archivePrefix) ? String(root.dropFirst(archivePrefix.count)) : root
      self.path = path
    }
  }

  struct Locations {
    let home: URL
    let client: URL
    let projects: [String: URL]
    private let searchRoots: [(key: String, path: String)]

    init(home: URL, client: URL, projects: [String: URL]) {
      self.home = home
      self.client = client
      self.projects = projects
      let roots =
        projects.map { (key: $0.key, path: $0.value.standardizedFileURL.path) }
        + [(key: "client", path: client.standardizedFileURL.path)]
      searchRoots = roots.sorted {
        if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
        return $0.key < $1.key
      }
    }

    func url(_ file: File) -> URL? {
      let root = file.root == "client" ? client : projects[file.root]
      return root?.appendingPathComponent(file.path)
    }

    func resolve(_ token: String, from file: File) -> File? {
      guard let document = url(file) else { return nil }
      let target: URL
      if token.hasPrefix("~/") {
        target = home.appendingPathComponent(String(token.dropFirst(2)))
      } else if token.hasPrefix("/") {
        target = URL(fileURLWithPath: token)
      } else if !token.hasPrefix("~") {
        target = document.deletingLastPathComponent().appendingPathComponent(token)
      } else {
        return nil
      }
      let path = target.standardizedFileURL.path
      for (key, root) in searchRoots where path.hasPrefix(root + "/") {
        let relative = String(path.dropFirst(root.count + 1))
        guard let parts = try? BackupIO.components(relative), allows(parts) else { return nil }
        return File(root: key, path: relative)
      }
      return nil
    }
  }

  private struct Reference {
    let token: String
    let range: Range<String.Index>
  }

  static func allows(_ parts: [String]) -> Bool {
    !parts.isEmpty
      && parts.enumerated().allSatisfy { index, part in
        !BackupScope.excluded(part) && (!part.hasPrefix(".") || (index == 0 && part == ".claude"))
      }
  }

  static func isEntry(_ file: File, projects: [String: URL]) -> Bool {
    if file.root == "client" {
      return ["CLAUDE.md", "CLAUDE.local.md"].contains(file.path)
        || (file.path.hasPrefix("rules/") && file.path.hasSuffix(".md"))
    }
    guard projects[file.root] != nil else { return false }
    return BackupScope.projectContextNames(.claudeCode).contains(
      file.path.split(separator: "/").last.map(String.init) ?? "")
      || (file.path.hasPrefix(".claude/rules/") && file.path.hasSuffix(".md"))
  }

  static func closure(
    entries: [File], locations: Locations, load: (File) throws -> Data?
  ) throws -> Set<File> {
    var depths: [File: Int] = [:]
    func visit(_ file: File, depth: Int) throws {
      if let prior = depths[file], prior <= depth { return }
      guard let bytes = try load(file) else {
        throw ClientBackupError.invalidLocation(locations.url(file)?.path ?? file.path)
      }
      depths[file] = depth
      guard depth < 4, let source = String(data: bytes, encoding: .utf8) else { return }
      for reference in try references(source) {
        if let target = locations.resolve(reference.token, from: file) {
          try visit(target, depth: depth + 1)
        }
      }
    }
    for entry in entries { try visit(entry, depth: 0) }
    return Set(depths.keys)
  }

  static func relocated(
    _ bytes: Data, file: File, source: Locations, destination: Locations
  ) throws -> Data? {
    guard let document = String(data: bytes, encoding: .utf8) else { return nil }
    var edits: [(Range<String.Index>, String)] = []
    for reference in try references(document) {
      guard let target = source.resolve(reference.token, from: file),
        destination.resolve(reference.token, from: file) != target,
        let url = destination.url(target)
      else { continue }
      edits.append((reference.range, url.path.replacingOccurrences(of: " ", with: "\\ ")))
    }
    guard !edits.isEmpty else { return nil }
    var result = document
    for (range, replacement) in edits.reversed() {
      result.replaceSubrange(range, with: replacement)
    }
    return Data(result.utf8)
  }

  private static func references(_ source: String) throws -> [Reference] {
    var lineStarts = [0]
    for (index, byte) in source.utf8.enumerated() where byte == 0x0a {
      lineStarts.append(index + 1)
    }
    var code: [Range<Int>] = []
    let document = Document(parsing: source, options: [.disableSmartOpts])
    func visit(_ node: any Markup) {
      if node is CodeBlock || node is InlineCode || node is HTMLBlock {
        if let range = node.range, lineStarts.indices.contains(range.lowerBound.line - 1),
          lineStarts.indices.contains(range.upperBound.line - 1)
        {
          let lower = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
          let upper = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
          if lower <= upper { code.append(lower..<upper) }
        }
        return
      }
      for child in node.children { visit(child) }
    }
    visit(document)
    let pattern = try NSRegularExpression(pattern: #"(?<![\w@'"\x60])@((?:\\ |[^\s<>'"\x60\\])+)"#)
    let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
    return matches.compactMap { match in
      guard let whole = Range(match.range, in: source),
        let range = Range(match.range(at: 1), in: source)
      else { return nil }
      let offset = source.utf8.distance(from: source.utf8.startIndex, to: whole.lowerBound)
      guard !code.contains(where: { $0.contains(offset) }) else { return nil }
      return Reference(
        token: source[range].replacingOccurrences(of: "\\ ", with: " "), range: range)
    }
  }
}
