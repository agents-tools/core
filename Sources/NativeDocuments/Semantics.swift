import AgentsCore
import Foundation
import TOMLSemantics

extension Node {
  func equal(to other: Node, budget: NativeDocumentBudget) throws -> Bool {
    try budget.step()
    guard kind == other.kind else { return false }
    if kind == .object {
      guard members.count == other.members.count else { return false }
      for member in members {
        guard let i = try other.member(member.key, budget: budget),
          try member.node.equal(to: other.members[i].node, budget: budget)
        else { return false }
      }
      return true
    }
    if kind == .array {
      guard elements.count == other.elements.count else { return false }
      for (a, b) in zip(elements, other.elements) {
        if try !a.equal(to: b, budget: budget) { return false }
      }
      return true
    }
    return try budget.equal(text, other.text)
  }

  func fingerprint(_ budget: NativeDocumentBudget) throws -> Data {
    var data = Data()
    func append(_ text: String) throws {
      try budget.allocate(text.utf8.count + 24, stage: "observation")
      try budget.step(text.utf8.count)
      data.append(contentsOf: "\(text.utf8.count):".utf8)
      data.append(contentsOf: text.utf8)
    }
    try append(kind.rawValue)
    if kind == .object {
      try append(String(members.count))
      var sorted: [Member] = []
      for m in members {
        var index = 0
        while index < sorted.count {
          try budget.step(m.key.utf8.count + sorted[index].key.utf8.count)
          if m.key.utf8.lexicographicallyPrecedes(sorted[index].key.utf8) { break }
          index += 1
        }
        try budget.allocate(1, stage: "observation members")
        sorted.insert(m, at: index)
      }
      for m in sorted {
        try append(m.key)
        let child = try m.node.fingerprint(budget)
        try budget.allocate(child.count, stage: "observation subtree")
        data.append(child)
      }
    } else if kind == .array {
      try append(String(elements.count))
      for e in elements {
        let child = try e.fingerprint(budget)
        try budget.allocate(child.count, stage: "observation subtree")
        data.append(child)
      }
    } else {
      try append(text)
    }
    return data
  }

  func projectionFailure(_ budget: NativeDocumentBudget) throws -> NativeProjectionFailure? {
    try budget.step()
    if kind == .atom { return .nativeType(atomType ?? "nativeAtom") }
    if kind == .object {
      var keys: Set<String> = []
      for member in members {
        try budget.allocate(member.key.utf8.count, stage: "projection key")
        try budget.step(member.key.utf8.count)
        if !keys.insert(member.key).inserted { return .canonicalKeyCollision }
        if let failure = try member.node.projectionFailure(budget) { return failure }
      }
    }
    for element in elements {
      if let failure = try element.projectionFailure(budget) { return failure }
    }
    return nil
  }

  func project(_ budget: NativeDocumentBudget) throws -> NativeValue? {
    try budget.step()
    switch kind {
    case .object:
      var result: [String: NativeValue] = [:]
      for m in members {
        try budget.allocate(m.key.utf8.count + 1, stage: "projection")
        // Core dictionaries use canonical equivalence; refuse this projection rather than collapse keys.
        guard result[m.key] == nil, let value = try m.node.project(budget) else { return nil }
        result[m.key] = value
      }
      return .object(result)
    case .array:
      var values: [NativeValue] = []
      for e in elements {
        guard let v = try e.project(budget) else { return nil }
        values.append(v)
      }
      return .array(values)
    case .string: return .string(text)
    case .integer: return Int(text).map(NativeValue.integer) ?? .decimal(raw)
    case .decimal: return .decimal(text)
    case .boolean: return .boolean(text == "true")
    case .null: return .null
    case .atom: return nil
    }
  }
}

struct NativeRenderer {
  let format: NativeDocumentFormat
  let budget: NativeDocumentBudget
  let region: NativeRegion
  var toml: Bool { format == .toml }
  func string(_ value: String) throws -> String {
    guard value.utf8.count <= (Int.max - 2) / 6 else {
      throw NativeDocumentError.budgetExceeded("string encoding")
    }
    try budget.allocate(value.utf8.count * 6 + 2, stage: "string encoding")
    try budget.step(value.utf8.count)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    try budget.allocate(bytes.count, stage: "encoded string")
    if toml {
      try budget.allocate(bytes.count, stage: "TOML string escaping")
      var escaped: [UInt8] = []
      for byte in bytes {
        try budget.step()
        if byte == 127 {
          try budget.allocate(6, stage: "TOML string escaping")
          escaped.append(contentsOf: "\\u007F".utf8)
        } else {
          escaped.append(byte)
        }
      }
      return String(decoding: escaped, as: UTF8.self)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
  func render(_ value: NativeValue, depth: Int = 0) throws -> String {
    try budget.node(depth: depth)
    switch value {
    case .string(let value): return try string(value)
    case .integer(let value): return String(value)
    case .decimal(let raw):
      try budget.allocate(raw.utf8.count, stage: "decimal input")
      var parser = JSONParser(bytes: Array(raw.utf8), format: .json, budget: budget)
      let node: Node
      do { node = try parser.parse() } catch let failure as TOMLSemantics.SemanticBudget.Failure {
        throw failure
      } catch { throw NativeDocumentError.unrepresentableValue(format, region, "decimal") }
      guard node.kind == .integer || node.kind == .decimal, node.range == 0..<raw.utf8.count else {
        throw NativeDocumentError.unrepresentableValue(format, region, "decimal")
      }
      return toml && node.kind == .integer ? raw + "e0" : raw
    case .boolean(let value): return value ? "true" : "false"
    case .null:
      guard !toml else { throw NativeDocumentError.unrepresentableValue(format, region, "null") }
      return "null"
    case .array(let values):
      var parts: [String] = []
      for v in values { parts.append(try render(v, depth: depth + 1)) }
      return try nativeJoin(parts, prefix: "[", suffix: "]", separator: ", ", budget: budget)
    case .object(let values):
      var keys: [String] = []
      for key in values.keys {
        try budget.allocate(key.utf8.count + 1, stage: "rendered key order")
        var i = 0
        while i < keys.count {
          try budget.step(key.utf8.count + keys[i].utf8.count)
          if key.utf8.lexicographicallyPrecedes(keys[i].utf8) { break }
          i += 1
        }
        keys.insert(key, at: i)
      }
      var parts: [String] = []
      for key in keys {
        parts.append(
          try string(key) + (toml ? " = " : ": ") + render(values[key]!, depth: depth + 1))
      }
      return try nativeJoin(parts, prefix: "{", suffix: "}", separator: ", ", budget: budget)
    }
  }
}

func nativeJoin(
  _ parts: [String], prefix: String, suffix: String, separator: String, budget: NativeDocumentBudget
) throws -> String {
  try budget.allocate(prefix.utf8.count + suffix.utf8.count, stage: "rendered container")
  for part in parts {
    try budget.step(part.utf8.count)
    try budget.allocate(part.utf8.count + separator.utf8.count, stage: "rendered container")
  }
  return prefix + parts.joined(separator: separator) + suffix
}
