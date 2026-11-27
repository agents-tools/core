import AgentsManifest
import AgentsUpdates
import Foundation
import StateTestSupport
import Synchronization
import Testing

@testable import AgentsCore

@Suite("Producer patch export")
struct ProducerPatchTests {
  @Test func appliesReviewedBytesToTheExactRepositoryCommit() throws {
    let fixture = try UpdateFixture()
    let package = "nested pack"
    let skill = package + "/skills/demo"
    let path = "assets/café file.md"
    let source = fixture.repo.appendingPathComponent(skill)
    let header = "<!-- apm-build-id: producer-authored -->"
    let original = header + "\nold"
    let edited = header + "\n<!-- apm-build-id: consumer-authored -->\nnew"
    try fixture.write("# Notes\n", to: source.appendingPathComponent("notes.md"))
    try fixture.write(original, to: source.appendingPathComponent(path))
    try fixture.write("old\r\n", to: source.appendingPathComponent("crlf.md"))
    try fixture.write("old\n", to: source.appendingPathComponent("gone.md"))
    try fixture.write("old\n", to: source.appendingPathComponent("replaced.md"))
    try fixture.write("$Format:%H$\n", to: source.appendingPathComponent("archive.md"))
    try fixture.write(
      "archive.md export-subst\n", to: source.appendingPathComponent(".gitattributes"))
    try Data([0, 1, 2]).write(to: source.appendingPathComponent("binary"))
    try fixture.write(
      "---\nname: demo\ndescription: fixture\n---\n\nBody\n",
      to: source.appendingPathComponent("SKILL.md"))
    try fixture.write(
      "---\ndescription: fixture\n---\n# Rule\n\nText\n",
      to: fixture.repo.appendingPathComponent(package + "/instructions/rule.md"))
    try fixture.commit()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(fixture, ref: base, location: "https://producer.invalid/team/tool")
    var nested = remote
    nested.path = package
    let declaration = Declaration(
      sources: ["nested": nested],
      skills: ["nested": .init(select: .all, agents: [.codex, .claudeCode], mode: .copy)],
      instructions: .init(agents: [.codex], sections: ["nested:rule"]))
    try install(declaration, in: fixture)

    let target = fixture.target()
    try fixture.write(
      "\u{feff}" + edited.replacingOccurrences(of: "\n", with: "\r\n"),
      to: target.appendingPathComponent(path))
    try fixture.write(edited, to: fixture.target(.claudeCode).appendingPathComponent(path))
    try fixture.write("# New notes\n", to: target.appendingPathComponent("notes.md"))
    try fixture.write("new\n", to: target.appendingPathComponent("crlf.md"))
    try FileManager.default.removeItem(at: target.appendingPathComponent("gone.md"))
    let replaced = target.appendingPathComponent("replaced.md")
    try FileManager.default.removeItem(at: replaced)
    try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: source)
    try fixture.write("archive edit\n", to: target.appendingPathComponent("archive.md"))
    let instructions = String(decoding: try fixture.bytes(fixture.instruction()), as: UTF8.self)
    let markerEnd = try #require(instructions.firstIndex(of: "\n"))
    try fixture.write(
      "<!-- changed generated marker -->" + instructions[markerEnd...], to: fixture.instruction())
    let cache = SourceCache(store: fixture.store)
    let materialized = try cache.materializedURL(
      sourceID: remote.identity(environment: fixture.environment), revision: base)
    if FileManager.default.fileExists(atPath: materialized.path) {
      try FileManager.default.removeItem(at: materialized)
    }

