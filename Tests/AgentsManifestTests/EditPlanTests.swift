import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

func planned(_ previous: Declaration, _ next: Declaration, in text: String?) throws -> [UInt8]? {
  try DeclarationEditPlan.bytes(
    replacing: previous, with: next, in: text.map { Array($0.utf8) },
    identity: DocumentIdentity("manifest"), environment: projectionEnvironment)
}

@Suite("Declaration edit planning")
struct EditPlanTests {
  @Test func equivalentSpellingsAndWatchOrderPreserveEveryByte() throws {
    let body = """
      # header
      version: 1
      defaultAgents: [codex, claude-code]
      sources:
        g: {url: https://github.com/team/skills, requirement: {from: "1.2.0", to: "2.0.0"}}
        l: {path: ./rules/, subpath: ./skills} # retained
      components: [{kind: skills, source: g, select: [b, a], exclude: []}]
      watch: [l, g]
      """
    let previous = try projected(body)
    var next = previous
    next.agents = [.claudeCode, .codex]
    next.sources["g"] = SourceDeclaration(
      kind: .git, location: "https://GitHub.com/team/skills.git",
      requirement: .upToNextMajor(from: "1.2.0"))
    next.sources["l"] = SourceDeclaration(
      kind: .local, location: "/work/project/rules", path: "skills")
    try next.updateSkills { $0?["g"] = SkillDeclaration(select: .names(["a", "b"])) }
    next.watch = ["g", "l"]
    #expect(try planned(previous, next, in: body) == nil)
    #expect(try planned(Declaration(), Declaration(), in: nil) == nil)
  }
  @Test func defaultRecipientsCanBeInsertedReplacedAndOmitted() throws {
    var previous = try projected("version: 1\n")
    var bytes = Array("version: 1\n".utf8)
    for recipients: [AgentID]? in [[], [.codex, .claudeCode], nil] {
      var next = previous
      next.agents = recipients
      bytes = try #require(try planned(previous, next, in: String(decoding: bytes, as: UTF8.self)))
      #expect(try projected(String(decoding: bytes, as: UTF8.self)).agents == recipients)
      previous = next
    }
  }
  @Test func missingCollectionsAndLastElementRemovalKeepValidDocuments() throws {
    let doc = try document("# header\r\nversion: 1\r\n")
    let added = try doc.preparing([
      .insertComponent(
        .instructions(InstructionsDeclaration(sections: ["guide"])), into: .root, at: .last)
    ])
    let populated = try DeclarationDocument(
      bytes: added.bytes, identity: DocumentIdentity("manifest"))
    let removed = try populated.preparing([
      .removeComponent(#require(populated.node(at: "/components/0")))
    ])
    #expect(
      try DeclarationDocument(bytes: removed.bytes, identity: DocumentIdentity("manifest"))
        .declaration.components.isEmpty)
    #expect(String(decoding: removed.bytes, as: UTF8.self).hasPrefix("# header\r\n"))
  }
  @Test func preparationRejectsOversizedIntentBeforeRendering() throws {
    let doc = try document("version: 1\n")
    expectManifestFailure("manifest.limit") {
      try doc.preparing([
        .insertComponent(
          .ignore(name: "large", patterns: [String(repeating: "x", count: 20_000_000)]),
          into: .root, at: .first)
      ])
    }
  }
}

