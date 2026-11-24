import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

struct SourceReplacementTests {
  @Test func replacementRetargetsTypedReferencesAndPreservesOtherBytes() throws {
    let body = """
      # source header
      version: 1
      sources:
        first: {path: first}
        original: {path: original, subpath: original} # source comment
        other: {path: other}
      components:
        - {kind: skills, source: original, path: original, select: [], mode: copy}
        - {kind: instructions, sections: [{name: original, source: original}], chatgpt: {original: {sections: [{name: original, source: original}], append: original}}}
        - {kind: mcpServer, name: original, transport: {kind: stdio, executable: ./original, executableSource: original, arguments: [original], workingDirectory: {path: original, source: other}}, native: {schema: {source: original, executableSource: original}}}
        - {kind: hook, name: hook, event: sessionStart, run: {executable: ./original, executableSource: other, workingDirectory: {path: original, source: original}}}
        - {kind: lspServer, name: language, run: {executable: ./original, executableSource: original}, languages: {".original": original}}
        - {kind: command, name: command, description: original, prompt: {file: {path: original, source: original}}}
        - {kind: subagent, name: agent, description: original, prompt: {file: {path: original, source: original}}}
        - {kind: plugin, name: plugin, path: original, source: original}
      groups:
        unused:
          components:
            - {kind: skills, source: original, select: []}
            - {kind: instructions, sections: [{name: original, source: original}], chatgpt: {p: {sections: [{name: original, source: original}]}}}
            - {kind: command, name: unused, description: original, prompt: {file: {path: original, source: original}}}
          uses: [{group: original, source: original}]
      uses: [{group: original, source: original}, {group: unused, source: "."}]
      watch: [original, other]
      # tail
      """
    let doc = try document(body)
    let source = try #require(doc.node(at: "/sources/1"))
    let change = try doc.preparing([
      .replaceSource(
        source,
        with: .init(
          name: "renamed", source: .init(kind: .local, location: "new-location", path: "original")))
    ])
    let output = String(decoding: change.bytes, as: UTF8.self)
    let next = try DeclarationDocument(bytes: change.bytes, identity: .init("manifest"))
    let tree = IRTree.root(next.declaration)
    for pointer in [
      "/components/0/source", "/components/1/sections/0/source",
      "/components/1/chatGPT/0/sections/0/source",
      "/components/2/transport/executableSource", "/components/3/run/workingDirectory/source",
      "/components/4/run/executableSource", "/components/5/prompt/source",
      "/components/6/prompt/source", "/components/7/source",
      "/groups/0/components/0/source", "/groups/0/components/1/sections/0/source",
      "/groups/0/components/1/chatGPT/0/sections/0/source",
      "/groups/0/components/2/prompt/source", "/groups/0/uses/0/source", "/uses/0/source",
      "/watch/0",
    ] { #expect(IRTree.value(tree, at: pointer)?.string == "renamed") }
    #expect(next.declaration.sources.map { $0["name"]?.string } == ["first", "renamed", "other"])
    #expect(
      IRTree.value(tree, at: "/components/2/transport/workingDirectory/source")?.string == "other")
    #expect(IRTree.value(tree, at: "/components/3/run/executableSource")?.string == "other")
    #expect(IRTree.value(tree, at: "/uses/1/source")?.string == ".")
    #expect(output.contains("native: {schema: {source: original, executableSource: original}}"))
    #expect(output.contains("executable: ./original") && output.contains("arguments: [original]"))
    #expect(
      output.contains(#"languages: {".original": original}"#) && output.contains("append: original")
    )
    #expect(
      output.contains("# source comment") && output.hasPrefix("# source header\n")
        && output.hasSuffix("# tail"))
    #expect(doc.bytes == Array(body.utf8))
  }

  @Test func handlesNoopsCollisionsAndSourceKindsKeepExistingAdmission() throws {
    let doc = try document(
      "version: 1\nsources: {s: {path: old}, other: {path: other}}\ncomponents: [{kind: skills, source: s, mode: edit}]\n"
    )
    let source = try #require(doc.node(at: "/sources/0"))
    let same = NamedSourceDeclaration(name: "s", source: .init(kind: .local, location: "old"))
    #expect(try doc.preparing([.replaceSource(source, with: same)]).patches.isEmpty)
    let updated = try doc.preparing([
      .replaceSource(source, with: .init(name: "s", source: .init(kind: .local, location: "new")))
    ])
    #expect(
      try DeclarationDocument(bytes: updated.bytes, identity: .init("manifest")).declaration
        .sources[0]["path"]?.string == "new")
    for name in ["other", "."] {
      #expect(throws: (any Error).self) {
        try doc.preparing([.replaceSource(source, with: .init(name: name, source: same.source))])
      }
    }
    #expect(throws: (any Error).self) {
      try doc.preparing([
        .replaceSource(
          source,
          with: .init(
            name: "s", source: .init(kind: .git, location: "https://example.invalid/repo.git")))
      ])
    }
    #expect(throws: (any Error).self) {
      try doc.preparing([.replaceSource(#require(doc.node(at: "/components/0")), with: same)])
    }
    #expect(throws: (any Error).self) {
      try doc.preparing([.removeSource(alias: "s"), .replaceSource(source, with: same)])
    }
    let changed = try document("# changed\n" + String(decoding: doc.bytes, as: UTF8.self))
    #expect(throws: (any Error).self) {
      try changed.preparing([.replaceSource(source, with: same)])
    }
    #expect(throws: (any Error).self) {
      try doc.preparing([
        .replaceSource(NodeID(digest: doc.digest, pointer: "/sources/99", syntax: 0), with: same)
      ])
    }
    let chained = try doc.preparing([
      .replaceSource(source, with: .init(name: "temporary", source: same.source)),
      .replaceSource(source, with: .init(name: "final", source: same.source)),
    ])
    #expect(
      try DeclarationDocument(bytes: chained.bytes, identity: .init("manifest")).declaration
        .components[0]["source"]?.string == "final")
  }

  @Test func replacementComposesAcrossBatchesAndRemapsOriginalHandles() throws {
    let uses = (0..<105).map { "{group: g\($0), source: original}" }.joined(separator: ", ")
    let doc = try document(
      "version: 1\nsources: {first: {path: first}, original: {path: original}}\nuses: [" + uses
        + "]\nwatch: [original]\n")
    let source = try #require(doc.node(at: "/sources/1"))
    let reference = try #require(doc.node(at: "/uses/104"))
    let change = try doc.preparing([
      .removeSource(alias: "first"),
      .replaceSource(
        source, with: .init(name: "renamed", source: .init(kind: .local, location: "new"))),
      .removeGroupReference(reference),
    ])
    let result = try DeclarationDocument(bytes: change.bytes, identity: .init("manifest"))
    #expect(result.declaration.uses.count == 104)
    #expect(result.declaration.uses.allSatisfy { $0["source"]?.string == "renamed" })
    #expect(result.declaration.watch == ["renamed"])
    #expect(result.declaration.sources.first?["name"]?.string == "renamed")
  }
}
