import Foundation
import Testing

@testable import AgentsCore

@Suite("State file layout")
struct StateJSONTests {
  private func layout(_ compact: String) throws -> String {
    String(decoding: try StateJSON.format(Data(compact.utf8)), as: UTF8.self)
  }

  @Test func expandsObjectsAndKeepsShortScalarArraysOnOneLine() throws {
    let compact = """
      {"instructions":{"agents":["claude-code","codex"],"chatgpt":{},"sections":["guide","agents-tools:shared/swift-package-route","agents-tools:shared/swift-package-tests"]},"nested":[{"a":1},{"b":[]}],"skills":{},"text":"x : y \\"q\\" \\\\ é"}
      """
    #expect(
      try layout(compact) == """
        {
          "instructions": {
            "agents": ["claude-code", "codex"],
            "chatgpt": {},
            "sections": [
              "guide",
              "agents-tools:shared/swift-package-route",
              "agents-tools:shared/swift-package-tests"
            ]
          },
          "nested": [
            {
              "a": 1
            },
            {
              "b": []
            }
          ],
          "skills": {},
          "text": "x : y \\"q\\" \\\\ é"
        }

        """)
  }

  @Test func breaksAnArrayOnlyPastEightyColumnsIncludingItsComma() throws {
    // `  "k": [...]` with one element whose quoted text fills the rest of the line.
    func array(_ length: Int, comma: Bool) throws -> String {
      let element = String(repeating: "a", count: length)
      let compact = "{\"k\":[\"\(element)\"]" + (comma ? ",\"z\":0}" : "}")
      return try layout(compact).split(separator: "\n")[1].description
    }
    // `  "k": ` ends at column 7 and `["…"]` adds four characters: Prettier keeps 69 characters
    // on the line, or 68 when a comma follows.
    #expect(try array(69, comma: false).hasSuffix("\"]"))
    #expect(try array(70, comma: false) == "  \"k\": [")
    #expect(try array(68, comma: true).hasSuffix("\"],"))
    #expect(try array(69, comma: true) == "  \"k\": [")
    #expect(try layout("{}") == "{}\n")
    #expect(try layout("[]") == "[]\n")
  }
}
