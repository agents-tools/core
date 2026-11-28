import AgentsCore

/// Read-only access to the admitted YAML data graph, without canonical manifest validation.
/// Parser limits, duplicate admission and YAML 1.2 scalar identity remain owned by this module.
package struct YAMLReader: Sendable {
  package let root: YAMLNode
  private let source: SourceText

  package init(bytes: [UInt8], identity: DocumentIdentity) throws {
    let source = SourceText(bytes, identity: identity)
    do {
      root = try YAMLParser.parse(source).root
      self.source = source
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as ManifestFailure {
      // Decoder and duplicate-key messages can contain source values. Only coordinates escape.
      throw YAMLReadFailure(span: failure.diagnostics.first?.span ?? source.span(0..<0))
    } catch {
      throw YAMLReadFailure(span: source.span(0..<0))
    }
  }

  package func span(of node: YAMLNode) -> SourceSpan { source.span(node.range) }
}

package struct YAMLReadFailure: Error, Sendable, CustomStringConvertible {
  package let span: SourceSpan
  package var description: String { "YAML input is not admitted." }
}
