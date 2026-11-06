import AgentsCore
import AgentsDescription

/// Diffs full symbolic values against their source locations. Direct constructions are edited
/// by field, ordered arrays by occurrence, and assembled expressions remain read-only.
struct CompleteDeclarationPlanner {
  let document: DeclarationDocument
  let next: Declaration

  func plan() throws -> [DocumentOperation] {
    var operations: [DocumentOperation] = []
    let desired = try DeclarationConstruction.root(next).constructionValue
    try difference(document.evaluation.root.value, desired, at: "", into: &operations)
    return operations
  }

  private func handle(_ pointer: String) throws -> NodeID {
    guard let handle = document.node(at: pointer) else {
      throw DeclarationEditPlan.failure(
        "manifest.edit.readOnly", "value has no independent source location",
        span: document.source.span(0..<0))
    }
    return handle
  }

  private func difference(
    _ old: ConstructionValue, _ new: ConstructionValue, at pointer: String,
    into operations: inout [DocumentOperation]
  ) throws {
    if Lowering.lower(old) == Lowering.lower(new) { return }
    switch (old, new) {
    case (.node("SkillSelection", "names", let left), .node("SkillSelection", "names", let right)):
      try array(left["names"]!.array!, right["names"]!.array!, at: pointer, into: &operations)
    case (.node(let type, let member, let fields), .node(let newType, let newMember, let desired))
    where type == newType && member == newMember && type != "Source" && type != "SkillSelection":
      if let value = document.values[pointer], document.admission.nodes[value.syntax].kind != .call,
        type != "ConfigurationValue" || !["array", "object"].contains(member)
      {
        operations.append(.replaceValue(try handle(pointer), new))
        return
      }
      // Vocabulary order keeps the batch deterministic and respects constructor argument order.
      let signature = Vocabulary.signatures.filter { $0.type == type && $0.member == member }.max {
        $0.parameters.count < $1.parameters.count
      }
      let names = signature?.parameters.map(\.name) ?? []
      if names.isEmpty {
        operations.append(.replaceValue(try handle(pointer), new))
        return
      }
      for name in names {
        guard let left = fields[name], let right = desired[name],
          Lowering.lower(left) != Lowering.lower(right)
        else { continue }
        let child = pointer + "/" + pointerEscape(name)
        let explicit = document.values[child].map { !$0.defaulted } ?? false
        if explicit, canDescend(left, right) {
          try difference(left, right, at: child, into: &operations)
        } else {
          operations.append(.setArgument(try handle(pointer), field: name, value: right))
        }
      }
    case (.array(let left), .array(let right)):
      try array(left, right, at: pointer, into: &operations)
    case (.object(let left), .object(let right)):
      for key in right.keys.sorted(by: utf8Less) {
        if let old = left[key] {
          try difference(
            old, right[key]!, at: pointer + "/" + pointerEscape(key), into: &operations)
        } else {
          operations.append(.dictionaryEntry(try handle(pointer), key: key, value: right[key]!))
        }
      }
      for key in left.keys.sorted(by: utf8Less) where right[key] == nil {
        operations.append(.dictionaryEntry(try handle(pointer), key: key, value: nil))
      }
    default:
      operations.append(.replaceValue(try handle(pointer), new))
    }
  }

  private func canDescend(_ old: ConstructionValue, _ new: ConstructionValue) -> Bool {
    switch (old, new) {
    case (.array, .array), (.object, .object): return true
    case (.node(let a, let b, _), .node(let x, let y, _)):
      return a == x && b == y && a != "Source" && (a != "SkillSelection" || b == "names")
    default: return false
    }
  }

