import AgentsCore
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
      version: 1
      sources: {a: {path: a}, b: {path: b}}
      components:
        - {kind: skills, source: a, select: [\(literals(old))]}
        - {kind: skills, source: b, select: [\(literals(keep))]}
      """
    let previous = try projected(body)
    var next = previous
    try next.updateSkills { $0?["a"]?.select = .names(replacement) }
    let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
    let document = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(
      document.declaration
        == YAMLConstruction.root(next))
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
      version: 1
      sources: {b: {path: b}, a: {path: a}}
      components:
        - {kind: skills, source: a, select: [\(literals(old))]}
        - {kind: skills, source: b, select: [\(literals(keep))]}
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
        == YAMLConstruction.root(next))
    let result = try ManifestProjection.declaration(
      of: document, environment: projectionEnvironment)
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }
}
