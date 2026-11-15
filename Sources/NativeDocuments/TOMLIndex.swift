import Foundation
import TOMLSemantics
import TreeSitter
import TreeSitterTOML

private struct ParseInput {
  let bytes: UnsafePointer<CChar>
  let count: Int
  let budget: NativeDocumentBudget
  var failure: (any Error)?
}

struct TOMLIndex {
  let bytes: [UInt8]
  let budget: NativeDocumentBudget
  var comments: [Range<Int>] = []
  var located = true
  var offset: Int { bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0 }

  mutating func parse() throws -> Node {
    try budget.allocate(bytes.count, stage: "TOML string")
    guard let source = String(bytes: bytes.dropFirst(offset), encoding: .utf8) else {
      throw NativeDocumentError.invalidDocument(code: "utf8", range: nil)
    }
    let semantics = try SemanticDocument(source: source, budget: budget)
    let root = try convert(semantics.root, depth: 0)
    root.syntaxLocated = true
    // The admitted whole envelope includes long comments and whitespace absent from semantic tokens.
    try budget.admitCST(bytes: bytes.count)
    guard bytes.count <= Int(UInt32.max), let parser = ts_parser_new() else {
      throw NativeDocumentError.budgetExceeded("CST input")
    }
    defer { ts_parser_delete(parser) }
    guard ts_parser_set_language(parser, tree_sitter_toml()) else {
      throw NativeDocumentError.invalidDocument(code: "parserABI", range: nil)
    }
    var failure: (any Error)?
    let tree = bytes.withUnsafeBytes { raw -> OpaquePointer? in
      var empty: CChar = 0
      return withUnsafePointer(to: &empty) { emptyPointer in
        var state = ParseInput(
          bytes: raw.baseAddress?.assumingMemoryBound(to: CChar.self).advanced(by: offset)
            ?? emptyPointer, count: bytes.count - offset, budget: budget)
        return withUnsafeMutablePointer(to: &state) { pointer in
          let input = TSInput(
            payload: UnsafeMutableRawPointer(pointer),
            read: { payload, index, _, count in
              let state = payload!.assumingMemoryBound(to: ParseInput.self).pointee
              let offset = min(Int(index), state.count)
              count!.pointee = UInt32(state.count - offset)
              return state.bytes.advanced(by: offset)
            }, encoding: TSInputEncodingUTF8, decode: nil)
          let options = TSParseOptions(
            payload: UnsafeMutableRawPointer(pointer),
            progress_callback: { progress in
              let state = progress!.pointee.payload!.assumingMemoryBound(to: ParseInput.self)
              do {
                try state.pointee.budget.step()
                return false
              } catch {
                state.pointee.failure = error
                return true
              }
            })
          let tree = ts_parser_parse_with_options(parser, nil, input, options)
          failure = pointer.pointee.failure
          return tree
        }
      }
    }
    if let failure {
      if let tree { ts_tree_delete(tree) }
      throw failure
    }
    guard let tree else {
      throw NativeDocumentError.invalidDocument(code: "parserFailure", range: nil)
    }
    defer { ts_tree_delete(tree) }
    try budget.check()
    let syntax = ts_tree_root_node(tree)
    if ts_node_has_error(syntax) {
      located = false
      return root
    }
    let top = try children(syntax)
    root.insertion =
      top.first(where: { type($0) == "table" || type($0) == "table_array_element" }).map {
        span($0).lowerBound
      } ?? bytes.count
    var active = root
    for child in top {
      try budget.step()
      switch type(child) {
      case "comment": comments.append(span(child))
      case "pair": try pair(child, in: root)
      case "table", "table_array_element":
        let parts = try children(child)
        guard let key = parts.first(where: { type($0) != "comment" }) else {
          located = false
          continue
        }
        let keys = try keyParts(key)
        let isArray = type(child) == "table_array_element"
        active = try table(root, keys: keys, aot: isArray)
        let start = span(child).lowerBound
        var end = span(key).upperBound
        while end < bytes.count && bytes[end] != 93 {
          try budget.step()
          end += 1
        }
        guard end < bytes.count else {
          located = false
          continue
        }
        end += isArray ? 2 : 1
        active.syntaxLocated = true
        active.headers.append(start..<end)
        active.insertion = span(child).upperBound
        for part in parts where type(part) == "pair" { try pair(part, in: active) }
        for part in parts where type(part) == "comment" { comments.append(span(part)) }
      default: break
      }
    }
    try validateLocated(root)
    return root
  }

