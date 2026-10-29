import AgentsCore
import AgentsDescription
import Testing

@testable import AgentsManifest

@Suite("Manifest literal conversion")
struct LiteralConversionTests {
  @Test(arguments: [
    "let versions: [Version] = [\"1.2.3\"]",
    "let versions: [String: Version] = [\"stable\": \"1.2.3\"]",
    "let version: Version = \"1.2.3\"\nlet versions: [Version] = [version]",
  ])
  func versionCollectionsPreserveContextuallyTypedElements(_ body: String) throws {
    _ = try document(body + "\nlet agents = Agents()")
  }
  @Test func valueLiteralExamplesMatchTheRealCompiler() throws {
    let values: [(String, ConfigurationValue)] = [
      ("nil", nil), ("true", true), ("-9_223_372_036_854_775_808", .integer(Int.min)),
      ("[1, true, nil, \"x\"]", [1, true, nil, "x"]),
      ("[\"x\": [\"y\": .decimal(\"1.25\")]]", ["x": ["y": .decimal("1.25")]]),
      ("\"\\0\\t\\n\\r\\\"\\'\\\\\\u{1F600}\"", "\0\t\n\r\"'\\😀"),
      ("\"\"\"\n  first\n\n  last\n  \"\"\"", "first\n\nlast"),
    ]
    for (expression, compiled) in values {
      let doc = try document(
        "let value: ConfigurationValue = " + expression + "\nlet agents = Agents()")
      #expect(doc.evaluation.constants["value"]!.value == compiled.constructionValue)
    }
  }
  @Test func editorLiteralConversionsMatchCompiledConfigurationValues() throws {
    let values: [(StaticValue, ConfigurationValue)] = [
      (.null, nil), (.boolean(true), true), (.integer(Int.min), .integer(Int.min)),
      (.string("first\n\nlast"), "first\n\nlast"),
      (.array([.integer(1), .boolean(true), .null, .string("x")]), [1, true, nil, "x"]),
      (
        .dictionary(["x": .dictionary(["y": .configuration(.decimal("1.25"))])]),
        ["x": ["y": .decimal("1.25")]]
      ),
    ]
    for (literal, compiled) in values {
      let doc = try document("let value: ConfigurationValue = 0\nlet agents = Agents()")
      let changed = try edited(
        doc, [.replaceConstant(doc.constant(named: "value")!, with: literal, acceptingUses: [])])
      #expect(changed.evaluation.constants["value"]?.value == compiled.constructionValue)
    }
  }

}
