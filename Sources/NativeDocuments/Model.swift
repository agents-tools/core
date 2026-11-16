import AgentsCore
import Foundation
import TOMLSemantics

package enum NativeDocumentFormat: Equatable {
  case json
  case jsonc(trailingCommas: Bool)
  case toml
}

package enum NativeDocumentError: Error, CustomStringConvertible {
  package var description: String {
    switch self {
    case .invalidDocument(let code, _): "Invalid native document (\(code))."
    case .ownershipMismatch: "Native region ownership does not match."
    case .unsupportedEdit(let reason, _, _): "Unsupported native edit (\(reason))."
    case .unrepresentableValue: "Value is not representable in the native format."
    case .budgetExceeded(let stage): "Native document budget exceeded (\(stage))."
    case .cancelled: "Native document operation cancelled."
    }
  }
  case invalidDocument(code: String, range: Range<Int>?)
  case ownershipMismatch(NativeRegion)
  case unsupportedEdit(NativeUnsupportedEdit, NativeRegion, [Range<Int>])
  case unrepresentableValue(NativeDocumentFormat, NativeRegion, String)
  case budgetExceeded(String)
  case cancelled
}

package enum NativeUnsupportedEdit {
  case syntaxNotLocated, ambiguousOccurrence, ambiguousTrivia, wouldRewriteUnownedStructure,
    overlappingEdits
}

package struct NativeRegion: Equatable {
  package let steps: [NativePathStep]
  package init(_ steps: [NativePathStep]) { self.steps = steps }
  package init(keys: [String]) { steps = keys.map(NativePathStep.key) }
  package static func == (lhs: Self, rhs: Self) -> Bool { lhs.steps == rhs.steps }
}

package enum NativePathStep: Equatable {
  case key(String)
  case occurrence(NativeOccurrenceEvidence)
  package static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.key(let x), .key(let y)): return x.utf8.elementsEqual(y.utf8)
    case (.occurrence(let x), .occurrence(let y)): return x == y
    default: return false
    }
  }
}

package struct NativeOccurrenceEvidence: Equatable {
  package let idKey: String?
  package let id: String?
  /// Versioned format owners may retain these semantic fingerprints and neighbor evidence.
  /// They contain no byte offsets and do not authorize adoption of an observed occurrence.
  /// Fingerprints contain value bytes: secret-bearing matches stay in E/D's private plan,
  /// while only non-secret semantic evidence may enter a versioned locked layout.
  package let snapshot: Data?
  /// Insertion ownership pins the complete semantic array and its position. Changed arrays
  /// require fresh evidence from an authorized same-snapshot prepare, never duplicate reselection.
  package let arraySnapshot: Data?
  package let ordinal: Int?
  package let previous: Data?
  package let next: Data?
  package init(idKey: String, id: String) {
    self.idKey = idKey
    self.id = id
    snapshot = nil
    arraySnapshot = nil
    ordinal = nil
    previous = nil
    next = nil
  }
  package init(
    snapshot: Data, ordinal: Int, previous: Data?, next: Data?, arraySnapshot: Data? = nil
  ) {
    idKey = nil
    id = nil
    self.snapshot = snapshot
    self.arraySnapshot = arraySnapshot
    self.ordinal = ordinal
    self.previous = previous
    self.next = next
  }
  package static func == (a: Self, b: Self) -> Bool {
    func same(_ x: String?, _ y: String?) -> Bool {
      switch (x, y) {
      case (.some(let x), .some(let y)): x.utf8.elementsEqual(y.utf8)
      case (.none, .none): true
      default: false
      }
    }
    return same(a.idKey, b.idKey) && same(a.id, b.id) && a.snapshot == b.snapshot
      && a.arraySnapshot == b.arraySnapshot && a.ordinal == b.ordinal && a.previous == b.previous
      && a.next == b.next
  }
}

package enum NativeProjectionFailure {
  case canonicalKeyCollision
  case nativeType(String)
}

package struct NativeObservation {
  package let region: NativeRegion
  package let value: NativeValue?
  package let nativeKind: String
  package let numericLexeme: String?
  package let projectionFailure: NativeProjectionFailure?
  package let valueRange: Range<Int>?
  package let entryRanges: [Range<Int>]
  package let occurrences: [NativeOccurrenceEvidence]
  let fingerprint: Data
}

package enum NativeExpectedRegion {
  case absent
  case owned(NativeObservation)
  /// Creation evidence authorizes only empty, comment-safe pruning, never a put.
  case createdContainer(NativeObservation)
}

