import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation
import Testing

struct ReadFootprintIntegrationTests {
  @Test func unsavedDeclarationAndAbsentExportInputsHaveDurableReadLocations() throws {
    let f = try UpdateFixture()
    try f.declare(agents: [.claudeCode])
    let own = f.root.appendingPathComponent(".agent/instructions/own.md")
    let appendix = f.root.appendingPathComponent("future-append.md")
    let unused = f.root.appendingPathComponent("future-source")
    try f.write("---\ndescription: Own rules.\n---\n# Own\n\nCurrent own rules.", to: own)
    var declaration = try f.store.loadDeclaration()
    declaration.sources["unused"] = SourceDeclaration(kind: .local, location: unused.path)
    for index in declaration.components.indices {
      if case .instructions(var selection) = declaration.components[index] {
        selection.sectionReferences.append(SectionDeclaration(name: "own"))
        selection.prompts[0].prompt.append = "future-append.md"
        declaration.components[index] = .instructions(selection)
      }
    }
    let before = try FileHash.folderHash(f.root)
    let report = try UpdateOperations.preview(
      UpdateRequest(operation: .declaration(declaration)), environment: f.environment)
    let discovery = try UpdateOperations.discover(declaration, environment: f.environment)
    for locations in [report.readLocations, discovery.readLocations] {
      let paths = Set(locations.map(\.path))
      #expect(paths.contains(unused.path))
      #expect(paths.contains(own.path))
      #expect(paths.contains(appendix.path))
      #expect(paths.contains(f.store.declarationURL.path))
      #expect(
        !paths.contains { $0.contains("agents-replay-") || $0.contains("agents-resolution-") })
    }
    #expect(try FileHash.folderHash(f.root) == before)
    _ = try UpdateOperations.withPreparedUpdate(
      UpdateRequest(operation: .declaration(declaration)), environment: f.environment
    ) {
      try $0.apply(ifUnchangedFrom: report.displayedFingerprint)
    }
    let inspected = try UpdateOperations.inspect(environment: f.environment)
    #expect(
      Set(inspected.readLocations.map(\.path)).isSuperset(of: [
        unused.path, own.path, appendix.path,
      ]))
    #expect(throws: (any Error).self) {
      try InstructionOperations.inspectChatGPTExport(prompt: "weekly", environment: f.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: appendix.path))
    try f.write("Live appendix", to: appendix)
    let current = try InstructionOperations.inspectChatGPTExport(
      prompt: "weekly", environment: f.environment)
    #expect(String(decoding: current.bytes, as: UTF8.self).contains("Live appendix"))
    #expect(current.readLocations.map(\.path).contains(appendix.path))
    let ownInspection = try InstructionOperations.inspectOwnInstructions(environment: f.environment)
    #expect(ownInspection.units.map(\.record.name) == ["own"])
    #expect(ownInspection.readLocations.map(\.path).contains(own.deletingLastPathComponent().path))
  }
}
