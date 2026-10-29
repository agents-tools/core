import AgentsCore
import AgentsDescription
import Foundation

final class DocumentEditor {
  let original: DeclarationDocument
  var current: DeclarationDocument
  var table: PieceTable
  var history: [SourcePatch] = []
  var expected: ConstructionValue
  var impacted: [NodeID] = []
  var steps = 0

  init(document: DeclarationDocument) {
    original = document
    current = document
    table = PieceTable(document.bytes)
    expected = document.evaluation.root.value
  }

  func fail(_ code: String, _ message: String, range: Range<Int>? = nil) -> ManifestFailure {
    current.source.failure(
      code, message, (range ?? 0..<0).lowerBound, end: (range ?? 0..<0).upperBound)
  }
  func charge(_ count: Int) throws {
    if count > ManifestLimits.Editing.steps - steps {
      throw fail("manifest.limit", "edit batch work steps")
    }
    steps += count
  }
  func valueCost(_ value: ConstructionValue) throws -> ValueCost {
    // Iterative preflight bounds external vocabulary values before recursive consumers.
    var pending: [(ConstructionValue, Int)] = [(value, 1)]
    var nodes = 0
    var strings = 0
    while let (value, depth) = pending.popLast() {
      try charge(1)
      nodes += 1
      if nodes > ManifestLimits.Values.nodes || depth > ManifestLimits.Values.depth {
        throw fail("manifest.limit", "edit value node/depth budget")
      }
      let children: [ConstructionValue]
      switch value {
      case .text(let text):
        strings = ValueCost.add(strings, text.utf8.count)
        children = []
      case .array(let values):
        if values.count > ManifestLimits.Values.entries {
          throw fail("manifest.limit", "edit collection entries")
        }
        children = values
      case .object(let fields), .node(_, _, let fields):
        if fields.count > ManifestLimits.Values.entries {
          throw fail("manifest.limit", "edit dictionary entries")
        }
        strings = ValueCost.add(strings, fields.keys.reduce(0) { ValueCost.add($0, $1.utf8.count) })
        children = Array(fields.values)
      case .version(let version):
        strings = ValueCost.add(strings, version.normalized.utf8.count)
        children = []
      case .range(let range): children = [.version(range.lowerBound), .version(range.upperBound)]
      default: children = []
      }
      if strings > ManifestLimits.Values.stringBytes
        || pending.count + children.count > ManifestLimits.Values.nodes
      {
        throw fail("manifest.limit", "edit expanded value bytes/nodes")
      }
      for child in children { pending.append((child, depth + 1)) }
    }
    let cost = constructionCost(value)
    if !cost.fits { throw fail("manifest.limit", "edit value/output budget") }
    return cost
  }

  func prepare(_ edits: [ManifestEdit]) throws -> DocumentChange {
    if edits.count > ManifestLimits.Editing.requests {
      throw fail("manifest.limit", "edit batch has more than 100 requests")
    }
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
    if expectedCost.nodes + actualCost.nodes > ManifestLimits.Editing.comparisonPairs {
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

  func semanticDelta() throws -> SemanticDelta {
    var pending: [(DeclarationValue, DeclarationValue, String)] = [
      (Lowering.lower(original.evaluation.root.value), Lowering.lower(expected), "")
    ]
    var visited = 0
    var pointers: [String] = []
    while let (left, right, pointer) = pending.popLast() {
      try charge(1)
      visited += 1
      if visited > ManifestLimits.Editing.comparisonPairs {
        throw fail("manifest.limit", "semantic delta comparison node pairs")
      }
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
      if pending.count > ManifestLimits.Editing.comparisonPairs - visited {
        throw fail("manifest.limit", "semantic delta scheduled pairs")
      }
    }
    return SemanticDelta(changedPointers: pointers.sorted())
  }

  func requireType(_ pointer: String, _ type: String, member: String? = nil) throws {
    guard current.values[pointer]?.type.unwrapped == .named(type),
      member == nil || current.values[pointer]?.value.member == member
    else { throw fail("manifest.edit.readOnly", "handle has the wrong domain kind") }
  }
  func resolve(_ handle: NodeID) throws -> String {
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
  /// History ranges use the snapshot immediately before each patch. Earlier siblings
  /// translate both bounds; contained edits resize the owner. Crossing an owner boundary
  /// cannot preserve occurrence identity and is rejected instead of guessing a pointer.
  func translated(_ originalRange: Range<Int>) throws -> Range<Int> {
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
  func direct(_ pointer: String) throws -> EvaluatedValue {
    guard let value = current.values[pointer], !value.defaulted, value.referent == nil,
      !current.hasAssembledAncestor(pointer),
      current.admission.nodes[value.syntax].kind != .sequence,
      current.admission.nodes[value.syntax].kind != .name
    else {
      throw fail(
        "manifest.edit.readOnly",
        "target is a shared constant, assembled value or inherited default")
    }
    return value
  }
  func containerPath(_ container: ContainerID) throws -> String {
    switch container {
    case .root: return ""
    case .group(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "ComponentGroup")
      return pointer
    }
  }
  func parent(_ pointer: String) -> String {
    String(pointer[..<pointer.lastIndex(of: "/")!])
  }
  func key(_ pointer: String) -> String {
    pointerUnescape(String(pointer[pointer.index(after: pointer.lastIndex(of: "/")!)...]))
  }

  func patch(_ range: Range<Int>, _ text: String) throws {
    try patch(range, bytes: Array(text.utf8))
  }
  func patch(_ range: Range<Int>, bytes: [UInt8]) throws {
    guard range.lowerBound >= 0, range.upperBound <= table.count else {
      throw fail("manifest.edit.overlap", "patch is outside the snapshot")
    }
    if table.count - range.count + bytes.count > ManifestLimits.Input.bytes {
      throw fail("manifest.limit", "generated manifest input bytes")
    }
    if current.bytes[range].elementsEqual(bytes) { return }
    table.replace(range, with: bytes)
    history.append(SourcePatch(range: range, replacement: bytes))
  }
  func mutate(_ pointer: String, _ replacement: ConstructionValue) throws {
    _ = try valueCost(replacement)
    let parts = pointerSegments(pointer)
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

  func replacementText(_ value: ConstructionValue, at range: Range<Int>) throws -> String {
    _ = try valueCost(value)
    let (style, indentation) = try style(at: range)
    let lineEnd =
      current.bytes[range.upperBound...].firstIndex(where: { $0 == 10 || $0 == 13 })
      ?? current.bytes.count
    var text = CanonicalPrinter(style: style).render(
      value, indentation: indentation, column: range.lowerBound - lineStart(range.lowerBound),
      trailing: lineEnd - range.upperBound)
    if text.hasPrefix("-"), range.lowerBound > 0 {
      let previous = current.bytes[range.lowerBound - 1]
      if ![
        UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
        UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: ","), UInt8(ascii: ":"),
      ].contains(previous) {
        text = " " + text
      }
    }
    return text
  }

  func replace(_ pointer: String, with value: ConstructionValue) throws {
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

  func contextualValue(_ input: StaticValue, as context: ConstructionType) throws
    -> ConstructionValue
  {
    _ = try valueCost(input.value)
    if input.type == context || input.type == context.unwrapped { return input.value }
    guard input.literal else {
      throw fail("manifest.type", "replacement has the wrong contextual type")
    }
    let result: ConstructionValue
    do {
      result = try LiteralConversion.convert(input.value, to: context) { try charge(1) }
    } catch let error as LiteralConversionError {
      throw fail(error.code, error.message)
    }
    _ = try valueCost(result)
    return result
  }

}
