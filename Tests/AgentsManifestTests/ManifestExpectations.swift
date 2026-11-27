import Testing

@testable import AgentsManifest

func expectManifestFailure<T>(
  _ code: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ operation: () throws -> T
) {
  do {
    _ = try operation()
    Issue.record("expected diagnostic \(code)", sourceLocation: sourceLocation)
  } catch let failure as ManifestFailure {
    #expect(failure.diagnostics.map(\.code) == [code], sourceLocation: sourceLocation)
  } catch {
    Issue.record(error, sourceLocation: sourceLocation)
  }
}
