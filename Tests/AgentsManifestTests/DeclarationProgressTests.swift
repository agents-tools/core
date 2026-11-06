import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

@Suite("Declaration edit progress")
struct DeclarationProgressTests {
  @Test func flatSkillReplacementsKeepTheirInsertionAndRemovalProgressAcrossBatches() throws {
    let old = (0..<100).map { "old\($0)" }
    let replacement = (0..<100).map { "new\($0)" }.sorted(by: utf8Less)
    let keep = (0..<2000).map { "keep\($0)" }
    func literals(_ names: [String]) -> String {
      names.map { "\"\($0)\"" }.joined(separator: ", ")
    }
    let body = """
      let agents = Agents(
        sources: [.source(name: "a", path: "a"), .source(name: "b", path: "b")],
        components: [
          .skills(source: "a", select: [\(literals(old))]),
          .skills(source: "b", select: [\(literals(keep))]),
        ]
      )
      """
    let previous = try projected(body)
    var next = previous
    try next.updateSkills { $0?["a"]?.select = .names(replacement) }
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      document.declaration
        == Lowering.declaration(try DeclarationConstruction.root(next).constructionValue))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(try result.skills?["b"]?.select == .names(keep))
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }

  @Test func sourceReorderingAndSkillReplacementProgressAcrossBatches() throws {
    let old = (0..<100).map { "old\($0)" }
    let replacement = (0..<100).map { "new\($0)" }
    let keep = (0..<2000).map { "keep\($0)" }
    func literals(_ names: [String]) -> String {
      names.map { "\"\($0)\"" }.joined(separator: ", ")
    }
    let body = """
      let agents = Agents(
        sources: [
          .source(name: "b", path: "b"),
          .source(name: "a", path: "a"),
        ],
        components: [
          .skills(source: "a", select: [\(literals(old))]),
          .skills(source: "b", select: [\(literals(keep))]),
        ]
      )
      """
    let previous = try projected(body)
    var next = previous
    next.sourceDeclarations.reverse()
    try next.updateSkills { $0?["a"]?.select = .names(replacement) }
    try previous.validate(environment: projectionEnvironment)
    try next.validate(environment: projectionEnvironment)
    #expect(previous.sourceDeclarations.map(\.name) == ["b", "a"])
    #expect(next.sourceDeclarations.map(\.name) == ["a", "b"])
    #expect(try previous.skills?["a"]?.select == .names(old))
    #expect(try next.skills?["a"]?.select == .names(replacement))
    #expect(try next.skills?["b"]?.select == .names(keep))

    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      document.declaration
        == Lowering.declaration(try DeclarationConstruction.root(next).constructionValue))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }
}
