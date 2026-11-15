import AgentsCore
import Foundation
import NativeDocuments
import Testing

func document(
  _ text: String, _ format: NativeDocumentFormat = .toml, budget: NativeDocumentBudget? = nil
) throws -> NativeDocument {
  try NativeDocument(bytes: Data(text.utf8), format: format, budget: budget ?? generousBudget())
}
func keyRegion(_ keys: String...) -> NativeRegion { NativeRegion(keys: keys) }
func owned(_ doc: NativeDocument, _ region: NativeRegion) throws -> NativeExpectedRegion {
  .owned(try #require(try doc.read(region)))
}
func text(_ change: PreparedNativeChange) -> String {
  String(decoding: change.bytes, as: UTF8.self)
}

@Test func jsoncRegionalOwnershipAndBytes() throws {
  let source = """
    {
      // client-owned , [ ] \" sentinel
      "accountSentinel": "keep",
      "projects": {
        "/work/a.b": {
          "hasTrustDialogAccepted": false,
          "mcpServers": {"db": {"command": "old", "args": []}}
        },
        "/work/b": {"mcpServers": {"other": {"command": "keep"}}}
      },
      "mcpServers": {"user": {"command": "keep"}}
    }
    """
  let doc = try document(source, .jsonc(trailingCommas: true))
  let command = keyRegion("projects", "/work/a.b", "mcpServers", "db", "command")
  let commandObservation = try #require(try doc.read(command))
  #expect(
    commandObservation.entryRanges.contains {
      String(decoding: Array(source.utf8)[$0], as: UTF8.self) == "\"command\": \"old\""
    })
  let updated = try doc.prepare([
    .put(region: command, expected: owned(doc, command), value: .string("new"))
  ])
  #expect(text(updated) == source.replacingOccurrences(of: "\"old\"", with: "\"new\""))
  let db = keyRegion("projects", "/work/a.b", "mcpServers", "db")
  let removed = try doc.prepare([.remove(region: db, expected: owned(doc, db))])
  #expect(text(removed).contains("\"mcpServers\": {}"))
  #expect(text(removed).contains("// client-owned , [ ] \" sentinel"))
  #expect(text(removed).contains("\"hasTrustDialogAccepted\": false"))
  #expect(text(removed).contains("\"user\": {\"command\": \"keep\"}"))
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([.put(region: command, expected: .absent, value: .string("old"))])
  }
  #expect(try doc.prepare([]).bytes == Data(source.utf8))
  let crlf = "\u{feff}" + source.replacingOccurrences(of: "\n", with: "\r\n")
  let crDoc = try document(crlf, .jsonc(trailingCommas: false))
  #expect(
    try crDoc.prepare([
      .put(region: command, expected: owned(crDoc, command), value: .string("old"))
    ]).bytes == Data(crlf.utf8))
}

@Test func jsonSyntaxExactIdentityAndNumbers() throws {
  for source in [
    #"{"db":1,"\u0064b":2}"#, "{}{}", "[1,]", "{/*comment*/}", "{a:1}", "[01]", "[1.]", "[NaN]",
    #"["\uD800"]"#,
  ] {
    #expect(throws: NativeDocumentError.self) { try document(source, .json) }
  }
  let source = #"{"é":1,"e\u0301":2,"value":"\u00e9","decimal":12345678901234567890.00100}"#
  let doc = try document(source, .json)
  #expect(try doc.read(keyRegion("é"))?.value == .integer(1))
  #expect(try doc.read(keyRegion("e\u{301}"))?.value == .integer(2))
  #expect(try doc.read(NativeRegion(keys: []))?.value == nil)
  let r = keyRegion("value")
  #expect(
    try doc.prepare([.put(region: r, expected: owned(doc, r), value: .string("é"))]).bytes
      == Data(source.utf8))
  let change = try doc.prepare([
    .put(region: r, expected: owned(doc, r), value: .string("e\u{301}"))
  ])
  #expect(change.bytes != Data(source.utf8))
  #expect(text(change).contains("12345678901234567890.00100"))
  for format: NativeDocumentFormat in [.json, .toml] {
    for decimal in ["1", "1.00", "1E+2", "-0", "123456789012345678901234567890"] {
      let doc = try document(format == .json ? "{}" : "", format)
      let c = try doc.prepare([
        .put(region: keyRegion("n"), expected: .absent, value: .decimal(decimal))
      ])
      let result = try NativeDocument(bytes: c.bytes, format: format, budget: generousBudget())
      #expect(try result.read(keyRegion("n")) != nil)
      #expect(text(c).contains(decimal))
    }
  }
}

