import AgentsCore
import Foundation

/// Pure UTF-8 transformations. Filesystem access and lifecycle authorization belong to the caller.
public enum Instructions {
  public static func validateSource(_ bytes: Data, id: String) throws -> InstructionSection {
    let document = try MarkdownDocument(bytes: bytes)
    func invalid(_ reason: String) -> InstructionError {
      .invalidSource(id: id, reason: reason)
    }
    guard let first = document.topLevelHeadings.first, first.level == 1, first.isATX,
      document.lines[..<first.lines.lowerBound].allSatisfy(\.isBlank)
    else {
      throw invalid("the file must start with a level-1 ATX heading.")
    }
    guard document.headings.filter({ $0.level == 1 }).count == 1 else {
      throw invalid("exactly one level-1 heading is required.")
    }
    guard document.headings.allSatisfy(\.isATX) else {
      throw invalid("Setext headings are not allowed; use ATX headings.")
    }
    guard !document.endsInCode else { throw invalid("the file ends inside a code block.") }
    guard !document.endsInHTML else { throw invalid("the file ends inside an HTML block.") }
    guard document.markers.isEmpty else { throw invalid("managed marker lines are not allowed.") }
    let content = MarkdownDocument.content(document.lines[...])
    return InstructionSection(
      id: id, heading: first.key, hash: hash(bytes), content: content,
      document: MarkdownDocument(content))
  }

  /// Reports custom-section adoptions and conflicts without side effects. Empty sections remove the block.
  /// A caller previewing conflicts uses `replaceConflicts`, then decides whether to persist the result.
  public static func assemble(
    _ bytes: Data, sections: [InstructionSection],
    options: InstructionOptions = InstructionOptions()
  ) throws -> InstructionAssembly {
    try validateSelection(sections)
    if sections.isEmpty { return try remove(from: bytes) }
    let document = try MarkdownDocument(bytes: bytes)
    let oldBlock = try document.managedBlock()
    let selectedHeadings = Set(sections.map(\.heading))
    let title = document.topLevelHeadings.first {
      $0.level == 1 && $0.lines.lowerBound < (oldBlock?.lowerBound ?? document.lines.count)
        && !selectedHeadings.contains($0.key)
    }
    let offset = options.headingOffset ?? (title == nil ? 0 : 1)
    guard (0...1).contains(offset) else { throw InstructionError.invalidHeadingOffset(offset) }
    let rendered = try sections.map { try render($0, offset: offset) }
    var removals: [Range<Int>] = []
    var adopted: [String] = []
    var conflicts: [InstructionConflict] = []
    for (section, content) in zip(sections, rendered) {
      let identity = HeadingIdentity(level: 1 + offset, text: section.heading)
      let matches = (document.sections[identity] ?? []).filter {
        !(oldBlock?.contains($0.headingLine) ?? false)
      }
      if matches.count > 1 {
        throw InstructionError.ambiguousMatch(
          sectionID: section.id, lines: matches.map { $0.headingLine + 1 })
      }
      if let match = matches.first {
        let existing = MarkdownDocument.content(
          match.contentRanges.flatMap { document.lines[$0] }[...])
        removals.append(contentsOf: match.contentRanges)
        if existing.utf8.elementsEqual(content.utf8) {
          adopted.append(section.id)
        } else {
          conflicts.append(
            InstructionConflict(
              sectionID: section.id, existing: existing, proposed: content,
              difference: difference(from: existing, to: content)))
        }
      }
    }
    if !conflicts.isEmpty && !options.replaceConflicts {
      throw InstructionError.conflictingSections(conflicts)
    }
    let insertion: Int
    if let oldBlock {
      insertion = oldBlock.lowerBound
      removals.append(oldBlock)
    } else if let earliest = removals.map(\.lowerBound).min() {
      insertion = earliest
    } else if let title {
      insertion =
        document.topLevelHeadings.first { $0.lines.lowerBound >= title.lines.upperBound }?
        .lines.lowerBound ?? document.lines.count
    } else {
      insertion = 0
    }
    var prefix: [MarkdownLine] = []
    var suffix: [MarkdownLine] = []
    removals.sort { $0.lowerBound < $1.lowerBound }
    var removalIndex = 0
    for (index, line) in document.lines.enumerated() {
      while removalIndex < removals.count, removals[removalIndex].upperBound <= index {
        removalIndex += 1
      }
      if removalIndex < removals.count, removals[removalIndex].contains(index) { continue }
      if index < insertion { prefix.append(line) } else { suffix.append(line) }
    }
    // Exactly one adjacent blank belongs to the block; any additional blanks remain custom bytes.
    if prefix.last?.isBlank == true { prefix.removeLast() }
    if suffix.first?.isBlank == true { suffix.removeFirst() }
    let before = prefix.map(\.raw).joined()
    let after = suffix.map(\.raw).joined()
    let block =
      MarkdownDocument.begin + "\n" + rendered.joined(separator: "\n\n")
      + "\n" + MarkdownDocument.end + "\n"
    let output = separatedPrefix(before) + block + (after.isEmpty ? "" : "\n" + after)
    try validateAssembly(output, expected: block)
    let previous = oldBlock.map { document.normalized($0) }
    return InstructionAssembly(
      bytes: document.byteOrderMark + Data(output.utf8), headingOffset: offset, block: block,
      blockHash: hash(Data(block.utf8)),
      adoptedSections: adopted, conflicts: conflicts,
      blockDifference: previous.flatMap {
        $0.utf8.elementsEqual(block.utf8) ? nil : difference(from: $0, to: block)
      },
      hasCustomContent: !before.isEmpty || !after.isEmpty)
  }

