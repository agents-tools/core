import AgentsCore
import Foundation
import TreeSitter
import TreeSitterYAML
import Yams

/// Ordered, decoded data with concrete UTF-8 ranges. Mapping order is retained independently
/// of the domain's dictionary semantics. The parser tree never escapes this module.
indirect enum YAMLData: Sendable, Equatable {
  case scalar(String, quoted: Bool, decimalTag: Bool)
  case sequence([YAMLNode])
  case mapping([(key: YAMLNode, value: YAMLNode)])

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.scalar(let a, let q, let t), .scalar(let b, let r, let u)):
      return a == b && q == r && t == u
    case (.sequence(let a), .sequence(let b)): return a == b
    case (.mapping(let a), .mapping(let b)):
      return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    default: return false
    }
  }
}

struct YAMLNode: Sendable, Equatable {
  let data: YAMLData
  let range: Range<Int>
  let entryRange: Range<Int>
  let flow: Bool

  var text: String? {
    if case .scalar(let text, _, _) = data { return text }
    return nil
  }
  var pairs: [(key: YAMLNode, value: YAMLNode)]? {
    if case .mapping(let pairs) = data { return pairs }
    return nil
  }
  var items: [YAMLNode]? {
    if case .sequence(let items) = data { return items }
    return nil
  }
}

private struct YAMLParseInput {
  let bytes: UnsafePointer<CChar>
  let count: Int
  var callbacks = 0
  var offset = 0
  var failed = false
  var cancelled = false
}

struct YAMLParseResult {
  let root: YAMLNode
  let callbacks: Int
  let nodes: Int
  let depth: Int
  let comments: [Range<Int>]
  let metrics: FrontEndMetrics
}

enum YAMLParser {
  // The pinned runtime reports periodic parse progress, including weighted tree compression.
  // Scalar scanning remains input-byte bounded. This measured work policy is not an allocation bound.
  static let callbackLimit = 16_000

