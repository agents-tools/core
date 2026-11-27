import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

private let yamlEnvironment = RuntimeEnvironment(
  projectDirectory: URL(fileURLWithPath: "/work/project", isDirectory: true),
  homeDirectory: URL(fileURLWithPath: "/work/home", isDirectory: true), environment: [:])
private let yamlIdentity = DocumentIdentity("agents.yaml")

private func yamlDocument(_ text: String) throws -> DeclarationDocument {
  try DeclarationDocument(bytes: Array(text.utf8), identity: yamlIdentity)
}

private func yamlProjection(_ text: String) throws -> Declaration {
  try ManifestProjection.declaration(of: yamlDocument(text), environment: yamlEnvironment)
}

private func yamlPlan(_ before: Declaration, _ after: Declaration, _ text: String?) throws
  -> [UInt8]?
{
  try DeclarationEditPlan.bytes(
    replacing: before, with: after, in: text.map { Array($0.utf8) },
    identity: yamlIdentity, environment: yamlEnvironment)
}

private func assertYAMLEdit(
  _ input: String, _ target: Declaration, preserving segments: [String],
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> String {
  let before = try yamlProjection(input)
  let bytes = try #require(try yamlPlan(before, target, input), sourceLocation: sourceLocation)
  let output = String(decoding: bytes, as: UTF8.self)
  let actual = try yamlProjection(output)
  #expect(actual == target, sourceLocation: sourceLocation)
  for segment in segments {
    #expect(
      output.contains(segment), "missing unchanged bytes: \(segment)",
      sourceLocation: sourceLocation)
  }
  #expect(try yamlPlan(actual, target, output) == nil, sourceLocation: sourceLocation)
  return output
}

@Suite("Independent YAML acceptance")
struct IndependentYAMLAcceptanceTests {
  @Test func nativeValuesRoundTripWithoutLosingNumericIdentity() throws {
    let values: [NativeValue] = [
      .integer(1), .decimal("1"), .decimal("9223372036854775808"), .decimal("-0"),
      .decimal("1.00"), .decimal("1E+003"), .decimal("1.2345678901234567890123456789"),
      .string("1"), .string("true"), .boolean(true), .null,
    ]
    let desired = Declaration(components: [
      .lspServer(
        name: "server", run: ExecutableDeclaration(executable: "missing-program"),
        languages: [".swift": "swift"],
        initializationOptions: ["nested": .array(values), "<<": .object(["text": .string("1")])],
        native: ["example/lsp@1": ["values": .object(["nested": .array(values)])]]),
      .ignore(name: "second", patterns: ["private/**"]),
    ])
    let bytes = try #require(try yamlPlan(Declaration(), desired, nil))
    let text = String(decoding: bytes, as: UTF8.self)
    let actual = try yamlProjection(text)
    #expect(actual == desired)
    guard case .lspServer(_, _, let languages, let options, _, _, let native) = actual.components[0]
    else {
      Issue.record("expected LSP component")
      return
    }
    #expect(languages == [".swift": "swift"])
    #expect(options["nested"] == .array(values))
    #expect(options["<<"] == .object(["text": .string("1")]))
    #expect(native["example/lsp@1"]?["values"] == .object(["nested": .array(values)]))
    #expect(actual.components[1] == .ignore(name: "second", patterns: ["private/**"]))
    #expect(try yamlPlan(actual, desired, text) == nil)
  }

