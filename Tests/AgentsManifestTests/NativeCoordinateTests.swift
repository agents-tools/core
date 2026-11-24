import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

struct NativeCoordinateTests {
  @Test func completeCoordinatesRoundTripAndRenameLosslessly() throws {
    let body = """
      # retained header
      version: 1
      sources: {s: {path: missing, subpath: bundle}}
      components:
        - {kind: skills, source: s, path: skills/helper, select: [helper]}
        - {kind: mcpServer, name: server, transport: {kind: stdio, executable: ./server, executableSource: s, workingDirectory: {path: cwd, source: s}}}
        - {kind: hook, name: check, event: sessionStart, run: {executable: ./server, executableSource: s}}
      groups:
        unused:
          components:
            - {kind: lspServer, name: language, run: {executable: bin/server, executableSource: s}, languages: {".swift": swift}}
      # retained tail
      """
    let previous = try projected(body)
    let ir = YAMLConstruction.root(previous)
    #expect(try projected(String(decoding: YAMLWriter.manifest(ir), as: UTF8.self)) == previous)
    #expect(try planned(previous, previous, in: body) == nil)
    let target = body.replacingOccurrences(of: "{s:", with: "{t:")
      .replacingOccurrences(of: "source: s", with: "source: t")
      .replacingOccurrences(of: "executableSource: s", with: "executableSource: t")
      .replacingOccurrences(of: "skills/helper", with: "skills/other")
    let next = try projected(target)
    let output = String(
      decoding: try #require(try planned(previous, next, in: body)), as: UTF8.self)
    #expect(try projected(output) == next)
    #expect(output.hasPrefix("# retained header\n") && output.hasSuffix("# retained tail"))
    #expect(SkillDeclaration(select: .all).path == nil)
    #expect(ExecutableDeclaration(executable: "tool").executableSource == nil)
  }

  @Test func invalidCoordinatesAreRejectedByTypedAndManifestAdmission() throws {
    let index = SourceDeclaration(kind: .wellKnown, location: "https://example.invalid/index.json")
    let invalid = Declaration(
      sources: ["s": index],
      components: [
        .skills(source: "s", .init(select: .all, path: "skills"))
      ])
    #expect(throws: (any Error).self) { try invalid.validate(environment: projectionEnvironment) }
    for component in [
      "{kind: skills, source: s, path: ../outside}",
      "{kind: mcpServer, name: server, transport: {kind: stdio, executable: tool, executableSource: s}}",
      "{kind: hook, name: check, event: sessionStart, run: {executable: ./server, executableSource: missing}}",
    ] {
      #expect(throws: (any Error).self) {
        try projected(
          "version: 1\nsources: {s: {path: missing}}\ncomponents: [" + component + "]\n")
      }
    }
    #expect(throws: (any Error).self) {
      try projected(
        "version: 1\nsources: {s: {index: https://example.invalid/index.json}}\ncomponents: [{kind: skills, source: s, path: skills}]\n"
      )
    }
    let ambient = Declaration(
      sources: ["s": .init(kind: .local, location: "missing")],
      components: [
        .mcpServer(
          name: "server", transport: .stdio(.init(executable: "tool", executableSource: "s")))
      ])
    #expect(throws: (any Error).self) { try ambient.validate(environment: projectionEnvironment) }
  }
}
