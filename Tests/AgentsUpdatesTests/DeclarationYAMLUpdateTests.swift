import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

struct DeclarationYAMLUpdateTests {
  @Test(arguments: [InstallScope.project, .user])
  func createsFirstDeclarationWithExactBytes(_ scope: InstallScope) throws {
    let fixture = try UpdateFixture(scope: scope)
    let yaml = """
      \u{FEFF}# Déclaration
      version: 1  # keep spacing
      defaultAgents: [codex]
      components:
        - kind: mcpServer
          name: documentation
          transport: {kind: stdio, executable: fixture-command}
      """
    let bytes = Data(yaml.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    let request = UpdateRequest(declarationYAML: bytes, expectedDeclarationDigest: "absent")
    let report = try UpdateOperations.preview(
      request, scope: scope, environment: fixture.environment)
    #expect(report.hasChanges)
    #expect(report.components.map(\.name) == ["documentation"])
    #expect(try fixture.store.loadManifest() == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))

    let applied = try UpdateOperations.withPreparedUpdate(
      request, scope: scope, environment: fixture.environment
    ) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    #expect(applied.report.hasChanges)
    #expect(try fixture.bytes(fixture.store.declarationURL) == bytes)
    #expect(FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
    let inspection = try UpdateOperations.inspect(scope: scope, environment: fixture.environment)
    #expect(inspection.deployments.contains { $0.status == .current })
  }

  @Test func commentOnlyEditReportsChangesAndConfirmsExactBytes() throws {
    let fixture = try UpdateFixture()
    let url = fixture.store.declarationURL
    try fixture.store.save(declaration: Declaration(), ledger: ResolvedLedger())
    try fixture.write("version: 1\n# Before\n", to: url)
    let baseline = try #require(try fixture.store.loadManifest())
    let previousLock = try fixture.bytes(fixture.store.resolvedURL)
    let bytes = Data("version: 1\n# After\n".utf8)
    let request = UpdateRequest(declarationYAML: bytes, expectedDeclarationDigest: baseline.digest)
    let report = try UpdateOperations.preview(request, environment: fixture.environment)
    #expect(report.hasChanges)
    #expect(report.components.isEmpty)
    #expect(report.skills.isEmpty)
    #expect(!report.instructions.hasChanges)
    #expect(try fixture.bytes(url) == Data(baseline.bytes))

    let alternate = UpdateRequest(
      declarationYAML: Data("version: 1\n# Another draft\n".utf8),
      expectedDeclarationDigest: baseline.digest)
    let alternateReport = try UpdateOperations.preview(alternate, environment: fixture.environment)
    #expect(alternateReport.displayedFingerprint != report.displayedFingerprint)
    #expect(throws: UpdateApplyError.self) {
      try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
        try $0.apply(ifUnchangedFrom: alternateReport.displayedFingerprint)
      }
    }
    #expect(try fixture.bytes(url) == Data(baseline.bytes))

    _ = try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    #expect(try fixture.bytes(url) == bytes)
    #expect(try fixture.bytes(fixture.store.resolvedURL) == previousLock)
    let updated = try #require(try fixture.store.loadManifest())
    #expect(updated.declaration == baseline.declaration)
    let unchanged = UpdateRequest(declarationYAML: bytes, expectedDeclarationDigest: updated.digest)
    let unchangedReport = try UpdateOperations.preview(unchanged, environment: fixture.environment)
    #expect(!unchangedReport.hasChanges)
  }

  @Test func invalidYAMLIsRejectedBeforePublication() throws {
    let fixture = try UpdateFixture()
    let url = fixture.store.declarationURL
    try fixture.write("version: 1\n", to: url)
    let baseline = try #require(try fixture.store.loadManifest())
    for bytes in [
      Data("version: [\n".utf8),
      Data("version: 1\nwatch: [missing-source]\n".utf8),
      Data([0xFF]),
      Data(repeating: 0x20, count: ManifestLimits.Input.bytes + 1),
    ] {
      let request = UpdateRequest(
        declarationYAML: bytes, expectedDeclarationDigest: baseline.digest)
      #expect(throws: ManifestFailure.self) {
        try UpdateOperations.preview(request, environment: fixture.environment)
      }
      #expect(throws: ManifestFailure.self) {
        try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
          try $0.apply()
        }
      }
    }
    #expect(try fixture.bytes(url) == Data(baseline.bytes))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
  }

  @Test func staleDigestRejectsCommentChangeAfterPreview() throws {
    let fixture = try UpdateFixture()
    let url = fixture.store.declarationURL
    try fixture.write("version: 1\n# Before\n", to: url)
    let baseline = try #require(try fixture.store.loadManifest())
    let request = UpdateRequest(
      declarationYAML: Data("version: 1\n# Draft\n".utf8),
      expectedDeclarationDigest: baseline.digest)
    let report = try UpdateOperations.preview(request, environment: fixture.environment)
    let external = "version: 1\n# External edit\n"
    try fixture.write(external, to: url)
    #expect(throws: CoreError.self) {
      try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
        try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
      }
    }
    #expect(try fixture.bytes(url) == Data(external.utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.resolvedURL.path))
  }

  @Test func absentDigestDoesNotReplaceMissingDeclarationInEstablishedScope() throws {
    let fixture = try UpdateFixture()
    try fixture.store.save(declaration: Declaration(), ledger: ResolvedLedger())
    let previousLock = try fixture.bytes(fixture.store.resolvedURL)
    try FileManager.default.removeItem(at: fixture.store.declarationURL)
    let request = UpdateRequest(
      declarationYAML: Data("version: 1\n".utf8), expectedDeclarationDigest: "absent")
    let error = CoreError.missingDeclaration(fixture.store.declarationURL.path)
    #expect(throws: error) {
      try UpdateOperations.preview(request, environment: fixture.environment)
    }
    #expect(throws: error) {
      try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
        try $0.apply()
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.declarationURL.path))
    #expect(try fixture.bytes(fixture.store.resolvedURL) == previousLock)
  }

  @Test func editedSourcesMustPassSourcePolicy() throws {
    let fixture = try UpdateFixture()
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: fixture.environment)
    try fixture.write("version: 1\ndeny: [local]\n", to: policy)
    let bytes = Data(
      """
      version: 1
      sources: {fixture: {path: ./source}}
      components:
        - {kind: skills, source: fixture, select: [demo], agents: [codex], mode: edit}
      """.utf8)
    let request = UpdateRequest(declarationYAML: bytes, expectedDeclarationDigest: "absent")
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.preview(request, environment: fixture.environment)
    }
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.withPreparedUpdate(request, environment: fixture.environment) {
        try $0.apply()
      }
    }
    #expect(try fixture.store.loadManifest() == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.target().path))
  }
}
