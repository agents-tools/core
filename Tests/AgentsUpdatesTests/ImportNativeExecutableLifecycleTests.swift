import AgentsCore
import AgentsUpdates
import Components
import Foundation
import Testing

struct ImportNativeExecutableLifecycleTests {
  @Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
  func nativeContainerExecutableUsesItsDeclaredInputRoot(
    _ linked: Bool, _ configuration: (Bool, Bool)
  ) throws {
    let (rootBasename, gemini) = configuration
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("producer")
    let executable = rootBasename ? "server" : "bin/server"
    let document = gemini ? "gemini-extension.json" : ".claude-plugin/plugin.json"
    let prefix = gemini ? "${extensionPath}/" : "${CLAUDE_PLUGIN_ROOT}/"
    let cwd = gemini ? ",\"cwd\":\"./cwd\"" : ""
    try f.write(
      "{\"name\":\"producer\",\"version\":\"1.2.3\",\"mcpServers\":{\"review\":{\"command\":\""
        + prefix + executable + "\"" + cwd + "}}}",
      to: input.appendingPathComponent("bundle/" + document))
    if gemini {
      try f.write(
        "Working directory support", to: input.appendingPathComponent("bundle/cwd/config.txt"))
    }
    let program = linked ? "shared/server" : executable
    try f.write("Frozen executable bytes\n", to: input.appendingPathComponent("bundle/" + program))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: input.appendingPathComponent("bundle/" + program).path)
    if linked {
      try FileManager.default.createDirectory(
        at: input.appendingPathComponent("bundle/bin"), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: input.appendingPathComponent("bundle/" + executable).path,
        withDestinationPath: rootBasename ? "shared/server" : "../shared/server")
    }
    let report = try SourceImportOperations.inspect(
      format: gemini ? "geminiExtensionV1" : "claudePluginV1", root: input,
      document: "bundle/" + document)
    #expect(report.diagnostics.isEmpty)
    #expect(report.sources.first?.declaration?.location == "bundle")
    #expect(
      report.resources.contains { $0.path == executable && $0.sourceAlias == "native-input" })
    guard case .mcpServer(_, .stdio(let run), _, _, _, _) = report.components.first?.declaration
    else {
      Issue.record("Expected native MCP executable")
      return
    }
    #expect(run.executable == (rootBasename ? "./server" : "bin/server"))
    #expect(run.executableSource == "native-input")
    let request = try report.updateRequest(in: UpdateOperations.inspect(environment: f.environment))
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      #expect($0.report.displayedFingerprint == preview.displayedFingerprint)
      return try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    func verify() throws {
      let installed = try UpdateOperations.inspect(environment: f.environment)
      #expect(installed.deployments.allSatisfy { $0.status == .current })
      let component = try #require(installed.components.first { $0.kind == .mcpServer })
      let ledger = try f.store.readLedger()
      let record = try #require(ledger.components.values.first { $0.kind == "mcpServer" })
      try LedgerReplay.withLockedResources(
        ledger, store: f.store, roots: f.store.ledgerRoots, limits: .standard
      ) { _, resources, _ in
        let programID = try #require(record.resources.first)
        let program = try #require(resources[programID])
        #expect(try String(contentsOf: program, encoding: .utf8) == "Frozen executable bytes\n")
        let mode =
          try FileManager.default.attributesOfItem(atPath: program.resolvingSymlinksInPath().path)[
            .posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0) & 0o777 == 0o755)
        if linked {
          #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: program.path)
              == (rootBasename ? "shared/server" : "../shared/server"))
        }
        if gemini {
          #expect(record.resources.count == 2)
          let directory = try #require(resources[record.resources[1]])
          #expect(
            try String(contentsOf: directory.appendingPathComponent("config.txt"), encoding: .utf8)
              == "Working directory support")
        }
      }
      let snapshot = try MCPConnectionOperations.snapshot(
        selection: component.selection, scope: .project, environment: f.environment)
      let description = MCPConnectionOperations.describe(snapshot)
      #expect(description.executableIsCaptured)
      #expect(description.executable == executable)
      #expect(description.workingDirectoryIsCaptured == gemini)
      if gemini { #expect(description.workingDirectory == "cwd") }
    }
    try verify()
    let installed = try UpdateOperations.inspect(environment: f.environment)
    try FileManager.default.removeItem(at: input)
    for target in Set(installed.deployments.map(\.location)) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.removeItem(at: f.store.cacheDirectory)
    _ = try UpdateOperations.restore(environment: f.environment)
    try verify()
  }
  @Test func sourceQualifiedAmbientCommandCannotProduceSnapshot() throws {
    let f = try UpdateFixture()
    #expect(throws: MCPConnectionPreparationError.self) {
      try MCPConnectionOperations.snapshot(
        selectionID: "qualified",
        transport: .stdio(.init(executable: "tool", executableSource: "producer")),
        workingDirectory: .live(f.root))
    }
  }

}
