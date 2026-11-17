import AgentsCore
import Foundation

/// Concrete collection and field changes. A patch owns only the selected value/entry and its
/// attached trivia. Structural ambiguity is reported before a candidate can be published.
struct YAMLPatches {
  let document: DeclarationDocument
  private var source: SourceText { document.source }
  private var bytes: [UInt8] { document.bytes }

  func patches(for edit: IREdit, expected: DeclarationValue) throws -> [SourcePatch] {
    switch edit {
    case .set(let pointer, let value): return try set(pointer, value)
    case .insert(let pointer, let index, let value): return try insert(pointer, index, value)
    case .remove(let pointer, let index): return try remove(pointer, index, retainComments: true)
    case .relocate(let origin, let from, let destination, let to):
      let nodes = try children(origin)
      let originalContainer = document.locations[origin]!
      let node = nodes[from]
      let value = IRTree.value(IRTree.root(document.declaration), at: origin)!.elements![from]
      let removal = try remove(origin, from, retainComments: false)
      var insertion = try insert(destination, to, value)
      let carried = document.comments.filter {
        owned(node, container: originalContainer).contains($0.lowerBound)
      }.map { source.spelling($0) }
      let target = document.locations[destination]!
      if !originalContainer.flow, !target.flow, !document.defaulted.contains(destination) {
        let raw = source.spelling(owned(node, container: originalContainer))
        let oldIndent = indentation(at: node.entryRange.lowerBound)
        let targetNodes = try children(destination)
        let newIndent =
          targetNodes.first.map { indentation(at: $0.entryRange.lowerBound) }
          ?? indentation(at: target.range.lowerBound)
        let shifted = raw.components(separatedBy: newline).map { line in
          line.hasPrefix(oldIndent) ? newIndent + line.dropFirst(oldIndent.count) : line
        }.joined(separator: newline)
        insertion = insertion.map {
          SourcePatch(range: $0.range, replacement: movedEntry(shifted, at: $0.range.lowerBound))
        }
      } else if !carried.isEmpty {
        let rendered = YAMLWriter.flow(value)
        let prefix = newline + carried.map { "  " + $0 + newline }.joined() + "  "
        insertion = insertion.map {
          let text = String(decoding: $0.replacement, as: UTF8.self).replacingOccurrences(
            of: rendered, with: prefix + rendered)
          return SourcePatch(range: $0.range, replacement: Array(text.utf8))
        }
      }
      return removal + insertion
    case .move(let pointer, let from, let to):
      guard let container = document.locations[pointer], !document.defaulted.contains(pointer)
      else { throw readOnly(pointer, "missing collection") }
      if container.flow {
        if document.comments.contains(where: { container.range.contains($0.lowerBound) }) {
          var content = flowContent(container)
          content.entries.insert(content.entries.remove(at: from), at: to)
          return [
            SourcePatch(
              range: container.range,
              replacement: Array(renderFlow(content, container: container).utf8))
          ]
        }
        // Common flow collections retain the exact moved value and comments. Delimiters are
        // reconstructed within the collection; nested values and their spelling remain owned.
        let values = IRTree.value(IRTree.root(document.declaration), at: pointer)!.elements!
        var order = Array(values.indices)
        order.insert(order.remove(at: from), at: to)
        let children = try children(pointer)
        let named = isNamed(pointer)
        let text = order.map { i -> String in
          let node = children[i]
          let range = named ? node.entryRange : node.range
          return source.spelling(range)
        }.joined(separator: ", ")
        let opening = named ? "{" : "["
        let closing = named ? "}" : "]"
        return [
          SourcePatch(range: container.range, replacement: Array((opening + text + closing).utf8))
        ]
      }
      let children = try children(pointer)
      let moved = children[from]
      let range = owned(moved, container: container)
      let remaining = children.indices.filter { $0 != from }
      let offset: Int
      if to < remaining.count {
        offset = owned(children[remaining[to]], container: container).lowerBound
      } else {
        offset = owned(children[remaining.last ?? from], container: container).upperBound
      }
      return [
        SourcePatch(range: range, replacement: []),
        SourcePatch(
          range: offset..<offset, replacement: movedEntry(source.spelling(range), at: offset)),
      ]
    }
  }