  private func identity(_ value: ConstructionValue) -> String? {
    guard case .node(let type, let member, let fields) = value else { return nil }
    if let name = fields["name"]?.text {
      if type == "GroupReference" || type == "SectionReference" {
        let kind = Lowering.recordKind(type: type, member: member, fields: fields)
        return type + ":" + kind + ":" + (fields["source"]?.text ?? ".") + ":" + name
      }
      return type + ":" + member + ":" + name
    }
    if type == "Component", let source = fields["source"]?.text {
      return type + ":" + member + ":" + source
    }
    if type == "Component", member == "instructions" { return type + ":" + member }
    return nil
  }

  private func array(
    _ old: [ConstructionValue], _ new: [ConstructionValue], at pointer: String,
    into operations: inout [DocumentOperation]
  ) throws {
    // Equal-length occurrence-addressed changes retain each position, including repeated names.
    if old.count == new.count, zip(old, new).allSatisfy({ identity($0) == identity($1) }) {
      for index in old.indices {
        try difference(old[index], new[index], at: pointer + "/\(index)", into: &operations)
      }
      return
    }
    let (count, overflow) = (old.count + 1).multipliedReportingOverflow(by: new.count + 1)
    guard !overflow, count <= ManifestLimits.Editing.comparisonPairs else {
      throw DeclarationEditPlan.failure(
        "manifest.limit", "declaration comparison pairs", span: document.source.span(0..<0))
    }
    func matches(_ a: ConstructionValue, _ b: ConstructionValue) -> Bool {
      if let identity = identity(a), identity == self.identity(b) { return true }
      return Lowering.lower(a) == Lowering.lower(b)
    }
    // A named edit across a length change cannot infer which conditional occurrence survives.
    let keys = old.compactMap(identity)
    for key in Set(keys) where keys.filter({ $0 == key }).count > 1 {
      if old != new, new.contains(where: { identity($0) == key }) {
        let candidates = old.indices.filter { identity(old[$0]) == key }.map { pointer + "/\($0)" }
        let spans = candidates.compactMap { document.sourceMap.locations(at: $0).first?.span }
        throw ManifestFailure(
          ManifestDiagnostic(
            code: "manifest.ambiguous",
            message: "multiple matching occurrences require an occurrence-addressed edit",
            span: spans.first ?? document.source.span(0..<0), related: Array(spans.dropFirst())))
      }
    }
    let width = new.count + 1
    var lengths = [Int](repeating: 0, count: count)
    for i in old.indices.reversed() {
      for j in new.indices.reversed() {
        lengths[i * width + j] =
          matches(old[i], new[j])
          ? lengths[(i + 1) * width + j + 1] + 1
          : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
      }
    }
    var pairs: [(Int, Int)] = []
    var (i, j) = (0, 0)
    while i < old.count && j < new.count {
      if matches(old[i], new[j]) {
        pairs.append((i, j))
        i += 1
        j += 1
      } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    let anchors = pairs
    var keptOld = Set(pairs.map(\.0))
    let anchoredNew = Set(pairs.map(\.1))
    var moved: [Int: Int] = [:]
    for j in new.indices where !anchoredNew.contains(j) {
      let candidates = old.indices.filter { !keptOld.contains($0) && matches(old[$0], new[j]) }
      if candidates.count == 1, let i = candidates.first {
        moved[j] = i
        keptOld.insert(i)
        pairs.append((i, j))
      }
    }
    // Field edits precede moves so original occurrence handles still address their owners.
    for (i, j) in pairs {
      try difference(old[i], new[j], at: pointer + "/\(i)", into: &operations)
    }
    for j in new.indices where !anchoredNew.contains(j) {
      let anchor = try anchors.first { $0.1 > j }.map {
        InsertionPosition.before(try handle(pointer + "/\($0.0)"))
      }
      if let i = moved[j] {
        operations.append(
          .moveElement(
            try handle(pointer + "/\(i)"), into: try handle(pointer), at: anchor ?? .last))
      } else {
        operations.append(.insertElement(new[j], into: try handle(pointer), at: anchor ?? .last))
      }
    }
    for i in old.indices where !keptOld.contains(i) {
      operations.append(.removeElement(try handle(pointer + "/\(i)")))
    }
  }
}
