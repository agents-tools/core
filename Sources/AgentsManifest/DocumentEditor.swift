import AgentsCore
import AgentsDescription
import Foundation

package final class DocumentEditor {
  private let original: DeclarationDocument
  private var current: DeclarationDocument
  private var table: PieceTable
  private var history: [SourcePatch] = []
  private var expected: ConstructionValue
  private var impacted: [NodeID] = []
  private var steps = 0

  package init(document: DeclarationDocument) {
    original = document
    current = document
    table = PieceTable(document.bytes)
    expected = document.evaluation.root.value
  }

  private func fail(_ code: String, _ message: String, range: Range<Int>? = nil) -> ManifestFailure
  {
    current.source.failure(
      code, message, (range ?? 0..<0).lowerBound, end: (range ?? 0..<0).upperBound)
  }
  private func charge(_ count: Int) throws {
    if count > 1_000_000 - steps { throw fail("manifest.limit", "edit batch work steps") }
    steps += count
  }
  private func valueCost(_ value: ConstructionValue) throws -> ValueCost {
    // Iterative preflight bounds external vocabulary values before recursive consumers.
    var pending: [(ConstructionValue, Int)] = [(value, 1)]
    var nodes = 0
    var strings = 0
    while let (value, depth) = pending.popLast() {
      try charge(1)
      nodes += 1
      if nodes > 100_000 || depth > 64 {
        throw fail("manifest.limit", "edit value node/depth budget")
      }
      let children: [ConstructionValue]
      switch value {
      case .text(let text):
        strings = ValueCost.add(strings, text.utf8.count)
        children = []
      case .array(let values):
        if values.count > 10_000 { throw fail("manifest.limit", "edit collection entries") }
        children = values
      case .object(let fields), .node(_, _, let fields):
        if fields.count > 10_000 { throw fail("manifest.limit", "edit dictionary entries") }
        strings = ValueCost.add(strings, fields.keys.reduce(0) { ValueCost.add($0, $1.utf8.count) })
        children = Array(fields.values)
      case .version(let version):
        strings = ValueCost.add(strings, version.normalized.utf8.count)
        children = []
      case .range(let range): children = [.version(range.lowerBound), .version(range.upperBound)]
      default: children = []
      }
      if strings > 16_777_216 || pending.count + children.count > 100_000 {
        throw fail("manifest.limit", "edit expanded value bytes/nodes")
      }
      for child in children { pending.append((child, depth + 1)) }
    }
    let cost = constructionCost(value)
    if !cost.fits { throw fail("manifest.limit", "edit value/output budget") }
    return cost
  }

  package func prepare(_ edits: [ManifestEdit]) throws -> DocumentChange {
    if edits.count > 100 { throw fail("manifest.limit", "edit batch has more than 100 requests") }
    for edit in edits {
      let before = history.count
      try apply(edit)
      if before != history.count {
        current = try DeclarationDocument(
          bytes: table.bytes, identity: original.source.identity, validateDomain: false)
        try charge(current.metrics.evaluationSteps + current.metrics.syntaxNodes)
      }
    }
    let expectedCost = try valueCost(expected)
    try charge(expectedCost.nodes)
    let bytes = table.bytes
    if bytes == original.bytes {
      guard Lowering.declaration(expected) == original.declaration else {
        throw fail("manifest.edit.mismatch", "no-op bytes disagree with expected declaration")
      }
      return DocumentChange(
        originalDigest: original.digest, patches: [], bytes: bytes, digest: original.digest,
        expectedDeclaration: original.declaration, impactedReferences: [],
        diagnostics: original.diagnostics, delta: SemanticDelta(changedPointers: []))
    }
    let candidate = try DeclarationDocument(bytes: bytes, identity: original.source.identity)
    let actualCost = candidate.evaluation.root.cost
    if expectedCost.nodes + actualCost.nodes > 200_000 {
      throw fail("manifest.limit", "comparison node-pair budget")
    }
    try charge(expectedCost.nodes + actualCost.nodes)
    let expectedIR = Lowering.declaration(expected)
    guard candidate.declaration == expectedIR else {
      throw fail(
        "manifest.edit.mismatch", "complete candidate differs from the expected declaration")
    }
    return DocumentChange(
      originalDigest: original.digest, patches: table.patches(), bytes: bytes,
      digest: candidate.digest, expectedDeclaration: expectedIR,
      impactedReferences: Array(Set(impacted)).sorted { $0.syntax < $1.syntax },
      diagnostics: candidate.diagnostics,
      delta: try semanticDelta())
  }

  private func semanticDelta() throws -> SemanticDelta {
    var pending: [(DeclarationValue, DeclarationValue, String)] = [
      (Lowering.lower(original.evaluation.root.value), Lowering.lower(expected), "")
    ]
    var visited = 0
    var pointers: [String] = []
    while let (left, right, pointer) = pending.popLast() {
      try charge(1)
      visited += 1
      if visited > 200_000 { throw fail("manifest.limit", "semantic delta comparison node pairs") }
      switch (left, right) {
      case (.array(let a), .array(let b)) where a.count == b.count:
        for index in a.indices { pending.append((a[index], b[index], pointer + "/\(index)")) }
      case (.dictionary(let a), .dictionary(let b)) where a.keys == b.keys:
        for key in a.keys { pending.append((a[key]!, b[key]!, pointer + "/" + pointerEscape(key))) }
      case (.record(let a), .record(let b)) where a.kind == b.kind:
        pending.append((.dictionary(a.fields), .dictionary(b.fields), pointer))
      default:
        if left != right { pointers.append(pointer) }
      }
      if pending.count > 200_000 - visited {
        throw fail("manifest.limit", "semantic delta scheduled pairs")
      }
    }
    return SemanticDelta(changedPointers: pointers.sorted())
  }

  private func apply(_ edit: ManifestEdit) throws {
    switch edit {
    case .setDefaultAgents(let agents): try setField("", "defaultAgents", agents.constructionValue)
    case .setExports(let exports): try setField("", "exports", exports.constructionValue)
    case .setWatch(let watch): try setField("", "watch", watch.constructionValue)
    case .upsertSource(let source):
      try upsert(source.constructionValue, collection: "/sources", key: "name")
    case .removeSource(let alias): try removeNamed(alias, collection: "/sources", key: "name")
    case .upsertGroup(let group):
      try upsert(group.constructionValue, collection: "/groups", key: "name")
    case .removeGroup(let name): try removeNamed(name, collection: "/groups", key: "name")
    case .insertComponent(let component, let container, let position):
      try insert(
        component.constructionValue, into: containerPath(container) + "/components", at: position)
    case .replaceComponent(let handle, let component):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try replace(pointer, with: component.constructionValue)
    case .removeComponent(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try remove(pointer)
    case .moveComponent(let handle, let container, let position):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try move(pointer, into: containerPath(container) + "/components", at: position)
    case .setSkillSelection(let handle, let selection):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try setField(pointer, "select", selection.constructionValue)
    case .upsertSkillOverride(let handle, let override):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try upsert(override.constructionValue, collection: pointer + "/overrides", key: "name")
    case .removeSkillOverride(let handle, let name):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try removeNamed(name, collection: pointer + "/overrides", key: "name")
    case .insertSection(let section, let handle, let position):
      let pointer = try resolve(handle)
      guard current.values[pointer]?.value.fields["sections"] != nil else {
        throw fail("manifest.edit.readOnly", "target has no instruction sections")
      }
      try insert(section.constructionValue, into: pointer + "/sections", at: position)
    case .removeSection(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "SectionReference")
      try remove(pointer)
    case .moveSection(let handle, let position):
      let pointer = try resolve(handle)
      try requireType(pointer, "SectionReference")
      try move(pointer, into: parent(pointer), at: position)
    case .upsertPrompt(let handle, let prompt):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "instructions")
      try upsert(prompt.constructionValue, collection: pointer + "/chatGPT", key: "name")
    case .removePrompt(let handle, let name):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "instructions")
      try removeNamed(name, collection: pointer + "/chatGPT", key: "name")
    case .insertGroupReference(let reference, let container, let position):
      try insert(
        reference.constructionValue, into: containerPath(container) + "/uses", at: position)
    case .removeGroupReference(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "GroupReference")
      try remove(pointer)
    case .setDictionaryEntry(let handle, let key, let value):
      let pointer = try resolve(handle)
      try dictionary(pointer, key: key, value: value)
    case .removeDictionaryEntry(let handle, let key):
      try dictionary(resolve(handle), key: key, value: nil)
    case .replaceConstant(let handle, let value, let accepted):
      try constant(handle, value: value, accepted: accepted)
    }
  }

  private func requireType(_ pointer: String, _ type: String, member: String? = nil) throws {
    guard current.values[pointer]?.type.unwrapped == .named(type),
      member == nil || current.values[pointer]?.value.member == member
    else { throw fail("manifest.edit.readOnly", "handle has the wrong domain kind") }
  }
  private func resolve(_ handle: NodeID) throws -> String {
    guard handle.digest == original.digest, let originalValue = original.values[handle.pointer],
      originalValue.syntax == handle.syntax
    else { throw fail("manifest.edit.stale", "handle belongs to a different snapshot") }
    let mapped = try translated(original.admission.nodes[handle.syntax].range)
    if handle.pointer.hasPrefix("/constants/"), let value = current.values[handle.pointer],
      current.admission.nodes[value.syntax].range == mapped
    {
      return handle.pointer
    }
    guard
      let pointer = current.values.keys.sorted().first(where: { key in
        guard let value = current.values[key], !value.defaulted else { return false }
        return value.type == originalValue.type
          && current.admission.nodes[value.syntax].range == mapped
      })
    else { throw fail("manifest.edit.stale", "the addressed occurrence was removed or replaced") }
    return pointer
  }
  private func translated(_ originalRange: Range<Int>) throws -> Range<Int> {
    var range = originalRange
    for patch in history {
      let delta = patch.replacement.count - patch.range.count
      if patch.range.isEmpty && patch.range.lowerBound == range.lowerBound {
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
      } else if patch.range.upperBound <= range.lowerBound {
        range = (range.lowerBound + delta)..<(range.upperBound + delta)
      } else if patch.range.lowerBound >= range.upperBound {
        continue
      } else if patch.range.lowerBound >= range.lowerBound
        && patch.range.upperBound <= range.upperBound
      {
        if patch.range == range && patch.replacement.isEmpty {
          throw fail("manifest.edit.stale", "addressed occurrence was removed")
        }
        range = range.lowerBound..<(range.upperBound + delta)
      } else {
        throw fail("manifest.edit.overlap", "edit overlaps a previously changed occurrence")
      }
    }
    return range
  }
  private func direct(_ pointer: String) throws -> EvaluatedValue {
    guard let value = current.values[pointer], !value.defaulted, value.referent == nil,
      !current.hasAssembledAncestor(pointer),
      current.admission.nodes[value.syntax].kind != "sequence",
      current.admission.nodes[value.syntax].kind != "name"
    else {
      throw fail(
        "manifest.edit.readOnly",
        "target is a shared constant, assembled value or inherited default")
    }
    return value
  }
  private func containerPath(_ container: ContainerID) throws -> String {
    switch container {
    case .root: return ""
    case .group(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "ComponentGroup")
      return pointer
    }
  }
  private func parent(_ pointer: String) -> String {
    String(pointer[..<pointer.lastIndex(of: "/")!])
  }
  private func key(_ pointer: String) -> String {
    String(pointer[pointer.index(after: pointer.lastIndex(of: "/")!)...]).replacingOccurrences(
      of: "~1", with: "/"
    ).replacingOccurrences(of: "~0", with: "~")
  }

  private func patch(_ range: Range<Int>, _ text: String) throws {
    try patch(range, bytes: Array(text.utf8))
  }
  private func patch(_ range: Range<Int>, bytes: [UInt8]) throws {
    guard range.lowerBound >= 0, range.upperBound <= table.count else {
      throw fail("manifest.edit.overlap", "patch is outside the snapshot")
    }
    if table.count - range.count + bytes.count > 2_097_152 {
      throw fail("manifest.limit", "generated manifest input bytes")
    }
    if current.bytes[range].elementsEqual(bytes) { return }
    table.replace(range, with: bytes)
    history.append(SourcePatch(range: range, replacement: bytes))
  }
  private func mutate(_ pointer: String, _ replacement: ConstructionValue) throws {
    _ = try valueCost(replacement)
    let parts = pointer.split(separator: "/").map {
      String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
    func update(_ value: ConstructionValue, _ depth: Int) throws -> ConstructionValue {
      try charge(1)
      if depth == parts.count { return replacement }
      let part = parts[depth]
      switch value {
      case .node(let type, let member, var fields):
        guard let child = fields[part] else {
          throw fail("manifest.edit.mismatch", "expected field is missing")
        }
        fields[part] = try update(child, depth + 1)
        return .node(type: type, member: member, fields: fields)
      case .object(var fields):
        guard let child = fields[part] else {
          throw fail("manifest.edit.mismatch", "expected dictionary field is missing")
        }
        fields[part] = try update(child, depth + 1)
        return .object(fields)
      case .array(var values):
        guard let index = Int(part), values.indices.contains(index) else {
          throw fail("manifest.edit.mismatch", "expected array occurrence is missing")
        }
        values[index] = try update(values[index], depth + 1)
        return .array(values)
      default: throw fail("manifest.edit.readOnly", "value has no editable child")
      }
    }
    expected = try update(expected, 0)
    _ = try valueCost(expected)
  }

  private func style(at range: Range<Int>) throws -> (PrintStyle, String) {
    try charge(current.admission.nodes.count)
    let bytes = current.bytes
    var endings = Set<String>()
    var cursor = 0
    while cursor < bytes.count {
      if bytes[cursor] == 13 {
        if cursor + 1 < bytes.count && bytes[cursor + 1] == 10 {
          endings.insert("\r\n")
          cursor += 1
        } else {
          endings.insert("\r")
        }
      } else if bytes[cursor] == 10 {
        endings.insert("\n")
      }
      cursor += 1
    }
    guard endings.count <= 1 else {
      throw fail("manifest.edit.readOnly", "conflicting newline styles", range: range)
    }
    let indentation = indentation(at: range.lowerBound)
    let candidates = current.admission.nodes.filter { node in
      ["array", "dictionary", "call"].contains(node.kind)
        && node.range.lowerBound <= range.lowerBound && node.range.upperBound >= range.upperBound
    }
    var unit: String?
    var trailingComma = true
    for container in candidates.sorted(by: { $0.range.count < $1.range.count }) {
      var units = Set<String>()
      let base = self.indentation(at: container.range.lowerBound)
      let offsets =
        container.kind == "dictionary"
        ? container.keys.map { $0.range.lowerBound }
        : container.kind == "array"
          ? container.children.map { current.admission.nodes[$0].range.lowerBound }
          : container.arguments.map {
            $0.labelRange?.lowerBound ?? current.admission.nodes[$0.value].range.lowerBound
          }
      for offset in offsets {
        let start = lineStart(offset)
        let prefix = current.source.spelling(start..<offset)
        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
        guard prefix.hasPrefix(base), prefix.count > base.count else {
          throw fail("manifest.edit.readOnly", "conflicting local indentation", range: range)
        }
        units.insert(String(prefix.dropFirst(base.count)))
      }
      guard units.count <= 1 else {
        throw fail("manifest.edit.readOnly", "conflicting local indentation", range: range)
      }
      if let evidence = units.first {
        unit = evidence
        break
      }
    }
    for container in candidates.sorted(by: { $0.range.count < $1.range.count })
    where container.kind == "array" || container.kind == "dictionary" {
      guard let last = container.children.last,
        let token = current.admission.tokens.first(where: {
          $0.range.lowerBound >= current.admission.nodes[last].range.upperBound
        })
      else { continue }
      trailingComma = token.text == ","
      break
    }
    return (
      PrintStyle(
        indent: unit ?? "  ", newline: endings.first ?? "\n", trailingComma: trailingComma),
      indentation
    )
  }

  private func indentation(at offset: Int) -> String {
    String(current.source.spelling(lineStart(offset)..<offset).prefix { $0 == " " || $0 == "\t" })
  }

  private func replacementText(_ value: ConstructionValue, at range: Range<Int>) throws -> String {
    _ = try valueCost(value)
    let (style, indentation) = try style(at: range)
    var text = CanonicalPrinter(style: style).render(value, indentation: indentation)
    if text.hasPrefix("-"), range.lowerBound > 0 {
      let previous = current.bytes[range.lowerBound - 1]
      if ![32, 9, 10, 13, 40, 91, 44, 58].contains(previous) { text = " " + text }
    }
    return text
  }
  private func internalComments(_ range: Range<Int>) -> Bool {
    current.admission.comments.contains {
      $0.lowerBound >= range.lowerBound && $0.upperBound <= range.upperBound
    }
  }

  private func replace(_ pointer: String, with value: ConstructionValue) throws {
    let old = try direct(pointer)
    _ = try valueCost(value)
    if Lowering.lower(old.value) == Lowering.lower(value) { return }
    let range = current.admission.nodes[old.syntax].range
    if internalComments(range) {
      throw fail(
        "manifest.edit.readOnly",
        "internal comments cannot be mapped through whole-node replacement", range: range)
    }
    try patch(range, replacementText(value, at: range))
    try mutate(pointer, value)
  }

  private func setField(
    _ pointer: String, _ field: String, _ value: ConstructionValue, spelling: String? = nil
  ) throws {
    let owner = try direct(pointer)
    let node = current.admission.nodes[owner.syntax]
    guard node.kind == "call", let old = owner.value.fields[field] else {
      throw fail("manifest.edit.readOnly", "target is not a direct construction")
    }
    _ = try valueCost(value)
    if Lowering.lower(old) == Lowering.lower(value) { return }
    if let child = owner.field(field), !child.defaulted {
      try replace(pointer + "/" + pointerEscape(field), with: value)
      return
    }
    let signatures = Vocabulary.signatures.filter {
      $0.type == owner.type.name && $0.member == owner.value.member
    }
    guard
      let signature = signatures.first(where: {
        $0.parameters.contains(where: { $0.name == field })
      }), let position = signature.parameters.firstIndex(where: { $0.name == field })
    else { throw fail("manifest.edit.readOnly", "unknown construction field") }
    let next = node.arguments.first { argument in
      let index = signature.parameters.firstIndex { $0.label == argument.label } ?? -1
      return index > position
    }
    let (style, indentation) = try style(at: node.range)
    let content =
      field + ": "
      + (spelling
        ?? CanonicalPrinter(style: style).render(value, indentation: indentation + style.indent))
    let multiline = current.bytes[node.range].contains(10) || current.bytes[node.range].contains(13)
    if let next {
      let start =
        next.labelRange?.lowerBound ?? current.admission.nodes[next.value].range.lowerBound
      if multiline {
        let line = lineStart(start)
        if current.bytes[line..<start].allSatisfy({ $0 == 32 }) {
          try patch(line..<line, indentation + style.indent + content + "," + style.newline)
        } else {
          try patch(start..<start, content + ", ")
        }
      } else {
        try patch(start..<start, content + ", ")
      }
    } else {
      let close = node.range.upperBound - 1
      if node.arguments.isEmpty {
        try patch(close..<close, content)
      } else if multiline {
        let last = node.arguments.last!
        let end = current.admission.nodes[last.value].range.upperBound
        if internalComments(end..<close) {
          throw fail("manifest.edit.readOnly", "ambiguous trailing argument comments")
        }
        try patch(end..<end, "," + style.newline + indentation + style.indent + content)
      } else {
        try patch(close..<close, ", " + content)
      }
    }
    try mutate(pointer + "/" + pointerEscape(field), value)
  }

  private func upsert(_ value: ConstructionValue, collection: String, key: String) throws {
    guard let old = current.values[collection] else {
      throw fail("manifest.edit.readOnly", "collection has no source map")
    }
    let name = value.fields[key]?.text
    if let index = old.elementsForUse.firstIndex(where: { $0.value.fields[key]?.text == name }) {
      try replace(collection + "/\(index)", with: value)
    } else {
      try insert(value, into: collection, at: .last)
    }
  }
  private func removeNamed(_ name: String, collection: String, key: String) throws {
    guard let old = current.values[collection] else {
      throw fail("manifest.edit.readOnly", "collection has no source map")
    }
    if let index = old.elementsForUse.firstIndex(where: { $0.value.fields[key]?.text == name }) {
      try remove(collection + "/\(index)")
    }
  }
  private func position(_ position: InsertionPosition, collection: String, count: Int) throws -> Int
  {
    switch position {
    case .first: return 0
    case .last: return count
    case .before(let handle), .after(let handle):
      let pointer = try resolve(handle)
      guard parent(pointer) == collection, let index = Int(key(pointer)) else {
        throw fail("manifest.edit.impact", "insertion anchor belongs to another container")
      }
      if case .after = position { return index + 1 }
      return index
    }
  }

  private func insert(
    _ value: ConstructionValue, into pointer: String, at position: InsertionPosition,
    carried: [UInt8]? = nil
  ) throws {
    guard let collection = current.values[pointer], case .array(let previous) = collection.value
    else { throw fail("manifest.edit.readOnly", "target is not an array") }
    let incoming = try valueCost(value)
    guard previous.count < 10_000 else { throw fail("manifest.limit", "edited array entries") }
    let combined = ValueCost.container(collection.elementsForUse.map(\.cost) + [incoming])
    let total = current.evaluation.total
    let projected = ValueCost(
      nodes: total.nodes - collection.cost.nodes + combined.nodes,
      strings: total.strings - collection.cost.strings + combined.strings,
      encoded: total.encoded - collection.cost.encoded + combined.encoded,
      depth: max(total.depth, incoming.depth + pointer.split(separator: "/").count + 1),
      origins: total.origins - collection.cost.origins + combined.origins)
    guard combined.fits, projected.fits else {
      throw fail("manifest.limit", "edited expanded document budget")
    }
    let index = try self.position(position, collection: pointer, count: previous.count)
    var expectedValues = previous
    expectedValues.insert(value, at: index)
    if collection.defaulted {
      if let carried {
        let owner = try direct(parent(pointer))
        let (style, indentation) = try style(at: current.admission.nodes[owner.syntax].range)
        let text =
          "[" + style.newline + indentation + style.indent + style.indent
          + String(decoding: carried, as: UTF8.self) + style.newline + indentation + style.indent
          + "]"
        try setField(parent(pointer), key(pointer), .array(expectedValues), spelling: text)
      } else {
        try setField(parent(pointer), key(pointer), .array(expectedValues))
      }
      return
    }
    _ = try direct(pointer)
    let node = current.admission.nodes[collection.syntax]
    guard node.kind == "array" else {
      throw fail("manifest.edit.readOnly", "target is an assembled array")
    }
    let (style, indentation) = try style(at: node.range)
    let multiline =
      current.bytes[node.range].contains(10) || current.bytes[node.range].contains(13)
      || carried?.contains(10) == true || carried?.contains(13) == true
    let rendered =
      carried.map { String(decoding: $0, as: UTF8.self) }
      ?? CanonicalPrinter(style: style).render(
        value, indentation: multiline ? indentation + style.indent : indentation)
    if previous.isEmpty {
      let interior = (node.range.lowerBound + 1)..<(node.range.upperBound - 1)
      if !current.bytes[interior].allSatisfy({ [32, 9, 10, 13].contains($0) }) {
        throw fail(
          "manifest.edit.readOnly", "comment-only container insertion is ambiguous", range: interior
        )
      }
      try patch(
        interior,
        multiline
          ? style.newline + indentation + style.indent + rendered + (carried == nil ? "," : "")
            + style.newline + indentation : rendered)
    } else if index < previous.count {
      let child = collection.elementsForUse[index]
      let owned = try ownedRange(child, container: node, index: index)
      if multiline {
        guard owned.lowerBound == lineStart(owned.lowerBound) else {
          throw fail("manifest.edit.readOnly", "mixed inline and multiline collection layout")
        }
        try patch(
          owned.lowerBound..<owned.lowerBound,
          indentation + style.indent + rendered + (carried == nil ? "," : "") + style.newline)
      } else {
        try patch(owned.lowerBound..<owned.lowerBound, rendered + (carried == nil ? ", " : " "))
      }
    } else {
      let child = collection.elementsForUse.last!
      let range = current.admission.nodes[child.syntax].range
      let close = node.range.upperBound - 1
      let commas = current.admission.tokens.filter {
        $0.text == "," && $0.range.lowerBound >= range.upperBound && $0.range.upperBound <= close
      }
      let gap = range.upperBound..<close
      if internalComments(gap) {
        throw fail(
          "manifest.edit.readOnly", "trailing comments need an unambiguous insertion anchor",
          range: gap)
      }
      if multiline {
        let end = commas.first?.range.upperBound ?? range.upperBound
        try patch(
          end..<end,
          (commas.isEmpty ? "," : "") + style.newline + indentation + style.indent + rendered
            + (carried == nil && !commas.isEmpty ? "," : ""))
      } else {
        try patch(
          close..<close,
          (commas.isEmpty ? ", " : " ") + rendered + (carried == nil && !commas.isEmpty ? "," : ""))
      }
    }
    try mutate(pointer, .array(expectedValues))
  }

  private func lineStart(_ offset: Int) -> Int {
    var result = offset
    while result > 0 && current.bytes[result - 1] != 10 && current.bytes[result - 1] != 13 {
      result -= 1
    }
    return result
  }
  private func lineEnd(_ offset: Int) -> Int {
    var result = offset
    while result < current.bytes.count && current.bytes[result] != 10 && current.bytes[result] != 13
    { result += 1 }
    return result
  }
  private func blankLine(_ range: Range<Int>) -> Bool {
    let normalized = current.source.spelling(range).replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
      .dropLast().contains { $0.allSatisfy { $0 == " " || $0 == "\t" } }
  }
  private func ownedRange(_ value: EvaluatedValue, container: GrammarNode, index: Int) throws
    -> Range<Int>
  {
    let expressionRange = current.admission.nodes[value.syntax].range
    let range =
      container.kind == "dictionary"
      ? container.keys[index].range.lowerBound..<expressionRange.upperBound : expressionRange
    let siblings = container.children
    let previous =
      index == 0
      ? container.range.lowerBound + 1
      : current.admission.nodes[siblings[index - 1]].range.upperBound
    let next =
      index + 1 == siblings.count
      ? container.range.upperBound - 1
      : (container.kind == "dictionary"
        ? container.keys[index + 1].range.lowerBound
        : current.admission.nodes[siblings[index + 1]].range.lowerBound)
    var start = range.lowerBound
    var end = range.upperBound
    let preceding = current.admission.comments.filter {
      $0.lowerBound >= previous && $0.upperBound <= start
    }
    for comment in preceding.reversed() {
      if blankLine(comment.upperBound..<start) { break }
      let line = lineStart(comment.lowerBound)
      guard line >= previous,
        current.bytes[line..<comment.lowerBound].allSatisfy({ $0 == 32 || $0 == 9 })
      else { break }
      start = line
    }
    let line = lineStart(start)
    if line >= previous && current.bytes[line..<start].allSatisfy({ $0 == 32 || $0 == 9 }) {
      start = line
    }
    let comma = current.admission.tokens.first {
      $0.text == "," && $0.range.lowerBound >= end && $0.range.upperBound <= next
    }
    if let comma { end = comma.range.upperBound }
    for comment in current.admission.comments
    where comment.lowerBound >= range.upperBound && comment.upperBound <= next {
      if comment.lowerBound <= (comma?.range.lowerBound ?? range.upperBound)
        || lineStart(comment.lowerBound) == lineStart(end)
      {
        end = max(end, comment.upperBound)
      }
    }
    let ending = lineEnd(end)
    if start == lineStart(start), ending <= next,
      current.bytes[end..<ending].allSatisfy({ $0 == 32 || $0 == 9 })
    {
      end = ending
      if end < current.bytes.count && current.bytes[end] == 13 { end += 1 }
      if end < current.bytes.count && current.bytes[end] == 10 { end += 1 }
    }
    return start..<end
  }

  private func remove(_ pointer: String) throws {
    let value = try direct(pointer)
    let collectionPointer = parent(pointer)
    let collection = try direct(collectionPointer)
    let node = current.admission.nodes[collection.syntax]
    guard node.kind == "array", let index = Int(key(pointer)),
      case .array(var values) = collection.value
    else { throw fail("manifest.edit.readOnly", "removal requires a direct array element") }
    let range = try ownedRange(value, container: node, index: index)
    let hasComma = current.admission.tokens.contains {
      $0.text == ","
        && $0.range.lowerBound >= current.admission.nodes[value.syntax].range.upperBound
        && $0.range.upperBound <= range.upperBound
    }
    var patches = [SourcePatch(range: range, replacement: [])]
    if !hasComma && index > 0 {
      let previous = current.admission.nodes[node.children[index - 1]].range.upperBound
      if let comma = current.admission.tokens.last(where: {
        $0.text == "," && $0.range.lowerBound >= previous && $0.range.upperBound <= range.lowerBound
      }) {
        patches.append(SourcePatch(range: comma.range, replacement: []))
      } else {
        throw fail("manifest.edit.readOnly", "ambiguous separator ownership", range: range)
      }
    }
    values.remove(at: index)
    for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      try self.patch(patch.range, bytes: patch.replacement)
    }
    try mutate(collectionPointer, .array(values))
  }

  private func move(_ pointer: String, into collection: String, at position: InsertionPosition)
    throws
  {
    let value = try direct(pointer)
    let from = parent(pointer)
    guard let old = current.values[from], let index = Int(key(pointer)),
      let target = current.values[collection], case .array = target.value
    else { throw fail("manifest.edit.readOnly", "move requires array containers") }
    let destination = try self.position(
      position, collection: collection, count: target.elementsForUse.count)
    if from == collection && (destination == index || destination == index + 1) { return }
    let node = current.admission.nodes[old.syntax]
    let owned = try ownedRange(value, container: node, index: index)
    let expression = current.admission.nodes[value.syntax].range
    let leading = current.source.spelling(owned.lowerBound..<expression.lowerBound)
    let comma = current.admission.tokens.first {
      $0.text == "," && $0.range.lowerBound >= expression.upperBound
        && $0.range.upperBound <= owned.upperBound
    }
    let beforeComma =
      comma.map { current.source.spelling(expression.upperBound..<$0.range.lowerBound) } ?? ""
    let afterComma = current.source.spelling(
      (comma?.range.upperBound ?? expression.upperBound)..<owned.upperBound)
    let prefix = leading.trimmingCharacters(in: .whitespacesAndNewlines)
    let carried =
      (prefix.isEmpty ? "" : prefix + "\n") + current.source.spelling(expression) + beforeComma
      + "," + afterComma.trimmingCharacters(in: .newlines)
    try remove(pointer)
    current = try DeclarationDocument(
      bytes: table.bytes, identity: original.source.identity, validateDomain: false)
    // Stable container coordinates survive removals; same-container positions shift once.
    let refreshed =
      from == collection ? from : try currentPointerForContainer(collection, previous: target)
    let adjusted = from == collection && destination > index ? destination - 1 : destination
    let count = current.values[refreshed]?.elementsForUse.count ?? 0
    let insertion: InsertionPosition
    if adjusted == 0 {
      insertion = .first
    } else if adjusted == count {
      insertion = .last
    } else {
      // Use a current local anchor for the internal move only.
      try insertAtIndex(value.value, pointer: refreshed, index: adjusted, carried: carried)
      return
    }
    try insert(value.value, into: refreshed, at: insertion, carried: Array(carried.utf8))
  }
  private func insertAtIndex(
    _ value: ConstructionValue, pointer: String, index: Int, carried: String
  ) throws {
    // A direct byte anchor avoids manufacturing a public snapshot handle.
    let collection = try direct(pointer)
    let node = current.admission.nodes[collection.syntax]
    let owned = try ownedRange(collection.elementsForUse[index], container: node, index: index)
    let (style, indentation) = try style(at: node.range)
    let multiline = current.bytes[node.range].contains(10)
    try patch(
      owned.lowerBound..<owned.lowerBound,
      multiline ? indentation + style.indent + carried + style.newline : carried + " ")
    var values = collection.value.array!
    values.insert(value, at: index)
    try mutate(pointer, .array(values))
  }
  private func currentPointerForContainer(_ pointer: String, previous: EvaluatedValue) throws
    -> String
  {
    // Removing a root component cannot move a group definition, and group moves never nest groups.
    if let value = current.values[pointer], value.type == previous.type { return pointer }
    throw fail("manifest.edit.stale", "destination container changed during move")
  }

  private func contextualValue(_ input: StaticValue, as context: ConstructionType) throws
    -> ConstructionValue
  {
    _ = try valueCost(input.value)
    if input.type == context || input.type == context.unwrapped { return input.value }
    guard input.literal else {
      throw fail("manifest.type", "replacement has the wrong contextual type")
    }
    func convert(_ value: ConstructionValue, _ context: ConstructionType) throws
      -> ConstructionValue
    {
      try charge(1)
      if case .optional(let wrapped) = context {
        if value == .none { return .none }
        return try convert(value, wrapped)
      }
      switch (value, context) {
      case (.text, .named("String")), (.integer, .named("Int")), (.boolean, .named("Bool")):
        return value
      case (.array(let values), .array(let element)):
        return .array(try values.map { try convert($0, element) })
      case (.object(let fields), .dictionary(let element)):
        return .object(try fields.mapValues { try convert($0, element) })
      case (.text(let text), .named("Version")):
        let version = Version(stringLiteral: text)
        guard version.valid else { throw fail("manifest.domain", "invalid version replacement") }
        return .version(version)
      case (.text, .named("PromptContent")), (.text, .named("RuntimeValue")):
        return .node(type: context.name, member: "literal", fields: ["value": value])
      case (.text, .named("SectionReference")), (.text, .named("GroupReference")):
        return .node(
          type: context.name, member: context.name == "SectionReference" ? "section" : "group",
          fields: ["name": value, "source": .none, "condition": .none])
      case (.array(let values), .named("SkillSelection")):
        return .node(
          type: "SkillSelection", member: "names",
          fields: ["names": .array(try values.map { try convert($0, .named("String")) })])
      case (_, .named("ConfigurationValue")):
        let kind: String
        let payload: ConstructionValue
        switch value {
        case .text:
          kind = "string"
          payload = value
        case .integer:
          kind = "integer"
          payload = value
        case .boolean:
          kind = "boolean"
          payload = value
        case .none: return .node(type: "ConfigurationValue", member: "null", fields: [:])
        case .array(let values):
          kind = "array"
          payload = .array(try values.map { try convert($0, context) })
        case .object(let fields):
          kind = "object"
          payload = .object(try fields.mapValues { try convert($0, context) })
        case .node(let type, _, _) where type == "ConfigurationValue": return value
        default: throw fail("manifest.type", "value cannot use configuration literal conversion")
        }
        return .node(type: "ConfigurationValue", member: kind, fields: ["value": payload])
      default: throw fail("manifest.type", "replacement has the wrong contextual type")
      }
    }
    let result = try convert(input.value, context)
    _ = try valueCost(result)
    return result
  }

  private func dictionary(_ pointer: String, key: String, value replacement: StaticValue?) throws {
    let value = try direct(pointer)
    if value.type == .named("ConfigurationValue"), value.value.member == "object" {
      try dictionary(pointer + "/value", key: key, value: replacement)
      return
    }
    let node = current.admission.nodes[value.syntax]
    guard node.kind == "dictionary", case .dictionary(let elementType) = value.type.unwrapped,
      case .object(var fields) = value.value
    else { throw fail("manifest.edit.readOnly", "target is not a direct dictionary") }
    if let replacement {
      let replacementValue = try contextualValue(replacement, as: elementType)
      if let index = node.keys.firstIndex(where: { $0.decoded == key }) {
        let childPointer = pointer + "/" + pointerEscape(key)
        try replace(childPointer, with: replacementValue)
        _ = index
        return
      }
      let close = node.range.upperBound - 1
      let (style, indentation) = try style(at: node.range)
      let text =
        quoted(key) + ": "
        + CanonicalPrinter(style: style).render(
          replacementValue, indentation: indentation + style.indent)
      let multiline = current.bytes[node.range].contains(10)
      if node.children.isEmpty {
        let interior = (node.range.lowerBound + 1)..<close
        guard !internalComments(interior) else {
          throw fail("manifest.edit.readOnly", "comment-only dictionary insertion is ambiguous")
        }
        try patch(interior, text)
      } else {
        let end = current.admission.nodes[node.children.last!].range.upperBound
        guard !internalComments(end..<close) else {
          throw fail("manifest.edit.readOnly", "dictionary trailing comments are ambiguous")
        }
        let comma = current.admission.tokens.first {
          $0.text == "," && $0.range.lowerBound >= end && $0.range.upperBound <= close
        }
        if multiline {
          let at = comma?.range.upperBound ?? end
          try patch(
            at..<at,
            (comma == nil ? "," : "") + style.newline + indentation + style.indent + text
              + (comma == nil ? "" : ","))
        } else {
          try patch(close..<close, (comma == nil ? ", " : " ") + text + (comma == nil ? "" : ","))
        }
      }
      fields[key] = replacementValue
    } else {
      guard let index = node.keys.firstIndex(where: { $0.decoded == key }) else { return }
      let child = current.values[pointer + "/" + pointerEscape(key)]!
      let range = try ownedRange(child, container: node, index: index)
      let childEnd = current.admission.nodes[child.syntax].range.upperBound
      let hasComma = current.admission.tokens.contains {
        $0.text == "," && $0.range.lowerBound >= childEnd && $0.range.upperBound <= range.upperBound
      }
      var patches = [SourcePatch(range: range, replacement: [])]
      if !hasComma && index > 0 {
        let previous = current.admission.nodes[node.children[index - 1]].range.upperBound
        guard
          let comma = current.admission.tokens.last(where: {
            $0.text == "," && $0.range.lowerBound >= previous
              && $0.range.upperBound <= range.lowerBound
          })
        else { throw fail("manifest.edit.readOnly", "dictionary separator is ambiguous") }
        patches.append(SourcePatch(range: comma.range, replacement: []))
      }
      for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        try self.patch(patch.range, bytes: patch.replacement)
      }
      fields.removeValue(forKey: key)
      if fields.isEmpty {
        // The colon is necessary even if retained container whitespace/comments remain.
        let opener = node.range.lowerBound + 1
        try patch(opener..<opener, ":")
      }
    }
    try mutate(pointer, .object(fields))
  }

  private func constant(_ handle: NodeID, value: StaticValue, accepted: [NodeID]) throws {
    let pointer = try resolve(handle)
    guard pointer.hasPrefix("/constants/"), let old = current.values[pointer] else {
      throw fail("manifest.edit.readOnly", "replaceConstant requires a definition handle")
    }
    let name = key(pointer)
    let uses = original.uses(ofConstant: name)
    guard Set(uses) == Set(accepted), accepted.allSatisfy({ $0.digest == original.digest }) else {
      throw fail("manifest.edit.impact", "accept the complete impacted reference set")
    }
    let replacementValue = try contextualValue(value, as: old.type)
    if Lowering.lower(old.value) == Lowering.lower(replacementValue) { return }
    let range = current.admission.nodes[old.syntax].range
    if internalComments(range) {
      throw fail(
        "manifest.edit.readOnly", "constant contains unmappable internal comments", range: range)
    }
    let altered = try Evaluator(
      source: current.source, admission: current.admission,
      replacements: [name: StaticValue.checked(replacementValue, type: old.type)]
    ).evaluate()
    func merge(_ old: ConstructionValue, _ new: ConstructionValue, _ expected: ConstructionValue)
      throws -> ConstructionValue
    {
      try charge(1)
      if old == new { return expected }
      switch (old, new, expected) {
      case (.array(let a), .array(let b), .array(let e))
      where a.count == b.count && a.count == e.count:
        return .array(try a.indices.map { try merge(a[$0], b[$0], e[$0]) })
      case (.node(let t, let m, let a), .node(let nt, let nm, let b), .node(_, _, let e))
      where t == nt && m == nm && a.keys == b.keys && a.keys == e.keys:
        var result = e
        for key in a.keys { result[key] = try merge(a[key]!, b[key]!, e[key]!) }
        return .node(type: t, member: m, fields: result)
      case (.object(let a), .object(let b), .object(let e))
      where a.keys == b.keys && a.keys == e.keys:
        var result = e
        for key in a.keys { result[key] = try merge(a[key]!, b[key]!, e[key]!) }
        return .object(result)
      default: return new
      }
    }
    expected = try merge(current.evaluation.root.value, altered.root.value, expected)
    impacted += uses
    try patch(range, replacementText(replacementValue, at: range))
    if let declaration = current.admission.declarations.first(where: { $0.name == name }),
      declaration.type == nil,
      needsContext(replacementValue, type: old.type)
    {
      let offset = declaration.nameRange.upperBound
      try patch(offset..<offset, ": " + typeSpelling(old.type))
    }
  }

  private func needsContext(_ value: ConstructionValue, type: ConstructionType) -> Bool {
    switch (value, type) {
    case (.text, .named("String")), (.integer, .named("Int")), (.boolean, .named("Bool")):
      return false
    case (.node(let type, _, _), _) where type == "Agents": return false
    case (.array(let values), .array(let element)):
      return values.first.map { needsContext($0, type: element) } ?? true
    case (.object(let fields), .dictionary(let element)):
      return fields.keys.sorted(by: utf8Less).first.map { needsContext(fields[$0]!, type: element) }
        ?? true
    default: return true
    }
  }

  private func typeSpelling(_ type: ConstructionType) -> String {
    switch type {
    case .named(let name): return name
    case .array(let element): return "[" + typeSpelling(element) + "]"
    case .dictionary(let element): return "[String: " + typeSpelling(element) + "]"
    case .optional(let element): return typeSpelling(element)
    }
  }
}

extension ConstructionType {
  package var name: String {
    if case .named(let name) = unwrapped { return name }
    return ""
  }
}
