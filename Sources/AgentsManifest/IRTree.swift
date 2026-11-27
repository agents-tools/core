import AgentsCore

/// A single complete IR tree is used for edit intent and comparison; no mutable domain mirror
/// is retained alongside it.
enum IRTree {
  static func root(_ ir: DeclarationIR) -> DeclarationValue {
    var fields: [String: DeclarationValue] = [
      "defaultAgents": ir.defaultAgents.map(YAMLConstruction.strings) ?? .null,
      "sources": .array(ir.sources.map(DeclarationValue.record)),
      "packages": .array(ir.packages.map(DeclarationValue.record)),
      "components": .array(ir.components.map(DeclarationValue.record)),
      "groups": .array(ir.groups.map(DeclarationValue.record)),
      "uses": .array(ir.uses.map(DeclarationValue.record)),
      "exports": YAMLConstruction.strings(ir.exports),
      "watch": YAMLConstruction.strings(ir.watch),
    ]
    fields["lifecycle"] = ir.lifecycle
    return .record(DeclarationRecord(kind: "declaration", fields: fields))
  }

  static func equivalent(_ lhs: DeclarationValue, _ rhs: DeclarationValue) -> Bool {
    lhs == rhs
      && LifecycleDeclaration.equivalent(lhs.record?["lifecycle"], rhs.record?["lifecycle"])
  }

  static func declaration(_ root: DeclarationValue) -> DeclarationIR {
    let f = root.record!.fields
    func records(_ key: String) -> [DeclarationRecord] { f[key]!.elements!.map { $0.record! } }
    func strings(_ key: String) -> [String] { f[key]!.elements!.map { $0.string! } }
    return DeclarationIR(
      defaultAgents: f["defaultAgents"]?.elements.map { $0.map { $0.string! } },
      exports: strings("exports"), sources: records("sources"), components: records("components"),
      groups: records("groups"), uses: records("uses"), watch: strings("watch"),
      packages: records("packages"), lifecycle: f["lifecycle"])
  }
  static func segments(_ pointer: String) -> [String] {
    guard !pointer.isEmpty else { return [] }
    return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
      pointerUnescape(String($0))
    }
  }
  static func value(_ root: DeclarationValue, at pointer: String) -> DeclarationValue? {
    var value = root
    for key in segments(pointer) {
      switch value {
      case .record(let record):
        guard let next = record[key] else { return nil }
        value = next
      case .dictionary(let fields):
        guard let next = fields[key] else { return nil }
        value = next
      case .array(let items):
        guard let index = Int(key), items.indices.contains(index) else { return nil }
        value = items[index]
      default: return nil
      }
    }
    return value
  }
  static func replacing(
    _ root: DeclarationValue, at pointer: String, with replacement: DeclarationValue?
  ) -> DeclarationValue {
    let keys = segments(pointer)
    func update(_ value: DeclarationValue, _ depth: Int) -> DeclarationValue {
      if depth == keys.count { return replacement ?? .null }
      let key = keys[depth]
      switch value {
      case .record(let record):
        var fields = record.fields
        if depth + 1 == keys.count && replacement == nil {
          fields.removeValue(forKey: key)
        } else {
          fields[key] = update(fields[key] ?? .null, depth + 1)
        }
        return .record(DeclarationRecord(kind: record.kind, fields: fields))
      case .dictionary(var fields):
        if depth + 1 == keys.count && replacement == nil {
          fields.removeValue(forKey: key)
        } else {
          fields[key] = update(fields[key] ?? .null, depth + 1)
        }
        return .dictionary(fields)
      case .array(var values):
        let index = Int(key)!
        if depth + 1 == keys.count && replacement == nil {
          values.remove(at: index)
        } else {
          values[index] = update(values[index], depth + 1)
        }
        return .array(values)
      default: preconditionFailure("checked IR pointer")
      }
    }
    return update(root, 0)
  }
  static func count(_ value: DeclarationValue) -> Int {
    switch value {
    case .record(let record): return 1 + record.fields.values.reduce(0) { $0 + count($1) }
    case .dictionary(let fields): return 1 + fields.values.reduce(0) { $0 + count($1) }
    case .array(let values): return 1 + values.reduce(0) { $0 + count($1) }
    default: return 1
    }
  }
}

enum IREdit {
  case set(String, DeclarationValue?)
  case insert(String, Int, DeclarationValue)
  case remove(String, Int)
  case move(String, Int, Int)
  case relocate(String, Int, String, Int)

  func applying(to root: DeclarationValue) -> DeclarationValue {
    switch self {
    case .set(let pointer, let value): return IRTree.replacing(root, at: pointer, with: value)
    case .insert(let pointer, let index, let value):
      var values = IRTree.value(root, at: pointer)!.elements!
      values.insert(value, at: index)
      return IRTree.replacing(root, at: pointer, with: .array(values))
    case .remove(let pointer, let index):
      var values = IRTree.value(root, at: pointer)!.elements!
      values.remove(at: index)
      return IRTree.replacing(root, at: pointer, with: .array(values))
    case .relocate(let source, let from, let destination, let to):
      let value = IRTree.value(root, at: source)!.elements![from]
      let removed = IREdit.remove(source, from).applying(to: root)
      return IREdit.insert(destination, to, value).applying(to: removed)
    case .move(let pointer, let from, let to):
      var values = IRTree.value(root, at: pointer)!.elements!
      let value = values.remove(at: from)
      values.insert(value, at: to)
      return IRTree.replacing(root, at: pointer, with: .array(values))
    }
  }
}