    let baseline = try fixture.snapshot()
    let preview = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    let patch = try #require(preview.patches.first)
    #expect(preview.patches.count == 1)
    #expect(patch.producer.base == .git(commit: base))
    #expect(patch.producer.source == "producer.invalid/team/tool")
    #expect(patch.producer.root == package)
    #expect(patch.paths == [skill + "/" + path, skill + "/notes.md"])
    #expect(patch.content.contains("consumer-authored"))
    #expect(
      preview.skipped.contains { $0.path == fixture.instruction() && $0.reason == .transformed })
    #expect(
      preview.skipped.contains {
        $0.path == target.appendingPathComponent("archive.md") && $0.reason == .transformed
      })
    let reasons = Set(preview.skipped.map(\.reason))
    #expect(reasons == [.transformed, .uncleanSource, .deleted, .binary, .nonRegular])
    let defaultOutput = fixture.root.appendingPathComponent("patches")
    #expect(!FileManager.default.fileExists(atPath: defaultOutput.path))
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preview))
    let fields = try #require(encoded as? [String: Any])
    #expect(Set(fields.keys) == ["patches", "skipped"])

    // The local producer may move while the patch still names the reviewed commit.
    try fixture.advance()
    let checkout = fixture.root.appendingPathComponent("independent")
    try fixture.git([
      "clone", "--no-local", "--no-checkout", "--", fixture.repo.path, checkout.path,
    ])
    try git(["checkout", "--detach", base], at: checkout)
    let exported = try UpdateOperations.exportProducerPatches(preview)
    let output = try #require(exported.written.first)
    #expect(exported.directory?.path == defaultOutput.path)
    #expect(try fixture.bytes(output) == Data(patch.content.utf8))
    #expect(exported.failures.isEmpty)
    try git(["apply", "--check", "--", output.path], at: checkout)
    try git(["apply", "--", output.path], at: checkout)
    #expect(
      try fixture.bytes(checkout.appendingPathComponent(skill + "/" + path)) == Data(edited.utf8))
    #expect(
      try fixture.bytes(checkout.appendingPathComponent(skill + "/notes.md"))
        == Data("# New notes\n".utf8))
    #expect(try fixture.snapshot() == baseline)
    #expect(try git(["rev-parse", "HEAD"], at: checkout) == base)
  }

  @Test func comparesOverlappingPackagesBeforeChoosingAnOwner() throws {
    let fixture = try UpdateFixture()
    let package = "nested"
    let source = fixture.repo.appendingPathComponent(package + "/skills/shared/SKILL.md")
    let header = "---\nname: shared\ndescription: fixture\n---\n"
    try fixture.write(header + "base\n", to: source)
    try fixture.commit()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(
      fixture, ref: base, location: "https://producer.invalid/team/overlap")
    var nested = remote
    nested.path = package
    try install(
      Declaration(
        sources: ["root": remote, "nested": nested],
        groups: [
          .init(
            name: "outer",
            components: [
              .skills(
                source: "root",
                .init(select: .names(["shared"]), path: package, agents: [.codex], mode: .copy))
            ]),
          .init(
            name: "inner",
            components: [
              .skills(source: "nested", .init(select: .all, agents: [.claudeCode], mode: .copy))
            ]),
        ], uses: [.init(name: "outer"), .init(name: "inner")]),
      in: fixture)
    let codex = installed("shared", on: .codex, in: fixture)
    let claude = installed("shared", on: .claudeCode, in: fixture)
    try fixture.write(header + "new\n", to: codex)
    let oneEdit = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    #expect(oneEdit.patches.count == 1)
    try fixture.write(header + "different\n", to: claude)
    let conflict = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    #expect(conflict.patches.isEmpty)
    #expect(
      Set(conflict.skipped.filter { $0.reason == .conflictingEdits }.map(\.path)) == [
        codex, claude,
      ])
    let empty = try UpdateOperations.exportProducerPatches(conflict)
    #expect(empty.directory == nil)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("patches").path))

    try fixture.write(header + "new\n", to: claude)
    let agreed = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    let patch = try #require(agreed.patches.first)
    #expect(agreed.patches.count == 1)
    #expect(patch.producer.root == ".")
    #expect(patch.paths == [package + "/skills/shared/SKILL.md"])
    #expect(patch.selectors.contains { $0.contains(":outer:") })
    #expect(patch.selectors.contains { $0.contains(":inner:") })
    #expect(patch.content.components(separatedBy: "diff --git ").count == 2)
  }

  @Test func usesRecordedOpaqueAndGeneratedPluginResourcePlacements() throws {
    let fixture = try UpdateFixture()
    let manifest = ".claude-plugin/plugin.json"
    let resource = "skills/helper/SKILL.md"
    let skillHeader = "---\nname: helper\ndescription: Help\n---\n"
    for name in ["opaque", "composed"] {
      let tree = fixture.repo.appendingPathComponent("plugins/" + name)
      try fixture.write("{\"name\":\"\(name)\"}\n", to: tree.appendingPathComponent(manifest))
      try fixture.write(skillHeader + "Original\n", to: tree.appendingPathComponent(resource))
    }
    try fixture.commit()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(
      fixture, ref: base, location: "https://producer.invalid/team/plugins")
    try install(
      Declaration(
        sources: ["producer": remote],
        components: [
          .plugin(
            name: "opaque", path: "plugins/opaque", source: "producer", mode: .native,
            agents: [.claudeCode]),
          .plugin(
            name: "composed", path: "plugins/composed", source: "producer", agents: [.claudeCode]),
        ]), in: fixture)
    let state = try UpdateOperations.inspect(environment: fixture.environment)
    let opaque = try #require(state.deployments.first { $0.location.lastPathComponent == "opaque" })
    let composed = try #require(
      state.deployments.first { $0.location.lastPathComponent == "composed" })
    try fixture.write(
      skillHeader + "Edited\n", to: opaque.location.appendingPathComponent(resource))
    try fixture.write(
      skillHeader + "Edited\n", to: composed.location.appendingPathComponent(resource))
    try fixture.write(
      "changed generated output\n", to: composed.location.appendingPathComponent(manifest))
    let report = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    #expect(
      report.patches.flatMap(\.paths).sorted()
        == ["plugins/composed/" + resource, "plugins/opaque/" + resource])
    #expect(report.patches.allSatisfy { $0.producer.base == .git(commit: base) })
    #expect(
      report.skipped.contains {
        $0.path == composed.location.appendingPathComponent(manifest) && $0.reason == .transformed
      })
  }

  @Test func staleAfterSelectionAndPoliciesCannotWrite() throws {
    let fixture = try UpdateFixture()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(fixture, ref: base, location: "https://producer.invalid/team/tool")
    try install(single(remote), in: fixture)
    let copy = fixture.target().appendingPathComponent("run.sh")
    try fixture.write("first\n", to: copy)
    let first = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    let output = fixture.root.appendingPathComponent("selected")
    try fixture.write("second\n", to: copy)
    #expect(throws: ProducerPatchError.stale) {
      try UpdateOperations.exportProducerPatches(first, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    let fresh = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    #expect(fresh.patches.first?.content.contains("+second\n") == true)
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: fixture.environment)
    try fixture.write("version: 1\ndeny: [{git: producer.invalid/team/tool}]\n", to: policy)
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.exportProducerPatches(fresh, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    try FileManager.default.removeItem(at: policy)
    let organization = fixture.root.appendingPathComponent("organization.yaml")
    var environment = fixture.environment
    environment.projectOrganizationPolicy = .init(.local(organization))
    try fixture.write("enforcement: block\n", to: organization)
    let admitted = try UpdateOperations.previewProducerPatches(environment: environment)
    try fixture.write(
      "enforcement: block\nsources: {deny: [producer.invalid/team/tool]}\n", to: organization
    )
    let denial = try #require(throws: OrganizationPolicyFailure.self) {
      try UpdateOperations.exportProducerPatches(admitted, to: output)
    }
    #expect(denial.report.findings.contains { $0.rule == "source-deny" })
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func localOnlySkipsReplayButMissingRemoteInputsFail() throws {
    let local = try UpdateFixture()
    try local.install(agents: [.codex])
    try FileManager.default.removeItem(at: local.store.cacheDirectory)
    try FileManager.default.removeItem(at: local.repo)
    let preview = try UpdateOperations.previewProducerPatches(environment: local.environment)
    #expect(preview.patches.isEmpty)
    #expect(!preview.skipped.isEmpty)
    #expect(preview.skipped.allSatisfy { $0.reason == .locallyOwned })
    #expect(try UpdateOperations.exportProducerPatches(preview).directory == nil)

    let remote = try UpdateFixture()
    let base = try remote.git(["rev-parse", "HEAD"])
    let declaration = try seedMirror(
      remote, ref: base, location: "https://producer.invalid/team/tool")
    try install(single(declaration), in: remote)
    try FileManager.default.removeItem(at: remote.store.cacheDirectory)
    #expect(throws: ProducerPatchError.lockedInputUnavailable) {
      try UpdateOperations.previewProducerPatches(environment: remote.environment)
    }
  }

  @Test func pendingResolutionDoesNotInvalidateDeployedEdits() throws {
    let fixture = try UpdateFixture()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(fixture, ref: base, location: "https://producer.invalid/team/tool")
    try install(single(remote), in: fixture)
    try fixture.write("edited\n", to: fixture.target().appendingPathComponent("run.sh"))
    let preview = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    let before = try fixture.store.loadLedger()
    let catalog = try GraphCatalog()
    try catalog.publish("preview", "1.0.0")
    let pending = try MarketplaceOperations.previewLockOnly(
      .install(catalog.root("future", package: "preview")), environment: fixture.environment)
    try MarketplaceOperations.writeLockOnly(pending)
    let after = try fixture.store.loadLedger()
    #expect(after.pendingMarketplaceDeployment != nil)
    #expect(after.deployments == before.deployments)
    #expect(after.marketplaceGraph == before.marketplaceGraph)
    let lock = try fixture.bytes(fixture.store.resolvedURL)
    let result = try UpdateOperations.exportProducerPatches(preview)
    #expect(result.written.count == 1)
    #expect(try fixture.bytes(fixture.store.resolvedURL) == lock)
  }

  @Test func portableGitClaimsDoNotAttributeARepublishedPath() throws {
    let producer = try UpdateFixture()
    let base = try producer.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(producer, ref: base, location: "https://producer.invalid/team/tool")
    try install(single(remote), in: producer)
    let inspection = try UpdateOperations.inspect(environment: producer.environment)
    let selection = try #require(inspection.components.first?.selection)
    let archive = try BundleOperations.export(
      .init(name: "forwarded", version: "1.0.0"), selections: [selection], scope: .project,
      environment: producer.environment)
    let bundle = try BundleOperations.inspect(archive)
    let member = try #require(bundle.components.first)
    #expect(member.sources.contains { $0.kind == .git && $0.revision == base })
    #expect(member.sources.contains { $0.policyOrigin == .missing })

    let consumer = try UpdateFixture()
    let imported = try BundleOperations.previewImport(
      bundle, selections: [.init(componentID: member.id, targets: [.codex])],
      scope: .project, environment: consumer.environment)
    _ = try BundleOperations.withPreparedImport(imported) { try $0.apply() }
    var declaration = try consumer.store.loadDeclaration()
    let alias = try #require(declaration.sourceDeclarations.first?.name)
    declaration.components.append(
      .skills(
        source: alias,
        .init(
          select: .names(["demo"]), path: "payload/skills/demo", agents: [.claudeCode], mode: .copy)
      ))
    _ = try UpdateOperations.withPreparedUpdate(
      .init(operation: .declaration(declaration)), environment: consumer.environment
    ) { try $0.apply() }
    let copy = consumer.target(.claudeCode)
    try consumer.write("edited\n", to: copy.appendingPathComponent("run.sh"))
    let report = try UpdateOperations.previewProducerPatches(environment: consumer.environment)
    #expect(report.patches.isEmpty)
    let copyReasons = report.skipped.filter { $0.path == copy }.map(\.reason)
    #expect(copyReasons == [.missingPathAttribution])
    #expect(
      report.skipped.contains { $0.path == consumer.target() && $0.reason == .linkedDeployment })
  }

  @Test func detectsEditAndDirectoryReplacementDuringPublication() throws {
    let fixture = try UpdateFixture(scope: .user)
    let base = try fixture.git(["rev-parse", "HEAD"])
    let remote = try seedMirror(fixture, ref: base, location: "https://producer.invalid/team/tool")
    try install(single(remote), in: fixture)
    let copy = fixture.target().appendingPathComponent("run.sh")
    try fixture.write("first edit\n", to: copy)
    let preview = try UpdateOperations.previewProducerPatches(
      scope: .user, environment: fixture.environment)
    let output = fixture.root.appendingPathComponent("missing/selected")
    let parent = fixture.root
    let observeEdit = onStaging(in: parent) {
      try Data("second edit\n".utf8).write(to: copy)
    }
    #expect(throws: ProducerPatchError.stale) {
      try DirectoryHandle.$synchronizationObserver.withValue(observeEdit) {
        try UpdateOperations.exportProducerPatches(preview, to: output)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("missing").path))
    #expect(
      try !FileManager.default.contentsOfDirectory(atPath: parent.path).contains {
        $0.hasPrefix(".stage-")
      })

    let current = try UpdateOperations.previewProducerPatches(
      scope: .user, environment: fixture.environment)
    let selection = fixture.root.appendingPathComponent("existing")
    let moved = fixture.root.appendingPathComponent("moved")
    let elsewhere = fixture.root.appendingPathComponent("elsewhere")
    for directory in [selection, elsewhere] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let swap = onStaging(in: selection) {
      try FileManager.default.moveItem(at: selection, to: moved)
      try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: elsewhere)
    }
    let result = try DirectoryHandle.$synchronizationObserver.withValue(swap) {
      try UpdateOperations.exportProducerPatches(current, to: selection)
    }
    #expect(result.written.isEmpty)
    #expect(result.failures.map(\.reason) == [.destinationChanged])
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
  }

  @Test func publicationKeepsCompetitorsAndSafeRetriesReusePriorFiles() throws {
    let fixture = try UpdateFixture()
    let base = try fixture.git(["rev-parse", "HEAD"])
    let one = try seedMirror(fixture, ref: base, location: "https://one.invalid/team/tool")
    let two = try seedMirror(fixture, ref: base, location: "https://two.invalid/team/tool")
    try install(
      Declaration(
        sources: [
          "one": one, "two": two, "local": .init(kind: .local, location: fixture.repo.path),
        ],
        skills: [
          "one": .init(select: .all, agents: [.codex], mode: .copy),
          "two": .init(select: .all, agents: [.claudeCode], mode: .copy),
        ]), in: fixture)
    for agent in [AgentID.codex, .claudeCode] {
      try fixture.write(
        agent.rawValue + "\n", to: fixture.target(agent).appendingPathComponent("run.sh"))
    }
    let preview = try UpdateOperations.previewProducerPatches(environment: fixture.environment)
    try #require(preview.patches.count == 2)
    #expect(Set(preview.patches.map(\.filename)).count == 2)
    #expect(preview.patches.allSatisfy { $0.filename.hasPrefix("tool@" + base.prefix(12)) })

    let selection = fixture.root.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: false)
    let first = selection.appendingPathComponent(preview.patches[0].filename)
    let competing = selection.appendingPathComponent(preview.patches[1].filename)
    let unrelated = fixture.repo.appendingPathComponent("outside")
    try fixture.write("competing bytes", to: unrelated)
    let observer = onStaging(in: selection, after: first) {
      try FileManager.default.createSymbolicLink(at: competing, withDestinationURL: unrelated)
    }
    let partial = try DirectoryHandle.$synchronizationObserver.withValue(observer) {
      try UpdateOperations.exportProducerPatches(preview, to: selection)
    }
    #expect(partial.written == [first])
    #expect(partial.failures.map(\.reason) == [.occupied])
    #expect(try fixture.bytes(unrelated) == Data("competing bytes".utf8))
    let retry = try UpdateOperations.exportProducerPatches(preview, to: selection)
    #expect(retry.reused == [first])
    #expect(retry.failures.map(\.file) == [competing])
    try FileManager.default.removeItem(at: competing)
    let complete = try UpdateOperations.exportProducerPatches(preview, to: selection)
    #expect(complete.reused == [first])
    #expect(complete.written == [competing])

    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: fixture.store.cacheDirectory)
    for path in [fixture.store.cacheDirectory, fixture.target(), fixture.repo, alias] {
      #expect(throws: ProducerPatchError.unsafeDestination(path)) {
        try UpdateOperations.exportProducerPatches(preview, to: path)
      }
    }
  }

  private func onStaging(
    in directory: URL, after previous: URL? = nil, _ action: @escaping @Sendable () throws -> Void
  ) -> DirectoryHandle.SynchronizationObserver {
    let injected = Mutex(false)
    return .init {
      guard previous.map({ FileManager.default.fileExists(atPath: $0.path) }) != false,
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains(
          where: { $0.hasPrefix(".stage-") }) == true
      else { return }
      injected.withLock { didInject in
        guard !didInject else { return }
        didInject = true
        do { try action() } catch { Issue.record(error) }
      }
    }
  }

  private func seedMirror(_ fixture: UpdateFixture, ref: String, location: String) throws
    -> SourceDeclaration
  {
    let source = SourceDeclaration(kind: .git, location: location, requirement: .revision(ref))
    let cache = SourceCache(store: fixture.store)
    let mirror = try cache.mirrorURL(sourceID: source.identity(environment: fixture.environment))
    try FileManager.default.createDirectory(
      at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.git(["clone", "--mirror", "--no-local", "--", fixture.repo.path, mirror.path])
    try git(["config", "remote.origin.url", source.gitURL], at: mirror)
    try git(["config", "maintenance.auto", "false"], at: mirror)
    try git(["config", "gc.auto", "0"], at: mirror)
    let lock = fixture.store.cacheDirectory.appendingPathComponent("locks")
      .appendingPathComponent(mirror.deletingPathExtension().lastPathComponent + ".lock")
    try FileLock.withLock(at: lock) {}
    return source
  }

  private func single(_ source: SourceDeclaration) -> Declaration {
    Declaration(
      sources: ["fixture": source],
      skills: ["fixture": .init(select: .all, agents: [.codex], mode: .copy)])
  }

  private func install(_ declaration: Declaration, in fixture: UpdateFixture) throws {
    try fixture.store.save(declaration: declaration, ledger: ResolvedLedger())
    _ = try fixture.apply()
  }

  private func installed(_ name: String, on agent: AgentID, in fixture: UpdateFixture) -> URL {
    AgentRegistry.installSkillsDirectory(
      for: agent, scope: .project, environment: fixture.environment
    )
    .appendingPathComponent(name + "/SKILL.md")
  }

  @discardableResult
  private func git(_ arguments: [String], at directory: URL) throws -> String {
    try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", directory.path] + arguments)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