package enum NativeRegionEdit {
  case put(region: NativeRegion, expected: NativeExpectedRegion, value: NativeValue)
  case remove(region: NativeRegion, expected: NativeExpectedRegion)
  /// Appends a distinct occurrence even when an equal unmanaged value exists. The precondition
  /// observes the original array, or its absence. Several appends retain caller order.
  case append(region: NativeRegion, expected: NativeExpectedRegion, value: NativeValue)
  /// The caller must hold durable creation authority for this object or array. The observation
  /// must match the preimage; removal is conditional on emptiness after all descendant edits.
  /// Unowned comments or ambiguous removal syntax retain the container.
  case pruneCreatedContainer(region: NativeRegion, observed: NativeObservation)
  var region: NativeRegion {
    switch self {
    case .put(let r, _, _), .append(let r, _, _), .remove(let r, _),
      .pruneCreatedContainer(let r, _):
      r
    }
  }
  var expected: NativeExpectedRegion {
    switch self {
    case .put(_, let e, _), .append(_, let e, _), .remove(_, let e): e
    case .pruneCreatedContainer(_, let observation): .createdContainer(observation)
    }
  }
  var isAppend: Bool {
    if case .append = self { true } else { false }
  }
  var isConditionalPrune: Bool {
    if case .pruneCreatedContainer = self { true } else { false }
  }
}

package struct PreparedNativeChange {
  package let bytes: Data
  package let changedRegions: [NativeRegion]
  package let observations: [NativeObservation]
  package let createdContainers: [NativeRegion]
  /// Input edit index associates each inserted owner with its final, rematchable observation.
  package let appendedOccurrences: [NativeAppendedOccurrence]
}

package struct NativeAppendedOccurrence {
  package let editIndex: Int
  package let observation: NativeObservation
}

struct Member {
  var key: String
  var node: Node
  var entry: Range<Int>?
  var comma: Range<Int>?
  var keyRange: Range<Int>? = nil
}

final class Node {
  enum Kind: String { case object, array, string, integer, decimal, boolean, null, atom }
  var kind: Kind
  var text: String
  var raw: String
  var atomType: String?
  var range: Range<Int>?
  var entry: Range<Int>?
  var members: [Member] = []
  var elements: [Node] = []
  var headers: [Range<Int>] = []
  var insertion: Int?
  var inline = false
  // Dotted descendants own entries inside these braces, not a separately extensible table.
  weak var enclosingInline: Node?
  var inlineKeyPath: [String] = []
  var aot = false
  var syntaxLocated = false
  var commas: [Range<Int>] = []
  init(_ kind: Kind, text: String = "", raw: String = "", range: Range<Int>? = nil) {
    self.kind = kind
    self.text = text
    self.raw = raw
    self.range = range
  }
  func member(_ key: String, budget: NativeDocumentBudget) throws -> Int? {
    for i in members.indices {
      try budget.step()
      if try budget.equal(members[i].key, key) { return i }
    }
    return nil
  }
  func inlineEntries(_ budget: NativeDocumentBudget) throws -> [(parent: Node, index: Int)] {
    var result: [(parent: Node, index: Int)] = []
    func collect(_ node: Node, depth: Int) throws {
      try budget.enter(depth)
      for i in node.members.indices {
        try budget.step()
        if node.members[i].entry != nil {
          try budget.allocate(1, stage: "inline entries")
          result.append((node, i))
        } else {
          try collect(node.members[i].node, depth: depth + 1)
        }
      }
    }
    try collect(self, depth: 0)
    try budget.allocate(result.count, stage: "inline entry order")
    return try result.sorted {
      try budget.step()
      return $0.parent.members[$0.index].entry!.lowerBound
        < $1.parent.members[$1.index].entry!.lowerBound
    }
  }
  func copy(_ budget: NativeDocumentBudget, depth: Int = 0) throws -> Node {
    try budget.node(depth: depth)
    let result = Node(kind, text: text, raw: raw, range: range)
    result.entry = entry
    result.atomType = atomType
    result.headers = headers
    result.insertion = insertion
    result.inline = inline
    result.aot = aot
    result.syntaxLocated = syntaxLocated
    result.commas = commas
    for member in members {
      try budget.allocate(1, stage: "expected member")
      result.members.append(
        Member(
          key: member.key, node: try member.node.copy(budget, depth: depth + 1),
          entry: member.entry, comma: member.comma, keyRange: member.keyRange))
    }
    for element in elements { result.elements.append(try element.copy(budget, depth: depth + 1)) }
    return result
  }
}

func translated<T>(_ body: () throws -> T) throws -> T {
  do { return try body() } catch SemanticBudget.Failure.exceeded(let stage) {
    throw NativeDocumentError.budgetExceeded(stage)
  } catch SemanticBudget.Failure.cancelled { throw NativeDocumentError.cancelled } catch let error
    as NativeDocumentError
  { throw error } catch {
    throw NativeDocumentError.invalidDocument(code: "invalidSyntaxOrValue", range: nil)
  }
}