  private func set(_ pointer: String, _ value: DeclarationValue?) throws -> [SourcePatch] {
    let (parent, key) = split(pointer)
    let absent = document.defaulted.contains(pointer) || document.locations[pointer] == nil
    if absent {
      guard let value, value != .null else { return [] }
      return try addField(parent, key, value)
    }
    let node = document.locations[pointer]!
    if value == nil || value == .null {
      guard let container = mapping(at: parent),
        let pair = container.pairs?.first(where: { $0.key.text == yamlKey(key, parent: parent) })
      else {
        throw readOnly(pointer, "value has no removable mapping entry")
      }
      return try removeEntry(pair.value, container: container, retainComments: true)
    }
    if let next = value?.record, ["git", "local", "index"].contains(next.kind),
      field(pointer) == "sources",
      let old = IRTree.value(IRTree.root(document.declaration), at: pointer)?.record,
      old.kind != next.kind
    {
      let oldKey = old.kind == "git" ? "url" : old.kind == "local" ? "path" : "index"
      let newKey = next.kind == "git" ? "url" : next.kind == "local" ? "path" : "index"
      guard let pair = node.pairs?.first(where: { $0.key.text == oldKey }) else {
        throw readOnly(pointer, "source location has no concrete field")
      }
      var patches = [
        SourcePatch(range: pair.key.range, replacement: Array(YAMLWriter.quote(newKey).utf8)),
        SourcePatch(
          range: pair.value.range, replacement: Array(YAMLWriter.flow(next[newKey]!).utf8)),
      ]
      for field in ["name", "requirement", "subpath"] where old[field] != next[field] {
        patches += try set(pointer + "/" + field, next[field])
      }
      return patches
    }
    var rendered = YAMLWriter.flow(value!, field: field(pointer))
    if key == "value",
      IRTree.value(IRTree.root(document.declaration), at: parent)?.record?.kind == "decimal",
      let text = value?.string
    {
      rendered = "!!float " + YAMLWriter.quote(text)
    }
    // Comments inside a block scalar belong to its header, never its decoded payload.
    let comments = document.comments.filter { node.range.contains($0.lowerBound) }
    if !comments.isEmpty {
      if comments.count == 1, !rendered.contains("\n") {
        rendered += " " + source.spelling(comments[0])
      } else if let container = document.locations[parent], container.items != nil,
        let index = Int(key)
      {
        if container.flow {
          var content = flowContent(container)
          content.entries[index].text = rendered
          content.entries[index].leading += comments.map { source.spelling($0) }
          return [
            SourcePatch(
              range: container.range,
              replacement: Array(renderFlow(content, container: container).utf8))
          ]
        }
        let indent = indentation(at: node.entryRange.lowerBound)
        let prefix = comments.map { source.spelling($0) + newline + indent }.joined()
        return [
          SourcePatch(range: node.entryRange, replacement: Array((prefix + "- " + rendered).utf8))
        ]
      } else {
        throw readOnly(pointer, "replacement has comments without a precise entry boundary")
      }
    }
    if node.range.upperBound > node.range.lowerBound, bytes[node.range.upperBound - 1] == 10,
      !rendered.hasSuffix("\n")
    {
      rendered += newline
    }
    if node.range.isEmpty, node.range.lowerBound > 0,
      [UInt8(ascii: ":"), UInt8(ascii: "-")].contains(bytes[node.range.lowerBound - 1])
    {
      rendered = " " + rendered
    }
    return [SourcePatch(range: node.range, replacement: Array(rendered.utf8))]
  }

