import Foundation
import Testing

@testable import AgentsCore

@Suite("Git failures")
struct GitErrorTests {
  @Test func operationDescriptionsPreserveUserFacingPhrases() {
    let operations: [(GitError.Operation, String)] = [
      (.clone, "clone"),
      (.fetch, "fetch"),
      (.listRemoteReferences, "list remote refs for"),
      (.listTags, "list tags for"),
      (.resolveRevision(revision: "missing"), "read a revision from"),
      (.countCommits, "count commits in"),
      (.listReferences, "list references for"),
      (.updateReference, "retain a revision for"),
      (.deleteReference, "release a revision for"),
      (.extractRevision, "extract a revision from"),
      (.updateDefaultBranch, "update the default branch for"),
      (.readOrigin, "read the origin of"),
      (.findRepositoryRoot, "find the repository root for"),
      (.readStatus, "read the status of"),
    ]
    for (operation, phrase) in operations {
      let error = GitError(
        operation: operation, source: "https://example.com/source.git",
        stderr: "fatal: failed\n", command: [], exitCode: 128)

      #expect(operation.description == phrase)
      #expect(
        error.description
          == "Git could not \(phrase) https://example.com/source.git.\nfatal: failed")
    }
  }

  @Test func missingFileRepositoryIdentifiesCloneAndSource() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = SourceCache(
      store: StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root)))
    let source = SourceDeclaration(
      kind: .git,
      location: root.appendingPathComponent("missing.git").absoluteString
        .replacingOccurrences(of: "file://", with: "file://localhost"))

    let error = try #require(throws: GitError.self) { try cache.resolve(source) }

    expectConcise(error, operation: .clone, source: source.location, cache: cache)
    #expect(error.stderr.contains("does not appear to be a git repository"))
    #expect(error.command.contains("clone"))
    #expect(error.command.contains("-c"))
    #expect(error.command.contains { $0.contains(".staging-") })
    #expect(error.exitCode != 0)
  }

  @Test func unreachableRemoteIdentifiesCloneAndRefListing() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = SourceCache(
      store: StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root)))
    let source = SourceDeclaration(kind: .git, location: "http://127.0.0.1:1/unreachable.git")

    let clone = try #require(throws: GitError.self) { try cache.resolve(source) }
    expectConcise(clone, operation: .clone, source: source.location, cache: cache)
    let refs = try #require(throws: GitError.self) { try cache.inspectRevision(source) }
    expectConcise(refs, operation: .listRemoteReferences, source: source.location, cache: cache)
  }

  @Test func unavailableUpstreamIdentifiesFetchAndOriginalSource() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let cache = SourceCache(
      store: StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root)))
    let source = SourceDeclaration(
      kind: .git,
      location: upstream.absoluteString.replacingOccurrences(
        of: "file://", with: "file://localhost"))
    _ = try cache.resolve(source)
    try FileManager.default.removeItem(at: upstream)

    let error = try #require(throws: GitError.self) { try cache.resolve(source) }

    expectConcise(error, operation: .fetch, source: source.location, cache: cache)
    #expect(error.command.contains("fetch"))
  }

  @Test(arguments: [false, true])
  func missingRevisionIdentifiesSource(_ inspect: Bool) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let cache = SourceCache(
      store: StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root)))
    let source = SourceDeclaration(
      kind: .local, location: upstream.path, requirement: .branch("missing"))

    let error = try #require(throws: GitError.self) {
      try inspect ? cache.inspectRevision(source) : cache.resolve(source)
    }

    expectConcise(
      error, operation: .resolveRevision(revision: "refs/heads/missing"), source: source.location,
      cache: cache)
  }

  @Test func watchSeenFailureCarriesRequestedRevision() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let environment = RuntimeEnvironment(projectDirectory: root)
    let watch = WatchOperations(discoverSkills: { _ in [] }, fetchArtifacts: { _ in [] })
    try watch.add(upstream.path, alias: "source", environment: environment)

    let error = try #require(throws: GitError.self) {
      try watch.seen("source", revision: "missing-revision", environment: environment)
    }

    guard case .resolveRevision(let revision) = error.operation else {
      Issue.record("Expected a revision resolution failure, got \(error.operation)")
      return
    }
    #expect(revision == "missing-revision")
    #expect(error.source == upstream.path)
    #expect(error.description.hasPrefix("Git could not read a revision from \(upstream.path).\n"))
  }

  @Test func recoveryPreservesKnownSourceAndGitConfigurationFailure() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    let source = SourceDeclaration(kind: .local, location: upstream.path)
    try store.save(declaration: Declaration(sources: ["source": source]), resolved: ResolvedState())
    let cache = SourceCache(store: store)
    _ = try cache.resolve(source)
    try cache.beginWatchReferenceUpdate()
    let mirror = cache.mirrorURL(sourceID: try source.identity(environment: store.environment))
    try Data("[invalid\n".utf8).write(to: mirror.appendingPathComponent("config"))

    let error = try #require(throws: GitError.self) { try cache.recoverWatchReferences() }

    expectConcise(error, operation: .listReferences, source: source.location, cache: cache)
    #expect(error.stderr.contains("bad config"))
  }

  @Test func orphanedMirrorFailureUsesOriginLocation() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("upstream")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    let source = SourceDeclaration(kind: .local, location: upstream.path)
    let cache = SourceCache(store: store)
    let pin = try cache.resolve(source)
    let id = try source.identity(environment: store.environment)
    try cache.retainWatchRevision(sourceID: id, source: source.location, revision: pin.revision)
    let mirror = cache.mirrorURL(sourceID: id)
    let hook = mirror.appendingPathComponent("hooks/reference-transaction")
    try Data("#!/bin/sh\necho 'ref update rejected' >&2\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

    let error = try #require(throws: GitError.self) { try cache.recoverWatchReferences() }

    expectConcise(error, operation: .deleteReference, source: source.location, cache: cache)
    #expect(error.stderr.contains("ref update rejected"))
  }

  @Test func removesProgressAndReplacesInternalPathsWhileKeepingDiagnostics() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let mirror = root.appendingPathComponent("cache/mirrors/source.git.staging-id")
    let source = "https://github.com/agents-tools/does-not-exist.git"
    let stderr = """
      Cloning into bare repository '\(mirror.path)'...
      remote: Enumerating objects: 5\rremote: Enumerating objects: 10, done.
      remote: Counting objects:  10% (1/10)\rremote: Counting objects: 100% (10/10), done.
      remote: Compressing objects: 100% (10/10), done.
      remote: Total 10 (delta 2), reused 10 (delta 2), pack-reused 0
      Receiving objects:   1% (1/100)\rReceiving objects: 100% (100/100), done.
      Resolving deltas: 100% (10/10), done.
      50% (5/10)
      remote: error: repository access denied
      warning: 100% of the requested refs are unavailable
      fatal: cannot write '\(mirror.resolvingSymlinksInPath().path)/config'
      fatal: could not read Username for 'https://github.com': terminal prompts disabled
      """
    let command = ["/usr/bin/env", "git", "clone", source, mirror.path]
    let error = GitError(
      operation: .clone, source: source, stderr: stderr, command: command, exitCode: 128,
      replacingPaths: [root, mirror])

    #expect(
      error.description == """
        Git could not clone \(source).
        remote: error: repository access denied
        warning: 100% of the requested refs are unavailable
        fatal: cannot write '\(source)/config'
        fatal: could not read Username for 'https://github.com': terminal prompts disabled
        """)
    #expect(error.command == command)
    #expect(error.exitCode == 128)
  }

  @Test(
    arguments: [
      "100% of the authentication token quota is exhausted; contact support.",
      "50% (5/10) of the required credentials are unavailable.",
      "Receiving objects: 100% (10/10), authentication token quota exhausted.",
      "Counting objects: 10, done. Authentication failed.",
      "Total 10 (delta 2), authentication token quota exhausted.",
    ], ["", "remote: "])
  func preservesExplanatoryProgressSuffixes(_ diagnostic: String, _ prefix: String) {
    let source = "https://example.com/source.git"
    let error = GitError(
      operation: .fetch, source: source, stderr: prefix + diagnostic + "\n",
      command: [], exitCode: 128)

    #expect(error.stderr == prefix + diagnostic)
    #expect(error.description == "Git could not fetch \(source).\n" + prefix + diagnostic)
  }

  @Test(
    arguments: [
      "50% (5/10)",
      "100% (10/10), done.",
      "Receiving objects:   1% (1/100), 1.25 MiB | 2.50 MiB/s",
      "Receiving objects: 100% (100/100), 1.25 MiB | 2.50 MiB/s, done.",
      "Receiving objects: 100% (1/1), 256 bytes | 1.00 KiB/s, done.",
      "Total 10 (delta 2), reused 10 (delta 2), pack-reused 0 (from 0)",
    ], ["", "remote: "])
  func removesCompleteProgressLines(_ progress: String, _ prefix: String) {
    let error = GitError(
      operation: .fetch, source: "https://example.com/source.git",
      stderr: prefix + progress + "\n", command: [], exitCode: 128)

    #expect(error.stderr.isEmpty)
  }

  @Test func preservesPercentageDiagnosticFromSSHHelper() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let helper = root.appendingPathComponent("ssh-helper")
    let diagnostic = "100% of the authentication token quota is exhausted; contact support."
    try Data("#!/bin/sh\nprintf '%s\\n' '\(diagnostic)' >&2\nexit 1\n".utf8).write(to: helper)
    let source = "ssh://git@example.invalid/source.git"
    let quotedHelper = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let arguments = [
      "-c", "core.sshCommand=/bin/sh " + quotedHelper, "-c", "ssh.variant=ssh",
      "ls-remote", "--", source,
    ]

    let error = try #require(throws: GitError.self) {
      try ProcessRunner.git(arguments, operation: .listRemoteReferences, source: source)
    }

    #expect(error.stderr.contains(diagnostic))
    #expect(error.description.contains(diagnostic))
    #expect(error.command == ["/usr/bin/env", "git"] + arguments)
  }

  @Test(arguments: ["\n", "\r"], [false, true])
  func redactsMultilinePathsBeforeFilteringProgress(_ lineBreak: String, _ resolved: Bool) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let parent = root.appendingPathComponent("project" + lineBreak + "private")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let mirror = parent.appendingPathComponent(".agent/cache/mirrors/source.git.staging-review")
    let emittedPath = resolved ? mirror.resolvingSymlinksInPath().path : mirror.path
    let source = "https://example.com/source.git"
    let command = ["/usr/bin/env", "git", "clone", source, mirror.path]
    let error = GitError(
      operation: .clone, source: source,
      stderr:
        "Cloning into bare repository '\(emittedPath)'...\nfatal: cannot write '\(emittedPath)/config'\n",
      command: command, exitCode: 128, replacingPaths: [parent, mirror])

    #expect(error.stderr == "fatal: cannot write '\(source)/config'")
    #expect(error.description == "Git could not clone \(source).\n" + error.stderr)
    #expect(error.command == command)
  }

  @Test(arguments: ["\n", "\r"])
  func redactsMultilineCachePathsEmittedByGit(_ lineBreak: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let mirror = root.appendingPathComponent("project" + lineBreak + "private")
      .appendingPathComponent(".agent/cache/mirrors/source.git.staging-review")
    let source = "https://example.com/source.git"
    let arguments = ["-C", mirror.path, "rev-parse", "--verify", "HEAD"]

    let error = try #require(throws: GitError.self) {
      try ProcessRunner.git(
        arguments, operation: .resolveRevision(revision: "HEAD"), source: source,
        replacingPaths: [mirror])
    }

    #expect(error.stderr.contains(source))
    #expect(!error.stderr.contains("project"))
    #expect(!error.stderr.contains("private"))
    #expect(!error.stderr.contains(".agent/cache"))
    #expect(!error.stderr.contains(".staging-"))
    #expect(error.command == ["/usr/bin/env", "git"] + arguments)
  }

  @Test func emptyDiagnosticHasOnlyTheSummary() {
    let error = GitError(
      operation: .clone, source: "https://example.com/source.git",
      stderr: "Cloning into bare repository 'cache.git'...\r\n", command: [], exitCode: 1)
    #expect(error.stderr.isEmpty)
    #expect(error.description == "Git could not clone https://example.com/source.git.")
  }

  @Test func gitChildrenDisablePromptsAndPreserveCallerEnvironment() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let upstream = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try Data("content".utf8).write(to: upstream.appendingPathComponent("content"))
    try initGitRepo(upstream)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let git = bin.appendingPathComponent("git")
    try Data(
      """
      #!/bin/sh
      printf '%s|%s|%s|%s\\n' "$GIT_TERMINAL_PROMPT" "$GCM_INTERACTIVE" \
        "$GIT_TEST_SENTINEL" "$SSH_AUTH_SOCK" >> "$GIT_TEST_LOG"
      exec /usr/bin/git "$@"
      """.utf8
    ).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
    let log = root.appendingPathComponent("git-environment.log")
    let process = try stateTestProcess(
      root: root, arguments: ["git-environment"],
      environment: [
        "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
        "GIT_TERMINAL_PROMPT": "1", "GCM_INTERACTIVE": "always",
        "GIT_TEST_SENTINEL": "preserved", "SSH_AUTH_SOCK": "fixture-socket",
        "GIT_TEST_LOG": log.path,
      ])
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    // Clone/fetch hold a mirror lock; local inspection uses Foundation.Process.
    #expect(lines.count >= 12)
    #expect(lines.allSatisfy { $0 == "0|never|preserved|fixture-socket" })
  }

  private func expectConcise(
    _ error: GitError, operation: GitError.Operation, source: String, cache: SourceCache
  ) {
    #expect(error.operation == operation)
    #expect(error.source == source)
    #expect(error.description.hasPrefix("Git could not \(operation) \(source).\n"))
    #expect(!error.stderr.isEmpty)
    #expect(!error.description.contains(cache.store.cacheDirectory.path))
    #expect(!error.description.contains(".staging-"))
    #expect(!error.description.contains(" -c "))
    #expect(!error.description.contains("Cloning into "))
    #expect(!error.description.contains("Command failed:"))
  }
}