  static func parse(
    _ source: SourceText, observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws -> YAMLParseResult {
    try Task.checkCancellation()
    let clock = ContinuousClock()
    var start = clock.now
    var metrics = FrontEndMetrics()
    var stage = FrontEndStage.admission
    observe?(stage, metrics)
    do {
      guard source.bytes.count <= ManifestLimits.Input.bytes else {
        throw source.failure("manifest.limit", "input byte limit", ManifestLimits.Input.bytes)
      }
      guard let text = String(bytes: source.bytes, encoding: .utf8) else {
        throw source.failure("manifest.encoding", "expected UTF-8", 0)
      }
      var offset = 0
      for scalar in text.unicodeScalars {
        let value = scalar.value
        if value == 0 || value == 0x85 || value == 0x2028 || value == 0x2029
          || value < 0x20 && ![9, 10, 13].contains(value)
          || (0x7F...0x9F).contains(value) || value == 0xFFFE || value == 0xFFFF

        {
          throw source.failure(
            "manifest.character", "unsupported raw source character", offset,
            end: offset + scalar.utf8.count)
        }
        offset += scalar.utf8.count
      }
      metrics.admissionSeconds = seconds(start.duration(to: clock.now))
      start = clock.now
      stage = .parser
      metrics.parserCalls = 1
      observe?(stage, metrics)
      guard let parser = ts_parser_new() else {
        throw source.failure("manifest.parser", "could not allocate YAML parser", 0)
      }
      defer { ts_parser_delete(parser) }
      guard ts_parser_set_language(parser, tree_sitter_yaml()) else {
        throw source.failure("manifest.parser", "YAML grammar ABI mismatch", 0)
      }
      var callbacks = 0
      var parserOffset = 0
      var cancelled = false
      let tree = source.bytes.withUnsafeBytes { raw -> OpaquePointer? in
        // A stable non-null pointer is required for empty input too.
        var empty: CChar = 0
        return withUnsafePointer(to: &empty) { emptyPointer in
          var state = YAMLParseInput(
            bytes: raw.baseAddress?.assumingMemoryBound(to: CChar.self) ?? emptyPointer,
            count: raw.count)
          return withUnsafeMutablePointer(to: &state) { pointer in
            let input = TSInput(
              payload: UnsafeMutableRawPointer(pointer),
              read: { payload, index, _, count in
                let state = payload!.assumingMemoryBound(to: YAMLParseInput.self).pointee
                let offset = min(Int(index), state.count)
                count!.pointee = UInt32(state.count - offset)
                return state.bytes.advanced(by: offset)
              }, encoding: TSInputEncodingUTF8, decode: nil)
            let options = TSParseOptions(
              payload: UnsafeMutableRawPointer(pointer),
              progress_callback: { progress in
                let state = progress!.pointee.payload!.assumingMemoryBound(to: YAMLParseInput.self)
                state.pointee.callbacks += 1
                state.pointee.offset = Int(progress!.pointee.current_byte_offset)
                state.pointee.failed = progress!.pointee.has_error
                state.pointee.cancelled = Task.isCancelled
                return state.pointee.cancelled || state.pointee.failed
                  || state.pointee.callbacks > YAMLParser.callbackLimit
              })
            let result = ts_parser_parse_with_options(parser, nil, input, options)
            callbacks = pointer.pointee.callbacks
            parserOffset = pointer.pointee.offset
            cancelled = pointer.pointee.cancelled
            return result
          }
        }
      }
      metrics.parsingSeconds = seconds(start.duration(to: clock.now))
      metrics.parserCallbacks = callbacks
      guard let tree else {
        if cancelled { throw CancellationError() }
        throw source.failure(
          callbacks > callbackLimit ? "manifest.limit" : "manifest.syntax",
          callbacks > callbackLimit ? "YAML parser work limit" : "invalid YAML", parserOffset)
      }
      defer { ts_tree_delete(tree) }
      try Task.checkCancellation()
      start = clock.now
      let root = ts_tree_root_node(tree)
      var pending: [(TSNode, Int)] = [(root, 1)]
      var count = 0
      var depth = 0
      var documents = 0
      var comments: [Range<Int>] = []
      while let (node, level) = pending.popLast() {
        count += 1
        depth = max(depth, level)
        metrics.syntaxNodes = count
        metrics.syntaxDepth = depth
        let start = Int(ts_node_start_byte(node))
        if count > ManifestLimits.Syntax.nodes || level > ManifestLimits.Syntax.depth {
          throw source.failure("manifest.limit", "YAML CST node/depth limit", start)
        }
        let kind = String(cString: ts_node_type(node))
        if kind == "document" { documents += 1 }
        if kind == "comment" { comments.append(nodeRange(node)) }
        if ["anchor", "alias", "yaml_directive", "tag_directive", "reserved_directive"].contains(
          kind)
        {
          throw source.failure("manifest.unsupported", "unsupported YAML \(kind)", start)
        }
        if kind == "tag", source.spelling(nodeRange(node)) != "!!float" {
          throw source.failure("manifest.tag", "only NativeValue !!float is supported", start)
        }
        if ts_node_is_error(node) || ts_node_is_missing(node) {
          throw source.failure("manifest.syntax", "invalid YAML", start)
        }
        for index in 0..<ts_node_child_count(node) {
          pending.append((ts_node_child(node, index), level + 1))
        }
      }
      guard documents == 1, !ts_node_has_error(root) else {
        throw source.failure("manifest.syntax", "expected one YAML document", 0)
      }
      metrics.guardSeconds = seconds(start.duration(to: clock.now))
      stage = .decoding
      start = clock.now
      observe?(stage, metrics)
      try Task.checkCancellation()
      let decoded: Yams.Node
      do {
        guard let value = try Yams.compose(yaml: text, .basic, .default, .utf8) else {
          throw source.failure("manifest.schema", "expected a declaration mapping", 0)
        }
        decoded = value
      } catch let failure as ManifestFailure { throw failure } catch {
        throw source.failure("manifest.syntax", "YAML decoding failed: \(error)", 0)
      }
      let value = try pair(root, decoded, source: source)
      metrics.evaluationSeconds = seconds(start.duration(to: clock.now))
      return YAMLParseResult(
        root: value, callbacks: callbacks, nodes: count, depth: depth,
        comments: comments.sorted { $0.lowerBound < $1.lowerBound },
        metrics: metrics)
    } catch let failure as ManifestFailure {
      throw ManifestFailure(failure.diagnostics[0], metrics: metrics, stage: stage)
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  private static func nodeRange(_ node: TSNode) -> Range<Int> {
    Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node))
  }

  private static func children(_ node: TSNode) -> [TSNode] {
    (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) }
      .filter { String(cString: ts_node_type($0)) != "comment" }
  }

