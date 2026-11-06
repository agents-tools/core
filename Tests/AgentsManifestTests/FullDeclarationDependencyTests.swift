import AgentsCore
import Testing

@testable import AgentsManifest

extension FullDeclarationTests {
  @Test(arguments: [false, true])
  func addingAndRemovingGroupDependenciesAcrossBatches(_ removing: Bool) throws {
    let groups =
      (0..<102).map { index in
        ComponentGroupDeclaration(name: "g\(index)", uses: [GroupUseDeclaration(name: "hub")])
      } + [ComponentGroupDeclaration(name: "hub")]
    let populated = Declaration(
      sourceDeclarations: [], groups: groups, uses: [GroupUseDeclaration(name: "g0")],
      exports: ["g0"])
    let empty = try projected("let agents = Agents()")
    let previous = removing ? populated : empty
    let next = removing ? empty : populated
    let initial =
      try planned(Declaration(), previous, in: nil)
      ?? Array((manifestHeader + "let agents = Agents()").utf8)
    let bytes = try #require(
      try planned(previous, next, in: String(decoding: initial, as: UTF8.self)))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result == next)
    #expect(try planned(result, next, in: String(decoding: bytes, as: UTF8.self)) == nil)
  }

  @Test func reversingGroupDependenciesAcrossBatchesProducesTheCompleteDeclaration() throws {
    var previous = Declaration(
      sourceDeclarations: [],
      groups: (0..<102).map { index in
        ComponentGroupDeclaration(name: "g\(index)", uses: [GroupUseDeclaration(name: "hub")])
      } + [ComponentGroupDeclaration(name: "hub")])
    let initial = try #require(try planned(Declaration(), previous, in: nil))
    previous = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: initial, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    var next = previous
    for index in next.groups.indices {
      next.groups[index].uses =
        next.groups[index].name == "hub"
        ? (0..<102).map { GroupUseDeclaration(name: "g\($0)") } : []
    }
    let bytes = try #require(
      try planned(previous, next, in: String(decoding: initial, as: UTF8.self)))
    let result = try ManifestProjection.declaration(
      of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
      environment: projectionEnvironment)
    #expect(result == next)
  }
}
