import Foundation

/// Declaration source bytes that the declaration format planned and verified for one prepared
/// generation. Core publishes them without reading the format.
package struct DeclarationChange: Sendable {
  package let bytes: Data

  package init(bytes: Data) {
    self.bytes = bytes
  }
}

/// Reads and plans declarations through the module that owns the declaration format.
package struct DeclarationAccess: Sendable {
  /// Reads the declaration, from the prepared generation when one is supplied.
  package typealias Read = @Sendable (StateStore, StatePrecondition?) throws -> Declaration
  /// Plans `next` against the prepared document that `previous` was read from; nil leaves the
  /// declaration unchanged.
  package typealias Plan =
    @Sendable (StateStore, _ previous: Declaration, _ next: Declaration, StatePrecondition)
    throws -> DeclarationChange?

  package let read: Read
  package let plan: Plan

  package init(read: @escaping Read, plan: @escaping Plan) {
    self.read = read
    self.plan = plan
  }
}
