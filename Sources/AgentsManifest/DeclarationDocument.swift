import AgentsCore
import Foundation

/// A fully admitted, schema-checked and domain-valid immutable YAML declaration snapshot.
public struct DeclarationDocument: Sendable {
  public let declaration: DeclarationIR
  public let diagnostics: [ManifestDiagnostic]
  public let sourceMap: DeclarationSourceMap
  public let digest: String
  public var bytes: [UInt8] { source.bytes }
  package let metrics: FrontEndMetrics
  let source: SourceText
  let root: YAMLNode
  let locations: [String: YAMLNode]
  let defaulted: Set<String>
  let comments: [Range<Int>]

  public init(bytes: [UInt8], identity: DocumentIdentity) throws {
    try self.init(bytes: bytes, identity: identity, validateDomain: true)
  }

  /// Private drafts remain parser/schema/budget checked; only the edit composer can construct
  /// them, and it validates the complete final domain before any bytes leave preparation.
  init(
    bytes: [UInt8], identity: DocumentIdentity, validateDomain: Bool,
    observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws {
    source = SourceText(Array(bytes.prefix(ManifestLimits.Input.bytes + 1)), identity: identity)
    let parsed = try YAMLParser.parse(source, observe: observe)
    let validation = YAMLValidation(source: source)
    do { try validation.validate(parsed.root) } catch let failure as ManifestFailure {
      throw ManifestFailure(failure.diagnostics, metrics: parsed.metrics, stage: .decoding)
    }
    observe?(.lowering, parsed.metrics)
    let projection = YAMLProjection(source: source)
    declaration = try projection.declaration(parsed.root)
    try validateIRBudget(IRTree.root(declaration), source: source)
    observe?(.domain, parsed.metrics)
    var diagnostics: [ManifestDiagnostic] = []
    if validateDomain {
      do {
        diagnostics = try YAMLDomainValidation(
          declaration: declaration, source: source, locations: projection.locations
        ).validate()
      } catch let failure as ManifestFailure {
        throw ManifestFailure(failure.diagnostics[0], metrics: parsed.metrics, stage: .domain)
      }
    }
    defaulted = Set(projection.entries.filter(\.defaulted).map(\.pointer))
    comments = parsed.comments
    root = parsed.root
    locations = projection.locations
    sourceMap = DeclarationSourceMap(entries: projection.entries)
    digest = "sha256:" + FileHash.sha256Hex(data: Data(bytes))
    self.diagnostics = diagnostics
    var metrics = parsed.metrics
    metrics.parserCalls = 1
    metrics.syntaxNodes = parsed.nodes
    metrics.syntaxDepth = parsed.depth
    metrics.evaluationSteps = validation.work
    metrics.expandedNodes = IRTree.count(IRTree.root(declaration))
    metrics.decodedBytes = validation.strings
    observe?(.sourceMap, metrics)
    self.metrics = metrics
  }

  /// JSON Pointers address complete semantic IR, including indexed sources, groups and prompts.
  public func node(at pointer: String) -> NodeID? {
    locations[pointer].map { NodeID(digest: digest, pointer: pointer, syntax: $0.range.lowerBound) }
  }

  public func editability(of node: NodeID) -> Editability {
    guard node.digest == digest, locations[node.pointer]?.range.lowerBound == node.syntax else {
      return .readOnly(reason: "stale snapshot handle")
    }
    if node.pointer.hasSuffix("/kind") {
      return .readOnly(reason: "record kind; replace its containing value")
    }
    return .direct
  }

  public func preparing(_ edits: [ManifestEdit]) throws -> DocumentChange {
    try DocumentEditor(document: self).prepare(edits)
  }
}