extension EditPlanTests {
  @Test func blockAndFlowMovesCarryCommentsAcrossContainers() throws {
    let doc = try document(
      """
      version: 1
      components:
        # owned entry
        - kind: ignore
          name: moving
          patterns: [] # owned tail
      groups:
        target:
          components:
            - {kind: ignore, name: existing, patterns: []}
      """)
    let change = try doc.preparing([
      .moveComponent(
        #require(doc.node(at: "/components/0")), into: .group(#require(doc.node(at: "/groups/0"))),
        at: .last)
    ])
    let result = try DeclarationDocument(
      bytes: change.bytes, identity: DocumentIdentity("manifest"))
    #expect(result.declaration.components.isEmpty)
    #expect(result.declaration.groups[0]["components"]?.elements?.count == 2)
    let text = String(decoding: change.bytes, as: UTF8.self)
    #expect(text.contains("# owned entry\n      - kind: ignore"))
    #expect(text.contains("patterns: [] # owned tail"))
    let flow = try document(
      "version: 1\ncomponents: [{kind: ignore, name: moving, patterns: []}]\ngroups: {target: {}}\n"
    )
    let moved = try flow.preparing([
      .moveComponent(
        #require(flow.node(at: "/components/0")),
        into: .group(#require(flow.node(at: "/groups/0"))), at: .first)
    ])
    #expect(
      try DeclarationDocument(bytes: moved.bytes, identity: DocumentIdentity("manifest"))
        .declaration.groups[0]["components"]?.elements?.count == 1)
  }

  @Test func sourceKindChangeRetainsInternalCommentsAndUnchangedFields() throws {
    let body =
      "version: 1\nsources:\n  s:\n    path: ./s # location\n    # root comment\n    subpath: rules\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
    let previous = try projected(body)
    var next = previous
    next.sourceDeclarations[0].source = SourceDeclaration(
      kind: .git, location: "https://example.invalid/repo.git", path: "rules")
    try next.updateSkills { $0?["s"]?.mode = .copy }
    let bytes = try #require(try planned(previous, next, in: body))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(text.contains("# root comment\n    subpath: rules"))
    #expect(text.contains("# location"))
    #expect(try projected(text).components == next.components)
  }

  @Test func unrelatedHandlesAndLiteralKindsAreRejectedWithoutTrapping() throws {
    let doc = try document("version: 1\ncomponents: [{kind: ignore, name: i, patterns: []}]\n")
    let scalar = try #require(doc.node(at: "/components/0/name"))
    for edit in [
      ManifestEdit.setSkillSelection(scalar, .all), .moveComponent(scalar, into: .root, at: .first),
      .setDictionaryEntry(scalar, key: "k", value: .string("v")),
    ] {
      expectManifestFailure("manifest.edit.readOnly") { try doc.preparing([edit]) }
    }
  }
}

extension EditPlanTests {
  @Test func blockScalarHeaderCommentsAndFollowingFieldsSurviveReplacement() throws {
    let doc = try document(
      "version: 1\ncomponents:\n  - kind: subagent\n    name: a\n    description: d\n    prompt: |- # owned header\n      before\n    model: keep\n# tail\n"
    )
    let change = try doc.preparing([
      .replaceComponent(
        #require(doc.node(at: "/components/0")),
        with: .subagent(name: "a", description: "d", prompt: .literal("after"), model: "keep"))
    ])
    let text = String(decoding: change.bytes, as: UTF8.self)
    #expect(text.contains("# owned header\n    model: keep\n# tail\n"))
    #expect(
      try DeclarationDocument(bytes: change.bytes, identity: DocumentIdentity("manifest"))
        .declaration == change.expectedDeclaration)
  }
}

