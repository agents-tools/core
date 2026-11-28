import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Use Existing Configuration")
struct ExistingGlobalConfigurationTests {
  @Test func recognitionAndCancellationNeedNoWrites() throws {
    let f = try UpdateFixture(scope: .user)
    let empty = try FileHash.folderHash(f.environment.homeDirectory)
    #expect(try !ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    #expect(try FileHash.folderHash(f.environment.homeDirectory) == empty)
    let json = try #require(f.store.configurationJSONURL)
    try f.write("{}", to: json)
    #expect(try !ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    try ResolvedLedgerCodec.encode(ResolvedLedger(), limits: .standard).write(
      to: f.store.resolvedURL)
    #expect(try !ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    try StateStore.encodeState(ResolvedState()).write(to: f.store.resolvedURL)
    let before = try FileHash.folderHash(f.environment.homeDirectory)
    #expect(try ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    let cancelled = try ExistingGlobalConfiguration.preview(environment: f.environment)
    #expect(cancelled.skillCount == 0)
    #expect(cancelled.declarationURL == f.store.declarationURL)
    #expect(try FileHash.folderHash(f.environment.homeDirectory) == before)
    #expect(!FileManager.default.fileExists(atPath: cancelled.originalLedgerURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: f.store.directory.appendingPathComponent(".agents.lock").path))
  }

  @Test func importsIndependentPinsAndInspectsActualNativeInstalls() throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let before = try f.snapshot()
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    #expect(preview.sourceCount == 2)
    #expect(preview.skillCount == 2)
    #expect(preview.installationCount == 2)
    #expect(preview.instructionCount == 2)
    #expect(preview.originalLedgerURL.lastPathComponent == "agents.resolved.original")
    #expect(try f.snapshot() == before)
    try ExistingGlobalConfiguration.apply(preview)
    #expect(try f.bytes(input.json) == input.declarationBytes)
    #expect(try f.bytes(preview.originalLedgerURL) == input.lockBytes)
    #expect(try f.bytes(f.store.watchURL) == input.watchBytes)
    #expect(try !ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    let declaration = try f.store.loadDeclaration()
    #expect(declaration.agents == [.codex, .claudeCode])
    #expect(try declaration.skills?["fixture"]?.select == .all)
    #expect(try declaration.skills?["fixture"]?.exclude == ["excluded"])
    let override = try #require(try declaration.skills?["fixture"]?.overrides?["demo"])
    #expect(override.mode == .link)
    #expect(override.agents == [.codex, .geminiCLI, .claudeCode])
    #expect(try declaration.instructions?.sections == ["fixture:rules"])
    #expect(try declaration.instructions?.chatgpt?["weekly"]?.append == "custom.md")
    #expect(try declaration.skills?["live"]?.select == .names(["edit-demo", "uninstalled"]))
    #expect(declaration.watch == ["fixture"])
    #expect(try f.store.loadResolved().normalized == input.expected.normalized)
    let snapshot = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(snapshot.readLocations.contains(input.json))
    #expect(
      snapshot.components.first { $0.kind == .skills && $0.name == "demo" }?.version == "1.2.0")
    #expect(snapshot.components.first { $0.kind == .instructions }?.version == "1.3.0")
    let skills = snapshot.deployments.filter { $0.format == "agents/skill@1" }
    #expect(skills.filter { $0.status == .current }.count == 3)
    #expect(skills.filter { $0.status == .missing }.count == 1)
    #expect(snapshot.deployments.first { $0.format == "agents/instructions@1" }?.status == .drifted)
    #expect(
      snapshot.deployments.first { $0.format == "agents/claude-import@1" }?.status == .current)
    #expect(try f.bytes(f.instruction()) == Data("Edited outside agents.\n".utf8))
    let statePaths = [f.store.declarationURL.path, f.store.resolvedURL.path]
    #expect(
      try f.snapshot().filter { !statePaths.contains($0.key) }
        == before.filter { !statePaths.contains($0.key) })
  }

  @Test(arguments: [true, false])
  func importedArtifactUsesItsRetainedLocation(_ includeRemote: Bool) throws {
    let f = try UpdateFixture(scope: .user)
    let cache = SourceCache(store: f.store)
    let pin = try f.git(["rev-parse", "HEAD"])
    let remote = "example.invalid/remote"
    let gitTree = cache.materializedURL(sourceID: remote, revision: pin)
    let remoteSkill = gitTree.appendingPathComponent("skills/demo")
    let content = try f.bytes(f.repo.appendingPathComponent("skills/demo/SKILL.md"))
    try f.write(
      String(decoding: content, as: UTF8.self), to: remoteSkill.appendingPathComponent("SKILL.md"))
    let artifactBytes = Data(
      "---\nname: index-demo\ndescription: Index fixture\n---\n\nBody\n".utf8)
    let index = "https://index.example.invalid"
    let artifact = LockedArtifact(
      type: .skillMD, url: index + "/demo/SKILL.md",
      digest: "sha256:" + FileHash.sha256Hex(data: artifactBytes))
    let artifactTree = try cache.artifactContentURL(digest: artifact.digest)
    try f.write(
      String(decoding: artifactBytes, as: UTF8.self),
      to: artifactTree.appendingPathComponent("SKILL.md"))
    try FileManager.default.createDirectory(
      at: f.target().deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: f.target(), withDestinationURL: remoteSkill.resolvingSymlinksInPath())
    let artifactInstall = f.target().deletingLastPathComponent().appendingPathComponent(
      "index-demo")
    try FileManager.default.createSymbolicLink(
      at: artifactInstall, withDestinationURL: artifactTree)
    let artifactLink = try PathIdentity(artifactInstall)
    var lock = ResolvedState(
      sources: [
        remote: .init(kind: .git, url: "https://" + remote),
        index: .init(kind: .wellKnown),
      ],
      skills: [
        "demo": .init(
          source: remote, revision: pin, path: "skills/demo",
          hash: try "sha256:" + FileHash.folderHash(remoteSkill), installs: ["codex": .link]),
        "index-demo": .init(
          source: index, artifact: artifact,
          hash: try "sha256:" + FileHash.folderHash(artifactTree), installs: ["codex": .link]),
      ])
    if !includeRemote {
      try FileManager.default.removeItem(at: f.target())
      try FileManager.default.removeItem(at: gitTree)
      lock.sources.removeValue(forKey: remote)
      lock.skills.removeValue(forKey: "demo")
    }
    let remoteSource = includeRemote ? "\"remote\":{\"git\":\"https://\(remote)\"}," : ""
    let remoteSelection = includeRemote ? "\"remote\":{\"select\":[\"demo\"]}," : ""
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"agents":["codex"],"sources":{\(remoteSource)"index":{"well-known":"\(index)"}},
       "skills":{\(remoteSelection)"index":{"select":["index-demo"],"mode":"link"}}}
      """, to: json)
    try StateStore.encodeState(lock).write(to: f.store.resolvedURL)
    let cacheHash = try FileHash.folderHash(f.store.cacheDirectory)
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    #expect(preview.installationCount == lock.skills.count)
    try ExistingGlobalConfiguration.apply(preview)
    #expect(try f.store.loadResolved().normalized == lock.normalized)
    #expect(try FileHash.folderHash(f.store.cacheDirectory) == cacheHash)
    let inventory = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(
      inventory.deployments.map(\.status) == Array(repeating: .current, count: lock.skills.count))
    #expect(
      inventory.resources.first { $0.kind == "artifact" }?.location?.path == artifactTree.path)
    let restore = UpdateRequest(operation: .restore, kinds: [.skills])
    let report = try UpdateOperations.preview(restore, scope: .user, environment: f.environment)
    try #require(!report.hasChanges)
    _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
    try artifactLink.validate()
    #expect(try FileHash.folderHash(f.store.cacheDirectory) == cacheHash)

    if !includeRemote {
      let declaration = try f.store.loadDeclaration()
      _ = try UpdateOperations.withPreparedUpdate(
        UpdateRequest(operation: .declaration(declaration)), scope: .user,
        environment: f.environment
      ) { try $0.apply() }
      try artifactLink.validate()
      let reapplied = try UpdateOperations.inspect(scope: .user, environment: f.environment)
      #expect(reapplied.resources.first?.location?.path == artifactTree.path)

      try FileManager.default.removeItem(at: artifactTree)
      _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
      try artifactLink.validate()
      #expect(try f.bytes(artifactTree.appendingPathComponent("SKILL.md")) == artifactBytes)
      let restored = try UpdateOperations.inspect(scope: .user, environment: f.environment)
      #expect(restored.resources.first?.location?.path == artifactTree.path)
      #expect(restored.deployments.map(\.status) == [.current])

      var invalid = try f.store.loadLedger()
      let id = try #require(invalid.resources.first { $0.value.kind == .artifact }?.key)
      invalid.resources[id]?.location = .init(kind: .registered, root: "state", path: "cache/other")
      #expect(throws: CoreError.self) {
        _ = try ResolvedLedgerCodec.encode(invalid, limits: .standard)
      }
    }
  }

  @Test func importsAndInspectsLargeLiveEditSourceWithoutReplacingTheLink() throws {
    let f = try UpdateFixture(scope: .user)
    let directory = f.repo.appendingPathComponent("skills/demo").resolvingSymlinksInPath()
    let blob = directory.appendingPathComponent("references/blob")
    try f.write("", to: blob)
    let length = UInt64(max(180 * 1024 * 1024, LedgerLimits.standard.resourceBytes)) + 1
    do {
      let handle = try FileHandle(forWritingTo: blob)
      defer { try? handle.close() }
      try handle.truncate(atOffset: length)
    }
    try FileManager.default.createDirectory(
      at: f.target().deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.target(), withDestinationURL: directory)
    let targetIdentity = try PathIdentity(f.target())
    let sourceIdentity = "local:" + f.repo.path
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"sources":{"fixture":{"local":"\(f.repo.path)"}},
       "skills":{"fixture":{"select":["demo"],"agents":["codex"],"mode":"edit"}}}
      """, to: json)
    let saved = ResolvedState(
      sources: [sourceIdentity: .init(kind: .local)],
      skills: [
        "demo": .init(source: sourceIdentity, path: "skills/demo", installs: ["codex": .edit])
      ])
    let lockBytes = try StateStore.encodeState(saved)
    try lockBytes.write(to: f.store.resolvedURL)

    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    #expect(preview.skillCount == 1)
    #expect(preview.installationCount == 1)
    try ExistingGlobalConfiguration.apply(preview)
    try targetIdentity.validate()
    #expect(try f.bytes(preview.originalLedgerURL) == lockBytes)
    #expect(try f.store.loadResolved() == saved)

    let snapshot = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(snapshot.components.map(\.name) == ["demo"])
    #expect(snapshot.deployments.map(\.status) == [.current])
    let resource = try #require(snapshot.resources.first)
    #expect(resource.kind == "liveEdit")
    #expect(resource.location?.resolvingSymlinksInPath().path == directory.path)
    #expect(resource.entries.isEmpty)
    #expect(snapshot.readLocations.contains { $0.resolvingSymlinksInPath().path == directory.path })
    let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
    #expect((attributes[.size] as? NSNumber)?.uint64Value == length)
  }

  @Test(arguments: ["declaration", "native", "cache", "edit-source", "edit-link", "backup", "yaml"])
  func confirmationRejectsStaleEvidence(_ changed: String) throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    switch changed {
    case "declaration": try f.write("{}\n", to: input.json)
    case "native": try f.write("New native bytes\n", to: f.instruction())
    case "cache":
      try f.write(
        "Pinned resource changed\n", to: input.pinnedSkill.appendingPathComponent("run.sh"))
    case "edit-source":
      try f.write(
        "New reference data\n", to: f.root.appendingPathComponent("live/edit-demo/references.txt"))
    case "edit-link":
      let link = f.target().deletingLastPathComponent().appendingPathComponent("edit-demo")
      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.repo)
    case "backup": try f.write("Retained lock copy\n", to: preview.originalLedgerURL)
    default: try f.write("version: 1\n", to: f.store.declarationURL)
    }
    let before = try FileHash.folderHash(f.environment.homeDirectory)
    #expect(throws: ExistingGlobalConfigurationError.self) {
      try ExistingGlobalConfiguration.apply(preview)
    }
    let after = try FileManager.default.contentsOfDirectory(atPath: f.store.directory.path)
    #expect(!after.contains("transaction.json"))
    #expect(try f.bytes(f.store.resolvedURL) == input.lockBytes)
    #expect(try FileHash.folderHash(f.environment.homeDirectory) == before)
    if changed == "backup" {
      #expect(try f.bytes(preview.originalLedgerURL) == Data("Retained lock copy\n".utf8))
    }
  }

  @Test func aChangedSkillIsAnExplicitConflict() throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let changed = f.target(.claudeCode)
    try f.write("Unrelated directory\n", to: changed.appendingPathComponent("SKILL.md"))
    #expect(try ExistingGlobalConfiguration.isAvailable(environment: f.environment))
    do {
      _ = try ExistingGlobalConfiguration.preview(environment: f.environment)
      Issue.record("Imported a skill path with unrelated contents")
    } catch let error as ExistingGlobalConfigurationError {
      #expect(error.localizedDescription.contains(changed.path))
      #expect(error.localizedDescription.contains("move the changed entry aside"))
    }
    #expect(try f.bytes(f.store.resolvedURL) == input.lockBytes)
  }

  @Test func pendingOperationTakesPriorityOverRecognitionAndPreview() throws {
    let f = try UpdateFixture(scope: .user)
    try f.write("{}", to: f.store.directory.appendingPathComponent("transaction.json"))
    for operation in [
      { _ = try ExistingGlobalConfiguration.isAvailable(environment: f.environment) },
      { _ = try ExistingGlobalConfiguration.preview(environment: f.environment) },
    ] {
      do {
        try operation()
        Issue.record("Inspected a scope with a pending operation")
      } catch let error as ExistingGlobalConfigurationError {
        guard case .recovery = error else {
          Issue.record(error)
          continue
        }
        #expect(error.localizedDescription.contains("Finish it in the tool that started it"))
      }
    }
    #expect(
      try f.bytes(f.store.directory.appendingPathComponent("transaction.json")) == Data("{}".utf8))
  }

  @Test(arguments: [false, true])
  func retargetedInstallationRootInvalidatesConfirmation(_ duringPublication: Bool) throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let parent = f.target().deletingLastPathComponent()
    let inspected = f.store.directory.appendingPathComponent("inspected-skills")
    let other = f.store.directory.appendingPathComponent("other-skills")
    try FileManager.default.moveItem(at: parent, to: inspected)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: inspected)
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    let nativeBefore = try FileHash.folderHash(inspected)
    func redirect() throws {
      try FileManager.default.removeItem(at: parent)
      try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
    }
    if !duringPublication { try redirect() }

    #expect(throws: ExistingGlobalConfigurationError.self) {
      try ExistingGlobalConfiguration.apply(preview) { checkpoint in
        if duringPublication, checkpoint == TransactionCheckpoint.progress(2, .applied).name {
          try redirect()
        }
      }
    }
    #expect(try FileHash.folderHash(inspected) == nativeBefore)
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    try expectUnapplied(preview, ledger: input.lockBytes, fixture: f)
  }

  @Test func staleConfirmationLeavesPendingNativeRecoveryForItsOwner() throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    try ExistingGlobalConfiguration.apply(preview)
    let native = f.target().deletingLastPathComponent().appendingPathComponent("target/SKILL.md")
    try f.write("installed content\n", to: native)
    try f.write("partly published content\n", to: f.root.appendingPathComponent("new/SKILL.md"))
    let child = try launch(
      f, command: "inspection-transaction",
      argument: TransactionCheckpoint.progress(0, .applied).name)
    defer { terminate(child) }
    try waitFor("ready", fixture: f, child: child)
    terminate(child)

    let journal = f.store.directory.appendingPathComponent("transaction.json")
    let pending = try f.bytes(journal)
    #expect(try f.bytes(native) == Data("partly published content\n".utf8))
    do {
      try ExistingGlobalConfiguration.apply(preview)
      Issue.record("Confirmed configuration during native recovery")
    } catch let error as ExistingGlobalConfigurationError {
      guard case .recovery = error else {
        Issue.record(error)
        return
      }
    }
    #expect(try f.bytes(journal) == pending)
    #expect(try f.bytes(native) == Data("partly published content\n".utf8))
    #expect(throws: CoreError.transactionRecovered(f.store.directory.path)) {
      try f.store.withLock {}
    }
    #expect(try f.bytes(native) == Data("installed content\n".utf8))
  }

  @Test(arguments: [
    TransactionCheckpoint.preconditions.name, TransactionCheckpoint.progress(2, .applied).name,
  ])
  func lostOfflinePinAbortsConfirmation(_ point: String) throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    let displaced = f.root.appendingPathComponent("displaced-source")
    #expect(throws: ExistingGlobalConfigurationError.self) {
      try ExistingGlobalConfiguration.apply(preview) { checkpoint in
        if checkpoint == point { try FileManager.default.moveItem(at: f.repo, to: displaced) }
      }
    }
    #expect(FileManager.default.fileExists(atPath: displaced.path))
    try expectUnapplied(preview, ledger: input.lockBytes, fixture: f)
  }

  @Test(arguments: ["\"team\"", "null"])
  func rejectsUnsupportedSkillSelectionPath(_ path: String) throws {
    let f = try UpdateFixture(scope: .user)
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"sources":{"team":{"git":"example.invalid/team","path":"skills"}},
       "skills":{"team":{"select":"all","path":\(path)}}}
      """, to: json)
    try StateStore.encodeState(ResolvedState()).write(to: f.store.resolvedURL)
    do {
      _ = try ExistingGlobalConfiguration.preview(environment: f.environment)
      Issue.record("Accepted an unsupported skill selection path")
    } catch let error as ExistingGlobalConfigurationError {
      #expect(error.localizedDescription.contains("skills.team.path is unsupported"))
      #expect(error.localizedDescription.contains("sources.team.path"))
    }
  }

  @Test func preservesSourceDiscoveryPathAndSelection() throws {
    let f = try UpdateFixture(scope: .user)
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"sources":{"team":{"git":"example.invalid/team","path":"skills/team"}},
       "skills":{"team":{"select":"all","exclude":["retired"],"overrides":{"current":{"mode":"copy"}}}}}
      """, to: json)
    try StateStore.encodeState(ResolvedState()).write(to: f.store.resolvedURL)
    try ExistingGlobalConfiguration.apply(
      ExistingGlobalConfiguration.preview(environment: f.environment))

    let declaration = try f.store.loadDeclaration()
    #expect(declaration.sources["team"]?.path == "skills/team")
    let selection = try #require(try declaration.skills?["team"])
    #expect(selection.select == .all)
    #expect(selection.path == nil)
    #expect(selection.exclude == ["retired"])
    #expect(selection.overrides?["current"]?.mode == .copy)
  }

  @Test func rejectsAliasesForOneNormalizedSourceWithDistinctRoots() throws {
    let f = try UpdateFixture(scope: .user)
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"sources":{"team":{"git":"https://example.invalid/shared.git","path":"team"},
                  "tools":{"git":"https://example.invalid/shared","path":"tools"}}}
      """, to: json)
    try StateStore.encodeState(ResolvedState()).write(to: f.store.resolvedURL)
    do {
      _ = try ExistingGlobalConfiguration.preview(environment: f.environment)
      Issue.record("Accepted two aliases for one saved source identity")
    } catch let error as ExistingGlobalConfigurationError {
      #expect(error.localizedDescription.contains("'team' and 'tools'"))
      #expect(error.localizedDescription.contains("Use one alias per source"))
    }
  }

  @Test func reopensAnEditLinkThroughItsAuthoredSourceAlias() throws {
    let f = try UpdateFixture(scope: .user)
    let alias = try importEditAlias(f)
    let installed = try PathIdentity(f.target())
    let alternate = f.repo.appendingPathComponent("skills/alternate")
    try FileManager.default.copyItem(
      at: f.repo.appendingPathComponent("skills/demo"), to: alternate)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "alternate")

    let inventory = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(inventory.deployments.map(\.status) == [.current])
    #expect(inventory.resources.first?.location?.path == alias.path)
    _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
    try installed.validate()
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: f.target().path) == alias.path)
  }

  @Test(arguments: [false, true])
  func declinesAnEditAliasRetargetedOutsideItsSource(_ afterPreparation: Bool) throws {
    let f = try UpdateFixture(scope: .user)
    let alias = try importEditAlias(f)
    let installed = try PathIdentity(f.target())
    let ledger = try f.bytes(f.store.resolvedURL)
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.copyItem(at: f.repo.appendingPathComponent("skills/demo"), to: outside)
    func retarget() throws {
      try FileManager.default.removeItem(at: alias)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    }
    if !afterPreparation { try retarget() }
    do {
      if afterPreparation {
        _ = try UpdateOperations.withPreparedUpdate(
          UpdateRequest(operation: .restore, kinds: [.skills]), scope: .user,
          environment: f.environment
        ) { prepared in
          try retarget()
          return try prepared.apply()
        }
      } else {
        _ = try SkillOperations.installResolvedReport(scope: .user, environment: f.environment)
      }
      Issue.record("Restored an edit source outside its recorded source directory")
    } catch {
      let cause = (error as? UpdateApplyError)?.underlyingError ?? error
      guard case CoreError.unsafePath(let message) = cause else {
        Issue.record(error)
        return
      }
      #expect(message.contains("outside its recorded source directory"))
      #expect(message.contains("Point the source alias inside"))
    }

    let inventory = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    let deployment = try #require(inventory.deployments.first)
    #expect(deployment.status == .drifted)
    #expect(deployment.diagnostic?.contains("Point the source alias inside") == true)
    #expect(inventory.resources.first?.location?.path == alias.path)
    #expect(try f.bytes(f.store.resolvedURL) == ledger)
    try installed.validate()
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: f.target().path) == alias.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == outside.path)
  }

  private func importEditAlias(_ f: UpdateFixture) throws -> URL {
    let alias = f.repo.appendingPathComponent("skills/current")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "demo")
    let target = f.target()
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: alias)
    let json = try #require(f.store.configurationJSONURL)
    try f.write(
      """
      {"sources":{"fixture":{"local":"\(f.repo.path)"}},
       "skills":{"fixture":{"select":["demo"],"agents":["codex"],"mode":"edit"}}}
      """, to: json)
    let identity = "local:" + f.repo.path
    let saved = ResolvedState(
      sources: [identity: .init(kind: .local)],
      skills: ["demo": .init(source: identity, path: "skills/current", installs: ["codex": .edit])])
    try StateStore.encodeState(saved).write(to: f.store.resolvedURL)
    try ExistingGlobalConfiguration.apply(
      ExistingGlobalConfiguration.preview(environment: f.environment))
    return alias
  }

  @Test(arguments: [
    TransactionCheckpoint.progress(1, .applied).name, TransactionCheckpoint.phase(.committed).name,
  ])
  func recoveryAfterKilledWriterKeepsOneGeneration(_ point: String) throws {
    let input = try ExistingProfile()
    let f = input.fixture
    let preview = try ExistingGlobalConfiguration.preview(environment: f.environment)
    let child = try launch(f, command: "existing-configuration", argument: point)
    defer { terminate(child) }
    try waitFor("ready", fixture: f, child: child)
    terminate(child)
    let pending = try UpdateOperations.inspect(scope: .user, environment: f.environment)
    #expect(pending.recovery.pending)
    #expect(pending.readLocations.contains(input.json))
    #expect(throws: ExistingGlobalConfigurationError.self) {
      try ExistingGlobalConfiguration.preview(environment: f.environment)
    }
    #expect(throws: CoreError.transactionRecovered(f.store.directory.path)) {
      try f.store.withLock {}
    }
    if point == TransactionCheckpoint.phase(.committed).name {
      #expect(try f.store.loadResolved().normalized == input.expected.normalized)
      #expect(try f.bytes(preview.originalLedgerURL) == input.lockBytes)
    } else {
      #expect(try f.bytes(f.store.resolvedURL) == input.lockBytes)
      #expect(try ExistingGlobalConfiguration.isAvailable(environment: f.environment))
      #expect(!FileManager.default.fileExists(atPath: preview.originalLedgerURL.path))
      try ExistingGlobalConfiguration.apply(
        ExistingGlobalConfiguration.preview(environment: f.environment))
    }
    #expect(try f.bytes(input.json) == input.declarationBytes)
    #expect(try f.bytes(f.store.watchURL) == input.watchBytes)
  }

  private func expectUnapplied(
    _ preview: ExistingGlobalConfigurationPreview, ledger: Data, fixture: UpdateFixture
  ) throws {
    #expect(try fixture.bytes(preview.ledgerURL) == ledger)
    #expect(!FileManager.default.fileExists(atPath: preview.declarationURL.path))
    #expect(!FileManager.default.fileExists(atPath: preview.originalLedgerURL.path))
    #expect(try ExistingGlobalConfiguration.isAvailable(environment: fixture.environment))
  }
}

private struct ExistingProfile {
  let fixture: UpdateFixture
  let json: URL
  let declarationBytes: Data
  let lockBytes: Data
  let watchBytes: Data
  let expected: ResolvedState
  let pinnedSkill: URL

  init() throws {
    let f = try UpdateFixture(scope: .user)
    fixture = f
    json = try #require(f.store.configurationJSONURL)
    let cache = SourceCache(store: f.store)
    let identity = "local:" + f.repo.path
    let skillRevision = try f.git(["rev-parse", "HEAD"])
    let materialized = cache.materializedURL(sourceID: identity, revision: skillRevision)
    pinnedSkill = materialized.appendingPathComponent("skills/demo")
    try FileManager.default.createDirectory(
      at: pinnedSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: f.repo.appendingPathComponent("skills/demo"), to: pinnedSkill)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: pinnedSkill.appendingPathComponent("run.sh").path)
    try FileManager.default.createDirectory(
      at: f.target().deletingLastPathComponent(), withIntermediateDirectories: true)
    let relative = PathSafety.relativePath(pinnedSkill.path, to: f.store.directory.path)
    try FileManager.default.createSymbolicLink(
      atPath: f.target().path, withDestinationPath: "../" + relative)

    try f.advance()
    let instructionRevision = try f.git(["rev-parse", "HEAD"])
    let instructionBytes = try f.bytes(f.repo.appendingPathComponent("instructions/rules.md"))
    try f.writeSource("later HEAD and dirty working tree")
    try f.commit()
    try f.writeSource("dirty")
    let section = LockedSection(
      name: "rules", source: identity, revision: instructionRevision, version: "1.3.0",
      path: "instructions/rules.md", hash: Instructions.hash(instructionBytes))
    let rendered = try Instructions.render([
      Instructions.validateSource(instructionBytes, id: "rules")
    ])
    try f.write("Edited outside agents.\n", to: f.instruction())
    let forwarding = ClaudeForwarding.renderBlock(for: .root)
    try f.write("Custom prose\n\n" + forwarding, to: f.instruction(.claudeCode))

    let live = f.root.appendingPathComponent("live")
    let edit = live.appendingPathComponent("edit-demo")
    try f.write(
      "---\nname: edit-demo\ndescription: Live fixture\n---\n\nNew live content\n",
      to: edit.appendingPathComponent("SKILL.md"))
    try FileManager.default.createSymbolicLink(
      at: f.target().deletingLastPathComponent().appendingPathComponent("edit-demo"),
      withDestinationURL: edit.resolvingSymlinksInPath())
    let editIdentity = "local:" + live.path
    let unused = "example.invalid/unused"
    var lock = ResolvedState(
      sources: [
        identity: .init(kind: .local, requirement: .branch("main")),
        editIdentity: .init(kind: .local),
        unused: .init(kind: .git, url: "https://" + unused),
      ],
      skills: [
        "demo": .init(
          source: identity, revision: skillRevision, version: "1.2.0", path: "skills/demo",
          hash: try "sha256:" + FileHash.folderHash(pinnedSkill),
          installs: ["codex": .link, "gemini-cli": .link, "claude-code": .link]),
        "edit-demo": .init(source: editIdentity, path: "edit-demo", installs: ["codex": .edit]),
      ],
      instructions: .init(
        sections: [section], chatgpt: ["weekly": .init(sections: [section], append: "custom.md")],
        targets: [
          InstructionLocations.key(for: f.instruction(), store: f.store): .init(
            agents: [.codex], headingOffset: 0, blockHash: Instructions.hash(Data(rendered.utf8)),
            created: true),
          InstructionLocations.key(for: f.instruction(.claudeCode), store: f.store): .init(
            agents: [.claudeCode], import: "AGENTS.md",
            blockHash: Instructions.hash(Data(forwarding.utf8)), created: false),
        ]))
    lockBytes = try StateStore.encodeState(lock)
    try lockBytes.write(to: f.store.resolvedURL)
    lock.sources.removeValue(forKey: unused)
    expected = lock
    watchBytes = Data("{ \"version\": 1, \"sources\": {} }\n".utf8)
    try watchBytes.write(to: f.store.watchURL)
    declarationBytes = Data(
      """
      {
        "agents": ["codex","claude-code"],
        "sources": {
          "fixture": {"local": "\(f.repo.path)", "branch": "main"},
          "live": {"local": "\(live.path)"}
        },
        "skills": {
          "fixture": {"select":"all","exclude":["excluded"],"mode":"copy",
            "overrides":{"demo":{"agents":["codex","gemini-cli","claude-code"],"mode":"link"}}},
          "live": {"select":["edit-demo","uninstalled"],"agents":["codex"],"mode":"edit"}
        },
        "instructions": {"agents":["codex"],"sections":["fixture:rules"],
          "chatgpt":{"weekly":{"sections":["fixture:rules"],"append":"custom.md"}}},
        "watch": ["fixture"]
      }

      """.utf8)
    try declarationBytes.write(to: json)
  }
}
