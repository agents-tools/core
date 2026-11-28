import AgentsCore
import AgentsManifest
import Foundation

/// A single editable scope policy captured when the editor opened.
public struct SourcePolicyEditor: Sendable {
  public let url: URL
  public let original: Data?
  private let scope: InstallScope
  private let environment: RuntimeEnvironment
  private let projectRoot: ExistingProjectRoot?

  public init(scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()) throws {
    self.scope = scope
    self.environment = environment
    let store = StateStore(scope: scope, environment: environment)
    projectRoot = scope == .project ? try store.captureExistingProjectRoot() : nil
    let location = SourcePolicyOperations.policyURL(scope: scope, environment: environment)
    url = location
    original = try store.withReadLock { try TargetPrecondition.readingFile(location).bytes }
  }

  /// Parses the exact proposed bytes, then publishes only if the displayed policy still matches.
  public func save(_ bytes: Data) throws {
    _ = try SourcePolicyDocument.parse(bytes, identity: DocumentIdentity(url.path))
    if let managed = environment.organizationSourcePolicyURL,
      managed.resolvingSymlinksInPath().standardizedFileURL
        == url.resolvingSymlinksInPath().standardizedFileURL
    {
      throw CoreError.invalidState("this policy is managed by the organization")
    }
    let store = StateStore(scope: scope, environment: environment)
    try store.withLock(existingRoot: projectRoot) {
      let observed = try TargetPrecondition.readingFile(url)
      guard observed.bytes == original else {
        throw CoreError.invalidState("the source policy changed; reopen it before saving")
      }
      guard observed.bytes != bytes else { return }
      let transaction = FileTransaction(store: store)
      try transaction.replace(url, with: .data(bytes), expecting: observed.evidence)
      try transaction.commit()
    }
  }
}