extension EditPlanTests {
  @Test func promptKindChangesOwnTheWrapperAndRetainResourceLocations() throws {
    var text =
      "version: 1\nsources: {s: {path: ./s}}\ncomponents: [{kind: subagent, name: a, description: d, prompt: {file: {path: p.md}}, model: keep}] # tail\n"
    let original = try document(text)
    let prompt = try #require(original.sourceMap.locations(at: "/components/0/prompt").first?.span)
    let path = try #require(
      original.sourceMap.locations(at: "/components/0/prompt/path").first?.span)
    #expect(
      String(decoding: original.bytes[prompt.start..<prompt.end], as: UTF8.self)
        == "{file: {path: p.md}}")
    #expect(String(decoding: original.bytes[path.start..<path.end], as: UTF8.self) == "p.md")
    for body in [
      PromptBody.literal("hello"), .file(ResourceDeclaration(path: "other.md")),
      .file(ResourceDeclaration(path: "edited.md", source: "s")),
      .file(ResourceDeclaration(path: "edited.md")),
    ] {
      let before = try projected(text)
      var next = before
      next.components = [.subagent(name: "a", description: "d", prompt: body, model: "keep")]
      let bytes = try #require(try planned(before, next, in: text))
      text = String(decoding: bytes, as: UTF8.self)
      #expect(try projected(text) == next)
      #expect(text.contains("model: keep}] # tail\n"))
      #expect(try planned(next, next, in: text) == nil)
    }
  }

  @Test func emptyAndEscapedNativeKeysSupportPublicEditsAndCompletePlans() throws {
    var text =
      "version: 1\ncomponents: [{kind: lspServer, name: l, run: {executable: unused}, languages: {}, initializationOptions: {'': 1, nested: {'': {'a/b~': 1}}}}] # tail\n"
    let doc = try document(text)
    let dictionary = try #require(doc.node(at: "/components/0/initializationOptions"))
    let publicChange = try doc.preparing([
      .setDictionaryEntry(dictionary, key: "", value: .integer(2))
    ])
    text = String(decoding: publicChange.bytes, as: UTF8.self)
    #expect(text.contains("'': 2"))
    let before = try projected(text)
    var next = before
    next.components = [
      .lspServer(
        name: "l", run: ExecutableDeclaration(executable: "unused"), languages: [:],
        initializationOptions: [
          "": .integer(3), "nested": .object(["": .object(["a/b~": .integer(2)])]),
        ])
    ]
    let bytes = try #require(try planned(before, next, in: text))
    text = String(decoding: bytes, as: UTF8.self)
    #expect(try projected(text) == next)
    #expect(text.hasSuffix(" # tail\n"))
    #expect(try planned(next, next, in: text) == nil)
    let updated = try document(text)
    let removed = try updated.preparing([
      .removeDictionaryEntry(
        #require(updated.node(at: "/components/0/initializationOptions")), key: "")
    ])
    #expect(
      try document(String(decoding: removed.bytes, as: UTF8.self)).node(
        at: "/components/0/initializationOptions/") == nil)
  }

  @Test(arguments: ["", ",", ", # owned tail\n  "])
  func flowSequenceAppendsReuseDelimitersAndKeepTrivia(_ tail: String) throws {
    let text =
      "# header\nversion: 1\ncomponents: [{kind: ignore, name: a, patterns: []}" + tail + "]\n"
    let doc = try document(text)
    let change = try doc.preparing([
      .insertComponent(.ignore(name: "b", patterns: []), into: .root, at: .last)
    ])
    let output = String(decoding: change.bytes, as: UTF8.self)
    #expect(
      try projected(output).components == [
        .ignore(name: "a", patterns: []), .ignore(name: "b", patterns: []),
      ])
    #expect(
      output.hasPrefix("# header\nversion: 1\ncomponents: [{kind: ignore, name: a, patterns: []}"))
    if tail.contains("#") { #expect(output.contains("# owned tail")) }
    #expect(try planned(projected(output), projected(output), in: output) == nil)

  }

  @Test(arguments: [
    "missing: 1", "missing: 1,", "missing: ", "missing: ,", "missing: # owned tail\n    ",
    "\"missing\":",
  ])
  func flowDictionaryAppendsPreserveImplicitNullAndExistingTrivia(_ spelling: String) throws {
    let prefix =
      "# header\nversion: 1\ncomponents:\n  - kind: lspServer\n    name: l\n    run: {executable: unused}\n    languages: {}\n    initializationOptions: {"
    let suffix = "} # mapping tail\n"
    let input = prefix + spelling + suffix
    let doc = try document(input)
    let dictionary = try #require(doc.node(at: "/components/0/initializationOptions"))
    let change = try doc.preparing([.setDictionaryEntry(dictionary, key: "new", value: .integer(2))]
    )
    let output = String(decoding: change.bytes, as: UTF8.self)
    let before = try projected(input)
    var next = before
    next.components = [
      .lspServer(
        name: "l", run: ExecutableDeclaration(executable: "unused"), languages: [:],
        initializationOptions: [
          "missing": spelling.contains("1") ? .integer(1) : .null, "new": .integer(2),
        ])
    ]
    #expect(try projected(output) == next)
    #expect(try document(output).declaration == change.expectedDeclaration)
    #expect(output.hasPrefix(prefix))
    #expect(output.hasSuffix(suffix))
    if spelling.contains("1") { #expect(output.contains("{missing: 1")) }
    if spelling.hasPrefix("\"") { #expect(output.contains("{\"missing\":")) }
    if spelling.contains("#") { #expect(output.contains("# owned tail\n")) }
    #expect(try planned(before, next, in: input) == change.bytes)
    #expect(try planned(next, next, in: output) == nil)
    let updated = try document(output)
    #expect(
      try updated.preparing([
        .setDictionaryEntry(
          #require(updated.node(at: "/components/0/initializationOptions")), key: "new",
          value: .integer(2))
      ]).bytes == change.bytes)
  }

  @Test(arguments: ["", "\n", "\r\n"])
  func blockAppendsKeepTheOriginalEOFNewlineState(_ ending: String) throws {
    let text =
      "# header\nversion: 1\ncomponents:\n  - {kind: ignore, name: a, patterns: []}" + ending
    let before = try projected(text)
    var next = before
    next.components.append(.ignore(name: "b", patterns: []))
    let bytes = try #require(try planned(before, next, in: text))
    let output = String(decoding: bytes, as: UTF8.self)
    #expect(output.hasPrefix(text))
    #expect((bytes.last == 10) == !ending.isEmpty)
    if !ending.isEmpty { #expect(output.hasSuffix(ending)) }
    #expect(try projected(output) == next)
    #expect(try planned(next, next, in: output) == nil)
  }

  @Test func implicitNativeNullsCanBeReadAndEditedWithoutWideningOrdinaryFields() throws {
    for options in ["{missing: }", "\n      missing: # retained\n"] {
      var text =
        "version: 1\ncomponents:\n  - kind: lspServer\n    name: l\n    run: {executable: unused}\n    languages: {}\n    initializationOptions: "
        + options
      let doc = try document(text)
      let location = try #require(
        doc.sourceMap.locations(at: "/components/0/initializationOptions/missing").first?.span)
      #expect(location.start == location.end)
      let key = try #require(text.range(of: "missing:"))
      #expect(location.start == text[..<key.upperBound].utf8.count)
      #expect(try planned(projected(text), projected(text), in: text) == nil)
      #expect(
        try projected(text).components == [
          .lspServer(
            name: "l", run: ExecutableDeclaration(executable: "unused"), languages: [:],
            initializationOptions: ["missing": .null])
        ])
      for value in [NativeValue.string("present"), .null] {
        let current = try document(text)
        let changed = try current.preparing([
          .setDictionaryEntry(
            #require(current.node(at: "/components/0/initializationOptions")), key: "missing",
            value: value)
        ])
        text = String(decoding: changed.bytes, as: UTF8.self)
        #expect(try document(text).declaration == changed.expectedDeclaration)
        if options.contains("#") { #expect(text.contains("# retained")) }
        let repeated = try document(text)
        #expect(
          try repeated.preparing([
            .setDictionaryEntry(
              #require(repeated.node(at: "/components/0/initializationOptions")), key: "missing",
              value: value)
          ]).bytes == changed.bytes)
      }
    }
    expectManifestFailure("manifest.schema") {
      try document(
        "version: 1\ncomponents: [{kind: subagent, name: a, description: d, prompt: x, model: }]\n")
    }
  }
}
