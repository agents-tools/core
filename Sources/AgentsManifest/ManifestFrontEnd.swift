import AgentsCore

package enum FrontEndStage: String, Sendable, Codable {
  case admission, parser, decoding, domain, lowering, sourceMap, teardown
}
package enum FrontEndCheck: Sendable, Equatable { case syntax, declaration }
package enum ManifestFrontEnd {
  package static func inspect(
    bytes: [UInt8], identity: DocumentIdentity, checking: FrontEndCheck,
    observe: ((FrontEndStage, FrontEndMetrics) -> Void)? = nil
  ) throws -> FrontEndMetrics {
    observe?(.admission, FrontEndMetrics())
    let document = try DeclarationDocument(
      bytes: bytes, identity: identity, validateDomain: checking == .declaration, observe: observe)
    observe?(.teardown, document.metrics)
    return document.metrics
  }
}
