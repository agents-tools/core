import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

extension FullDeclarationTests {
  @Test(arguments: [false, true])
  func flatSourceTransitionsComposeWithoutOtherComponents(_ rename: Bool) throws {
    let body =
      "version: 1\nsources: {s: {path: missing}}\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
    let target =
      rename
      ? body.replacingOccurrences(of: "{s:", with: "{t:").replacingOccurrences(
        of: "source: s", with: "source: t")
      : body.replacingOccurrences(
        of: "path: missing", with: "url: https://example.invalid/repo.git"
      ).replacingOccurrences(of: "mode: edit", with: "mode: copy")
    let previous = try projected(body)
    let next = try projected(target)
    let bytes = try #require(try planned(previous, next, in: body))
    let result = try projected(String(decoding: bytes, as: UTF8.self))
    #expect(ManifestProjection.equivalent(result, next, environment: projectionEnvironment))
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }

  @Test func aliasRenameComposesRootAndUnusedGroupResourceReferencesAcrossBatches() throws {
    let components = (0..<101).map {
      "      - {kind: subagent, name: a\($0), description: d, prompt: {file: {path: x.md, source: s}}}"
    }.joined(separator: "\n")
    let body = """
      # Keep this header.
      version: 1
      sources: {s: {path: missing}}
      components:
        - {kind: instructions, sections: [{name: guide, source: s}]}
        - {kind: plugin, name: bundle, path: plugins/bundle, source: s}
        - {kind: hook, name: run, event: sessionStart, run: {executable: tool, workingDirectory: {path: dir, source: s}}}
      groups:
        unused:
          components:
      \(components)
          uses: [{group: remote, source: s}]
      # Keep this tail.
      """
    let next = try projected(
      body.replacingOccurrences(of: "{s:", with: "{t:").replacingOccurrences(
        of: "source: s", with: "source: t"))
    let bytes = try #require(try planned(try projected(body), next, in: body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.hasPrefix("# Keep this header.\n"))
    #expect(output.hasSuffix("# Keep this tail."))
    #expect(try projected(output) == next)
  }

  @Test func draftBatchesRejectExpectedIRMismatchAndRetainTheirLimits() throws {
    let doc = try document(
      "version: 1\ncomponents: [{kind: ignore, name: i, patterns: [], native: {schema: {key: text}}}]\n"
    )
    expectManifestFailure("manifest.edit.mismatch") {
      // Integer YAML cannot represent an integer payload inside a string-kind IR record.
      try DocumentEditor.draft(
        [.set("/components/0/native/schema/key/value", .integer(1))], in: doc)
    }
    expectManifestFailure("manifest.limit") {
      try DocumentEditor.draft(Array(repeating: .set("/watch", .array([])), count: 101), in: doc)
    }
    expectManifestFailure("manifest.limit") {
      try doc.preparing(Array(repeating: .setWatch([]), count: 101))
    }
  }

  @Test func publicPreparedChangesValidateDraftDomainEvenForNoOps() throws {
    let doc = try document(
      "version: 1\nsources: {s: {path: missing}}\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
    )
    let source = YAMLConstruction.source(
      NamedSourceDeclaration(
        name: "s",
        source: SourceDeclaration(kind: .git, location: "https://example.invalid/repo.git")))
    let draft = try DocumentEditor.draft([.set("/sources/0", .record(source))], in: doc).document
    expectManifestFailure("manifest.domain") { try draft.preparing([]) }
    expectManifestFailure("manifest.domain") { try draft.preparing([.setWatch([])]) }
    #expect(
      doc.bytes
        == Array(
          "version: 1\nsources: {s: {path: missing}}\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
            .utf8))
  }

  @Test func compositionRejectsNoProgressAndExcessOperationWork() throws {
    let doc = try document("version: 1\n")
    let next = Declaration(agents: [.codex])
    let intended = IRTree.root(YAMLConstruction.root(next))
    expectManifestFailure("manifest.edit.mismatch") {
      try DeclarationEditPlan.compose(
        [.set("/watch", .array([]))], original: doc, intended: intended, next: next,
        environment: projectionEnvironment)
    }
    expectManifestFailure("manifest.limit") {
      try DeclarationEditPlan.compose(
        Array(repeating: .set("/defaultAgents", .array([.string("codex")])), count: 100),
        original: doc, intended: intended, next: next, environment: projectionEnvironment)
    }
  }

  @Test func duplicateSourceAliasesCannotBeAdmittedAsDrafts() throws {
    let doc = try document("version: 1\n")
    let source = YAMLConstruction.source(
      NamedSourceDeclaration(name: "s", source: SourceDeclaration(kind: .local, location: "s")))
    #expect(throws: ManifestFailure.self) {
      try DocumentEditor.draft(
        [.set("/sources", .array([.record(source), .record(source)]))], in: doc)
    }
  }

  @Test func composedFinalProjectionPerformsEnvironmentValidation() throws {
    let doc = try document(
      "version: 1\nsources: {a: {path: '~/rules'}, b: {path: /work/home/rules}}\n")
    let next = try ManifestProjection.draftDeclaration(of: doc, environment: projectionEnvironment)
    #expect(throws: CoreError.self) { try planned(Declaration(), next, in: "version: 1\n") }
  }
}
