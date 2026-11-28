import AgentsInstructions
import AgentsManifest
import CPlatform
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore
@testable import AgentsUpdates

@Suite("Package-manager lifecycle", .serialized)
struct PackageLifecycleTests {
  @Test func readOnlyPreviewAndCanonicalEdit() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        # user formatting
        lifecycle:
          pre-install:
            - type: command
              run: 'echo fixture'
            - {run: 'echo fixture', type: command}
        """)
      let before = try fixture.readDeclaration()
      let preview = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      #expect(preview.inspection.actions.count == 2)
      #expect(preview.inspection.actions.map(\.index) == [0, 1])
      #expect(preview.inspection.actions.allSatisfy { $0.withheld == .projectUntrusted })
      #expect(try fixture.readDeclaration() == before)
      #expect(!fixture.exists(fixture.home.appendingPathComponent(".agents")))
      #expect(!fixture.exists(fixture.store.resolvedURL))

      let grant = try await fixture.enable()
      let snapshot = try fixture.store.loadManifest()
      let document = try #require(snapshot)
      let change = try document.preparing([.setDefaultAgents([.codex])])
      try Data(change.bytes).write(to: fixture.store.declarationURL)
      let after = try fixture.readDeclaration()
      #expect(after.contains("# user formatting"))
      #expect(after.contains("run: 'echo fixture'"))
      #expect(
        LifecycleOperations.list(environment: fixture.environment).projectTrusted)
      try fixture.write(
        """
        # same lifecycle data
        version: 1
        lifecycle: {pre-install: [{run: "echo fixture", type: command}, {type: command, run: "echo fixture"}]}
        """)
      let rereview = try LifecycleOperations.reviewEnable(environment: fixture.environment)
      #expect(rereview.enablement.digest == grant.digest)
      #expect(rereview.enablement.expectedRevision == 1)
      try fixture.write(
        """
        version: 1
        lifecycle: {pre-install: [{run: "echo edited", type: command}, {type: command, run: "echo fixture"}]}
        """)
      #expect(
        !LifecycleOperations.list(environment: fixture.environment).projectTrusted)
    }
  }

  @Test func validationAggregatesFieldsAndAdministratorShape() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          bad-event: []
          pre-install:
            - {type: command, command: echo one, bash: echo two, url: http://example.invalid}
            - {type: http, url: https://me:password@example.invalid, headers: {X-Test: 7}}
            - {type: other, timeout: 301}
          post-install: {type: command}
        """)
      let errors = LifecycleOperations.validate(environment: fixture.environment)
      #expect(errors.count == 8)
      #expect(errors.allSatisfy { $0.source.file == fixture.store.declarationURL })
      #expect(errors.contains { $0.event == "bad-event" })
      #expect(errors.contains { $0.event == "pre-install" && $0.index == 1 && $0.field == "url" })
      #expect(
        errors.contains { $0.event == "pre-install" && $0.index == 2 && $0.field == "timeout" })
      #expect(!errors.contains { $0.message.contains("password") })
      #expect(LifecycleOperations.list(environment: fixture.environment).actions.isEmpty)
    }

    var discovery = LifecycleDiscovery()
    let admin = LifecycleSource(
      authority: .administrator, file: fixture.root.appendingPathComponent("a.json"))
    try discovery.addAdmin(
      input: (
        Data(#"{"version":2,"scripts":{"bad":[],"pre-compile":[{"type":"command"}]}}"#.utf8),
        "fixture"
      ), source: admin)
    #expect(discovery.administratorInvalid)
    #expect(discovery.actions.isEmpty)
    #expect(discovery.diagnostics.count == 3)
    var good = LifecycleDiscovery()
    try good.addAdmin(
      input: (
        Data(
          #"{"version":1,"scripts":{"pre-compile":[{"type":"command","bash":"exit 7"},{"type":"command","bash":"exit 7"}]}}"#
            .utf8),
        "fixture"
      ), source: admin)
    #expect(!good.administratorInvalid)
    #expect(good.actions.map { $0.value.index } == [0, 1])
    let declared = try #require(good.actions.first)
    let opened = try DirectoryHandle.readDirectory(at: fixture.project)
    let launched = try LifecycleCommand.spawn(
      declared, in: opened, environment: fixture.environment)
    let reported = await LifecycleCommand.finish(
      launched, action: declared.summary(), payload: Data("{}".utf8))
    #expect(reported.disposition == .commandFailed)
    #expect(reported.exitStatus == 7)
    #expect(throws: (any Error).self) {
      try good.addAdmin(
        input: (Data(#"{"version":1,"version":1,"scripts":{}}"#.utf8), "fixture"), source: admin)
    }
  }

  @Test func confirmationClaimsOnceAndFreshReviewRunsAgain() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install:
            - {type: command, run: 'printf "%s\\n" "pre:$APM_NO_SCRIPTS" >> count', env: {APM_NO_SCRIPTS: "0"}}
            - {type: command, command: 'exit 7'}
          post-install:
            - {type: command, bash: 'test -f .agent/agents.resolved && printf "%s\\n" post >> count'}
        """)
      _ = try await fixture.enable()
      let request = UpdateRequest(operation: .edit([.setDefaultAgents([.codex])]))
      let review = try UpdateOperations.previewLifecycle(
        request, intent: .install, environment: fixture.environment)
      #expect(!fixture.exists(fixture.counter))
      let barrier = LifecycleBarrier()
      let running = Task {
        await LifecycleOperations.$checkpoint.withValue(
          .init { step in
            if step == .confirmationClaimed { barrier.pause() }
          }
        ) {
          await UpdateOperations.perform(review)
        }
      }
      #expect(await barrier.wait())
      defer { barrier.release() }
      guard case .alreadyRunning = await UpdateOperations.perform(review) else {
        Issue.record("Duplicate confirmation was not recognized as running.")
        return
      }
      barrier.release()
      let initial = try fixture.completed(await running.value)
      _ = try initial.package.result.get()
      #expect(initial.pre.map(\.disposition) == [.commandSucceeded, .commandFailed])
      #expect(initial.pre.last?.exitStatus == 7)
      #expect(initial.post.map(\.disposition) == [.commandSucceeded])
      #expect(try fixture.counterText() == "pre:1\npost\n")
      let replay = try fixture.completed(await UpdateOperations.perform(review))
      #expect(replay.pre.count == initial.pre.count)
      #expect(try fixture.counterText() == "pre:1\npost\n")
      let next = try UpdateOperations.previewLifecycle(
        request, intent: .install, environment: fixture.environment)
      let again = try fixture.completed(await UpdateOperations.perform(next))
      _ = try again.package.result.get()
      #expect(!next.report.hasChanges)
      #expect(try fixture.counterText() == "pre:1\npost\npre:1\npost\n")
    }
  }

  @Test func eventPairsAndPreCompileAreExplicit() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      let authored = LifecycleEvent.allCases.map { event in
        #"  \#(event.rawValue): [{type: command, run: 'printf "%s\n" \#(event.rawValue) >> count'}]"#
      }.joined(separator: "\n")
      try fixture.write("version: 1\nlifecycle:\n" + authored + "\n")
      _ = try await fixture.enable()
      let intents: [LifecycleOperationIntent] = [.install, .update, .uninstall]
      for intent in intents {
        let view = try fixture.review(intent)
        let result = try fixture.completed(await UpdateOperations.perform(view))
        _ = try result.package.result.get()
        #expect(result.pre.map(\.action.event) == [intent.events.pre])
        let post = try #require(intent.events.post)
        #expect(result.post.map(\.action.event) == [post])
      }
      let compile = try InstructionOperations.previewCompilation(environment: fixture.environment)
      let result = try fixture.completed(await UpdateOperations.perform(compile))
      _ = try result.package.result.get()
      #expect(result.pre.map(\.action.event) == [.preCompile])
      #expect(result.post.isEmpty)
      let lines = try fixture.counterText().split(separator: "\n").map(String.init)
      #expect(lines == LifecycleEvent.allCases.map(\.rawValue))
    }
  }

  @Test func receiptRevisionsArePerRootAndRevokeSurvivesReplacement() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(LifecycleFixture.command)
      try fixture.write(LifecycleFixture.command, project: fixture.secondProject)
      let first = try LifecycleOperations.reviewEnable(environment: fixture.environment)
      let secondEnvironment = fixture.environment(for: fixture.secondProject)
      let second = try LifecycleOperations.reviewEnable(environment: secondEnvironment)
      async let one = LifecycleOperations.enable(first)
      async let two = LifecycleOperations.enable(second)
      let granted = try await fixture.completed(one).get()
      let other = try await fixture.completed(two).get()
      #expect(granted.revision == 1 && other.revision == 1)
      #expect(granted.project != other.project && granted.digest == other.digest)
      let moved = fixture.root.appendingPathComponent("original-project")
      try FileManager.default.moveItem(at: fixture.project, to: moved)
      try fixture.write(LifecycleFixture.command)
      #expect(!LifecycleOperations.list(environment: fixture.environment).projectTrusted)
      let replacement = try await fixture.enable()
      #expect(replacement.project != granted.project)
      try FileManager.default.removeItem(at: moved)
      let revoked = try LifecycleOperations.revoke(
        granted.project, environment: fixture.environment)
      #expect(revoked.revision == 2 && revoked.digest == nil)
      #expect(LifecycleOperations.list(environment: fixture.environment).projectTrusted)
      let records = try LifecycleOperations.storedTrust(environment: fixture.environment)
      #expect(Set(records.map(\.project)) == [granted.project, other.project, replacement.project])
      let state = fixture.home.appendingPathComponent(".agents/lifecycle")
      let directory = try FileManager.default.attributesOfItem(atPath: state.path)
      let receipts = try FileManager.default.attributesOfItem(
        atPath: state.appendingPathComponent("receipts.json").path)
      #expect(directory[.posixPermissions] as? Int == 0o700)
      #expect(receipts[.posixPermissions] as? Int == 0o600)
    }
  }

  @Test func saveThenEnableDetectsInterveningGrantAndRevocation() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write("version: 1\n# fixture\n")
      let staged = try LifecycleOperations.previewDeclaration(
        try LifecycleFixture.subtree(), environment: fixture.environment)
      let barrier = LifecycleBarrier()
      let task = Task {
        await LifecycleOperations.$checkpoint.withValue(
          .init { step in
            if step == .declarationSaved { barrier.pause() }
          }
        ) {
          await LifecycleOperations.save(staged, enable: true)
        }
      }
      #expect(await barrier.wait())
      defer { barrier.release() }
      let first = try await fixture.enable()
      _ = try LifecycleOperations.revoke(first.project, environment: fixture.environment)
      barrier.release()
      guard case .savedEnablementIncomplete = try fixture.completed(await task.value).get() else {
        Issue.record("A stale enablement was accepted after grant and revoke.")
        return
      }
      #expect(try fixture.readDeclaration().contains("# fixture"))
      #expect(!LifecycleOperations.list(environment: fixture.environment).projectTrusted)
      #expect(
        try LifecycleOperations.storedTrust(environment: fixture.environment).first?.revision == 2)
    }
  }

  @Test func scaffoldRequiresForceAndPreservesOtherBytes() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        # owner comment
        lifecycle:
          # inside subtree
          pre-install:
            - {type: command, run: 'exit 0'} # action note
        defaultAgents: [codex] # target note
        """)
      #expect(throws: (any Error).self) {
        try LifecycleOperations.previewScaffold(environment: fixture.environment)
      }
      let review = try LifecycleOperations.previewScaffold(
        environment: fixture.environment, force: true)
      guard case .saved = try fixture.completed(await LifecycleOperations.save(review)).get() else {
        Issue.record("Scaffold should save without granting trust.")
        return
      }
      let bytes = try fixture.readDeclaration()
      #expect(bytes.contains("# owner comment"))
      #expect(bytes.contains("defaultAgents: [codex] # target note"))
      #expect(LifecycleOperations.list(environment: fixture.environment).actions.isEmpty)
      #expect(!fixture.exists(fixture.home.appendingPathComponent(".agents")))
    }
  }

  @Test func finalGateRejectsStaleTrustSourcePolicyAndDisable() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(LifecycleFixture.command)
      let grant = try await fixture.enable()
      let beforeRevoke = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      _ = try LifecycleOperations.revoke(grant.project, environment: fixture.environment)
      let revoked = try fixture.completed(await LifecycleOperations.executeTest(beforeRevoke))
      #expect(revoked.map(\.withholding) == [.trustChanged])

      _ = try await fixture.enable()
      let beforeSwap = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      let alternate = fixture.root.appendingPathComponent("alternate.yaml")
      try Data(LifecycleFixture.command.utf8).write(to: alternate)
      try FileManager.default.removeItem(at: fixture.store.declarationURL)
      try FileManager.default.createSymbolicLink(
        at: fixture.store.declarationURL, withDestinationURL: alternate)
      let swapped = try fixture.completed(await LifecycleOperations.executeTest(beforeSwap))
      #expect(swapped.allSatisfy { !$0.dispatched })
      #expect(!LifecycleOperations.validate(environment: fixture.environment).isEmpty)
      try FileManager.default.removeItem(at: fixture.store.declarationURL)
      try fixture.write(LifecycleFixture.command)

      let policy = fixture.root.appendingPathComponent("organization.yaml")
      try Data("enforcement: warn\n".utf8).write(to: policy)
      var governed = fixture.environment
      governed.projectOrganizationPolicy = .init(.local(policy))
      let beforePolicy = LifecycleOperations.simulate(.preInstall, environment: governed)
      try Data("enforcement: warn\nexecutables: {deny_all: true}\n".utf8).write(to: policy)
      let changed = try fixture.completed(await LifecycleOperations.executeTest(beforePolicy))
      #expect(changed.map(\.withholding) == [.policyDenied])
      try FileManager.default.removeItem(at: policy)
      let unavailable = LifecycleOperations.simulate(.preInstall, environment: governed)
      #expect(unavailable.inspection.allStartsWithheld == .policyUnavailable)
      var disabled = fixture.environment
      disabled.environment["APM_NO_SCRIPTS"] = "1"
      let noScripts = LifecycleOperations.simulate(.preInstall, environment: disabled)
      let rejected = try fixture.completed(await LifecycleOperations.executeTest(noScripts))
      #expect(rejected.map(\.withholding) == [.disabled])
      #expect(!fixture.exists(fixture.counter))
    }
  }

  @Test func protectedUserSourceAndBadAdministratorDirectory() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(LifecycleFixture.command)
      _ = try await fixture.enable()
      let user = StateStore(scope: .user, environment: fixture.environment)
      let valid = """
        version: 1
        lifecycle:
          pre-install: [{type: command, run: 'printf "%s\\n" user >> count'}]
        """
      try Data(valid.utf8).write(to: user.declarationURL)
      let listed = LifecycleOperations.list(environment: fixture.environment)
      #expect(listed.actions.map(\.source.authority) == [.user, .project])
      let test = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      let result = try fixture.completed(await LifecycleOperations.executeTest(test))
      #expect(result.allSatisfy { $0.disposition == .commandSucceeded })
      #expect(try fixture.counterText() == "user\nproject\n")
      let alias = fixture.root.appendingPathComponent("hardlink.yaml")
      try FileManager.default.linkItem(at: user.declarationURL, to: alias)
      let hardlink = LifecycleOperations.list(environment: fixture.environment)
      #expect(hardlink.actions.map(\.source.authority) == [.project])
      #expect(hardlink.diagnostics.map(\.source.authority) == [.user])
    }
    let admin = fixture.root.appendingPathComponent("administrator.d")
    try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
    try Data(#"{"version":1,"scripts":{}}"#.utf8).write(
      to: admin.appendingPathComponent("010.json"))
    await LifecycleOperations.$administratorDirectoryForTesting.withValue(admin) {
      let view = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      #expect(view.inspection.allStartsWithheld == .administratorSourceInvalid)
      #expect(view.inspection.diagnostics.contains { $0.source.file == admin })
      let result = try? fixture.completed(await LifecycleOperations.executeTest(view))
      #expect(result?.map(\.withholding) == [.administratorSourceInvalid])
    }
  }

  @Test func userScopeActionsSurviveOrdinaryDeclarationPublication() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      let store = StateStore(scope: .user, environment: fixture.environment)
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      let source = """
        version: 1
        lifecycle:
          pre-install: [{type: command, run: 'printf "%s\\n" pre >> count'}]
          post-install: [{type: command, run: 'printf "%s\\n" post >> count'}]
        """
      try Data(source.utf8).write(to: store.declarationURL)
      let request = UpdateRequest(operation: .edit([.setDefaultAgents([.codex])]))
      let review = try UpdateOperations.previewLifecycle(
        request, intent: .install, scope: .user, environment: fixture.environment)
      let result = try fixture.completed(await UpdateOperations.perform(review))
      _ = try result.package.result.get()
      #expect(result.pre.first?.action.source.authority == .user)
      #expect(result.post.first?.disposition == .commandSucceeded)
      let count = fixture.home.appendingPathComponent("count")
      #expect(try String(contentsOf: count, encoding: .utf8) == "pre\npost\n")

      #if os(macOS)
        _ = try ProcessRunner.run(
          "/bin/chmod", arguments: ["+a", "everyone allow write", store.declarationURL.path])
      #else
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o664], ofItemAtPath: store.declarationURL.path)
      #endif
      let refused = LifecycleOperations.list(scope: .user, environment: fixture.environment)
      #expect(refused.actions.isEmpty)
      #expect(refused.diagnostics.first?.source.authority == .user)
    }
  }

  @Test func completedRevocationWaitsForHandoffAndWithholdsRemainingStarts() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install:
            - {type: command, run: 'printf "%s\\n" one >> count'}
            - {type: command, run: 'printf "%s\\n" two >> count'}
        """)
      let grant = try await fixture.enable()
      let review = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      let handoff = LifecycleBarrier()
      let running = Task {
        await LifecycleOperations.$checkpoint.withValue(
          .init { point in
            if point == .handedOff { handoff.pause() }
          }
        ) {
          await LifecycleOperations.executeTest(review)
        }
      }
      #expect(await handoff.wait())
      defer { handoff.release() }
      let published = DispatchSemaphore(value: 0)
      let returned = DispatchSemaphore(value: 0)
      let revoking = Task {
        try LifecycleOperations.$checkpoint.withValue(
          .init { point in
            if point == .receiptPublished { published.signal() }
          }
        ) {
          defer { returned.signal() }
          return try LifecycleOperations.revoke(grant.project, environment: fixture.environment)
        }
      }
      #expect(await waitForLifecycleSignal(published, for: .seconds(5)) == .success)
      #expect(await waitForLifecycleSignal(returned, for: .milliseconds(50)) == .timedOut)
      handoff.release()
      #expect(try await revoking.value.revision == 2)
      let actions = try fixture.completed(await running.value)
      #expect(actions.map(\.dispatched) == [true, false])
      #expect(actions.last?.withholding == .trustChanged)
      #expect(try fixture.counterText() == "one\n")
    }
  }

  @Test func lockOnlyThenFrozenDeploymentUsesOneReviewedPhasePairEach() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      let catalog = try GraphCatalog()
      try catalog.publish("shared", "1.0.0")
      let package = try catalog.root("main", package: "shared", recipient: .codex)
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install: [{type: command, run: 'printf "%s\\n" pre >> count'}]
          post-install: [{type: command, run: 'printf "%s\\n" post >> count'}]
        """)
      _ = try await fixture.enable()
      let review = try MarketplaceOperations.previewLockOnlyLifecycle(
        .install(package), intent: .install, environment: fixture.environment)
      #expect(!fixture.exists(fixture.counter))
      let lock = try fixture.completed(await UpdateOperations.perform(review))
      let pending = try lock.package.result.get()
      #expect(pending.pendingDeployment.graph != nil)
      #expect(lock.post.first?.disposition == .commandSucceeded)
      #expect(try fixture.counterText() == "pre\npost\n")
      try FileManager.default.removeItem(at: catalog.catalog)

      let frozen = try MarketplaceOperations.previewFrozenLifecycle(
        intent: .install, environment: fixture.environment)
      let applied = try fixture.completed(await UpdateOperations.perform(frozen))
      _ = try applied.package.result.get()
      #expect(applied.post.first?.disposition == .commandSucceeded)
      #expect(try fixture.counterText() == "pre\npost\npre\npost\n")
      #expect(
        try UpdateOperations.inspect(environment: fixture.environment).pendingMarketplaceDeployment
          == nil)
    }
  }

  @Test func crashRecoveryDoesNotReplayEffects() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install: [{type: command, run: 'printf "%s\\n" pre >> count'}]
          post-install: [{type: command, run: 'printf "%s\\n" post >> count'}]
        """)
      _ = try await fixture.enable()
      var location = Bundle(for: LifecycleProbeBundle.self).bundleURL
      while !FileManager.default.isExecutableFile(
        atPath: location.appendingPathComponent("StateTestProcess").path),
        location.path != "/"
      { location.deleteLastPathComponent() }
      let probe = Process()
      probe.executableURL = location.appendingPathComponent("StateTestProcess")
      probe.arguments = [
        fixture.project.path, "lifecycle-crash",
        TransactionCheckpoint.persisted(.applying, .entry(0, .publishing), .renamed).name,
        fixture.home.path, fixture.absentAdministratorDirectory.path,
      ]
      try probe.run()
      defer {
        if probe.isRunning { try? ProcessWait.terminate(probe, timeout: 3) }
      }
      try ProcessWait.exit(probe, root: fixture.project, timeout: 15)
      try #require(probe.terminationReason == .uncaughtSignal && probe.terminationStatus == SIGKILL)
      #expect(try fixture.counterText() == "pre\n")

      let pending = LifecycleOperations.simulate(.preInstall, environment: fixture.environment)
      let result = try fixture.completed(await LifecycleOperations.executeTest(pending))
      #expect(result.map(\.withholding) == [.recoveryPending])
      let recovered = UpdateOperations.perform(environment: fixture.environment) { try $0.apply() }
      #expect(recovered.recoveredBeforePreparation)
      #expect(!recovered.recovery.pending)
      #expect(try fixture.counterText() == "pre\n")

      let review = try fixture.review(.install)
      let retry = try fixture.completed(await UpdateOperations.perform(review))
      _ = try retry.package.result.get()
      #expect(try fixture.counterText() == "pre\npre\npost\n")
    }
  }

  @Test func rollbackReportsStartedPreActionsAndSuppressesPost() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install: [{type: command, run: 'cat > fixture-event.json'}]
          post-install: [{type: command, run: 'touch count'}]
        """)
      _ = try await fixture.enable()
      let request = UpdateRequest(operation: .edit([.setDefaultAgents([.codex])]))
      let review = try UpdateOperations.previewLifecycle(
        request, intent: .install, environment: fixture.environment)
      let failAt = TransactionCheckpoint.progress(0, .applied).name
      let submission = await LifecycleOperations.$transactionCheckpointForTesting.withValue({
        step in
        if step == failAt { throw LifecycleFixtureAbort.rollback }
      }) {
        await UpdateOperations.perform(review)
      }
      let result = try fixture.completed(submission)
      #expect(result.package.disposition == .rolledBack)
      #expect(result.pre.first?.disposition == .commandSucceeded)
      #expect(result.post.first?.withholding == .packageDidNotComplete)
      #expect(!fixture.exists(fixture.counter))
      let file = try Data(contentsOf: fixture.project.appendingPathComponent("fixture-event.json"))
      let event = try JSONSerialization.jsonObject(with: file) as? [String: Any]
      #expect(event?["event"] as? String == "pre-install")
      #expect(event?["version"] as? Int == 1)
      #expect(event?["test"] as? Bool == false)
    }
  }

  @Test func childDeadlineCleanupAndOutputAreAdvisoryAndRedacted() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-install:
            - {type: command, run: 'sleep 10 & wait', timeout: 1}
            - {type: command, run: 'printf "synthetic-private-value" >&2; exit 19'}
            - {type: command, run: 'yes output'}
          post-install: [{type: command, run: 'touch count'}]
        """)
      _ = try await fixture.enable()
      let review = try fixture.review(.install)
      let result = try fixture.completed(await UpdateOperations.perform(review))
      _ = try result.package.result.get()
      #expect(
        result.pre.map(\.disposition) == [.commandTimedOut, .commandFailed, .commandOutputLimit])
      #expect(result.pre.allSatisfy { $0.processGroupCleanedUp == true })
      #expect(fixture.exists(fixture.counter))
      let encoded = try JSONEncoder().encode(result.pre)
      #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-private-value"))
    }
  }

  @Test func staleApplyReportsPreStartsAndSuppressesPost() async throws {
    let fixture = try LifecycleFixture()
    try await fixture.withoutAdministratorFiles {
      try fixture.write(
        """
        version: 1
        lifecycle:
          pre-update: [{type: command, run: 'printf "%s\\n" "# modified during pre" >> .agent/agents.yaml'}]
          post-update: [{type: command, run: 'touch count'}]
        """)
      _ = try await fixture.enable()
      let review = try fixture.review(.update)
      let result = try fixture.completed(await UpdateOperations.perform(review))
      #expect(throws: (any Error).self) { try result.package.result.get() }
      #expect(result.pre.first?.disposition == .commandSucceeded)
      #expect(result.post.first?.withholding == .packageDidNotComplete)
      #expect(!fixture.exists(fixture.counter))
    }
  }
}

private func waitForLifecycleSignal(
  _ semaphore: DispatchSemaphore, for duration: DispatchTimeInterval
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + duration))
    }
  }
}

private enum LifecycleFixtureAbort: Error { case rollback }

private final class LifecycleProbeBundle {}

private final class LifecycleBarrier: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let permitted = DispatchSemaphore(value: 0)

  func pause() {
    entered.signal()
    if permitted.wait(timeout: .now() + .seconds(60)) == .timedOut {
      Issue.record("Lifecycle barrier was not released.")
    }
  }

  func wait() async -> Bool { await waitForLifecycleSignal(entered, for: .seconds(60)) == .success }
  func release() { permitted.signal() }
}

final class LifecycleFixture: @unchecked Sendable {
  let root: URL
  let project: URL
  let secondProject: URL
  let home: URL
  let absentAdministratorDirectory: URL

  init() throws {
    let nonce = UUID().uuidString
    root = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath().appendingPathComponent("package-lifecycle-" + nonce)
    project = root.appendingPathComponent("project")
    secondProject = root.appendingPathComponent("project-two")
    home = root.appendingPathComponent("home")
    absentAdministratorDirectory = URL(fileURLWithPath: "/.agents-lifecycle-fixture-" + nonce)
    do {
      for url in [project, secondProject, home] {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      }
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }

  var environment: RuntimeEnvironment { environment(for: project) }
  var store: StateStore { .init(scope: .project, environment: environment) }
  var counter: URL { project.appendingPathComponent("count") }

  func environment(for root: URL) -> RuntimeEnvironment {
    RuntimeEnvironment(
      projectDirectory: root, homeDirectory: home,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
  }

  func write(_ text: String, project: URL? = nil) throws {
    let store = StateStore(scope: .project, environment: environment(for: project ?? self.project))
    try FileManager.default.createDirectory(
      at: store.directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: store.declarationURL)
  }

  func readDeclaration() throws -> String {
    try String(contentsOf: store.declarationURL, encoding: .utf8)
  }

  func counterText() throws -> String { try String(contentsOf: counter, encoding: .utf8) }
  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func withoutAdministratorFiles(_ body: () async throws -> Void) async rethrows {
    try await LifecycleOperations.$administratorDirectoryForTesting.withValue(
      absentAdministratorDirectory
    ) {
      try await body()
    }
  }

  func enable() async throws -> LifecycleTrustRecord {
    let review = try LifecycleOperations.reviewEnable(environment: environment)
    return try completed(await LifecycleOperations.enable(review)).get()
  }

  func review(_ intent: LifecycleOperationIntent) throws
    -> LifecyclePackageReview<CombinedUpdateReport, UpdateApplyResult>
  {
    try UpdateOperations.previewLifecycle(intent: intent, environment: environment)
  }

  func completed<T>(_ submission: LifecycleSubmission<T>) throws -> T {
    switch submission {
    case .completed(let result): result
    case .alreadyRunning: throw CoreError.invalidState("Confirmation already running.")
    }
  }

  static let command = """
    version: 1
    lifecycle:
      pre-install: [{type: command, run: 'printf "%s\\n" project >> count'}]
    """

  static func subtree() throws -> DeclarationValue {
    let document = try DeclarationDocument(bytes: Array(command.utf8), identity: .init("fixture"))
    return try #require(document.declaration.lifecycle)
  }
}