  /// Removes the entire block and its adjacent separating blanks, retaining all other custom bytes
  /// except trailing blank lines and the final line ending, which become a single LF.
  public static func remove(from bytes: Data) throws -> InstructionAssembly {
    let document = try MarkdownDocument(bytes: bytes)
    guard let block = try document.managedBlock() else {
      return InstructionAssembly(
        bytes: bytes, headingOffset: 0, block: nil, blockHash: nil, adoptedSections: [],
        conflicts: [],
        blockDifference: nil, hasCustomContent: !document.lines.isEmpty)
    }
    var lower = block.lowerBound
    var upper = block.upperBound
    if lower > 0, document.lines[lower - 1].isBlank { lower -= 1 }
    if upper < document.lines.count, document.lines[upper].isBlank { upper += 1 }
    var custom = Array(document.lines[..<lower]) + Array(document.lines[upper...])
    while custom.last?.isBlank == true { custom.removeLast() }
    var output = custom.dropLast().map(\.raw).joined()
    if let last = custom.last { output += last.text + "\n" }
    try validateAssembly(output, expected: nil)
    return InstructionAssembly(
      bytes: document.byteOrderMark + Data(output.utf8), headingOffset: 0, block: nil,
      blockHash: nil, adoptedSections: [],
      conflicts: [], blockDifference: difference(from: document.normalized(block), to: ""),
      hasCustomContent: !output.isEmpty)
  }

  /// Supply the block reconstructed from locked sources to receive a text difference on drift.
  /// Line endings inside the block are normalized to LF before hashing and comparison.
  public static func detectDrift(
    in bytes: Data, lockedBlockHash: String, lockedBlock: String? = nil
  ) throws -> InstructionDrift {
    var baseline: String?
    if let lockedBlock {
      let expected = MarkdownDocument(lockedBlock)
      guard let range = try expected.managedBlock(), range == 0..<expected.lines.count,
        hash(Data(expected.normalized(range).utf8)) == lockedBlockHash
      else { throw InstructionError.invalidLockedBlock }
      baseline = expected.normalized(range)
    }
    let document = try MarkdownDocument(bytes: bytes)
    guard let range = try document.managedBlock() else { return .missingBlock }
    let actual = document.normalized(range)
    if hash(Data(actual.utf8)) == lockedBlockHash { return .clean }
    return .drifted(
      actualBlock: actual,
      difference: baseline.map { difference(from: $0, to: actual) })
  }

