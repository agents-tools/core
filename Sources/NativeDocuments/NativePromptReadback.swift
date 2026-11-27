import Foundation

/// A read-only view onto the parser's indexed nodes. This avoids projecting unrelated
/// settings or constructing occurrence fingerprints during prompt field discovery.
package struct NativePromptNode {
  fileprivate let node: Node
  package var isObject: Bool { node.kind == .object }
  package var isArray: Bool { node.kind == .array }
  package var string: String? { node.kind == .string ? node.text : nil }
  package var sourceRange: Range<Int>? { node.range }
  package var fields: [(String, Self)] { node.members.map { ($0.key, .init(node: $0.node)) } }
  package var elements: [Self] { node.elements.map { .init(node: $0) } }

  package subscript(_ key: String) -> Self? {
    node.members.first { $0.key.utf8.elementsEqual(key.utf8) }.map { .init(node: $0.node) }
  }
}

extension NativeDocument {
  package var promptRoot: NativePromptNode { .init(node: root) }

  package func promptNode(at region: NativeRegion) throws -> NativePromptNode? {
    try resolve(region, on: root).map { .init(node: $0) }
  }
}