  private func convert(_ value: SemanticValue, depth: Int) throws -> Node {
    try budget.node(depth: depth)
    switch value {
    case .object(let entries):
      let n = Node(.object)
      for e in entries {
        n.members.append(Member(key: e.key, node: try convert(e.value, depth: depth + 1)))
      }
      return n
    case .array(let elements):
      let n = Node(.array)
      for e in elements { n.elements.append(try convert(e, depth: depth + 1)) }
      return n
    case .scalar(let kind, let decoded, let raw, let range):
      let k: Node.Kind
      switch kind {
      case .string: k = .string
      case .boolean: k = .boolean
      case .integer: k = .integer
      case .float:
        k = ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(raw) ? .atom : .decimal
      case .dateTime: k = .atom
      }
      let node = Node(
        k, text: k == .atom ? raw : decoded, raw: raw,
        range: (range.lowerBound + offset)..<(range.upperBound + offset)
      )
      if k == .atom { node.atomType = kind == .dateTime ? "dateTime" : "nonFiniteFloat" }
      return node
    }
  }
  func span(_ node: TSNode) -> Range<Int> {
    (Int(ts_node_start_byte(node)) + offset)..<(Int(ts_node_end_byte(node)) + offset)
  }
  func type(_ node: TSNode) -> String { String(cString: ts_node_type(node)) }
  func children(_ node: TSNode) throws -> [TSNode] {
    var result: [TSNode] = []
    for i in 0..<ts_node_named_child_count(node) {
      try budget.step()
      try budget.allocate(1, stage: "CST index")
      result.append(ts_node_named_child(node, i))
    }
    return result
  }
  func keyParts(_ node: TSNode) throws -> [String] {
    try budget.step()
    if type(node) == "dotted_key" {
      var keys: [String] = []
      for c in try children(node) { keys += try keyParts(c) }
      return keys
    }
    try budget.allocate(span(node).count, stage: "CST key copy")
    return [try SemanticDocument.decodeKey(Array(bytes[span(node)]), budget: budget)]
  }
  func table(_ root: Node, keys: [String], aot: Bool) throws -> Node {
    var current = root
    for (i, key) in keys.enumerated() {
      guard let m = try current.member(key, budget: budget) else {
        throw NativeDocumentError.invalidDocument(code: "syntaxSemanticMismatch", range: nil)
      }
      current = current.members[m].node
      if current.kind == .array {
        if i == keys.count - 1 && aot {
          current.aot = true
          guard let next = current.elements.first(where: { $0.headers.isEmpty }) else {
            throw NativeDocumentError.invalidDocument(code: "arrayTableIndex", range: nil)
          }
          current = next
        } else {
          guard let latest = current.elements.last(where: { !$0.headers.isEmpty }) else {
            throw NativeDocumentError.invalidDocument(code: "arrayTableScope", range: nil)
          }
          current = latest
        }
      }
    }
    return current
  }
  mutating func pair(_ syntax: TSNode, in parent: Node) throws {
    let nodes = try children(syntax).filter { type($0) != "comment" }
    guard nodes.count >= 2 else {
      located = false
      return
    }
    let keys = try keyParts(nodes[0])
    var current = parent
    let enclosingInline = parent.inline ? parent : parent.enclosingInline
    var inlineKeyPath = parent.inline ? [] : parent.inlineKeyPath
    for key in keys.dropLast() {
      guard let m = try current.member(key, budget: budget) else {
        located = false
        return
      }
      current = current.members[m].node
      if let enclosingInline {
        try budget.allocate(key.utf8.count + inlineKeyPath.count + 1, stage: "inline key path")
        inlineKeyPath.append(key)
        current.enclosingInline = enclosingInline
        current.inlineKeyPath = inlineKeyPath
      }
    }
    guard let key = keys.last, let m = try current.member(key, budget: budget) else {
      located = false
      return
    }
    let value = nodes[1]
    current.members[m].entry = span(nodes[0]).lowerBound..<span(value).upperBound
    current.members[m].node.entry = current.members[m].entry
    current.members[m].keyRange = span(nodes[0])
    try locate(current.members[m].node, syntax: value)
  }
  mutating func locate(_ node: Node, syntax: TSNode) throws {
    try budget.step()
    if let range = node.range, node.kind != .object && node.kind != .array, range != span(syntax) {
      throw NativeDocumentError.invalidDocument(code: "syntaxSemanticMismatch", range: span(syntax))
    }
    node.syntaxLocated = true
    node.range = span(syntax)
    if node.kind == .object {
      node.inline = true
      node.insertion = span(syntax).upperBound - 1
      for c in try children(syntax) {
        if type(c) == "pair" { try pair(c, in: node) }
        if type(c) == "comment" { comments.append(span(c)) }
      }
      // Commas are selected from punctuation, never comments or string contents.
      for i in 0..<ts_node_child_count(syntax) {
        let c = ts_node_child(syntax, i)
        if type(c) == "," { node.commas.append(span(c)) }
      }
      try node.members.sort {
        try budget.step()
        return ($0.entry?.lowerBound ?? 0) < ($1.entry?.lowerBound ?? 0)
      }
      let entries = try node.inlineEntries(budget)
      for (i, entry) in entries.enumerated() where i < node.commas.count {
        entry.parent.members[entry.index].comma = node.commas[i]
      }
    } else if node.kind == .array {
      let all = try children(syntax)
      for c in all where type(c) == "comment" { comments.append(span(c)) }
      let children = all.filter { type($0) != "comment" }
      guard children.count == node.elements.count else {
        located = false
        return
      }
      for (child, c) in zip(node.elements, children) { try locate(child, syntax: c) }
      for i in 0..<ts_node_child_count(syntax) {
        let c = ts_node_child(syntax, i)
        if type(c) == "," { node.commas.append(span(c)) }
      }
    }
  }
  mutating func validateLocated(_ node: Node) throws {
    try budget.step()
    if node.kind != .object && node.kind != .array && !node.syntaxLocated { located = false }
    for m in node.members { try validateLocated(m.node) }
    for e in node.elements { try validateLocated(e) }
  }
}