  private static func pair(_ syntax: TSNode, _ semantic: Yams.Node, source: SourceText) throws
    -> YAMLNode
  {
    let kind = String(cString: ts_node_type(syntax))
    let children = children(syntax)
    let range = nodeRange(syntax)
    let tags = children.filter { String(cString: ts_node_type($0)) == "tag" }
    let content = children.filter { String(cString: ts_node_type($0)) != "tag" }
    if ["stream", "document", "block_node", "flow_node", "block_sequence_item"].contains(kind),
      content.count == 1
    {
      let node = try pair(content[0], semantic, source: source)
      let tagged = !tags.isEmpty
      if tagged {
        guard case .scalar(let text, let quoted, _) = node.data,
          semantic.tag.rawValue == "tag:yaml.org,2002:float"
        else { throw source.failure("manifest.tag", "!!float requires a scalar", range.lowerBound) }
        return YAMLNode(
          data: .scalar(text, quoted: quoted, decimalTag: true), range: range,
          entryRange: range, flow: node.flow)
      }
      return YAMLNode(data: node.data, range: node.range, entryRange: range, flow: node.flow)
    }
    if ["block_mapping", "flow_mapping", "flow_pair"].contains(kind), let mapping = semantic.mapping
    {
      let syntaxPairs = kind == "flow_pair" ? [syntax] : children
      guard syntaxPairs.count == mapping.count else {
        throw source.failure(
          "manifest.parser.mismatch", "YAML parsers disagree on mapping", range.lowerBound)
      }
      var pairs: [(key: YAMLNode, value: YAMLNode)] = []
      var keys = Set<String>()
      for (syntaxPair, semanticPair) in zip(syntaxPairs, mapping) {
        let key = field(syntaxPair, "key")
        let value = field(syntaxPair, "value")
        guard !ts_node_is_null(key), !ts_node_is_null(value) else {
          throw source.failure(
            "manifest.schema", "mapping entries require explicit keys and values",
            Int(ts_node_start_byte(syntaxPair)))
        }
        let keyNode = try pair(key, semanticPair.key, source: source)
        guard case .scalar(let name, let quoted, let tag) = keyNode.data,
          !tag, quoted || YAMLScalar.classify(name) == .string
        else {
          throw source.failure(
            "manifest.key", "mapping key must be a string", keyNode.range.lowerBound)
        }
        guard keys.insert(name).inserted else {
          throw source.failure(
            "manifest.key.duplicate", "duplicate decoded mapping key: \(name)",
            keyNode.range.lowerBound)
        }
        let node = try pair(value, semanticPair.value, source: source)
        pairs.append(
          (
            keyNode,
            YAMLNode(
              data: node.data, range: node.range, entryRange: nodeRange(syntaxPair), flow: node.flow
            )
          ))
      }
      return YAMLNode(
        data: .mapping(pairs), range: range, entryRange: range, flow: kind != "block_mapping")
    }
    if kind == "block_sequence" || kind == "flow_sequence", let sequence = semantic.sequence {
      guard children.count == sequence.count else {
        throw source.failure(
          "manifest.parser.mismatch", "YAML parsers disagree on sequence", range.lowerBound)
      }
      return YAMLNode(
        data: .sequence(try zip(children, sequence).map { try pair($0, $1, source: source) }),
        range: range, entryRange: range, flow: kind == "flow_sequence")
    }
    if let scalar = semantic.scalar,
      ["plain_scalar", "single_quote_scalar", "double_quote_scalar", "block_scalar"].contains(kind)
    {
      return YAMLNode(
        data: .scalar(scalar.string, quoted: kind != "plain_scalar", decimalTag: false),
        range: range, entryRange: range, flow: true)
    }
    throw source.failure(
      "manifest.parser.mismatch", "YAML parsers disagree on structure", range.lowerBound)
  }

  private static func field(_ node: TSNode, _ name: String) -> TSNode {
    name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) }
  }
}
