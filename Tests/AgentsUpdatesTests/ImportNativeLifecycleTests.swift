import AgentsCore
import AgentsUpdates
import Foundation
import Testing

struct ImportNativeLifecycleTests {
  @Test(arguments: [AgentID.claudeCode, .cursor, .geminiCLI], [false, true])
  func standaloneNativeSkillRetainsContainerSupportThroughColdRestore(
    _ agent: AgentID, _ atInputRoot: Bool
  ) throws {
    let f = try UpdateFixture()
    let input = f.root.appendingPathComponent("producer")
    let prefix = atInputRoot ? "" : "bundle/"
    let container = atInputRoot ? input : input.appendingPathComponent("bundle")
    let format: String
    let suffix: String
    switch agent {
    case .claudeCode:
      format = "claudePluginV1"
      suffix = ".claude-plugin/plugin.json"
    case .cursor:
      format = "cursorPluginV1"
      suffix = ".cursor-plugin/plugin.json"
    default:
      format = "geminiExtensionV1"
      suffix = "gemini-extension.json"
    }
    try f.write(
      #"{"name":"producer","version":"1.2.3"}"#, to: container.appendingPathComponent(suffix))
    let body = "---\nname: helper\ndescription: Helper\n---\nFrozen helper\n"
    try f.write(body, to: container.appendingPathComponent("skills/helper/SKILL.md"))
    try f.write("Frozen support\n", to: container.appendingPathComponent("shared/tool.txt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: container.appendingPathComponent("shared/tool.txt").path)
    try FileManager.default.createSymbolicLink(
      atPath: container.appendingPathComponent("skills/helper/reference.txt").path,
      withDestinationPath: "../../shared/tool.txt")
    try f.write(
      "---\nname: helper\ndescription: Hidden\n---\nHidden support skill\n",
      to: container.appendingPathComponent("shared/extras/SKILL.md"))
    try FileManager.default.createSymbolicLink(
      atPath: container.appendingPathComponent("skills/helper/data").path,
      withDestinationPath: "../../shared/extras")
    try f.write(
      "---\nname: helper\ndescription: Sibling\n---\nUnselected sibling\n",
      to: container.appendingPathComponent("other/SKILL.md"))
    try f.write(
      "---\nname: second\ndescription: Second\n---\nSelected second\n",
      to: container.appendingPathComponent("skills/second/SKILL.md"))
    let report = try SourceImportOperations.inspect(
      format: format, root: input, document: prefix + suffix)
    #expect(report.diagnostics.isEmpty)
    #expect(report.components.count == 2)
    #expect(report.sources.count == 1)
    let skillSource = try #require(report.sources.first { $0.alias == "native-input" })
    #expect(skillSource.declaration?.location == (atInputRoot ? "." : "bundle"))
    #expect(skillSource.declaration?.path == nil)
    let helper = try #require(
      report.components.first {
        if case .skills(_, let selection) = $0.declaration {
          return selection.path == "skills/helper"
        }
        return false
      })
    guard case .skills(let alias, let selection) = helper.declaration else {
      Issue.record("Expected selected native skill")
      return
    }
    #expect(alias == "native-input" && selection.path == "skills/helper")
    let scope = try UpdateOperations.inspect(environment: f.environment)
    let originalRequest = try report.updateRequest(in: scope)
    try f.write("Refreshed support\n", to: container.appendingPathComponent("shared/tool.txt"))
    #expect(throws: (any Error).self) {
      try UpdateOperations.withPreparedUpdate(originalRequest, environment: f.environment) { _ in
        Issue.record("Changed linked support must reject the original request")
      }
    }
    let refreshed = try SourceImportOperations.inspect(
      format: format, root: input, document: prefix + suffix)
    let request = try refreshed.updateRequest(in: scope)
    let preview = try UpdateOperations.preview(request, environment: f.environment)
    _ = try UpdateOperations.withPreparedUpdate(request, environment: f.environment) {
      #expect($0.report.displayedFingerprint == preview.displayedFingerprint)
      return try $0.apply(ifUnchangedFrom: preview.displayedFingerprint)
    }
    let installed = try UpdateOperations.inspect(environment: f.environment)
    #expect(Set(installed.components.compactMap(\.name)) == ["helper", "second"])
    #expect(installed.deployments.allSatisfy { $0.status == .current })
    let tree = try #require(
      installed.deployments.first { $0.location.lastPathComponent == "helper" }?.location)
    func verify() throws {
      #expect(
        try String(contentsOf: tree.appendingPathComponent("SKILL.md"), encoding: .utf8) == body)
      #expect(
        try String(contentsOf: tree.appendingPathComponent("reference.txt"), encoding: .utf8)
          == "Refreshed support\n")
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: tree.appendingPathComponent("reference.txt").path) == "../../shared/tool.txt")
      let support = tree.appendingPathComponent("reference.txt").resolvingSymlinksInPath()
      let mode =
        try FileManager.default.attributesOfItem(atPath: support.path)[.posixPermissions]
        as? NSNumber
      #expect((mode?.intValue ?? 0) & 0o777 == 0o755)
      #expect(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: tree.appendingPathComponent("data").path) == "../../shared/extras")
      #expect(
        try String(contentsOf: tree.appendingPathComponent("data/SKILL.md"), encoding: .utf8)
          .contains("Hidden support skill"))
    }
    try verify()
    try FileManager.default.removeItem(at: input)
    for target in Set(installed.deployments.map(\.location)) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.removeItem(at: f.store.cacheDirectory)
    _ = try UpdateOperations.restore(environment: f.environment)
    try verify()
    let restored = try UpdateOperations.inspect(environment: f.environment)
    #expect(Set(restored.components.compactMap(\.name)) == ["helper", "second"])
    #expect(restored.deployments.allSatisfy { $0.status == .current })
  }
}