  private func addField(_ parent: String, _ key: String, _ value: DeclarationValue) throws
    -> [SourcePatch]
  {
    guard let container = mapping(at: parent) else {
      throw readOnly(parent, "missing owning mapping")
    }
    if document.defaulted.contains(parent) {
      let (owner, field) = split(parent)
      return try addField(owner, field, .dictionary([key: value]))
    }
    let key = yamlKey(key, parent: parent)
    let text = YAMLWriter.quote(key) + ": " + YAMLWriter.flow(value, field: key)
    guard let pairs = container.pairs else {
      throw readOnly(parent, "field owner is not a mapping")
    }
    if container.flow {
      if bytes[container.range.lowerBound] != UInt8(ascii: "{") {
        return [
          SourcePatch(
            range: container.range,
            replacement: Array(("{" + source.spelling(container.range) + ", " + text + "}").utf8))
        ]
      }
      return appendFlow(text, to: container)
    }
    let indent =
      pairs.first.map { indentation(at: $0.key.range.lowerBound) }
      ?? indentation(at: container.range.lowerBound)
    let end =
      pairs.last.map { lineEnd($0.value.entryRange.upperBound) } ?? container.range.upperBound
    return [
      SourcePatch(range: end..<end, replacement: blockEntry(indent + text, at: end))
    ]
  }

  private func insert(_ pointer: String, _ index: Int, _ value: DeclarationValue) throws
    -> [SourcePatch]
  {
    guard let container = document.locations[pointer] else {
      throw readOnly(pointer, "missing collection")
    }
    let children = try children(pointer)
    let named = isNamed(pointer)
    let text: String
    if named {
      let record = value.record!
      text =
        YAMLWriter.quote(record["name"]!.string!) + ": "
        + YAMLWriter.flow(value, field: field(pointer))
    } else {
      text = YAMLWriter.flow(value)
    }
    if document.defaulted.contains(pointer) {
      let (parent, key) = split(pointer)
      return try addField(parent, key, .array([value]))
    }
    if container.flow {
      if index == children.count { return appendFlow(text, to: container) }
      if document.comments.contains(where: { container.range.contains($0.lowerBound) }) {
        var content = flowContent(container)
        content.entries.insert(FlowEntry(text: text), at: index)
        return [
          SourcePatch(
            range: container.range,
            replacement: Array(renderFlow(content, container: container).utf8))
        ]
      }
      if index < children.count {
        let offset = (named ? children[index].entryRange : children[index].range).lowerBound
        return [SourcePatch(range: offset..<offset, replacement: Array((text + ", ").utf8))]
      }
    }
    let indent =
      children.first.map { indentation(at: $0.entryRange.lowerBound) }
      ?? indentation(at: container.range.lowerBound)
    let offset =
      index < children.count
      ? owned(children[index], container: container).lowerBound
      : children.last.map { owned($0, container: container).upperBound }
        ?? container.range.upperBound
    return [
      SourcePatch(
        range: offset..<offset,
        replacement: blockEntry(indent + (named ? "" : "- ") + text, at: offset))
    ]
  }

  private func mapping(at pointer: String) -> YAMLNode? {
    guard let node = document.locations[pointer] else { return nil }
    if IRTree.value(IRTree.root(document.declaration), at: pointer)?.record?.kind == "file" {
      return node.pairs?.first(where: { $0.key.text == "file" })?.value
    }
    return node
  }

  private func movedEntry(_ text: String, at offset: Int) -> [UInt8] {
    let prefix = offset > 0 && bytes[offset - 1] != 10 ? newline : ""
    let suffix = offset < bytes.count && !text.hasSuffix(newline) ? newline : ""
    return Array((prefix + text + suffix).utf8)
  }

  private func blockEntry(_ text: String, at offset: Int) -> [UInt8] {
    let prefix = offset > 0 && bytes[offset - 1] != 10 ? newline : ""
    let suffix = offset == bytes.count && bytes.last != 10 ? "" : newline
    return Array((prefix + text + suffix).utf8)
  }