/// Computes one direct script in comparable operation units. The script is finite: each array
/// step fixes the next target position or removes a surplus occurrence; each field is visited once.
struct IRDiff {
  private(set) var comparisons = 0

  init(comparisons: Int = 0) { self.comparisons = comparisons }
  private(set) var edits: [IREdit] = []

  mutating func compare(_ old: DeclarationValue, _ new: DeclarationValue, at pointer: String = "")
    throws
  {
    if pointer == "/lifecycle" {
      if !LifecycleDeclaration.equivalent(old, new) { edits.append(.set(pointer, new)) }
      return
    }
    if try equal(old, new) { return }
    switch (old, new) {
    case (.record(let a), .record(let b))
    where a.kind == "package" && b.kind == "package"
      && (a["version"] == nil) != (b["version"] == nil):
      edits.append(.set(pointer, new))
    case (.record(let a), .record(let b)) where a.kind == b.kind:
      try fields(a.fields, b.fields, at: pointer)
    case (.dictionary(let a), .dictionary(let b)): try fields(a, b, at: pointer)
    case (.array(var a), .array(let b)):
      for index in b.indices {
        if index >= a.count {
          edits.append(.insert(pointer, index, b[index]))
          a.insert(b[index], at: index)
          continue
        }
        if try equal(a[index], b[index]) { continue }
        var exact: Int?
        var matches: [Int] = []
        for candidate in a.indices.dropFirst(index + 1) {
          if try equal(a[candidate], b[index]) {
            exact = candidate
            break
          }
          if identity(a[candidate]) != nil && identity(a[candidate]) == identity(b[index]) {
            matches.append(candidate)
          }
        }
        let sameIdentity = identity(a[index]) != nil && identity(a[index]) == identity(b[index])
        if exact == nil && !sameIdentity && matches.count > 1 {
          throw ManifestFailure(
            ManifestDiagnostic(
              code: "manifest.ambiguous", message: "ambiguous matching occurrences",
              span: SourceSpan(
                document: DocumentIdentity("manifest"), start: 0, end: 0, line: 1, column: 1)))
        }
        if let match = exact ?? (sameIdentity ? nil : matches.first) {
          edits.append(.move(pointer, match, index))
          a.insert(a.remove(at: match), at: index)
        } else if !sameIdentity {
          var retained = false
          for later in b.indices.dropFirst(index + 1) {
            if try equal(a[index], b[later]) {
              retained = true
              break
            }
            if identity(a[index]) != nil && identity(a[index]) == identity(b[later]) {
              retained = true
              break
            }
          }
          if retained {
            edits.append(.insert(pointer, index, b[index]))
            a.insert(b[index], at: index)
            continue
          }
        }
        try compare(a[index], b[index], at: pointer + "/\(index)")
        a[index] = b[index]
      }
      while a.count > b.count {
        edits.append(.remove(pointer, a.count - 1))
        a.removeLast()
      }
    default: edits.append(.set(pointer, new))
    }
  }
  private mutating func fields(
    _ old: [String: DeclarationValue], _ new: [String: DeclarationValue], at pointer: String
  ) throws {
    for key in Set(old.keys).union(new.keys).sorted(by: utf8Less) {
      let path = pointer + "/" + pointerEscape(key)
      if let a = old[key], let b = new[key] {
        try compare(a, b, at: path)
      } else {
        edits.append(.set(path, new[key]))
      }
    }
  }
  private mutating func equal(_ lhs: DeclarationValue, _ rhs: DeclarationValue) throws -> Bool {
    var pending = [(lhs, rhs)]
    while let (a, b) = pending.popLast() {
      comparisons += 1
      guard comparisons <= ManifestLimits.Editing.comparisonPairs else { throw limit() }
      switch (a, b) {
      case (.record(let x), .record(let y)):
        guard x.kind == y.kind, x.fields.keys == y.fields.keys else { return false }
        if x.kind == "declaration", !LifecycleDeclaration.equivalent(x["lifecycle"], y["lifecycle"])
        {
          return false
        }
        for key in x.fields.keys.sorted(by: utf8Less) {
          pending.append((x.fields[key]!, y.fields[key]!))
        }
      case (.dictionary(let x), .dictionary(let y)):
        guard x.keys == y.keys else { return false }
        for key in x.keys.sorted(by: utf8Less) { pending.append((x[key]!, y[key]!)) }
      case (.array(let x), .array(let y)):
        guard x.count == y.count else { return false }
        pending += zip(x, y)
      default: if a != b { return false }
      }
    }
    return true
  }
  private func identity(_ value: DeclarationValue) -> String? {
    guard let record = value.record else { return nil }
    return record["name"]?.string.map { record.kind + ":" + $0 }
      ?? (record.kind == "skills" ? record["source"]?.string.map { "skills:" + $0 } : nil)
  }
  private func limit() -> ManifestFailure {
    ManifestFailure(
      ManifestDiagnostic(
        code: "manifest.limit", message: "edit comparison limit",
        span: SourceSpan(
          document: DocumentIdentity("manifest"), start: 0, end: 0, line: 1, column: 1)))
  }
}