  /// Source headings are retained. Custom text is appended verbatim after one separating blank line.
  public static func renderChatGPT(
    sections: [InstructionSection], customContent: Data? = nil
  ) throws -> Data {
    guard !sections.isEmpty else { throw InstructionError.emptyPrompt }
    try validateSelection(sections)
    var output = Data((sections.map(\.content).joined(separator: "\n\n") + "\n").utf8)
    if let customContent, !customContent.isEmpty {
      guard String(data: customContent, encoding: .utf8) != nil else {
        throw InstructionError.invalidUTF8
      }
      output.append(10)
      output.append(customContent)
    }
    return output
  }

  /// Source-qualified identities installed in both scopes, in project order, for doctor warnings.
  public static func sectionsInBothScopes(user: [String], project: [String]) -> [String] {
    let installed = Set(user)
    var seen: Set<String> = []
    return project.filter { installed.contains($0) && seen.insert($0).inserted }
  }

  static func hash(_ bytes: Data) -> String { "sha256:" + FileHash.sha256Hex(data: bytes) }

  static func validateAssembly(_ text: String, expected: String?) throws {
    let document = MarkdownDocument(text)
    do {
      let actual = try document.managedBlock().map { document.normalized($0) }
      guard actual == expected else { throw InstructionError.invalidAssembly }
    } catch {
      throw InstructionError.invalidAssembly
    }
  }

  static func separatedPrefix(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    return text + (text.utf8.last == 10 ? "\n" : "\n\n")
  }

  private static func validateSelection(_ sections: [InstructionSection]) throws {
    let byHeading = Dictionary(grouping: sections, by: \.heading)
    for section in sections {
      if let duplicates = byHeading[section.heading], duplicates.count > 1 {
        throw InstructionError.duplicateHeading(
          heading: section.heading, sectionIDs: duplicates.map(\.id))
      }
    }
  }

  private static func render(_ section: InstructionSection, offset: Int) throws -> String {
    var lines = section.document.lines.map(\.text)
    for heading in section.document.headings {
      guard heading.level + offset <= 6 else {
        throw InstructionError.headingOverflow(
          sectionID: section.id, level: heading.level, offset: offset)
      }
      let line = heading.lines.lowerBound
      let index = lines[line].utf8.index(
        lines[line].utf8.startIndex, offsetBy: heading.openingOffset!)
      lines[line].insert(contentsOf: String(repeating: "#", count: offset), at: index)
    }
    return lines.joined(separator: "\n")
  }

  static func difference(from old: String, to new: String) -> String {
    let before = MarkdownLine.parse(old).map(\.text)
    let after = MarkdownLine.parse(new).map(\.text)
    let changes = after.map { Data($0.utf8) }.difference(from: before.map { Data($0.utf8) })
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in changes {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    var output = [
      "--- existing", "+++ proposed",
      "@@ -\(before.isEmpty ? 0 : 1),\(before.count) +\(after.isEmpty ? 0 : 1),\(after.count) @@",
    ]
    var left = 0
    var right = 0
    while left < before.count || right < after.count {
      if removed.contains(left) {
        output.append("-" + before[left])
        left += 1
      } else if inserted.contains(right) {
        output.append("+" + after[right])
        right += 1
      } else {
        output.append(" " + before[left])
        left += 1
        right += 1
      }
    }
    if !old.isEmpty, old.utf8.last != 10, old.utf8.last != 13 {
      output.append("\\ No newline at end of existing text")
    }
    if !new.isEmpty, new.utf8.last != 10, new.utf8.last != 13 {
      output.append("\\ No newline at end of proposed text")
    }
    return output.joined(separator: "\n") + "\n"
  }
}