  private func appendFlow(_ text: String, to container: YAMLNode) -> [SourcePatch] {
    let last = container.items?.last ?? container.pairs?.last?.value
    let start = last?.entryRange.upperBound ?? container.range.lowerBound + 1
    let end = container.range.upperBound - 1
    // An implicit value ends at its colon; a plain key still needs whitespace before the comma.
    let separator = last?.range.isEmpty == true ? " ," : ","
    if start == end {
      return [
        SourcePatch(
          range: end..<end, replacement: Array(((last == nil ? "" : separator + " ") + text).utf8))
      ]
    }
    var cursor = start
    var trailingComma = false
    for comment in document.comments where comment.lowerBound >= start && comment.lowerBound < end {
      if bytes[cursor..<comment.lowerBound].contains(UInt8(ascii: ",")) {
        trailingComma = true
        break
      }
      cursor = comment.upperBound
    }
    if !trailingComma {
      trailingComma = bytes[cursor..<end].contains(UInt8(ascii: ","))
    }
    let gap = source.spelling(start..<end)
    let addition: String
    if gap.contains("\n") {
      addition = "  " + text + (trailingComma ? "," : "") + newline + indentation(at: end)
    } else {
      addition = text + (trailingComma ? "," : "")
    }
    var patches = [SourcePatch(range: end..<end, replacement: Array(addition.utf8))]
    if last != nil && !trailingComma {
      patches.append(SourcePatch(range: start..<start, replacement: Array(separator.utf8)))
    }
    return patches
  }

  private func remove(_ pointer: String, _ index: Int, retainComments: Bool) throws -> [SourcePatch]
  {
    guard let container = document.locations[pointer] else {
      throw readOnly(pointer, "missing collection")
    }
    let children = try children(pointer)
    guard children.indices.contains(index) else { throw readOnly(pointer, "missing occurrence") }
    return try removeEntry(children[index], container: container, retainComments: retainComments)
  }

  private func removeEntry(_ node: YAMLNode, container: YAMLNode, retainComments: Bool) throws
    -> [SourcePatch]
  {
    if container.flow {
      let all = container.items ?? container.pairs!.map(\.value)
      guard let index = all.firstIndex(where: { $0.range == node.range }) else {
        throw readOnly("", "entry is not in its container")
      }
      var range = container.pairs == nil ? node.range : node.entryRange
      if index + 1 < all.count {
        let end =
          container.pairs == nil
          ? all[index + 1].range.lowerBound : all[index + 1].entryRange.lowerBound
        range = range.lowerBound..<end
      } else if index > 0 {
        let start =
          container.pairs == nil
          ? all[index - 1].range.upperBound : all[index - 1].entryRange.upperBound
        range = start..<range.upperBound
      }
      if document.comments.contains(where: { container.range.contains($0.lowerBound) }) {
        var content = flowContent(container)
        let removed = content.entries.remove(at: index)
        let kept = retainComments ? removed.leading + removed.trailing : []
        if index < content.entries.count {
          content.entries[index].leading = kept + content.entries[index].leading
        } else {
          content.footer = kept + content.footer
        }
        return [
          SourcePatch(
            range: container.range,
            replacement: Array(renderFlow(content, container: container).utf8))
        ]
      }
      return [SourcePatch(range: range, replacement: [])]
    }
    let range = owned(node, container: container)
    let comments = retainComments ? document.comments.filter { range.contains($0.lowerBound) } : []
    let kept = comments.map {
      indentation(at: node.entryRange.lowerBound) + source.spelling($0) + newline
    }.joined()
    // An emptied block collection must remain an explicit empty collection, preserving its field.
    let count = container.items?.count ?? container.pairs?.count ?? 0
    if count == 1 {
      let replacement = container.pairs == nil ? "[]" : "{}"
      let indent = indentation(at: node.entryRange.lowerBound)
      return [
        SourcePatch(range: range, replacement: Array((indent + replacement + newline + kept).utf8))
      ]
    }
    return [SourcePatch(range: range, replacement: Array(kept.utf8))]
  }

