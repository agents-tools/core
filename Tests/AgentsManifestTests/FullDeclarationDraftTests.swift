import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

extension FullDeclarationTests {
  @Test(arguments: [false, true])
  func flatSourceTransitionsComposeWithoutOtherComponents(_ rename: Bool) throws {
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "missing")], components: [
        .skills(source: "s", mode: .edit),
      ])
      """
    let target =
      rename
      ? body.replacingOccurrences(of: #""s""#, with: #""t""#)
      : body.replacingOccurrences(
        of: #"path: "missing""#, with: #"url: "https://example.invalid/repo.git""#
      ).replacingOccurrences(of: "mode: .edit", with: "mode: .copy")
    let previous = try projected(body)
    let next = try projected(target)
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(ManifestProjection.equivalent(result, next, environment: projectionEnvironment))
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }

  @Test func aliasRenameComposesRootAndUnusedGroupResourceReferencesAcrossBatches() throws {
    let components = (0..<101).map {
      #"        .subagent(name: "a\#($0)", description: "d", prompt: .file("x.md", source: "s"))"#
    }.joined(separator: ",\n")
    let body = """
      // Keep this header.
      let agents = Agents(
        sources: [.source(name: "s", path: "missing")],
        components: [
          .instructions(sections: [.section(name: "guide", source: "s")]),
          .plugin(name: "bundle", path: "plugins/bundle", source: "s"),
          .hook(name: "run", event: .sessionStart,
            run: .executable("tool", workingDirectory: .path("dir", source: "s"))),
        ],
        groups: [
          .group(
            name: "unused",
            components: [
      \(components)
            ],
            uses: [.group(name: "remote", source: "s")]
          ),
        ]
      )
      // Keep this tail.
      """
    let next = try projected(body.replacingOccurrences(of: #""s""#, with: #""t""#))
    let bytes = try #require(try planned(try projected(body), next, in: manifestHeader + body))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.hasPrefix(manifestHeader + "// Keep this header.\n"))
    #expect(output.hasSuffix("// Keep this tail."))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result == next)
  }

  @Test func draftBatchesRejectExpectedIRMismatchAndRetainTheirLimits() throws {
    let doc = try document("let agents = Agents()")
    for operations: [DocumentOperation] in [
      [], [.edit(.insertComponent(.instructions(), into: .root, at: .last))],
    ] {
      let editor = DocumentEditor(document: doc)
      editor.expected = Agents(defaultAgents: [.codex]).constructionValue
      expectManifestFailure("manifest.edit.mismatch") {
        try editor.prepareDraft(operations: operations)
      }
    }
    expectManifestFailure("manifest.limit") {
      try DocumentEditor(document: doc).prepareDraft(
        operations: Array(repeating: .edit(.setWatch([])), count: 101))
    }
    let exhausted = DocumentEditor(document: doc)
    exhausted.steps = ManifestLimits.Editing.steps
    expectManifestFailure("manifest.limit") { try exhausted.prepareDraft(operations: []) }
  }

  @Test func publicPreparedChangesValidateDraftDomainEvenForNoOps() throws {
    let doc = try document(
      "let agents = Agents(sources: [.source(name: \"s\", path: \"missing\")], components: [.skills(source: \"s\", mode: .edit)])"
    )
    let draft = try DocumentEditor(document: doc).prepareDraft(operations: [
      .edit(.upsertSource(.source(name: "s", url: "https://example.invalid/repo.git")))
    ])
    expectManifestFailure("manifest.domain") {
      try DeclarationDocument(bytes: draft.document.bytes, identity: DocumentIdentity("manifest"))
    }
    expectManifestFailure("manifest.domain") { try draft.document.preparing([]) }
    expectManifestFailure("manifest.domain") { try draft.document.preparing(operations: []) }
    #expect(throws: CoreError.self) {
      try ManifestProjection.declaration(of: draft.document, environment: projectionEnvironment)
    }
  }

  @Test func compositionRejectsNoProgressAndExcessOperationWork() throws {
    let doc = try document("let agents = Agents()")
    let next = Declaration(agents: [.codex])
    expectManifestFailure("manifest.edit.mismatch") {
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: next, in: doc.bytes,
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: { _ in [.edit(.setWatch([]))] })
    }
    expectManifestFailure("manifest.limit") {
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: next, in: doc.bytes,
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: { _ in Array(repeating: .edit(.setDefaultAgents([.codex])), count: 100) })
    }
  }

  @Test func draftReplanningDiagnosesDuplicateSourceAliases() throws {
    let doc = try document("let agents = Agents()")
    let root = try #require(doc.node(at: ""))
    let next = Declaration(sources: ["s": SourceDeclaration(kind: .local, location: "s")])
    var injected = false
    expectManifestFailure("manifest.ambiguous") {
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: next, in: doc.bytes,
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: { operations in
          if injected { return operations }
          injected = true
          return [
            .setArgument(
              root, field: "sources",
              value: .array([
                Source.source(name: "s", path: "s").constructionValue,
                Source.source(name: "s", path: "t").constructionValue,
              ]))
          ]
        })
    }
  }

  @Test func composedFinalProjectionPerformsEnvironmentValidation() throws {
    let doc = try document(
      "let agents = Agents(sources: [.source(name: \"a\", path: \"~/rules\"), .source(name: \"b\", path: \"/work/home/rules\")])"
    )
    let next = try ManifestProjection.draftDeclaration(of: doc, environment: projectionEnvironment)
    #expect(throws: CoreError.self) {
      try planned(Declaration(), next, in: manifestHeader + "let agents = Agents()")
    }
  }
}
