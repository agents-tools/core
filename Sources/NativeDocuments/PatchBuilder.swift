import Foundation

struct BytePatch {
  let range: Range<Int>
  let bytes: [UInt8]
}

struct PatchBuilder {
  let document: NativeDocument
  let region: NativeRegion
  var patches: [BytePatch] = []
  var budget: NativeDocumentBudget { document.budget }
  var toml: Bool { document.format == .toml }
  var newline: String {
    get throws {
      var lf = false
      var crlf = false
      for i in document.source.indices where document.source[i] == 10 {
        try budget.step()
        if i > 0 && document.source[i - 1] == 13 { crlf = true } else { lf = true }
      }
      if lf && crlf { throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, region, []) }
      return crlf ? "\r\n" : "\n"
    }
  }
  mutating func patch(_ range: Range<Int>, _ text: String = "") throws {
    try budget.allocate(text.utf8.count + 1, stage: "patch")
    try budget.step(text.utf8.count)
    patches.append(BytePatch(range: range, bytes: Array(text.utf8)))
  }
  func encoded(_ node: Node) throws -> String {
    let renderer = NativeRenderer(format: document.format, budget: budget, region: region)
    try budget.step()
    switch node.kind {
    case .string: return try renderer.string(node.text)
    case .integer, .decimal, .boolean, .null: return node.raw.isEmpty ? node.text : node.raw
    case .array:
      var values: [String] = []
      for e in node.elements { values.append(try encoded(e)) }
      return try nativeJoin(values, prefix: "[", suffix: "]", separator: ", ", budget: budget)
    case .object:
      var values: [String] = []
      for m in node.members {
        values.append(try renderer.string(m.key) + (toml ? " = " : ": ") + encoded(m.node))
      }
      return try nativeJoin(values, prefix: "{", suffix: "}", separator: ", ", budget: budget)
    case .atom:
      throw NativeDocumentError.unrepresentableValue(document.format, region, "nativeAtom")
    }
  }
  mutating func diff(_ old: Node, desired: Node, path: [NativePathStep]) throws {
    if try old.equal(to: desired, budget: budget) { return }
    if old.kind == .object && desired.kind == .object {
      var retained: [Int] = []
      var added: [Member] = []
      for (i, m) in old.members.enumerated() {
        if let next = try desired.member(m.key, budget: budget) {
          retained.append(i)
          try diff(m.node, desired: desired.members[next].node, path: path + [.key(m.key)])
        } else {
          try eraseMember(m, parent: old)
        }
      }
      if toml, let container = old.inline ? old : old.enclosingInline {
        try pruneInlineCommas(in: container)
      } else if old.inline && retained.count != old.members.count {
        let keepCommas = Set(retained.dropLast().compactMap { old.members[$0].comma?.lowerBound })
        for m in old.members {
          if let comma = m.comma, !keepCommas.contains(comma.lowerBound) { try patch(comma) }
        }
      }
      for m in desired.members where try old.member(m.key, budget: budget) == nil {
        added.append(m)
      }
      if !added.isEmpty {
        try insertMembers(
          added, in: old, path: path, remaining: retained.count,
          survivors: retained.map { old.members[$0] })
      }
      return
    }
    if old.kind == .array && desired.kind == .array && old.aot {
      if desired.elements.contains(where: { $0.kind != .object }) {
        for element in old.elements { try eraseTable(element) }
        try arrayAssignment(path: path, rendered: encoded(desired))
        return
      }
      let common = min(old.elements.count, desired.elements.count)
      for i in 0..<common { try diff(old.elements[i], desired: desired.elements[i], path: path) }
      for element in old.elements.dropFirst(common) { try eraseTable(element) }
      if desired.elements.isEmpty { try arrayAssignment(path: path) }
      if desired.elements.count > common {
        try budget.allocate(desired.elements.count - common, stage: "AoT append")
        try appendTables(Array(desired.elements.dropFirst(common)), path: path)
      }
      return
    }
    guard let range = old.range else {
      throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, region, old.headers)
    }
    if try document.hasComments(old) {
      throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, region, [range])
    }
    try patch(range, encoded(desired))
  }
  mutating func eraseMember(_ member: Member, parent: Node) throws {
    if let entry = member.entry {
      if try document.comments.contains(where: {
        try budget.step()
        return entry.overlaps($0)
      }) {
        throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, region, [entry])
      }
      try patch(entry)
    } else if toml && !parent.inline {
      try eraseTable(member.node)
    } else {
      throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, region, [])
    }
  }
  mutating func eraseTable(_ node: Node) throws {
    for header in node.headers { try patch(header) }
    for m in node.members {
      if let entry = m.entry {
        if try document.comments.contains(where: {
          try budget.step()
          return entry.overlaps($0)
        }) {
          throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, region, [entry])
        }
        try patch(entry)
      } else {
        try eraseTable(m.node)
      }
    }
    if node.aot { for e in node.elements { try eraseTable(e) } }
  }
  mutating func remove(_ node: Node, path: [NativePathStep]) throws {
    let parentPath = NativeRegion(Array(path.dropLast()))
    guard let parent = try document.resolve(parentPath, on: document.root), let last = path.last
    else { throw NativeDocumentError.ownershipMismatch(region) }
    switch last {
    case .key(let key):
      guard let i = try parent.member(key, budget: budget) else {
        throw NativeDocumentError.ownershipMismatch(region)
      }
      try eraseMember(parent.members[i], parent: parent)
      if toml, let container = parent.inline ? parent : parent.enclosingInline {
        try pruneInlineCommas(in: container)
      } else if parent.inline {
        if let comma = parent.members[i].comma {
          try patch(comma)
        } else if i > 0, let comma = parent.members[i - 1].comma {
          try patch(comma)
        }
      }
    case .occurrence(let evidence):
      let i = try document.occurrence(evidence, in: parent, region: region)
      if parent.aot {
        try eraseTable(node)
        if parent.elements.count == 1 { try arrayAssignment(path: Array(path.dropLast())) }
      } else {
        guard let range = node.range else {
          throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, region, [])
        }
        if try document.hasComments(node) {
          throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, region, [range])
        }
        try patch(range)
        if i < parent.commas.count {
          try patch(parent.commas[i])
        } else if i > 0 && i - 1 < parent.commas.count {
          try patch(parent.commas[i - 1])
        }
      }
    }
  }
  private func entryRemoved(_ member: Member) throws -> Bool {
    guard let entry = member.entry else { return false }
    return try patches.contains {
      try budget.step()
      return $0.bytes.isEmpty && $0.range.lowerBound <= entry.lowerBound
        && $0.range.upperBound >= entry.upperBound
    }
  }
  private func survivingInlineMembers(in container: Node) throws -> [Member] {
    var surviving: [Member] = []
    for entry in try container.inlineEntries(budget) {
      let member = entry.parent.members[entry.index]
      if try !entryRemoved(member) {
        try budget.allocate(1, stage: "inline survivors")
        surviving.append(member)
      }
    }
    return surviving
  }
  private mutating func pruneInlineCommas(in container: Node) throws {
    let surviving = try survivingInlineMembers(in: container)
    for entry in try container.inlineEntries(budget) {
      let member = entry.parent.members[entry.index]
      if let comma = member.comma,
        try entryRemoved(member) || member.entry == surviving.last?.entry
      {
        try patch(comma)
      }
    }
  }
  mutating func insert(path: [NativePathStep], value: Node, root: Node) throws {
    var parent = root
    var existing: [NativePathStep] = []
    for (i, step) in path.enumerated() {
      switch step {
      case .occurrence(let evidence):
        do {
          parent = parent.elements[try document.occurrence(evidence, in: parent, region: region)]
          existing.append(step)
        } catch NativeDocumentError.ownershipMismatch {
          guard i == path.count - 1 else { throw NativeDocumentError.ownershipMismatch(region) }
          if parent.aot {
            try appendTables([value], path: existing)
          } else {
            try appendValues([value], in: parent)
          }
          return
        }
      case .key(let key):
        if let m = try parent.member(key, budget: budget) {
          parent = parent.members[m].node
          existing.append(step)
          continue
        }
        let remainder = Array(path.dropFirst(i + 1))
        var new = value
        for step in remainder.reversed() {
          guard case .key(let key) = step else {
            throw NativeDocumentError.unsupportedEdit(.ambiguousOccurrence, region, [])
          }
          try budget.node(depth: remainder.count)
          let container = Node(.object)
          container.members = [Member(key: key, node: new)]
          new = container
        }
        try insertMembers(
          [Member(key: key, node: new)], in: parent, path: existing, remaining: parent.members.count
        )
        return
      }
    }
    throw NativeDocumentError.ownershipMismatch(region)
  }
  private mutating func arrayAssignment(path: [NativePathStep], rendered: String = "[]") throws {
    guard case .key(let key) = path.last,
      let parent = try document.resolve(NativeRegion(Array(path.dropLast())), on: document.root)
    else { throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, region, []) }
    let renderer = NativeRenderer(format: document.format, budget: budget, region: region)
    let nl = try newline
    let at: Int
    let assignmentKey: String
    if let insertion = parent.insertion {
      at = insertion
      assignmentKey = try renderer.string(key)
    } else {
      at = document.root.insertion ?? 0
      var keys: [String] = []
      for step in path {
        guard case .key(let key) = step else {
          throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, region, [])
        }
        keys.append(try renderer.string(key))
      }
      assignmentKey = keys.joined(separator: ".")
    }
    try patch(
      at..<at,
      (at > 0 && document.source[at - 1] != 10 ? nl : "") + assignmentKey + " = " + rendered + nl)
  }

  private mutating func appendTables(_ values: [Node], path: [NativePathStep]) throws {
    let renderer = NativeRenderer(format: document.format, budget: budget, region: region)
    var keys: [String] = []
    var current = document.root
    for step in path {
      switch step {
      case .key(let key):
        keys.append(try renderer.string(key))
        if let i = try current.member(key, budget: budget) { current = current.members[i].node }
      case .occurrence(let evidence):
        let i = try document.occurrence(evidence, in: current, region: region)
        guard i == current.elements.count - 1 else {
          throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, region, [])
        }
        current = current.elements[i]
      }
    }
    let nl = try newline
    var blocks: [String] = []
    for value in values {
      guard value.kind == .object else {
        throw NativeDocumentError.unrepresentableValue(document.format, region, "arrayTableElement")
      }
      var pairs: [String] = []
      for member in value.members {
        pairs.append(try renderer.string(member.key) + " = " + encoded(member.node))
      }
      blocks.append(
        try nativeJoin(
          pairs, prefix: "[[" + keys.joined(separator: ".") + "]]" + nl, suffix: "", separator: nl,
          budget: budget))
    }
    let at = document.source.count
    try patch(
      at..<at,
      (at > 0 && document.source[at - 1] != 10 ? nl : "")
        + (try nativeJoin(blocks, prefix: "", suffix: nl, separator: nl, budget: budget)))
  }

  private mutating func appendValues(_ values: [Node], in array: Node) throws {
    guard array.kind == .array, let range = array.range else {
      throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, region, [])
    }
    let at = range.upperBound - 1
    var pieces: [String] = []
    for value in values { pieces.append(try encoded(value)) }
    let comma = !array.elements.isEmpty && array.commas.count < array.elements.count
    if document.source[range].contains(10), let closeIndent = try indentation(at: at) {
      let nl = try newline
      var indent = closeIndent + "  "
      if let first = array.elements.first?.range, let local = try indentation(at: first.lowerBound)
      {
        indent = local
      }
      if comma, let end = array.elements.last?.range?.upperBound { try patch(end..<end, ",") }
      let start = at - closeIndent.utf8.count
      try patch(
        start..<start,
        nativeJoin(
          pieces.map { indent + $0 }, prefix: "", suffix: nl, separator: "," + nl, budget: budget))
    } else {
      var insertion = at
      while insertion > range.lowerBound + 1 && [9, 32].contains(document.source[insertion - 1]) {
        try budget.step()
        insertion -= 1
      }
      let separator = array.elements.count > 1 ? " " : ""
      try patch(
        insertion..<insertion,
        nativeJoin(
          pieces, prefix: (comma ? "," : "") + separator, suffix: "", separator: "," + separator,
          budget: budget))
    }
  }

  private func assignment(in parent: Node) throws -> String {
    let fallback = toml ? " = " : ": "
    let first: Member?
    if toml && parent.inline {
      first = try parent.inlineEntries(budget).first.map { $0.parent.members[$0.index] }
    } else {
      first = parent.members.first(where: { $0.keyRange != nil })
    }
    guard let first, let key = first.keyRange, let value = first.node.range else { return fallback }
    let gap = document.source[key.upperBound..<value.lowerBound]
    guard
      try gap.allSatisfy({
        try budget.step()
        return $0 == 9 || $0 == 32 || $0 == (toml ? 61 : 58)
      })
    else { return fallback }
    try budget.allocate(gap.count, stage: "local assignment style")
    return String(decoding: gap, as: UTF8.self)
  }

  private func indentation(at position: Int) throws -> String? {
    var start = position
    while start > 0 && document.source[start - 1] != 10 {
      try budget.step()
      start -= 1
    }
    let prefix = document.source[start..<position]
    guard prefix.allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
    try budget.allocate(prefix.count, stage: "local style")
    return String(decoding: prefix, as: UTF8.self)
  }

  mutating func insertMembers(
    _ members: [Member], in parent: Node, path: [NativePathStep], remaining: Int,
    survivors: [Member]? = nil
  ) throws {
    guard parent.kind == .object else { throw NativeDocumentError.ownershipMismatch(region) }
    let renderer = NativeRenderer(format: document.format, budget: budget, region: region)
    if let container = parent.inline ? parent : parent.enclosingInline {
      let keyPath = parent.inline ? [] : parent.inlineKeyPath
      let surviving = toml ? try survivingInlineMembers(in: container) : survivors ?? parent.members
      let remaining = toml ? surviving.count : remaining
      let parent = container
      guard let at = parent.insertion else {
        throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, region, [])
      }
      let assignment = try assignment(in: parent)
      var pieces: [String] = []
      for m in members {
        var keys: [String] = []
        for key in keyPath {
          try budget.allocate(1, stage: "inline rendered key")
          keys.append(try renderer.string(key))
        }
        try budget.allocate(1, stage: "inline rendered key")
        keys.append(try renderer.string(m.key))
        pieces.append(
          try nativeJoin(keys, prefix: "", suffix: "", separator: ".", budget: budget) + assignment
            + encoded(m.node))
      }
      let first =
        toml
        ? try parent.inlineEntries(budget).first.map { $0.parent.members[$0.index] }
        : parent.members.first
      let multiline = parent.range.map { document.source[$0].contains(10) } ?? false
      let last = surviving.last
      let commaRemoved =
        try last?.comma.map { comma in
          try patches.contains {
            try budget.step()
            return $0.range == comma && $0.bytes.isEmpty
          }
        } ?? false
      let hasComma = last?.comma != nil && !commaRemoved
      if multiline, let closeIndent = try indentation(at: at) {
        let nl = try newline
        var indent = closeIndent + "  "
        if let entry = first?.entry,
          let local = try indentation(at: entry.lowerBound)
        {
          indent = local
        }
        if let last, !hasComma, let entry = last.entry {
          try patch(entry.upperBound..<entry.upperBound, ",")
        }
        let lineStart = at - closeIndent.utf8.count
        let text = try nativeJoin(
          pieces.map { indent + $0 }, prefix: "", suffix: nl, separator: "," + nl, budget: budget)
        try patch(lineStart..<lineStart, text)
      } else {
        var separator = " "
        if let range = parent.range {
          let end = first?.entry?.lowerBound ?? at
          let gap = document.source[(range.lowerBound + 1)..<end]
          if try gap.allSatisfy({
            try budget.step()
            return $0 == 9 || $0 == 32
          }) {
            try budget.allocate(gap.count, stage: "local style")
            separator = String(decoding: gap, as: UTF8.self)
          }
        }
        var insertion = at
        let lower = parent.range.map { $0.lowerBound + 1 } ?? at
        while insertion > lower
          && (document.source[insertion - 1] == 9 || document.source[insertion - 1] == 32)
        {
          try budget.step()
          insertion -= 1
        }
        let text = try nativeJoin(
          pieces, prefix: (remaining > 0 && !hasComma ? "," : "") + separator, suffix: "",
          separator: "," + separator, budget: budget)
        try patch(insertion..<insertion, text)
      }
      return
    }
    guard toml else { throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, region, []) }
    let nl = try newline
    var pieces: [String] = []
    if let at = parent.insertion {
      for m in members {
        pieces.append(try renderer.string(m.key) + assignment(in: parent) + encoded(m.node))
      }
      let prefix = at > 0 && document.source[at - 1] != 10 ? nl : ""
      try patch(at..<at, prefix + pieces.joined(separator: nl) + nl)
    } else {
      // A new child table can be declared independently of a dotted/implicit parent.
      var keys: [String] = []
      for step in path {
        guard case .key(let key) = step else {
          throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, region, [])
        }
        keys.append(try renderer.string(key))
      }
      let at = document.source.count
      let prefix = at > 0 && document.source[at - 1] != 10 ? nl : ""
      var blocks: [String] = []
      var rootPairs: [String] = []
      for m in members {
        let full = keys + [try renderer.string(m.key)]
        if m.node.kind == .object {
          var pairs: [String] = []
          for child in m.node.members {
            pairs.append(try renderer.string(child.key) + " = " + encoded(child.node))
          }
          blocks.append("[" + full.joined(separator: ".") + "]" + nl + pairs.joined(separator: nl))
        } else {
          // A dotted assignment belongs in the root block, before the first header.
          rootPairs.append(full.joined(separator: ".") + " = " + (try encoded(m.node)))
        }
      }
      if !rootPairs.isEmpty {
        let rootAt = document.root.insertion ?? 0
        try patch(
          rootAt..<rootAt,
          nativeJoin(rootPairs, prefix: "", suffix: nl, separator: nl, budget: budget))
      }
      if !blocks.isEmpty { try patch(at..<at, prefix + blocks.joined(separator: nl) + nl) }

    }
  }
  func apply() throws -> Data {
    // Coalesce repeated deletions but reject any other overlap before allocating a result.
    try budget.allocate(patches.count, stage: "patch order")
    var ordered = try patches.sorted {
      try budget.step()
      if $0.range.lowerBound == $1.range.lowerBound { return $0.range.isEmpty && !$1.range.isEmpty }
      return $0.range.lowerBound < $1.range.lowerBound
    }
    var merged: [BytePatch] = []
    for p in ordered {
      try budget.step()
      if let last = merged.last, p.range.lowerBound < last.range.upperBound || p.range == last.range
      {
        guard p.bytes.isEmpty && last.bytes.isEmpty else {
          throw NativeDocumentError.unsupportedEdit(
            .overlappingEdits, region, [p.range, last.range])
        }
        merged.removeLast()
        merged.append(
          BytePatch(
            range: last.range.lowerBound..<max(last.range.upperBound, p.range.upperBound), bytes: []
          ))
      } else {
        merged.append(p)
      }
    }
    ordered = merged
    var size = document.source.count
    for p in ordered {
      size -= p.range.count
      guard p.bytes.count <= Int.max - size else {
        throw NativeDocumentError.budgetExceeded("output bytes")
      }
      size += p.bytes.count
    }
    try budget.allocate(size, stage: "output bytes")
    var output = Data()
    output.reserveCapacity(size)
    var cursor = 0
    for p in ordered {
      try budget.step(p.range.lowerBound - cursor + p.bytes.count)
      output.append(contentsOf: document.source[cursor..<p.range.lowerBound])
      output.append(contentsOf: p.bytes)
      cursor = p.range.upperBound
    }
    try budget.step(document.source.count - cursor)
    output.append(contentsOf: document.source[cursor...])
    // Every original segment outside the selected patch spans is copied exactly once above.
    return output
  }
}