  private struct FlowEntry {
    var text: String
    var leading: [String] = []
    var trailing: [String] = []
  }
  private struct FlowContent {
    var entries: [FlowEntry]
    var header: [String] = []
    var footer: [String] = []
  }
  private func flowContent(_ container: YAMLNode) -> FlowContent {
    let nodes = container.items ?? container.pairs!.map(\.value)
    let ranges = nodes.map { container.pairs == nil ? $0.range : $0.entryRange }
    var result = FlowContent(entries: ranges.map { FlowEntry(text: source.spelling($0)) })
    var index = 0
    for comment in document.comments
    where container.range.contains(comment.lowerBound) {
      while index < ranges.count && ranges[index].upperBound <= comment.lowerBound { index += 1 }
      if index < ranges.count && ranges[index].contains(comment.lowerBound) { continue }
      let text = source.spelling(comment)
      if index > 0 && lineStart(comment.lowerBound) == lineStart(ranges[index - 1].upperBound - 1) {
        result.entries[index - 1].trailing.append(text)
      } else if index < ranges.count {
        let gap = source.spelling(comment.upperBound..<ranges[index].lowerBound)
          .replacingOccurrences(of: "\r\n", with: "\n")
        if index == 0 && gap.contains("\n\n") {
          result.header.append(text)
        } else {
          result.entries[index].leading.append(text)
        }
      } else {
        result.footer.append(text)
      }
    }
    return result
  }
  private func renderFlow(_ content: FlowContent, container: YAMLNode) -> String {
    let base = indentation(at: container.range.lowerBound)
    let indent = base + "  "
    var text = (container.pairs == nil ? "[" : "{") + newline
    for comment in content.header { text += indent + comment + newline }
    for entry in content.entries {
      for comment in entry.leading { text += indent + comment + newline }
      text += indent + entry.text + ","
      if let first = entry.trailing.first { text += " " + first }
      text += newline
      for comment in entry.trailing.dropFirst() { text += indent + comment + newline }
    }
    for comment in content.footer { text += indent + comment + newline }
    return text + base + (container.pairs == nil ? "]" : "}")
  }

  private func children(_ pointer: String) throws -> [YAMLNode] {
    guard let node = document.locations[pointer] else {
      throw readOnly(pointer, "missing collection")
    }
    if document.defaulted.contains(pointer) { return [] }
    if let items = node.items { return items }
    if let pairs = node.pairs { return pairs.map(\.value) }
    throw readOnly(pointer, "expected a collection")
  }
  private func owned(_ node: YAMLNode, container: YAMLNode) -> Range<Int> {
    var start = lineStart(node.entryRange.lowerBound)
    while start > 0 {
      let end = start - 1
      let previous = lineStart(end)
      let line = source.spelling(previous..<end).trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("#"),
        indentation(at: previous) == indentation(at: node.entryRange.lowerBound)
      else { break }
      start = previous
    }
    return start..<lineEnd(node.entryRange.upperBound)
  }
  private func lineStart(_ offset: Int) -> Int {
    var index = min(offset, bytes.count)
    while index > 0 && bytes[index - 1] != 10 { index -= 1 }
    return index
  }
  private func lineEnd(_ offset: Int) -> Int {
    if offset > 0 && bytes[offset - 1] == 10 { return offset }
    var index = offset
    while index < bytes.count && bytes[index] != 10 { index += 1 }
    return min(bytes.count, index + 1)
  }
  private func indentation(at offset: Int) -> String {
    let start = lineStart(offset)
    var end = start
    while end < bytes.count && bytes[end] == 32 { end += 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
  }
  private var newline: String { bytes.contains(13) ? "\r\n" : "\n" }
  private func split(_ pointer: String) -> (String, String) {
    let index = pointer.lastIndex(of: "/")!
    return (
      String(pointer[..<index]), pointerUnescape(String(pointer[pointer.index(after: index)...]))
    )
  }
  private func field(_ pointer: String) -> String {
    let parts = IRTree.segments(pointer)
    if parts.last.flatMap(Int.init) != nil { return parts.dropLast().last ?? "" }
    return parts.last ?? ""
  }
  private func isNamed(_ pointer: String) -> Bool {
    ["sources", "groups", "overrides", "chatGPT"].contains(field(pointer))
  }
  private func yamlKey(_ field: String, parent: String) -> String {
    if field == "chatGPT" { return "chatgpt" }
    if field == "name", parent.contains("/uses/") { return "group" }
    return field
  }
  private func readOnly(_ pointer: String, _ message: String) -> ManifestFailure {
    source.failure(
      "manifest.edit.readOnly", message, document.locations[pointer]?.range.lowerBound ?? 0)
  }
}
