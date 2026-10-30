import AgentsCore
import AgentsDescription
import Foundation
import SwiftSyntax

public struct DeclarationDocument: Sendable {
  public let declaration: DeclarationIR
  public let diagnostics: [ManifestDiagnostic]
  public let sourceMap: DeclarationSourceMap
  public let digest: String
  package let metrics: FrontEndMetrics
  public var bytes: [UInt8] { source.bytes }
  let source: SourceText
  let admission: Admission
  let syntax: SourceFileSyntax
  let evaluation: Evaluation
  let locations: [String: NodeID]
  let values: [String: EvaluatedValue]

  public init(bytes: [UInt8], identity: DocumentIdentity) throws {
    try self.init(bytes: bytes, identity: identity, validateDomain: true)
  }

  init(
    bytes: [UInt8], identity: DocumentIdentity, validateDomain: Bool,
    observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws {
    let result = try ManifestFrontEnd.run(
      bytes: bytes, identity: identity, checking: .declaration,
      validateDomain: validateDomain, observe: observe)
    source = result.source
    admission = result.admission
    syntax = result.syntax
    let values = result.declaration!
    evaluation = values.evaluation
    declaration = values.ir
    diagnostics = values.diagnostics
    digest = values.digest
    sourceMap = DeclarationSourceMap(entries: values.map.entries)
    locations = values.map.locations
    self.values = values.map.values
    metrics = result.metrics
  }

  /// A JSON Pointer into the lowered declaration: empty string denotes the root,
  /// arrays use decimal indexes, and object keys escape `~` as `~0` and `/` as `~1`.
  /// Source requirements and literal wrappers use their lowered fields (for example `/value`).
  public func node(at pointer: String) -> NodeID? { locations[pointer] }
  /// Addresses a constant definition by its Swift identifier, without pointer escaping.
  public func constant(named name: String) -> NodeID? {
    locations["/constants/" + pointerEscape(name)]
  }
  /// Returns snapshot handles for all direct and transitive uses of this Swift identifier.
  public func uses(ofConstant name: String) -> [NodeID] {
    var pending = [name]
    var seen = Set<String>()
    var references = Set<Int>()
    while let name = pending.popLast() {
      if !seen.insert(name).inserted { continue }
      for id in evaluation.references[name] ?? [] {
        references.insert(id)
        let offset = admission.nodes[id].range.lowerBound
        if let owner = admission.declarations.first(where: { $0.range.contains(offset) }),
          owner.name != "agents"
        {
          pending.append(owner.name)
        }
      }
    }
    return references.sorted().map {
      NodeID(digest: digest, pointer: "/references/\($0)", syntax: $0)
    }
  }

  /// Agrees with the editor: elements and entries of a direct collection literal and signature
  /// arguments of a direct construction, including omitted ones, are direct, as are member values
  /// such as `.copy`. References, concatenations, normalized fields such as source requirements
  /// and component kinds, and everything inside a read-only value are read-only.
  public func editability(of node: NodeID) -> Editability {
    guard node.digest == digest, values[node.pointer]?.syntax == node.syntax else {
      return .readOnly(reason: "stale snapshot handle")
    }
    if node.pointer.hasPrefix("/constants/") {
      let name = pointerUnescape(String(node.pointer.dropFirst("/constants/".count)))
      return .sharedConstant(uses: uses(ofConstant: name))
    }
    return editability(at: node.pointer)
  }

  private func editability(at pointer: String) -> Editability {
    guard let value = values[pointer] else {
      return .readOnly(reason: "stale snapshot handle")
    }
    // Containing values are checked by the recursion below, so each entry costs its depth.
    if value.referent != nil {
      return .readOnly(
        reason: "shared constant or assembled value; replace its definition explicitly")
    }
    if admission.nodes[value.syntax].kind == .sequence {
      return .readOnly(reason: "concatenated value has no independent source range")
    }
    guard let slash = pointer.lastIndex(of: "/") else { return .direct }
    let parent = String(pointer[..<slash])
    let field = pointerUnescape(String(pointer[pointer.index(after: slash)...]))
    let containing = editability(at: parent)
    guard containing == .direct, let owner = values[parent] else { return containing }
    let syntax = admission.nodes[owner.syntax]
    let editable: Bool
    switch syntax.kind {
    case .array, .dictionary:
      // A literal configuration collection holds its elements or entries in `value`.
      editable =
        (syntax.kind == .array ? Int(field) != nil : syntax.keys.contains { $0.decoded == field })
        || field == "value" && owner.type.unwrapped == .named("ConfigurationValue")
    case .call:
      guard case .named(let type) = owner.type.unwrapped else {
        editable = false
        break
      }
      editable = Vocabulary.signatures.contains { signature in
        signature.type == type && signature.member == owner.value.member
          && signature.parameters.contains { $0.name == field }
      }
    default: editable = false
    }
    return editable
      ? .direct : .readOnly(reason: "normalized field; replace its containing construction")
  }

  func hasAssembledAncestor(_ pointer: String) -> Bool {
    var prefix = pointer
    while let slash = prefix.lastIndex(of: "/"), slash != prefix.startIndex {
      prefix = String(prefix[..<slash])
      if let parent = values[prefix],
        parent.referent != nil || admission.nodes[parent.syntax].kind == .sequence
      {
        return true
      }
    }
    return false
  }

  public func preparing(_ edits: [ManifestEdit]) throws -> DocumentChange {
    try DocumentEditor(document: self).prepare(edits)
  }

  package func preparing(operations: [DocumentOperation]) throws -> DocumentChange {
    try DocumentEditor(document: self).prepare(operations: operations)
  }
}