let t1 = #"""
  title = "keep"
  stamp = 1979-05-27T07:32:00Z

  [mcp_servers."db.prod"] # keep table note
  command = "old" # keep field note
  args = ["a", "b"]
  description = """first
  second # literal content
  """

  [mcp_servers."db.prod".env]
  TOKEN = "${REFERENCE}"
  [mcp_servers.other]
  command = "keep"
  """#

@Test func tomlQuotedNestedAndNativeAtoms() throws {
  let doc = try document(t1)
  let command = keyRegion("mcp_servers", "db.prod", "command")
  #expect(
    text(
      try doc.prepare([.put(region: command, expected: owned(doc, command), value: .string("new"))])
    ) == t1.replacingOccurrences(of: "\"old\"", with: "\"new\""))
  #expect(try doc.read(keyRegion("stamp"))?.value == nil)
  let token = keyRegion("mcp_servers", "db.prod", "env", "TOKEN")
  let newKey = keyRegion("mcp_servers", "db.prod", "env", "NEW")
  let added = try doc.prepare([.put(region: newKey, expected: .absent, value: .string("added"))])
  #expect(text(added).contains("TOKEN = \"${REFERENCE}\""))
  #expect(text(added).contains("\"NEW\" = \"added\"\n[mcp_servers.other]"))
  #expect(
    text(try doc.prepare([.remove(region: token, expected: owned(doc, token))])).contains(
      "[mcp_servers.other]"))
  let server = keyRegion("mcp_servers", "db.prod")
  let serverObservation = try #require(try doc.read(server))
  #expect(
    serverObservation.entryRanges.contains {
      String(decoding: Array(t1.utf8)[$0], as: UTF8.self) == "TOKEN = \"${REFERENCE}\""
    })
  let removed = text(try doc.prepare([.remove(region: server, expected: owned(doc, server))]))
  #expect(removed.contains("# keep table note"))
  #expect(removed.contains("# keep field note"))
  #expect(removed.contains("stamp = 1979-05-27T07:32:00Z"))
  #expect(!removed.contains("TOKEN ="))
  #expect(removed.contains("[mcp_servers.other]\ncommand = \"keep\""))
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([.put(region: command, expected: owned(doc, command), value: .null)])
  }
  #expect(
    try doc.prepare([.put(region: command, expected: owned(doc, command), value: .string("old"))])
      .bytes == Data(t1.utf8))
}

@Test func tomlDottedInlineAndScope() throws {
  let source = #"""
    mcp_servers."db.prod".command = "tool"
    mcp_servers."db.prod".env = { "A.B" = "old", C = "keep" }
    """#
  let doc = try document(source)
  let r = keyRegion("mcp_servers", "db.prod", "env", "A.B")
  #expect(
    text(try doc.prepare([.put(region: r, expected: owned(doc, r), value: .string("new"))]))
      == source.replacingOccurrences(of: "\"old\"", with: "\"new\""))
  let added = try doc.prepare([
    .put(
      region: keyRegion("mcp_servers", "db.prod", "env", "D"), expected: .absent,
      value: .boolean(true))
  ])
  #expect(text(added).contains("C = \"keep\""))
  let deleted = try doc.prepare([.remove(region: r, expected: owned(doc, r))])
  #expect(text(deleted).contains("C = \"keep\""))
  let sibling = try doc.prepare([
    .put(
      region: keyRegion("mcp_servers", "new"), expected: .absent,
      value: .object(["command": .string("new")]))
  ])
  #expect(
    try NativeDocument(bytes: sibling.bytes, format: .toml, budget: generousBudget()).read(
      keyRegion("mcp_servers", "new", "command"))?.value == .string("new"))
  #expect(throws: NativeDocumentError.self) {
    try document(source + "\n[mcp_servers.\"db.prod\"]\na=1")
  }
}

@Test func tomlArrayTablesLatestChildAndRemoval() throws {
  let source = """
    [[checks]]
    id = "first"
    [checks.env]
    MODE = "a"
    [[checks]]
    id = "second"
    [checks.env]
    MODE = "b"
    """
  let doc = try document(source)
  let second = NativeRegion([
    .key("checks"), .occurrence(.init(idKey: "id", id: "second")), .key("env"), .key("MODE"),
  ])
  #expect(try doc.read(second)?.value == .string("b"))
  let changed = try doc.prepare([
    .put(region: second, expected: owned(doc, second), value: .string("new"))
  ])
  #expect(text(changed) == source.replacingOccurrences(of: "\"b\"", with: "\"new\""))
  let first = NativeRegion([.key("checks"), .occurrence(.init(idKey: "id", id: "first"))])
  let removed = try doc.prepare([.remove(region: first, expected: owned(doc, first))])
  #expect(!text(removed).contains("MODE = \"a\""))
  #expect(text(removed).contains("id = \"second\"\n[checks.env]\nMODE = \"b\""))
  let duplicates = try document(String(repeating: "[[checks]]\nid=\"same\"\n", count: 5))
  let occurrences = try #require(try duplicates.read(keyRegion("checks"))).occurrences
  #expect(throws: NativeDocumentError.self) {
    try duplicates.read(NativeRegion([.key("checks"), .occurrence(occurrences[2])]))
  }

}

@Test func readOnlyBudgetsAndSafeErrors() throws {
  let source = "x = {\na = 1,\n}"
  let doc = try document(source)
  #expect(try doc.read(keyRegion("x", "a"))?.value == .integer(1))
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([
      .put(
        region: keyRegion("x", "a"), expected: owned(doc, keyRegion("x", "a")), value: .integer(2))
    ])
  }
  for source in [
    "x=\"" + String(repeating: "a", count: 2000) + "\"", "#" + String(repeating: "a", count: 2000),
    "x=1\n" + String(repeating: " ", count: 2000),
  ] {
    let budget = NativeDocumentBudget(
      limits: .init(
        storage: 100_000, work: 100_000, nodes: 1000, depth: 20, uninterruptedBytes: 100))
    #expect(throws: NativeDocumentError.self) { try document(source, budget: budget) }
  }
  let budget = NativeDocumentBudget(
    limits: .init(storage: 100_000, work: 300, nodes: 1000, depth: 20, uninterruptedBytes: 1000))
  let bounded = try document("x=1", budget: budget)
  var exhausted = false
  for _ in 0..<30 {
    do {
      _ = try bounded.prepare([
        .put(region: keyRegion("x"), expected: owned(bounded, keyRegion("x")), value: .integer(2))
      ])
    } catch NativeDocumentError.budgetExceeded {
      exhausted = true
      break
    }
  }
  #expect(exhausted)
  do { _ = try document("secret=\"PRIVATE_SENTINEL\"\nbad=1979-05") } catch {
    #expect(!String(describing: error).contains("PRIVATE_SENTINEL"))
  }
}

@Test func structuralObjectsTriviaAndContainerEvidence() throws {
  let source = "{\"a\": 1, /* sibling */ \"b\": 2, \"c\": 3}"
  let doc = try document(source, .jsonc(trailingCommas: true))
  let object = keyRegion("owned")
  let parent = try document(
    "{\"owned\": " + source + ", \"keep\": true}", .jsonc(trailingCommas: true))
  let result = try parent.prepare([
    .put(
      region: object, expected: owned(parent, object),
      value: .object(["a": .integer(1), "new": .string("yes")]))
  ])
  #expect(text(result).contains("/* sibling */"))
  #expect(text(result).contains("\"keep\": true"))
  #expect(
    try doc.prepare([.remove(region: keyRegion("b"), expected: owned(doc, keyRegion("b")))]).bytes
      != doc.bytes)
  let populated = try document(#"{"owned":{"client":true}}"#, .json)
  let populatedEvidence = try #require(try populated.read(object))
  do {
    _ = try populated.prepare([
      .remove(region: object, expected: .createdContainer(populatedEvidence))
    ])
    Issue.record("creation evidence removed later children")
  } catch NativeDocumentError.ownershipMismatch {}
  #expect(
    text(try populated.prepare([.remove(region: object, expected: .owned(populatedEvidence))]))
      == "{}")
  for value: NativeValue in [
    .object([:]), .string("replacement"), .object(["client": .boolean(true)]),
  ] {
    do {
      _ = try populated.prepare([
        .put(region: object, expected: .createdContainer(populatedEvidence), value: value)
      ])
      Issue.record("creation-only evidence authorized a put")
    } catch NativeDocumentError.ownershipMismatch {}
  }
  #expect(
    text(
      try populated.prepare([
        .put(region: object, expected: .owned(populatedEvidence), value: .object([:]))
      ])) == #"{"owned":{}}"#)
  let empty = try document("{\"owned\":{}}", .json)
  let observed = try #require(try empty.read(object))
  do {
    _ = try empty.prepare([
      .put(region: object, expected: .createdContainer(observed), value: .object([:]))
    ])
    Issue.record("creation-only evidence authorized an empty-container no-op put")
  } catch NativeDocumentError.ownershipMismatch {}
  #expect(throws: NativeDocumentError.self) {
    try empty.prepare([.remove(region: object, expected: .owned(observed))])
  }
  #expect(
    text(try empty.prepare([.remove(region: object, expected: .createdContainer(observed))]))
      == "{}")
  let commented = try document("{\"owned\":{/* preserve */}}", .jsonc(trailingCommas: true))
  let commentEvidence = try #require(try commented.read(object))
  #expect(throws: NativeDocumentError.self) {
    try commented.prepare([.remove(region: object, expected: .createdContainer(commentEvidence))])
  }
  let created = try empty.prepare([
    .put(region: keyRegion("new", "child"), expected: .absent, value: .object([:]))
  ])
  #expect(created.createdContainers.contains(keyRegion("new")))
  #expect(created.createdContainers.contains(keyRegion("new", "child")))
  let invalid = try document("{\"a\": /* ambiguous */ 1}", .jsonc(trailingCommas: true))
  #expect(throws: NativeDocumentError.self) {
    try invalid.prepare([.remove(region: keyRegion("a"), expected: owned(invalid, keyRegion("a")))])
  }
  let trailing = try document("{\"a\":1,}", .jsonc(trailingCommas: true))
  _ = try trailing.prepare([.put(region: keyRegion("b"), expected: .absent, value: .integer(2))])
}

@Test func tomlUnicodeBOMAndInlinePunctuation() throws {
  let source = "\u{feff}\"é\"=1\r\n\"e\u{301}\"=2\r\nx=\"\\u00e9\"\r\nstamp=nan\r\n"
  let doc = try document(source)
  #expect(try doc.read(keyRegion("é"))?.value == .integer(1))
  #expect(try doc.read(keyRegion("e\u{301}"))?.value == .integer(2))
  let x = keyRegion("x")
  #expect(
    try doc.prepare([.put(region: x, expected: owned(doc, x), value: .string("é"))]).bytes
      == Data(source.utf8))
  let changed = try doc.prepare([
    .put(region: x, expected: owned(doc, x), value: .string("e\u{301}"))
  ])
  #expect(text(changed) == source.replacingOccurrences(of: "\\u00e9", with: "e\u{301}"))
  let inline = try document("x={ a=\"first\", b=[], c=\"last\" }")
  let b = keyRegion("x", "b")
  #expect(
    text(try inline.prepare([.remove(region: b, expected: owned(inline, b))])).contains(
      "c=\"last\""))
  let r = keyRegion("a")
  let before = try document("a=\"old\"")
  let after = try document("a=\"new\"")
  #expect(throws: NativeDocumentError.self) {
    try after.prepare([.put(region: r, expected: owned(before, r), value: .string("replace"))])
  }
}

@Test func exactEvidenceAndMultiEditFailure() throws {
  let region = keyRegion("owned")
  let original = try document(#"{"owned":{"a":{},"b":"x"}}"#, .json)
  let changed = try document(#"{"owned":{"a":{"b":"x"}}}"#, .json)
  #expect(throws: NativeDocumentError.self) {
    try changed.prepare([
      .put(region: region, expected: owned(original, region), value: .object([:]))
    ])
  }
  let valid = try document(#"{"a":1,"b":2}"#, .json)
  let before = valid.bytes
  #expect(throws: NativeDocumentError.self) {
    try valid.prepare([
      .put(region: keyRegion("a"), expected: owned(valid, keyRegion("a")), value: .integer(3)),
      .put(region: keyRegion("b"), expected: .absent, value: .integer(4)),
    ])
  }
  #expect(valid.bytes == before)
  let source = "[owned]\nargs=[\n# keep array note\n\"a\"\n]\n"
  let table = try document(source)
  #expect(throws: NativeDocumentError.self) {
    try table.prepare([
      .remove(region: keyRegion("owned"), expected: owned(table, keyRegion("owned")))
    ])
  }
}

@Test func occurrenceIdentityEvidenceAndAliasOverlap() throws {
  let source = "[[checks]]\nid=\"é\"\nx=1\n[[checks]]\nid=\"e\u{301}\"\nx=2"
  let doc = try document(source)
  let array = try #require(try doc.read(keyRegion("checks")))
  let second = NativeRegion([
    .key("checks"), .occurrence(.init(idKey: "id", id: "e\u{301}")), .key("x"),
  ])
  #expect(try doc.read(second)?.value == .integer(2))
  let same = NativeRegion([.key("checks"), .occurrence(array.occurrences[1]), .key("x")])
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([
      .put(region: second, expected: owned(doc, second), value: .integer(3)),
      .put(region: same, expected: owned(doc, same), value: .integer(4)),
    ])
  }
  let id = NativeRegion([.key("checks"), .occurrence(.init(idKey: "id", id: "é")), .key("id")])
  let renamed = try doc.prepare([
    .put(region: id, expected: owned(doc, id), value: .string("renamed"))
  ])
  #expect(renamed.observations.first?.value == .string("renamed"))
  #expect(
    renamed.observations.first?.region
      == NativeRegion([.key("checks"), .occurrence(.init(idKey: "id", id: "renamed")), .key("id")]))
  let duplicates = try document("[[checks]]\nx=1\n[[checks]]\nx=2\n[[checks]]\nx=1")
  let evidence = try #require(try duplicates.read(keyRegion("checks"))).occurrences[2]
  #expect(
    try duplicates.read(NativeRegion([.key("checks"), .occurrence(evidence), .key("x")]))?.value
      == .integer(1))
}

@Test func arrayDraftsPreserveOriginalOwnershipAddresses() throws {
  let doc = try document(
    "[[checks]]\nid=\"first\"\nx=1\n[[checks]]\nid=\"second\"\nx=2\n[[checks]]\nid=\"third\"\nx=3")
  func occurrence(_ id: String, _ key: String? = nil) -> NativeRegion {
    var steps: [NativePathStep] = [.key("checks"), .occurrence(.init(idKey: "id", id: id))]
    if let key { steps.append(.key(key)) }
    return NativeRegion(steps)
  }
  let renamed = try doc.prepare([
    .put(
      region: occurrence("second", "id"), expected: owned(doc, occurrence("second", "id")),
      value: .string("renamed")),
    .put(
      region: occurrence("second", "x"), expected: owned(doc, occurrence("second", "x")),
      value: .integer(22)),
  ])
  #expect(renamed.observations.count == 2)
  #expect(renamed.observations.last?.value == .integer(22))
  let removed = try doc.prepare([
    .remove(region: occurrence("first"), expected: owned(doc, occurrence("first"))),
    .remove(region: occurrence("second"), expected: owned(doc, occurrence("second"))),
  ])
  #expect(text(removed).contains("id=\"third\""))
  #expect(!text(removed).contains("id=\"second\""))
}

@Test func exactTOMLDecimalProjectionAndTrueEOF() throws {
  let doc = try document("n=+1_000.00\nx=12:13:14.1")
  let region = keyRegion("n")
  let observation = try #require(try doc.read(region))
  #expect(observation.value == .decimal("1000.00"))
  #expect(observation.numericLexeme == "+1_000.00")
  #expect(
    try doc.prepare([
      .put(region: region, expected: .owned(observation), value: .decimal("1000.00"))
    ]).bytes == doc.bytes)
  #expect(try doc.prepare([]).bytes == doc.bytes)
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([.put(region: region, expected: .owned(observation), value: .decimal("1_000"))])
  }
}

@Test func nativeCanonicalTableCollisionAndReadOnlyReasons() throws {
  let a = "prefixabcdefgh-a\u{301}\u{327}-zyxwvuts"
  let b = "prefixabcdefgh-a\u{327}\u{301}-zyxwvuts"
  let source = "title=\"old\"\n[\"\(a)\"]\nx=1\n[\"\(b)\"]\nx=2"
  let doc = try document(source)
  #expect(try doc.read(keyRegion(a, "x"))?.value == .integer(1))
  #expect(try doc.read(keyRegion(b, "x"))?.value == .integer(2))
  #expect(
    text(
      try doc.prepare([
        .put(
          region: keyRegion("title"), expected: owned(doc, keyRegion("title")),
          value: .string("new"))
      ])) == source.replacingOccurrences(of: "\"old\"", with: "\"new\""))
  for source in ["x={\na=1,\n}", #"x="\x41""#, #"x="\e""#, "x=12:13"] {
    let doc = try document(source)
    #expect(try doc.read(keyRegion("x")) != nil)
    do {
      _ = try doc.prepare([
        .put(region: keyRegion("x"), expected: owned(doc, keyRegion("x")), value: .string("new"))
      ])
      Issue.record("read-only syntax was edited")
    } catch NativeDocumentError.unsupportedEdit(.syntaxNotLocated, _, _) {}
  }
}

@Test func cancellationAndReadOnlyAdmissionAreNotSyntaxFallbacks() throws {
  var checks = 0
  let cancelled = NativeDocumentBudget(
    limits: .init(
      storage: 1_000_000, work: 1_000_000, nodes: 10_000, depth: 30, uninterruptedBytes: 100_000),
    cancellation: {
      checks += 1
      return checks > 100
    })
  do {
    _ = try document("#" + String(repeating: "x", count: 10_000), budget: cancelled)
    Issue.record("cancellation was ignored")
  } catch NativeDocumentError.cancelled {}
  let wide = "x={\n" + (0..<1000).map { "k\($0)=1," }.joined(separator: "\n") + "\n}"
  let bounded = NativeDocumentBudget(
    limits: .init(
      storage: 1_000_000, work: 20_000, nodes: 100_000, depth: 30, uninterruptedBytes: 100_000))
  do {
    _ = try document(wide, budget: bounded)
    Issue.record("read-only semantics escaped the work budget")
  } catch NativeDocumentError.budgetExceeded {}
  for source in [
    "#" + String(repeating: "x", count: 2000), "x=1\n" + String(repeating: " ", count: 2000),
    "x=\"" + String(repeating: "x", count: 2000) + "\"",
  ] {
    let budget = NativeDocumentBudget(
      limits: .init(
        storage: 1_000_000, work: 1_000_000, nodes: 100_000, depth: 30, uninterruptedBytes: 100))
    do {
      _ = try document(source, budget: budget)
      Issue.record("CST envelope was not enforced")
    } catch NativeDocumentError.budgetExceeded(let stage) {
      #expect(stage == "CST uninterrupted input")
    }
  }
}

@Test func regionalInsertionUsesLocalWhitespace() throws {
  let pretty = "{\n  \"owned\": {\n    \"a\":1 // keep field note\n  },\n  \"keep\": true\n}"
  let doc = try document(pretty, .jsonc(trailingCommas: false))
  let result = try doc.prepare([
    .put(region: keyRegion("owned", "b"), expected: .absent, value: .integer(2))
  ])
  #expect(
    text(result)
      == pretty.replacingOccurrences(of: "\"a\":1", with: "\"a\":1,").replacingOccurrences(
        of: "  },", with: "    \"b\":2\n  },"))
  let compact = try document("{\"a\":1}", .json)
  #expect(
    text(try compact.prepare([.put(region: keyRegion("b"), expected: .absent, value: .integer(2))]))
      == "{\"a\":1,\"b\":2}")
  let inline = try document("x={ a = 1, b = 2 }")
  #expect(
    text(
      try inline.prepare([.put(region: keyRegion("x", "c"), expected: .absent, value: .integer(3))])
    ) == "x={ a = 1, b = 2, \"c\" = 3 }")
}

@Test func absentOccurrenceAppendAndOwnedArrayTables() throws {
  let source = "[[checks]]\nid=\"first\"\n[checks.env]\nMODE=\"a\"\n[other]\nvalue=\"keep\""
  let doc = try document(source)
  let second = NativeRegion([.key("checks"), .occurrence(.init(idKey: "id", id: "second"))])
  #expect(try doc.read(second) == nil)
  let appended = try doc.prepare([
    .put(
      region: second, expected: .absent,
      value: .object(["id": .string("second"), "env": .object(["MODE": .string("b")])]))
  ])
  #expect(text(appended).hasPrefix(source))
  let parsed = try NativeDocument(bytes: appended.bytes, format: .toml, budget: generousBudget())
  #expect(
    try parsed.read(NativeRegion(second.steps + [.key("env"), .key("MODE")]))?.value == .string("b")
  )
  #expect(try parsed.read(keyRegion("other", "value"))?.value == .string("keep"))
  #expect(throws: NativeDocumentError.self) {
    try doc.prepare([
      .put(region: second, expected: .absent, value: .object(["id": .string("wrong")]))
    ])
  }
  let array = keyRegion("checks")
  let replaced = try doc.prepare([
    .put(
      region: array, expected: owned(doc, array),
      value: .array([
        .object(["id": .string("renamed"), "env": .object(["MODE": .string("new")])]),
        .object(["id": .string("second")]),
      ]))
  ])
  #expect(text(replaced).contains("value=\"keep\""))
  #expect(
    try NativeDocument(bytes: replaced.bytes, format: .toml, budget: generousBudget()).read(
      NativeRegion([
        .key("checks"), .occurrence(.init(idKey: "id", id: "renamed")), .key("env"), .key("MODE"),
      ]))?.value == .string("new"))
  let json = try document("{\"checks\":[{\"id\":\"first\"}],\"keep\":true}", .json)
  let jsonAppend = try json.prepare([
    .put(region: second, expected: .absent, value: .object(["id": .string("second")]))
  ])
  #expect(
    try NativeDocument(bytes: jsonAppend.bytes, format: .json, budget: generousBudget()).read(
      second)?.value == .object(["id": .string("second")]))
}

@Test func finalArrayOccurrenceRetainsItsContainer() throws {
  let doc = try document(
    "[[checks]] # keep table note\nid=\"last\"\n[checks.env]\nMODE=\"a\"\n[other]\nx=1")
  let occurrence = NativeRegion([.key("checks"), .occurrence(.init(idKey: "id", id: "last"))])
  let removed = try doc.prepare([.remove(region: occurrence, expected: owned(doc, occurrence))])
  let result = try NativeDocument(bytes: removed.bytes, format: .toml, budget: generousBudget())
  #expect(try result.read(keyRegion("checks"))?.value == .array([]))
  #expect(text(removed).contains("# keep table note"))
  #expect(text(removed).contains("[other]\nx=1"))
  let mixed = try doc.prepare([
    .put(
      region: keyRegion("checks"), expected: owned(doc, keyRegion("checks")),
      value: .array([.integer(1), .string("two")]))
  ])
  #expect(
    try NativeDocument(bytes: mixed.bytes, format: .toml, budget: generousBudget()).read(
      keyRegion("checks"))?.value == .array([.integer(1), .string("two")]))
  let emptySet = try doc.prepare([
    .put(region: keyRegion("checks"), expected: owned(doc, keyRegion("checks")), value: .array([]))
  ])
  #expect(
    try NativeDocument(bytes: emptySet.bytes, format: .toml, budget: generousBudget()).read(
      keyRegion("checks"))?.value == .array([]))
}

@Test func completeJSONCObjectIntentPreservesUnselectedBytes() throws {
  let source =
    "{\n  \"owned\": {\"a\": 1, /* keep */ \"b\": 2, \"c\": 3},\n  \"outside\": { \"sentinel\": true }\n}"
  let doc = try document(source, .jsonc(trailingCommas: false))
  let region = keyRegion("owned")
  let change = try doc.prepare([
    .put(
      region: region, expected: owned(doc, region),
      value: .object(["a": .integer(1), "b": .integer(20), "new": .string("yes")]))
  ])
  let result = try NativeDocument(
    bytes: change.bytes, format: .jsonc(trailingCommas: false), budget: generousBudget())
  #expect(
    try result.read(region)?.value
      == .object([
        "a": .integer(1), "b": .integer(20), "new": .string("yes"),
      ]))
  #expect(try result.read(keyRegion("owned", "c")) == nil)
  #expect(text(change).contains("/* keep */"))
  #expect(text(change).hasSuffix(",\n  \"outside\": { \"sentinel\": true }\n}"))
}

@Test func occurrenceEvidenceAcrossExternalChanges() throws {
  let original = try document(#"{"items":[{"x":0},{"x":1},{"x":2}]}"#, .json)
  let evidence = try #require(try original.read(keyRegion("items"))).occurrences[1]
  let selected = NativeRegion([.key("items"), .occurrence(evidence), .key("x")])
  let observation = try #require(try original.read(selected))
  #expect(observation.value == .integer(1))
  let changed = try document(#"{"items":[{"x":0},{"x":1},{"x":2},{"x":0},{"x":1},{"x":2}]}"#, .json)
  do {
    _ = try changed.prepare([
      .put(region: selected, expected: .owned(observation), value: .integer(9))
    ])
    Issue.record("ambiguous occurrence was edited")
  } catch NativeDocumentError.unsupportedEdit(.ambiguousOccurrence, _, _) {}

  let first = try document(#"{"items":[{"id":"a","x":1},{"id":"b","x":2}]}"#, .json)
  let stable = NativeRegion([.key("items"), .occurrence(.init(idKey: "id", id: "b")), .key("x")])
  let prior = try #require(try first.read(stable))
  let inserted = try document(
    #"{"items":[{"id":"new","x":0},{"id":"a","x":1},{"id":"b","x":2}]}"#, .json)
  let result = try inserted.prepare([
    .put(region: stable, expected: .owned(prior), value: .integer(7))
  ])
  #expect(text(result) == #"{"items":[{"id":"new","x":0},{"id":"a","x":1},{"id":"b","x":7}]}"#)
}

@Test func sharedBudgetAcrossDocumentsAndDrafts() throws {
  func budget(_ work: Int) -> NativeDocumentBudget {
    NativeDocumentBudget(
      limits: .init(
        storage: 1_000_000, work: work, nodes: 10_000, depth: 30, uninterruptedBytes: 10_000))
  }
  func consume(_ budget: NativeDocumentBudget) throws {
    let doc = try document(#"{"data":[1,2,3,4,5,6,7,8]}"#, .json, budget: budget)
    _ = try doc.read(keyRegion("data"))
  }
  func setup(_ budget: NativeDocumentBudget) throws -> (NativeDocument, [NativeRegionEdit]) {
    let doc = try document(#"{"a":1,"b":2}"#, .json, budget: budget)
    let edits: [NativeRegionEdit] = try [
      .put(region: keyRegion("a"), expected: owned(doc, keyRegion("a")), value: .integer(3)),
      .put(region: keyRegion("b"), expected: owned(doc, keyRegion("b")), value: .integer(4)),
    ]
    return (doc, edits)
  }
  var demonstrated = false
  for limit in stride(from: 100, through: 5000, by: 50) {
    do {
      try consume(budget(limit))
      let (doc, edits) = try setup(budget(limit))
      _ = try doc.prepare(edits)
    } catch NativeDocumentError.budgetExceeded { continue }
    let shared = budget(limit)
    try consume(shared)
    let doc: NativeDocument
    let edits: [NativeRegionEdit]
    do {
      (doc, edits) = try setup(shared)
    } catch NativeDocumentError.budgetExceeded { continue }
    do {
      _ = try doc.prepare(edits)
    } catch NativeDocumentError.budgetExceeded {
      demonstrated = true
      break
    }
  }
  #expect(demonstrated)
}

@Test func publicErrorsDistinguishInvalidDocumentsAndOwnership() throws {
  for source in ["deep=[{bad=2023-02-30}]", #"deep=[{bad="\q"}]"#, "x=9223372036854775808"] {
    do {
      _ = try document(source)
      Issue.record("invalid document was accepted")
    } catch NativeDocumentError.invalidDocument {}
  }
  let doc = try document(#"{"a":1}"#, .json)
  do {
    _ = try doc.prepare([.put(region: keyRegion("a"), expected: .absent, value: .integer(1))])
    Issue.record("unowned value was adopted")
  } catch NativeDocumentError.ownershipMismatch {}
}

@Test(arguments: [false, true])
func dottedInlineInsertionStaysWithinBraces(_ ownedParent: Bool) throws {
  let source = "# keep\nx = { a.b = 1, z = 2 } # outside\n"
  let doc = try document(source)
  let region = keyRegion("x", "a", "c")
  let edit: NativeRegionEdit
  if ownedParent {
    let parent = keyRegion("x", "a")
    edit = .put(
      region: parent, expected: try owned(doc, parent),
      value: .object([
        "b": .integer(1), "c": .object(["d": .integer(2)]),
      ]))
  } else {
    edit = .put(region: region, expected: .absent, value: .object(["d": .integer(2)]))
  }
  let change = try doc.prepare([edit])
  #expect(text(change) == "# keep\nx = { a.b = 1, z = 2, \"a\".\"c\" = {\"d\" = 2} } # outside\n")
  let added = try NativeDocument(bytes: change.bytes, format: .toml, budget: generousBudget())
  #expect(try added.read(region)?.value == .object(["d": .integer(2)]))
  let child = keyRegion("x", "a", "c", "d")
  let update = try added.prepare([
    .put(region: child, expected: owned(added, child), value: .integer(3))
  ])
  #expect(text(update) == text(change).replacingOccurrences(of: "= 2}", with: "= 3}"))
  let remove = try added.prepare([.remove(region: region, expected: owned(added, region))])
  #expect(
    try NativeDocument(bytes: remove.bytes, format: .toml, budget: generousBudget()).read(
      keyRegion("x"))?.value == .object(["a": .object(["b": .integer(1)]), "z": .integer(2)]))
  #expect(text(remove).contains("a.b = 1, z = 2"))
  #expect(text(remove).hasSuffix(" # outside\n"))
}

@Test(arguments: invalidTOMLExtensionsAndTimes)
func invalidTOMLCannotBecomeReadOnly(_ source: String) throws {
  do {
    _ = try document(source)
    Issue.record("invalid TOML admitted as a document")
  } catch NativeDocumentError.invalidDocument {}
}

@Test func tomlDELStringsAndKeysRoundTrip() throws {
  let source = #"x="\u007F""#
  let doc = try document(source)
  let x = keyRegion("x")
  #expect(
    try doc.prepare([.put(region: x, expected: owned(doc, x), value: .string("\u{7f}"))]).bytes
      == doc.bytes)
  let key = "key\u{7f}"
  let change = try doc.prepare([
    .put(region: keyRegion(key), expected: .absent, value: .string("value\u{7f}"))
  ])
  #expect(!change.bytes.contains(127))
  let result = try NativeDocument(bytes: change.bytes, format: .toml, budget: generousBudget())
  #expect(try result.read(keyRegion(key))?.value == .string("value\u{7f}"))
}
