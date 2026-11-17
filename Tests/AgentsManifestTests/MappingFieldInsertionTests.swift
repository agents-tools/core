import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

struct MappingFieldInsertionTests {
  @Test(arguments: [false, true], ["\n", "\r\n"])
  func skillPathAlignsWithCompactMappingKeys(_ nested: Bool, _ newline: String) throws {
    let owner = nested ? "    " : ""
    let prefix =
      "# header\nversion: 1\ndefaultAgents: [codex]\nsources: {team: {path: ./source}}\n"
      + (nested ? "groups:\n  local:\n" : "")
    let first = """
      \(owner)components:
      \(owner)  - kind: skills # component
      \(owner)    source: team
      \(owner)    select: [demo]
      \(owner)    mode: link # mode
      """ + "\n"
    let following = """
      \(owner)  # following component
      \(owner)  - kind: instructions
      \(owner)    sections: [{name: style, source: team}]
      # tail
      """ + "\n"
    let body = (prefix + first + following).replacingOccurrences(of: "\n", with: newline)
    let doc = try document(body)
    let pointer = nested ? "/groups/0/components/0" : "/components/0"
    let edit = IREdit.set(pointer + "/path", .string("."))
    let patches = try YAMLPatches(document: doc).patches(
      for: edit, expected: edit.applying(to: IRTree.root(doc.declaration)))
    #expect(patches.count == 1)
    #expect(
      String(decoding: patches[0].replacement, as: UTF8.self) == owner + "    \"path\": \".\""
        + newline)
    let change = try doc.preparing([
      .replaceComponent(
        #require(doc.node(at: pointer)),
        with: .skills(source: "team", .init(select: .names(["demo"]), path: ".", mode: .link)))
    ])
    let expected = (prefix + first + owner + "    \"path\": \".\"\n" + following)
      .replacingOccurrences(of: "\n", with: newline)
    #expect(String(decoding: change.bytes, as: UTF8.self) == expected)
    #expect(try document(expected).declaration == change.expectedDeclaration)
  }

  @Test(arguments: [false, true])
  func executableSourcePreservesNestedBlockAndFlowMappings(_ flow: Bool) throws {
    let transport =
      flow
      ? "    transport: {kind: stdio, executable: ./tool} # transport\n"
      : "    transport:\n      kind: stdio\n      executable: ./tool # executable\n"
    let prefix =
      "version: 1\nsources: {team: {path: ./source}}\ncomponents:\n  - kind: mcpServer\n    name: server\n"
    let tail = "  - {kind: ignore, name: keep, patterns: []}\n"
    let doc = try document(prefix + transport + tail)
    let change = try doc.preparing([
      .replaceComponent(
        #require(doc.node(at: "/components/0")),
        with: .mcpServer(
          name: "server", transport: .stdio(.init(executable: "./tool", executableSource: "team"))))
    ])
    let expectedTransport =
      flow
      ? "    transport: {kind: stdio, executable: ./tool, \"executableSource\": \"team\"} # transport\n"
      : transport + "      \"executableSource\": \"team\"\n"
    #expect(String(decoding: change.bytes, as: UTF8.self) == prefix + expectedTransport + tail)
    #expect(
      try document(prefix + expectedTransport + tail).declaration == change.expectedDeclaration)
  }

  @Test func flowSkillPathPreservesCommentsAndFollowingComponent() throws {
    let body =
      "version: 1\nsources: {team: {path: ./source}}\ncomponents:\n  - {kind: skills, source: team, select: [demo], mode: link} # skill\n  - {kind: ignore, name: keep, patterns: []}\n"
    let doc = try document(body)
    let change = try doc.preparing([
      .replaceComponent(
        #require(doc.node(at: "/components/0")),
        with: .skills(source: "team", .init(select: .names(["demo"]), path: ".", mode: .link)))
    ])
    #expect(
      String(decoding: change.bytes, as: UTF8.self)
        == body.replacingOccurrences(of: "mode: link}", with: "mode: link, \"path\": \".\"}"))
  }

  @Test(arguments: [false, true])
  func rootFieldInsertionPreservesByteOrderMark(_ explicitKey: Bool) throws {
    let first = explicitKey ? "? version\r\n: 1" : "version: 1"
    let body = "\u{FEFF}" + first + "\r\n# retained\r\n"
    let doc = try document(body)
    let change = try doc.preparing([.setDefaultAgents([.codex])])
    #expect(
      String(decoding: change.bytes, as: UTF8.self)
        == "\u{FEFF}" + first + "\r\n\"defaultAgents\": [\"codex\"]\r\n# retained\r\n")
  }

}
