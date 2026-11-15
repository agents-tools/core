import AgentsCore

/// The finite constraints compiled from the bundled declaration schema. No caller supplies rules.
indirect enum YAMLRule: Sendable {
  case string, native, version
  case integer(minimum: Int)
  case constant(String)
  case enumeration([String])
  case named(String)
  case array(YAMLRule)
  case dictionary(YAMLRule)
  case object([String: YAMLRule], required: [String])
  case oneOf([YAMLRule])
}

final class YAMLValidation {
  let source: SourceText
  private(set) var work = 0
  private(set) var strings = 0
  private var nodes = 0

  init(source: SourceText) { self.source = source }

  func validate(_ node: YAMLNode) throws {
    try inspect(node, depth: 1)
    try check(node, ManifestSchema.root)
  }

  private func spend(_ node: YAMLNode) throws {
    work += 1
    guard work <= ManifestLimits.Domain.steps else {
      throw source.failure("manifest.limit", "schema work limit", node.range.lowerBound)
    }
  }

  private func inspect(_ node: YAMLNode, depth: Int) throws {
    nodes += 1
    guard nodes <= ManifestLimits.Values.nodes, depth <= ManifestLimits.Values.depth else {
      throw source.failure(
        "manifest.limit", "decoded value node/depth limit", node.range.lowerBound)
    }
    switch node.data {
    case .scalar(let text, _, _): strings += text.utf8.count
    case .sequence(let items):
      guard items.count <= ManifestLimits.Values.entries else {
        throw source.failure("manifest.limit", "container entry limit", node.range.lowerBound)
      }
      for item in items { try inspect(item, depth: depth + 1) }
    case .mapping(let pairs):
      guard pairs.count <= ManifestLimits.Values.entries else {
        throw source.failure("manifest.limit", "container entry limit", node.range.lowerBound)
      }
      for pair in pairs {
        try inspect(pair.key, depth: depth + 1)
        try inspect(pair.value, depth: depth + 1)
      }
    }
    guard strings <= ManifestLimits.Values.stringBytes else {
      throw source.failure("manifest.limit", "decoded string byte limit", node.range.lowerBound)
    }
  }

  private func check(_ node: YAMLNode, _ rule: YAMLRule) throws {
    try spend(node)
    func fail(_ message: String) -> ManifestFailure {
      source.failure("manifest.schema", message, node.range.lowerBound, end: node.range.upperBound)
    }
    func string() throws -> String {
      guard case .scalar(let text, let quoted, let tag) = node.data,
        !tag, quoted || YAMLScalar.classify(text) == .string
      else { throw fail("expected a string") }
      return text
    }
    switch rule {
    case .named(let name): try check(node, ManifestSchema.definitions[name]!)
    case .string: _ = try string()
    case .constant(let expected):
      guard try string() == expected else { throw fail("expected \(expected)") }
    case .enumeration(let values):
      guard try values.contains(string()) else {
        throw fail("expected one of \(values.joined(separator: ", "))")
      }
    case .integer, .version:
      guard case .scalar(let text, let quoted, let tag) = node.data,
        !quoted, !tag, YAMLScalar.classify(text) == .integer, let integer = YAMLScalar.integer(text)
      else { throw fail("expected a representable plain integer") }
      switch rule {
      case .version: guard integer == 1 else { throw fail("unsupported manifest version") }
      case .integer(let minimum):
        guard integer >= minimum else { throw fail("integer is below its minimum") }
      default: break
      }
    case .array(let item):
      guard let items = node.items else { throw fail("expected a sequence") }
      for node in items { try check(node, item) }
    case .dictionary(let value):
      guard let pairs = node.pairs else { throw fail("expected a mapping") }
      for pair in pairs { try check(pair.value, value) }
    case .object(let fields, let required):
      guard let pairs = node.pairs else { throw fail("expected a mapping") }
      let present = Set(pairs.map { $0.key.text! })
      for name in required where !present.contains(name) { throw fail("missing field: \(name)") }
      for pair in pairs {
        let name = pair.key.text!
        guard let rule = fields[name] else {
          throw source.failure(
            "manifest.schema", "unknown field: \(name)", pair.key.range.lowerBound)
        }
        try check(pair.value, rule)
      }
    case .oneOf(let choices):
      // Component and transport records have a literal discriminator in the generated schema.
      // Select that branch before traversing descendants, rather than rescanning whole subtrees.
      if let kind = node.pairs?.first(where: { $0.key.text == "kind" })?.value.text {
        for candidate in choices {
          let resolved: YAMLRule
          if case .named(let name) = candidate {
            resolved = ManifestSchema.definitions[name]!
          } else {
            resolved = candidate
          }
          if case .object(let fields, _) = resolved,
            let discriminator = fields["kind"]
          {
            switch discriminator {
            case .constant(let value) where value == kind:
              try check(node, candidate)
              return
            case .enumeration(let values) where values.contains(kind):
              try check(node, candidate)
              return
            default: continue
            }
          }
        }
      }
      var matches = 0
      var firstFailure: ManifestFailure?
      for choice in choices {
        do {
          try check(node, choice)
          matches += 1
        } catch let failure as ManifestFailure {
          if failure.diagnostics.first?.code == "manifest.limit" { throw failure }
          firstFailure = firstFailure ?? failure
        }
      }
      guard matches == 1 else {
        if matches == 0, let firstFailure { throw firstFailure }
        throw fail("ambiguous field shape")
      }
    case .native:
      switch node.data {
      case .scalar(let text, let quoted, let tag):
        if tag {
          guard YAMLScalar.decimal(text, explicit: true) != nil else {
            throw fail("!!float requires exact finite JSON-number text")
          }
        } else if !quoted {
          switch YAMLScalar.classify(text) {
          case .integer:
            guard YAMLScalar.integer(text) != nil else {
              throw fail("integer overflow; use !!float for a decimal value")
            }
          case .decimal:
            guard YAMLScalar.decimal(text, explicit: false) != nil else {
              throw fail("expected a finite decimal")
            }
          default: break
          }
        }
      case .sequence(let items): for item in items { try check(item, .native) }
      case .mapping(let pairs): for pair in pairs { try check(pair.value, .native) }
      }
    }
  }
}
