import AgentsCore

/// One expanded declaration sequence, counting repeated references by occurrence.
/// The caller retains spent traversal work across rejected source selections.
package struct ManifestExpansionBudget {
  package enum Failure: Error { case limit }

  private var total = ValueCost()
  private var sourceMap = SourceMapBudget()

  package init() {}

  package mutating func consume(
    _ record: DeclarationRecord, origins: [SourceSpan], locations: [SourceMapEntry],
    spending: (Int) throws -> Void
  ) throws {
    var cost = try cost(.record(record), depth: 1, spending: spending)
    guard origins.count <= ManifestLimits.SourceMap.origins else { throw Failure.limit }
    // Reference origins are inherited by every descendant value location.
    cost.origins = ValueCost.add(cost.origins, cost.nodes * origins.count)
    total.append(cost)
    guard total.fits, total.nodes <= ManifestLimits.SourceMap.locations else {
      throw Failure.limit
    }
    for location in locations {
      try spending(1 + location.origins.count + origins.count)
      guard
        sourceMap.consume(
          pointer: location.pointer, span: location.span,
          origins: location.origins + origins)
      else { throw Failure.limit }
    }
  }

  private func cost(
    _ value: DeclarationValue, depth: Int, spending: (Int) throws -> Void
  ) throws -> ValueCost {
    try spending(1)
    guard depth < ManifestLimits.Values.depth else { throw Failure.limit }
    let result: ValueCost
    switch value {
    case .string(let text): result = .scalar(text)
    case .integer, .boolean, .null: result = ValueCost()
    case .array(let values):
      guard values.count <= ManifestLimits.Values.entries else { throw Failure.limit }
      result = try .container(values.map { try cost($0, depth: depth + 1, spending: spending) })
    case .dictionary(let fields):
      result = try fieldsCost(fields, depth: depth, spending: spending)
    case .record(let record):
      result = try fieldsCost(
        record.fields, kind: record.kind, depth: depth, spending: spending)
    case .requirement(let requirement):
      var fields = [requirement.kind: DeclarationValue.string(requirement.value)]
      if let upper = requirement.upperBound { fields["to"] = .string(upper) }
      result = try fieldsCost(fields, depth: depth, spending: spending)
    }
    guard result.fits else { throw Failure.limit }
    return result
  }

  private func fieldsCost(
    _ fields: [String: DeclarationValue], kind: String? = nil, depth: Int,
    spending: (Int) throws -> Void
  ) throws -> ValueCost {
    guard fields.count <= ManifestLimits.Values.entries else { throw Failure.limit }
    var children: [ValueCost] = []
    var keys = fields.keys.sorted()
    if let kind {
      try spending(1)
      children.append(.scalar(kind))
      keys.append("kind")
    }
    for key in fields.keys.sorted() {
      children.append(try cost(fields[key]!, depth: depth + 1, spending: spending))
    }
    return .container(children, keys: keys)
  }
}