  @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}"])
  func rawLineSeparatorsAreRejectedAtTheirOriginalBytes(_ character: String) throws {
    let templates = [
      "version: 1\ncomponents:\n  - {kind: subagent, name: a, description: \"left@right\", prompt: ok}\n",
      "version: 1\ncomponents:\n  - {kind: subagent, name: a, description: 'left@right', prompt: ok}\n",
      "version: 1\ncomponents:\n  - {kind: subagent, name: a, description: left@right, prompt: ok}\n",
      "version: 1\ncomponents:\n  - kind: subagent\n    name: a\n    description: |-\n      left@right\n    prompt: ok\n",
      "version: 1\n# left@right\n",
    ]
    for template in templates {
      let input = template.replacingOccurrences(of: "@", with: character)
      let prefix = try #require(input.range(of: character)).lowerBound
      let start = input[..<prefix].utf8.count
      do {
        _ = try yamlDocument(input)
        Issue.record("raw separator accepted")
      } catch let failure as ManifestFailure {
        let span = try #require(failure.diagnostics.first?.span)
        #expect(span.start == start)
        #expect(span.end == start + character.utf8.count)
      }
    }
  }

  @Test func escapedSeparatorsAndOrdinaryUnicodeRemainExact() throws {
    let input = #"""
      version: 1
      components:
        - kind: subagent
          name: unicode
          description: "你好 😀 left\u0085right"
          prompt: "first\u2028second\u2029third"
      """#
    let declaration = try yamlProjection(input)
    #expect(
      declaration.components == [
        .subagent(
          name: "unicode", description: "你好 😀 left\u{0085}right",
          prompt: .literal("first\u{2028}second\u{2029}third"))
      ])
  }

  @Test func writerEscapesRestrictedSourceCharactersWithoutChangingValues() throws {
    let value = "one\u{0085}two\u{2028}three\u{2029}四"
    let target = Declaration(components: [
      .subagent(name: "unicode", description: value, prompt: .literal(value))
    ])
    let bytes = try #require(try yamlPlan(Declaration(), target, nil))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("\u{0085}"))
    #expect(!text.contains("\u{2028}"))
    #expect(!text.contains("\u{2029}"))
    #expect(text.contains(#"\u0085"#))
    #expect(text.contains(#"\u2028"#))
    #expect(text.contains(#"\u2029"#))
    #expect(try yamlProjection(text) == target)
  }

  @Test func bomCRLFAndUnicodeDoNotShiftFollowingDiagnostic() throws {
    let prefix =
      "\u{FEFF}version: 1\r\n# 😀 é\r\ncomponents:\r\n  - kind: subagent\r\n    name: a\r\n    description: \"😀 \\u2028\"\r\n    prompt: ok\r\n    unknownField: "
    let input = prefix + "value\r\n"
    do {
      _ = try yamlDocument(input)
      Issue.record("unknown field accepted")
    } catch let failure as ManifestFailure {
      let span = try #require(failure.diagnostics.first?.span)
      let linePrefix = "    "
      let start = prefix.utf8.count - "unknownField: ".utf8.count
      #expect(span.start == start)
      #expect(span.line == 8)
      #expect(span.column == linePrefix.utf8.count + 1)
    }
  }

  @Test func explicitFloatIsLimitedToNativeValuesAndPreservesPayload() throws {
    let input = #"""
      version: 1
      components:
        - kind: lspServer
          name: lsp
          run: {executable: missing}
          languages: {".swift": swift}
          initializationOptions:
            values: [1, !!float "1", !!float "9223372036854775808", !!float '-0', !!float 1.00, !!float "1E+003", "1"]
            <<: {enabled: true}
      """#
    let declaration = try yamlProjection(input)
    guard case .lspServer(_, _, _, let options, _, _, _) = declaration.components[0] else {
      Issue.record("expected LSP component")
      return
    }
    #expect(
      options["values"]
        == .array([
          .integer(1), .decimal("1"), .decimal("9223372036854775808"), .decimal("-0"),
          .decimal("1.00"), .decimal("1E+003"), .string("1"),
        ]))
    #expect(options["<<"] == .object(["enabled": .boolean(true)]))
  }

  @Test(arguments: [
    "components: [{kind: hook, name: h, event: sessionStart, run: {executable: missing}, timeoutSeconds: !!float \"1\"}]",
    "components: [{kind: hook, name: h, event: sessionStart, run: {executable: missing}, timeoutSeconds: 1.0}]",
    "components: [{kind: ignore, name: !!float \"1\", patterns: []}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {!!float \"1\": x}}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: !!float [1]}}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: !custom value}}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: !!str value}}]",
    "components: [{kind: ignore, name: a, patterns: [], native: !!float \"1\"}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: !!float .inf}}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: .nan}}]",
    "components: [{kind: lspServer, name: l, run: {executable: missing}, languages: {}, initializationOptions: {x: 9223372036854775808}}]",
  ])
  func rejectsInvalidTagAndScalarContexts(_ fields: String) throws {
    #expect(throws: ManifestFailure.self) { try yamlDocument("version: 1\n" + fields + "\n") }
  }

  @Test func symbolicIntentAndIndexedSourceMapSurviveKeyedMappings() throws {
    let input = """
      version: 1
      sources:
        zeta: {path: ./does-not-exist-z}
        alpha: {path: ./does-not-exist-a}
      components:
        - kind: instructions
          sections:
            - {source: alpha, name: guide, condition: {agents: [codex]}}
        - kind: mcpServer
          name: never-run
          condition: {agents: []}
          transport:
            kind: stdio
            executable: nonexistent-marker-program
            environment: {TOKEN: {secret: token}}
      groups:
        unused:
          components:
            - {kind: ignore, name: private, patterns: ["secret/**"], condition: {platforms: []}}
        later: {}
      uses: [{group: later}]
      exports: [unused]
      """
    let doc = try yamlDocument(input)
    let declaration = try ManifestProjection.declaration(of: doc, environment: yamlEnvironment)
    #expect(declaration.sourceDeclarations.map(\.name) == ["zeta", "alpha"])
    #expect(declaration.groups.map(\.name) == ["unused", "later"])
    #expect(declaration.uses == [GroupUseDeclaration(name: "later")])
    #expect(declaration.exports == ["unused"])
    guard case .instructions(let instructions) = declaration.components[0],
      case .mcpServer(_, let transport, _, let condition, _, _) = declaration.components[1]
    else {
      Issue.record("unexpected component payload")
      return
    }
    #expect(
      instructions.sectionReferences == [
        SectionDeclaration(
          name: "guide", source: "alpha", condition: DeclarationCondition(agents: [.codex]))
      ])
    #expect(condition == DeclarationCondition(agents: []))
    #expect(
      transport
        == .stdio(
          ExecutableDeclaration(
            executable: "nonexistent-marker-program", environment: ["TOKEN": .secret("token")]))
    )
    #expect(
      declaration.groups[0].components == [
        .ignore(
          name: "private", patterns: ["secret/**"], condition: DeclarationCondition(platforms: []))
      ])
    for (pointer, spelling) in [
      ("/sources/0/name", "zeta"), ("/sources/1/name", "alpha"),
      ("/groups/0/name", "unused"), ("/groups/1/name", "later"),
    ] {
      let entry = try #require(doc.sourceMap.locations(at: pointer).first)
      #expect(
        String(decoding: doc.bytes[entry.span.start..<entry.span.end], as: UTF8.self) == spelling)
    }
    let groupComponents = try #require(doc.sourceMap.locations(at: "/groups/0/components").first)
    #expect(
      String(
        decoding: doc.bytes[groupComponents.span.start..<groupComponents.span.end], as: UTF8.self
      ).contains("private"))
  }

  @Test func blockScalarFieldEditPreservesUnrelatedBytes() throws {
    let input = """
      # Header stays.
      version: 1
      components:
        - kind: command
          name: explain
          description: Keep this description.
          prompt: |- # prompt header
            Keep this block.
        - kind: ignore
          name: private
          patterns: [old]
      # Tail stays.
      """
    var target = try yamlProjection(input)
    target.components[1] = .ignore(name: "private", patterns: ["new"])
    let output = try assertYAMLEdit(
      input, target,
      preserving: [
        "# Header stays.\nversion: 1\n",
        "    prompt: |- # prompt header\n      Keep this block.\n",
        "\n# Tail stays.",
      ])
    let scalar = try #require(input.range(of: "old"))
    let prefix = String(input[..<scalar.lowerBound])
    let suffix = String(input[scalar.upperBound...])
    #expect(output.hasPrefix(prefix))
    #expect(output.hasSuffix(suffix))
    #expect(output.utf8.count >= prefix.utf8.count + suffix.utf8.count)
  }

  @Test func flowFieldEditRetainsNeighboringComments() throws {
    let input = """
      # Heading
      version: 1
      components: [ {kind: ignore, name: first, patterns: [old]}, {kind: ignore, name: second, patterns: [keep]} ] # components
      # Footer
      """
    var target = try yamlProjection(input)
    target.components[0] = .ignore(name: "first", patterns: ["new"])
    let output = try assertYAMLEdit(
      input, target,
      preserving: [
        "# Heading\nversion: 1\n", "{kind: ignore, name: second, patterns: [keep]} ] # components",
        "\n# Footer",
      ])
    let scalar = try #require(input.range(of: "old"))
    let prefix = String(input[..<scalar.lowerBound])
    let suffix = String(input[scalar.upperBound...])
    #expect(output.hasPrefix(prefix))
    #expect(output.hasSuffix(suffix))
    #expect(output.utf8.count >= prefix.utf8.count + suffix.utf8.count)
  }

  @Test func insertingIntoEmptyComponentsKeepsSurroundingSections() throws {
    let input = """
      # Header
      version: 1
      components: [] # empty components
      groups:
        unused: {}
      # Tail
      """
    var target = try yamlProjection(input)
    target.components = [.ignore(name: "new", patterns: ["private/**"])]
    _ = try assertYAMLEdit(
      input, target,
      preserving: [
        "# Header\nversion: 1\n", "# empty components", "groups:\n  unused: {}\n# Tail",
      ])
  }

  @Test func deletingComponentKeepsItsCommentAndUnrelatedSections() throws {
    let input = """
      # Header
      version: 1
      components:
        # Retain this note.
        - {kind: ignore, name: remove, patterns: [old]}
        # Kept item.
        - {kind: ignore, name: keep, patterns: [keep]}
      groups:
        unused: {}
      # Tail
      """
    var target = try yamlProjection(input)
    target.components.removeFirst()
    _ = try assertYAMLEdit(
      input, target,
      preserving: [
        "# Header\nversion: 1\n", "# Retain this note.",
        "# Kept item.\n  - {kind: ignore, name: keep, patterns: [keep]}",
        "groups:\n  unused: {}\n# Tail",
      ])
  }

  @Test func movingBlockComponentsCarriesUniquelyOwnedComments() throws {
    let input = """
      # Header
      version: 1
      components:
        # First item.
        - {kind: ignore, name: first, patterns: [one]} # first tail
        # Second item.
        - {kind: ignore, name: second, patterns: [two]} # second tail
      groups:
        unused: {}
      # Tail
      """
    var target = try yamlProjection(input)
    target.components.reverse()
    let output = try assertYAMLEdit(
      input, target,
      preserving: [
        "# Header\nversion: 1\n", "groups:\n  unused: {}\n# Tail",
        "# First item.\n  - {kind: ignore, name: first, patterns: [one]} # first tail",
        "# Second item.\n  - {kind: ignore, name: second, patterns: [two]} # second tail",
      ])
    let first = try #require(output.range(of: "# First item."))
    let second = try #require(output.range(of: "# Second item."))
    #expect(second.lowerBound < first.lowerBound)
  }

  @Test func flowComponentsSupportInsertionDeletionAndMove() throws {
    let input = """
      # Flow header
      version: 1
      components: [{kind: ignore, name: first, patterns: [one]}, {kind: ignore, name: second, patterns: [two]}] # flow items
      groups: {unused: {}}
      # Flow tail
      """
    let kept = ["# Flow header\nversion: 1\n", "# flow items", "groups: {unused: {}}\n# Flow tail"]
    var target = try yamlProjection(input)
    target.components.insert(.ignore(name: "middle", patterns: ["three"]), at: 1)
    let inserted = try assertYAMLEdit(input, target, preserving: kept)
    target.components.removeFirst()
    let deleted = try assertYAMLEdit(inserted, target, preserving: kept)
    target.components.reverse()
    _ = try assertYAMLEdit(deleted, target, preserving: kept)
  }

  @Test func semanticNoOpPreservesBOMCRLFAndOmittedWatchBytes() throws {
    let input = "\u{FEFF}# heading\r\nversion: 1\r\ncomponents: [] # untouched\r\n"
    let previous = try yamlProjection(input)
    var target = previous
    target.watch = []
    #expect(try yamlPlan(previous, target, input) == nil)
    #expect(try yamlDocument(input).bytes == Array(input.utf8))
  }

  @Test func inputByteLimitIncludesExactBoundary() throws {
    let prefix = "version: 1\n#"
    let limit = 2_097_152
    let boundary = prefix + String(repeating: "x", count: limit - prefix.utf8.count)
    #expect(boundary.utf8.count == limit)
    #expect(try yamlProjection(boundary) == Declaration())
    #expect(throws: ManifestFailure.self) { try yamlDocument(boundary + "x") }
  }
}
