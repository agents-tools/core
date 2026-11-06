import AgentsCore
import AgentsDescription

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

func constructionCost(_ value: ConstructionValue) -> ValueCost {
  switch value {
  case .text(let text): return .scalar(text)
  case .version(let version): return .scalar(version.normalized)
  case .range(let range):
    return .container([.scalar(range.lowerBound.normalized), .scalar(range.upperBound.normalized)])
  case .array(let values): return .container(values.map(constructionCost))
  case .object(let fields):
    return .container(fields.values.map(constructionCost), keys: Array(fields.keys))
  case .node(let type, let member, let fields):
    return .container(
      fields.values.map(constructionCost), keys: [type, member] + Array(fields.keys))
  case .none, .integer, .boolean: return ValueCost()
  }
}
