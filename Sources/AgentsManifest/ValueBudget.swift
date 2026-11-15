import AgentsCore

struct ValueCost: Sendable {
  var nodes = 1
  var strings = 0
  var encoded = 16
  var depth = 1
  var origins = 1

  static func scalar(_ text: String = "") -> Self {
    var encoded = 2
    for byte in text.utf8 {
      encoded +=
        byte < UInt8(ascii: " ")
        ? 6 : (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") ? 2 : 1)
    }
    return Self(strings: text.utf8.count, encoded: encoded)
  }

  static func container(_ children: [ValueCost], keys: [String] = []) -> Self {
    var result = Self()
    for child in children {
      result.append(child)
    }
    for key in keys {
      let cost = scalar(key)
      result.strings = add(result.strings, cost.strings)
      result.encoded = add(result.encoded, cost.encoded + 4)
    }
    return result
  }

  mutating func append(_ child: Self) {
    nodes = Self.add(nodes, child.nodes)
    strings = Self.add(strings, child.strings)
    encoded = Self.add(encoded, Self.add(child.encoded, 4 + child.nodes * 2))
    origins = Self.add(origins, child.origins)
    depth = max(depth, child.depth + 1)
  }

  var fits: Bool {
    nodes <= ManifestLimits.Values.nodes && strings <= ManifestLimits.Values.stringBytes
      && encoded <= ManifestLimits.Output.encodedBytes
      && depth <= ManifestLimits.Values.depth && origins <= ManifestLimits.SourceMap.origins
  }

  static func add(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow
      ? (ManifestLimits.Output.encodedBytes + 1)
      : min(result, (ManifestLimits.Output.encodedBytes + 1))
  }
}

struct SourceMapBudget {
  private var locations = 0
  private var origins = 0
  private var encoded = 0

  var remainingLocations: Int { ManifestLimits.SourceMap.locations - locations }
  var remainingOrigins: Int { ManifestLimits.SourceMap.origins - origins }

  mutating func consume(pointer: String, span: SourceSpan, origins: [SourceSpan]) -> Bool {
    guard remainingLocations > 0, origins.count <= remainingOrigins else { return false }
    let estimate =
      origins.reduce(pointer.utf8.count + span.document.rawValue.utf8.count + 160 + 80) {
        ValueCost.add($0, $1.document.rawValue.utf8.count + 160)
      }
    guard estimate <= ManifestLimits.SourceMap.encodedBytes - encoded else { return false }
    locations += 1
    self.origins += origins.count
    encoded += estimate
    return true
  }
}

func validateIRBudget(_ value: DeclarationValue, source: SourceText) throws {
  var work = 0
  func cost(_ value: DeclarationValue, depth: Int) throws -> ValueCost {
    work += 1
    guard depth <= ManifestLimits.Values.depth, work <= ManifestLimits.Values.nodes else {
      throw source.failure("manifest.limit", "domain value depth/node limit", 0)
    }
    let result: ValueCost
    switch value {
    case .string(let value): result = .scalar(value)
    case .array(let values):
      guard values.count <= ManifestLimits.Values.entries else {
        throw source.failure("manifest.limit", "container entry limit", 0)
      }
      result = try .container(values.map { try cost($0, depth: depth + 1) })
    case .dictionary(let fields):
      guard fields.count <= ManifestLimits.Values.entries else {
        throw source.failure("manifest.limit", "container entry limit", 0)
      }
      result = try .container(
        fields.values.map { try cost($0, depth: depth + 1) }, keys: Array(fields.keys))
    case .record(let record):
      result = try cost(.dictionary(record.fields), depth: depth)
    case .requirement(let value):
      result = .container([.scalar(value.value)] + (value.upperBound.map { [.scalar($0)] } ?? []))
    default: result = ValueCost()
    }
    guard result.fits else { throw source.failure("manifest.limit", "domain value budget", 0) }
    return result
  }
  _ = try cost(value, depth: 1)
}
