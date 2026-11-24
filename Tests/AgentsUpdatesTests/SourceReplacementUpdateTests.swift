import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

struct SourceReplacementUpdateTests {
  @Test func sourceReplacementPreviewApplyAndStaleReadUseCapturedDocument() throws {
    let f = try UpdateFixture()
    try f.store.save(
      declaration: Declaration(
        sources: ["original": .init(kind: .local, location: f.repo.path)], watch: ["original"],
        components: [
          .skills(
            source: "original", .init(select: .names(["demo"]), agents: [.claudeCode], mode: .copy))
        ]), ledger: .init())
    let identity = "local:" + f.repo.path
    let watch = try JSONEncoder().encode(
      WatchState(sources: [identity: .init(seen: .revision(try f.git(["rev-parse", "HEAD"])))]))
    try watch.write(to: f.store.watchURL)
    _ = try f.apply()
    let snapshot = try UpdateOperations.inspect(environment: f.environment)
    let doc = try #require(snapshot.document)
    let source = try #require(doc.node(at: "/sources/0"))
    let request = UpdateRequest(
      operation: .edit([
        .replaceSource(
          source, with: .init(name: "renamed", source: .init(kind: .local, location: f.repo.path)))
      ]), expectedDeclarationDigest: doc.digest)
    let before = try Data(contentsOf: f.store.declarationURL)
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    #expect(try Data(contentsOf: f.store.declarationURL) == before)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      #expect($0.report.displayedFingerprint == preview.displayedFingerprint)
      return try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let cold = try UpdateOperations.inspect(environment: f.environment)
    #expect(cold.deployments.allSatisfy { $0.status == .current })
    let declaration = try f.store.loadDeclaration()
    #expect(declaration.sources["original"] == nil && declaration.sources["renamed"] != nil)
    #expect(declaration.watch == ["renamed"])
    #expect(try Data(contentsOf: f.store.watchURL) == watch)
    #expect(throws: (any Error).self) {
      try UpdateOperations.preview(request, environment: f.environment)
    }
    let refreshed = try #require(cold.document)
    let replacement = try #require(refreshed.node(at: "/sources/0"))
    let nextRequest = UpdateRequest(
      operation: .edit([
        .replaceSource(
          replacement,
          with: .init(name: "final", source: .init(kind: .local, location: f.repo.path)))
      ]), expectedDeclarationDigest: refreshed.digest)
    _ = try UpdateOperations.preview(nextRequest, environment: f.environment)
    let external = Data("# external edit\n".utf8) + Data(refreshed.bytes)
    try external.write(to: f.store.declarationURL)
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(nextRequest, environment: f.environment) { _ in
        Issue.record("Changed source document must reject replacement before publication")
      }
    }
    #expect(try Data(contentsOf: f.store.declarationURL) == external)
  }
}
