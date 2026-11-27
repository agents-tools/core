import CPlatform
import Foundation
import Testing

@testable import AgentsCore

@Suite struct ClientBackupTests {
  @Test(arguments: [true, false])
  func codexRestoresWALStateAndKeepsUnrelatedSessions(sourceSetsSQLiteHome: Bool) throws {
    let fixture = try Fixture()
    let sourceHome = try fixture.directory("source")
    let backupFolder = try fixture.directory("backups")
    let oldProject = try fixture.directory("work/old")
    let newProject = try fixture.directory("work/new")
    let sourceClient = try fixture.directory("source/codex-config")
    let sourceDB = try fixture.directory("source/codex-db")
    let source = fixture.environment(
      sourceHome,
      [
        "CODEX_HOME": sourceClient.path, "CODEX_SQLITE_HOME": sourceDB.path,
      ])
    let rolloutName = "sessions/2026/11/25/rollout-thread.jsonl"
    let sourceRollout = sourceClient.appendingPathComponent(rolloutName)
    let event = try fixture.json([
      "type": "session_meta",
      "payload": [
        "cwd": oldProject.path, "id": "thread",
        "runtime_workspace_roots": [oldProject.path],
      ],
    ])
    try fixture.put(sourceRollout, event + "\n{\"type\":\"response_item\"}\n")
    try fixture.put(
      sourceClient, "archived_sessions/archived.jsonl", "{\"type\":\"session_meta\"}\n")
    try fixture.put(sourceClient, "attachments/thread/data.bin", "attachment")
    try fixture.put(
      sourceClient, "session_index.jsonl", "{\"id\":\"thread\",\"thread_name\":\"restored\"}\n")
    try fixture.put(sourceClient, "auth.json", "{\"token\":\"fixture-secret\"}")
    let archivedConfig =
      sourceSetsSQLiteHome
      ? "# keep this comment\nsqlite_home = \"\(sourceDB.path)\"\n"
      : "# keep this comment\n[features]\n"
    try fixture.put(sourceClient, "config.toml", archivedConfig)
    try fixture.put(oldProject, ".codex/config.toml", "model = \"fixture\"\n")
    try fixture.put(oldProject, ".git/irrelevant", "exclude")
    try fixture.put(oldProject, "work.txt", "exclude")

    let state = try createCodexDB(sourceDB, wal: true)
    try state.execute(
      "INSERT INTO threads VALUES (?,?,?)",
      [
        .text("thread"), .text(oldProject.path), .text(sourceRollout.path),
      ])
    try state.execute("INSERT INTO thread_attachments VALUES ('thread','one','attachment')")
    try state.execute("INSERT INTO thread_read_receipts VALUES ('thread',42)")
    let projection = sourceDB.appendingPathComponent("thread_history_1.sqlite")
    try Data().write(to: projection)
    do {
      let history = try BackupSQL(projection, writable: true)
      try history.execute(
        """
        CREATE TABLE thread_history_projection_state (
          thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER
        )
        """)
      try history.execute(
        "INSERT INTO thread_history_projection_state VALUES ('thread',?)",
        [
          .integer(Int64(event.utf8.count + 1))
        ])
    }
    #expect(
      FileManager.default.fileExists(
        atPath: sourceDB.appendingPathComponent("state_5.sqlite-wal").path))
    let package = try ClientBackups.create(
      client: .codex, projects: [oldProject], to: backupFolder, environment: source)
    #expect(try ClientBackups.inspect(package).projects == [oldProject.path])
    let mode =
      try FileManager.default.attributesOfItem(atPath: package.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    try fixture.remove(sourceHome)
    try fixture.remove(oldProject)
    withExtendedLifetime(state) {}

    let home = try fixture.directory("destination")
    let client = try fixture.directory("destination/.codex")
    let database = sourceSetsSQLiteHome ? client : try fixture.directory("destination/custom-db")
    if !sourceSetsSQLiteHome {
      try fixture.put(client, "config.toml", "sqlite_home = \"\(database.path)\"\n")
    }
    let destination = fixture.environment(home)
    let existing = try createCodexDB(database)
    try existing.execute(
      "INSERT INTO threads VALUES ('unrelated','/elsewhere','/elsewhere/rollout')")
    try existing.execute("INSERT INTO thread_attachments VALUES ('unrelated','other','keep')")
    try fixture.put(client, "session_index.jsonl", "{\"id\":\"unrelated\"}\n")
    let preview = try ClientBackups.preview(
      package, projects: [oldProject.path: newProject], environment: destination)
    #expect(
      preview.files.contains {
        $0.path == database.appendingPathComponent("state_5.sqlite").path && $0.kind == .replace
      })
    #expect(!preview.files.contains { $0.path.contains("fixture-secret") })
    #expect(!preview.files.contains { $0.path.hasSuffix("work.txt") || $0.path.contains("/.git/") })
    try ClientBackups.restore(preview)
    let newRollout = client.appendingPathComponent(rolloutName)
    let restoredRecord = try fixture.read(newRollout)
    #expect(restoredRecord.contains(newProject.path))
    #expect(!restoredRecord.contains(oldProject.path))
    #expect(try fixture.read(client, "attachments/thread/data.bin") == "attachment")
    #expect(try fixture.read(client, "auth.json").contains("fixture-secret"))
    let restoredConfig = try fixture.read(client, "config.toml")
    let expectedConfig =
      sourceSetsSQLiteHome
      ? "# keep this comment\nsqlite_home = \"\(database.path)\"\n"
      : "sqlite_home = \"\(database.path)\"\n" + archivedConfig
    #expect(restoredConfig == expectedConfig)
    let effective = try BackupRoots(.codex, environment: destination, projects: [:])
    #expect(effective.database.path == database.path)
    do {
      let history = try BackupSQL(database.appendingPathComponent("thread_history_1.sqlite"))
      let newMeta = try #require(try fixture.read(newRollout).split(separator: "\n").first)
      try history.rows("SELECT next_rollout_byte_offset FROM thread_history_projection_state") {
        row in
        let offset = try BackupSQL.integer(row, 0)
        #expect(offset == Int64(newMeta.utf8.count + 1))
      }
    }
    #expect(try fixture.read(client, "session_index.jsonl").contains("unrelated"))
    #expect(try fixture.read(newProject, ".codex/config.toml") == "model = \"fixture\"\n")
    do {
      let restored = try BackupSQL(
        database.appendingPathComponent("state_5.sqlite"), writable: true)
      var roots: [String: [String]] = [:]
      try restored.rows("SELECT id,cwd,rollout_path FROM threads") { row in
        roots[try BackupSQL.text(row, 0)] = [
          try BackupSQL.text(row, 1), try BackupSQL.text(row, 2),
        ]
      }
      #expect(roots["thread"] == [newProject.path, newRollout.path])
      #expect(roots["unrelated"] == ["/elsewhere", "/elsewhere/rollout"])
      var attachments: [String] = []
      try restored.rows("SELECT content FROM thread_attachments ORDER BY content") {
        attachments.append(try BackupSQL.text($0, 0))
      }
      #expect(attachments == ["attachment", "keep"])
      try restored.execute("UPDATE thread_read_receipts SET turn=43 WHERE thread_id='thread'")
    }
    try fixture.append(newRollout, "{\"type\":\"response_item\",\"turn\":3}\n")
    #expect(try fixture.read(newRollout).contains("\"turn\":3"))
    try fixture.put(newProject, ".codex/config.toml", "model = \"updated\"\n")
    #expect(try fixture.read(newProject, ".codex/config.toml").contains("updated"))
  }

  @Test(
    .enabled(if: BackupZstd.executable(path: ProcessInfo.processInfo.environment["PATH"]) != nil))
  func codexRelocatesCompressedRolloutsWithoutChangingPackageBytes() throws {
    let fixture = try Fixture()
    let source = try fixture.directory("source")
    let client = try fixture.directory("source/.codex")
    let destination = try fixture.directory("destination")
    let project = try fixture.directory("project")
    let moved = try fixture.directory("moved")
    let backups = try fixture.directory("packages")
    let rollout = "archived_sessions/rollout-thread.jsonl.zst"
    let text = source.appendingPathComponent("original.jsonl")
    let original =
      try fixture.json([
        "type": "session_meta", "payload": ["cwd": project.path, "id": "thread"],
      ]) + "\n"
    try fixture.put(text, original)
    let available = BackupZstd.executable(path: ProcessInfo.processInfo.environment["PATH"])
    let tool = try #require(available)
    let archiveFolder = try fixture.directory("source/.codex/archived_sessions")
    try BackupIO.write("rollout-thread.jsonl.zst", in: DirectoryHandle(at: archiveFolder)) {
      try BackupZstd.transcode(text, into: $0, using: tool, decode: false)
    }
    let compressedURL = client.appendingPathComponent(rollout)
    let compressed = try Data(contentsOf: compressedURL)
    do {
      let db = try createCodexDB(client)
      try db.execute(
        "INSERT INTO threads VALUES (?,?,?)",
        [
          .text("thread"), .text(project.path), .text(compressedURL.path),
        ])
    }
    let package = try ClientBackups.create(
      client: .codex, projects: [project], to: backups, environment: fixture.environment(source))
    try fixture.remove(source)
    let archive = try BackupArchive(reading: package)
    let archived = try #require(archive.manifest.entries.first { $0.path == rollout })
    var bytes = Data()
    try archive.read(archived) { bytes.append($0) }
    #expect(compressed == bytes)
    let preview = try ClientBackups.preview(
      package, projects: [project.path: moved], environment: fixture.environment(destination))
    try ClientBackups.restore(preview)
    let restored = destination.appendingPathComponent(".codex/" + rollout)
    try BackupIO.write("decoded.jsonl", in: DirectoryHandle(at: fixture.root)) {
      try BackupZstd.transcode(restored, into: $0, using: tool, decode: true)
    }
    let relocated = try fixture.read(fixture.root, "decoded.jsonl")
    #expect(relocated.contains(moved.path) && !relocated.contains(project.path))
    let db = try BackupSQL(destination.appendingPathComponent(".codex/state_5.sqlite"))
    try db.rows("SELECT cwd,rollout_path FROM threads WHERE id='thread'") { row in
      let cwd = try BackupSQL.text(row, 0)
      let path = try BackupSQL.text(row, 1)
      #expect(cwd == moved.path && path == restored.path)
    }
  }

  @Test func claudeAndGeminiProduceIndependentPackagesAndRemapNativeIndexes() throws {
    let fixture = try Fixture()
    let source = try fixture.directory("source")
    let output = try fixture.directory("packages")
    let oldProject = try fixture.directory("projects/original")
    let newProject = try fixture.directory("projects/relocated")
    let otherProject = try fixture.directory("projects/other")
    let sourceClaude = try fixture.directory("source/claude-profile")
    let sourceGeminiHome = try fixture.directory("source/gemini-home")
    let sourceGemini = try fixture.directory("source/gemini-home/.gemini")
    let originalKey = fixture.claudeKey(oldProject)
    let localKey = fixture.claudeKey(newProject)
    let sessionFolder = "projects/\(originalKey)"
    let originalSession = sourceClaude.appendingPathComponent(sessionFolder + "/thread.jsonl")
    try fixture.put(originalSession, fixture.json(["cwd": oldProject.path, "type": "user"]) + "\n")
    try fixture.put(
      sourceClaude, sessionFolder + "/thread/subagents/agent.jsonl", "{\"type\":\"assistant\"}\n")
    try fixture.put(sourceClaude, sessionFolder + "/thread/tool-results/result.txt", "tool output")
    try fixture.put(
      sourceClaude, sessionFolder + "/sessions-index.json",
      fixture.json([
        "version": 1, "entries": [["sessionId": "thread", "fullPath": originalSession.path]],
      ]))
    try fixture.put(
      sourceClaude, ".claude.json",
      fixture.json([
        "projects": [oldProject.path: ["mcpServers": ["test": ["command": "fixture"]]]]
      ]))
    try fixture.put(sourceClaude, "settings.json", "{\"theme\":\"dark\"}")
    try fixture.put(oldProject, ".claude/hooks/run.sh", "#!/bin/sh\nexit 0\n", mode: 0o700)
    try fixture.put(oldProject, ".claude/settings.local.json", "{\"model\":\"custom\"}")
    try fixture.put(sourceGemini, "tmp/original/.project_root", oldProject.path)
    try fixture.put(
      sourceGemini, "tmp/original/chats/session-fixture.json",
      fixture.json([
        "sessionId": "gemini", "projectHash": FileHash.sha256Hex(data: Data(oldProject.path.utf8)),
        "messages": [["type": "user", "content": "hello"]],
      ]))
    try fixture.put(sourceGemini, "tmp/original/cache/download", "exclude")
    try fixture.put(sourceGemini, "tmp/other/.project_root", otherProject.path)
    try fixture.put(sourceGemini, "tmp/other/chats/second.json", "{\"messages\":[]}")
    try fixture.put(
      sourceGemini, "projects.json",
      fixture.json([
        "projects": [oldProject.path: "original", otherProject.path: "other"]
      ]))
    try fixture.put(sourceGemini, "settings.json", "{\"model\":{\"name\":\"fixture\"}}")
    try fixture.put(
      oldProject, ".gemini/settings.json", "{\"context\":{\"fileName\":\"GEMINI.md\"}}")
    let sourceEnvironment = fixture.environment(
      source,
      [
        "CLAUDE_CONFIG_DIR": sourceClaude.path, "GEMINI_CLI_HOME": sourceGeminiHome.path,
      ])
    let claude = try ClientBackups.create(
      client: .claudeCode, projects: [oldProject], to: output, environment: sourceEnvironment)
    let gemini = try ClientBackups.create(
      client: .geminiCLI, projects: [oldProject], to: output, environment: sourceEnvironment)
    #expect(claude != gemini)
    try fixture.remove(source)
    try fixture.remove(oldProject)

    let home = try fixture.directory("destination")
    let environment = fixture.environment(home)
    let existingProject = try fixture.directory("projects/existing")
    try fixture.put(
      home, ".claude.json",
      fixture.json([
        "projects": [existingProject.path: ["lastSessionId": "keep"]]
      ]))
    try fixture.put(
      home, ".gemini/projects.json",
      fixture.json([
        "projects": [newProject.path: "existing", existingProject.path: "keep"]
      ]))
    try fixture.put(home, ".gemini/tmp/existing/.project_root", newProject.path)
    try fixture.put(home, ".gemini/tmp/existing/chats/keep.json", "{\"messages\":[]}")
    let map = [oldProject.path: newProject]
    let claudePreview = try ClientBackups.preview(claude, projects: map, environment: environment)
    let geminiPreview = try ClientBackups.preview(gemini, projects: map, environment: environment)
    #expect(claudePreview.client == .claudeCode)
    #expect(geminiPreview.client == .geminiCLI)
    try ClientBackups.restore(claudePreview)
    try ClientBackups.restore(geminiPreview)
    let transcript = home.appendingPathComponent(".claude/projects/\(localKey)/thread.jsonl")
    #expect(try fixture.read(transcript).contains(newProject.path))
    #expect(
      try fixture.read(home, ".claude/projects/\(localKey)/sessions-index.json").contains(
        transcript.path))
    #expect(
      try fixture.read(home, ".claude/projects/\(localKey)/thread/tool-results/result.txt")
        == "tool output")
    #expect(try fixture.read(home, ".claude.json").contains(existingProject.path))
    #expect(try fixture.read(home, ".claude.json").contains(newProject.path))
    let hook = newProject.appendingPathComponent(".claude/hooks/run.sh")
    #expect(
      try FileManager.default.attributesOfItem(atPath: hook.path)[.posixPermissions] as? Int
        == 0o700)
    try fixture.append(transcript, "{\"type\":\"assistant\"}\n")
    #expect(try fixture.read(transcript).contains("assistant"))
    let chat = home.appendingPathComponent(".gemini/tmp/existing/chats/session-fixture.json")
    #expect(try fixture.read(chat).contains("hello"))
    #expect(try fixture.read(chat).contains(FileHash.sha256Hex(data: Data(newProject.path.utf8))))
    try fixture.put(chat, "{\"sessionId\":\"gemini\",\"messages\":[\"hello\",\"continued\"]}")
    #expect(try fixture.read(chat).contains("continued"))
    #expect(try fixture.read(home, ".gemini/tmp/existing/chats/keep.json") == "{\"messages\":[]}")
    #expect(try fixture.read(home, ".gemini/tmp/other/chats/second.json") == "{\"messages\":[]}")
    #expect(
      !FileManager.default.fileExists(
        atPath: home.appendingPathComponent(".gemini/tmp/original/cache").path))
    #expect(try fixture.read(newProject, ".gemini/settings.json").contains("GEMINI.md"))
  }

  @Test func stalePreviewsAndFailedPublicationPreserveDestination() throws {
    let fixture = try Fixture()
    let home = try fixture.directory("home")
    let dest = try fixture.directory("restore")
    let output = try fixture.directory("output")
    try fixture.put(home, ".codex/config.toml", "new")
    try fixture.put(home, ".codex/AGENTS.md", "rules")
    try fixture.put(home, ".codex/archived_sessions/thread.jsonl", "{}\n")
    try fixture.put(dest, ".codex/config.toml", "before")
    let package = try ClientBackups.create(
      client: .codex, projects: [], to: output, environment: fixture.environment(home))
    let environment = fixture.environment(dest)
    let stale = try ClientBackups.preview(package, projects: [:], environment: environment)
    try fixture.put(dest, ".codex/config.toml", "changed since preview")
    #expect(throws: ClientBackupError.self) { try ClientBackups.restore(stale) }

    let plan = try ClientBackups.preview(package, projects: [:], environment: environment)
    let fault: @Sendable (String) throws -> Void = { step in
      if step == "published" { throw PublicationFailure.injected }
    }
    #expect(throws: PublicationFailure.self) {
      try BackupRestoreTransaction.$checkpoint.withValue(fault) {
        try ClientBackups.restore(plan)
      }
    }
    #expect(try fixture.read(dest, ".codex/config.toml") == "changed since preview")
    #expect(
      !FileManager.default.fileExists(atPath: dest.appendingPathComponent(".codex/AGENTS.md").path))
    let fresh = try ClientBackups.preview(package, projects: [:], environment: environment)
    try ClientBackups.restore(fresh)
    let unchanged = try ClientBackups.preview(package, projects: [:], environment: environment)
    #expect(unchanged.files.count == 3)
    #expect(unchanged.files.allSatisfy { $0.kind == .unchanged })
    try ClientBackups.restore(unchanged)
  }

  @Test func pendingJournalRollsBackOnNextRestoreAttempt() throws {
    let fixture = try Fixture()
    let home = try fixture.directory("home")
    let dest = try fixture.directory("restore")
    let output = try fixture.directory("output")
    try fixture.put(home, ".claude/CLAUDE.md", "restored guidance")
    try fixture.put(home, ".claude/settings.json", "{\"theme\":\"source\"}")
    try fixture.put(dest, ".claude/CLAUDE.md", "existing guidance")
    let package = try ClientBackups.create(
      client: .claudeCode, projects: [], to: output, environment: fixture.environment(home))
    let env = fixture.environment(dest)
    let preview = try ClientBackups.preview(package, projects: [:], environment: env)
    let fault: @Sendable (String) throws -> Void = { step in
      if step == "published" || step == "recovering" { throw PublicationFailure.injected }
    }
    #expect(throws: ClientBackupError.self) {
      try BackupRestoreTransaction.$checkpoint.withValue(fault) {
        try ClientBackups.restore(preview)
      }
    }
    #expect(try fixture.read(dest, ".claude/CLAUDE.md") == "restored guidance")
    let loaded = try ClientBackups.preview(package, projects: [:], environment: env)
    #expect(throws: ClientBackupError.self) { try ClientBackups.restore(loaded) }
    #expect(try fixture.read(dest, ".claude/CLAUDE.md") == "existing guidance")
    let verified = try ClientBackups.preview(package, projects: [:], environment: env)
    try ClientBackups.restore(verified)
    #expect(try fixture.read(dest, ".claude/CLAUDE.md") == "restored guidance")
  }

  @Test func rejectsCorruptionUnsafePathsAndUnknownDatabaseConflicts() throws {
    let fixture = try Fixture()
    let home = try fixture.directory("home")
    let dest = try fixture.directory("restore")
    let outside = try fixture.directory("outside")
    let output = try fixture.directory("output")
    try fixture.put(home, ".codex/AGENTS.md", "rules")
    try fixture.put(home, ".codex/archived_sessions/session.jsonl", "{}\n")
    let skill = try fixture.directory("outside/owned-skill")
    let skills = try fixture.directory("home/.codex/skills")
    try fixture.put(skill, "SKILL.md", "---\nname: test\ndescription: Example\n---\n# Test\n")
    try fixture.put(skill, "references/notes.md", "owned resource")
    try FileManager.default.createSymbolicLink(
      at: skills.appendingPathComponent("owned"), withDestinationURL: skill)
    let package = try ClientBackups.create(
      client: .codex, projects: [], to: output, environment: fixture.environment(home))
    try fixture.put(outside, "session.jsonl", "outside")
    let client = try fixture.directory("restore/.codex")
    let link = client.appendingPathComponent("archived_sessions")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let env = fixture.environment(dest)
    #expect(throws: ClientBackupError.self) {
      _ = try ClientBackups.preview(package, projects: [:], environment: env)
    }
    #expect(try fixture.read(outside, "session.jsonl") == "outside")
    try fixture.remove(link)
    try fixture.put(client, "agents.md", "case conflict")
    #expect(throws: ClientBackupError.self) {
      _ = try ClientBackups.preview(package, projects: [:], environment: env)
    }
    try fixture.remove(client.appendingPathComponent("agents.md"))
    let linked = try ClientBackups.preview(package, projects: [:], environment: env)
    #expect(linked.files.contains { $0.path.hasSuffix("skills/owned/references/notes.md") })
    #expect(!linked.files.contains { $0.path.contains("/unowned/") })
    try ClientBackups.restore(linked)
    #expect(try fixture.read(client, "skills/owned/references/notes.md") == "owned resource")

    let writable = try BackupSQL(package, writable: true)
    try writable.execute("UPDATE chunks SET bytes=X'FF' WHERE file=1 AND part=0")
    #expect(throws: ClientBackupError.self) { _ = try ClientBackups.inspect(package) }
    #expect(throws: ClientBackupError.self) {
      _ = try ClientBackups.preview(package, projects: [:], environment: env)
    }
    let folder = try DirectoryHandle(at: output)
    let invalid = "invalid.agentsbackup"
    do {
      let header = BackupHeader(
        client: .codex, sourceHome: home.path, sourceClient: home.path,
        sourceDatabase: home.path, projects: [])
      let archive = try BackupArchive(writing: invalid, in: folder, header: header)
      let file = try DirectoryHandle(at: home.appendingPathComponent(".codex"))
      let current = try BackupIO.generation(file, "AGENTS.md")
      let generation = try #require(current)
      try archive.add(
        root: "client", path: "sessions/../../escape", mode: 0o600, parent: file,
        name: "AGENTS.md", generation: generation)
      try archive.finish()
    }
    #expect(throws: ClientBackupError.self) {
      _ = try ClientBackups.inspect(output.appendingPathComponent(invalid))
    }

    let sourceDB = try createCodexDB(home.appendingPathComponent(".codex"))
    try sourceDB.execute("CREATE TABLE unclassified (id TEXT PRIMARY KEY, value TEXT)")
    try sourceDB.execute("INSERT INTO unclassified VALUES ('fixture','sensitive')")
    let targetDB = try createCodexDB(client)
    try targetDB.execute("CREATE TABLE unclassified (id TEXT PRIMARY KEY, value TEXT)")
    let original = try BackupIO.fingerprint(client.appendingPathComponent("state_5.sqlite"))
    let conflict = try ClientBackups.create(
      client: .codex, projects: [], to: output, environment: fixture.environment(home))
    #expect(throws: ClientBackupError.self) {
      _ = try ClientBackups.preview(conflict, projects: [:], environment: env)
    }
    #expect(try BackupIO.fingerprint(client.appendingPathComponent("state_5.sqlite")) == original)
  }

  @Test func restoresSharedAndClaudeSkillLinksAfterDonorIsGone() throws {
    let f = try Fixture()
    let source = try f.directory("source")
    let output = try f.directory("output")
    let donor = try f.directory("donor")
    let skill = try f.directory("donor/skills/check")
    let shared = try f.directory("source/.agents/skills")
    let claude = try f.directory("source/.claude/skills")
    let unrelated = try f.directory("outside")
    try f.put(donor, ".git/HEAD", "donor repository metadata")
    try f.put(donor, "unrelated.txt", "outside selected skill")
    try f.put(skill, "SKILL.md", "---\nname: check\n---\n# Check\n")
    try f.put(skill, "scripts/check.sh", "#!/bin/sh\nexit 0\n", mode: 0o751)
    try f.put(unrelated, "scripts/check.sh", "destination donor sentinel")
    let sharedLink = shared.appendingPathComponent("check")
    try FileManager.default.createSymbolicLink(at: sharedLink, withDestinationURL: skill)
    try FileManager.default.createSymbolicLink(
      at: claude.appendingPathComponent("check"), withDestinationURL: sharedLink)
    try f.put(source, ".claude/projects/example/thread.jsonl", "{\"type\":\"user\"}\n")
    let environment = f.environment(source)

    let escaping = skill.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: unrelated)
    do {
      _ = try ClientBackups.create(
        client: .claudeCode, projects: [], to: output, environment: environment)
      Issue.record("escaping dependency was admitted")
    } catch ClientBackupError.invalidLocation(let path) {
      #expect(path == escaping.path)
    }
    try f.remove(escaping)
    let bad = shared.appendingPathComponent("not-a-skill")
    try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: unrelated)
    do {
      _ = try ClientBackups.create(
        client: .claudeCode, projects: [], to: output, environment: environment)
      Issue.record("unowned skill directory was admitted")
    } catch ClientBackupError.invalidLocation(let path) {
      #expect(path == bad.path)
    }
    try f.remove(bad)

    let package = try ClientBackups.create(
      client: .claudeCode, projects: [], to: output, environment: environment)
    try f.remove(donor)
    try f.remove(source)
    let empty = try f.directory("empty")
    let clean = try ClientBackups.preview(package, projects: [:], environment: f.environment(empty))
    try ClientBackups.restore(clean)
    #expect(
      clean.files.allSatisfy { !$0.path.hasSuffix("unrelated.txt") && !$0.path.contains("/.git/") })
    for slot in [".agents", ".claude"] {
      let script = empty.appendingPathComponent(slot + "/skills/check/scripts/check.sh")
      let mode =
        try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
      #expect(mode == 0o751)
      #expect(try f.read(script).hasPrefix("#!/bin/sh"))
    }

    let existing = try f.directory("existing")
    let existingSlot = try f.directory("existing/.claude/skills").appendingPathComponent("check")
    try FileManager.default.createSymbolicLink(at: existingSlot, withDestinationURL: unrelated)
    let env = f.environment(existing)
    let preview = try ClientBackups.preview(package, projects: [:], environment: env)
    #expect(preview.files.contains { $0.path == existingSlot.path && $0.kind == .replace })
    #expect(preview.files.contains { $0.path.hasSuffix("thread.jsonl") && $0.kind == .add })
    let rollback: @Sendable (String) throws -> Void = { step in
      if step == "published", (try? BackupIO.directory(existingSlot)) != nil {
        throw PublicationFailure.injected
      }
    }
    #expect(throws: PublicationFailure.self) {
      try BackupRestoreTransaction.$checkpoint.withValue(rollback) {
        try ClientBackups.restore(preview)
      }
    }
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: existingSlot.path) == unrelated.path
    )
    try ClientBackups.restore(ClientBackups.preview(package, projects: [:], environment: env))
    #expect(try BackupIO.directory(existingSlot) != nil)
    #expect(
      try f.read(existing, ".claude/projects/example/thread.jsonl") == "{\"type\":\"user\"}\n")
    #expect(try f.read(unrelated, "scripts/check.sh") == "destination donor sentinel")
  }

  @Test func restoresClaudeInstructionImportsFromTheAdmittedScopes() throws {
    let f = try Fixture()
    let home = try f.directory("home")
    let project = try f.directory("project")
    let chosen = try f.directory("relocated")
    let dest = try f.directory("target")
    let output = try f.directory("archive")
    try f.put(
      project, "CLAUDE.md",
      """
      - Workflow @docs/git-instructions.md
      - User instructions @~/.claude/preferences.md
      - Absolute @\(project.path)/docs/absolute.md
      - External @\(f.root.path)/outside/private.md
      - Literal `@absent-inline.md`
      - Literal "@absent-quoted.md"
      ```md
      @absent-fenced.md
      ```
      """)
    try f.put(project, "docs/git-instructions.md", "See @detail\\ notes.md\n")
    try f.put(project, "docs/detail notes.md", "Back to @git-instructions.md\n")
    try f.put(project, "docs/unrelated.md", "exclude")
    try f.put(project, "docs/absolute.md", "absolute source")
    try f.put(f.root, "outside/private.md", "excluded unrelated fixture")
    try f.put(home, ".claude/preferences.md", "fixture preference")
    let package = try ClientBackups.create(
      client: .claudeCode, projects: [project], to: output, environment: f.environment(home))
    try f.remove(home)
    try f.remove(project)
    let preview = try ClientBackups.preview(
      package, projects: [project.path: chosen], environment: f.environment(dest))
    try ClientBackups.restore(preview)
    #expect(try f.read(chosen, "docs/detail notes.md") == "Back to @git-instructions.md\n")
    #expect(try f.read(dest, ".claude/preferences.md") == "fixture preference")
    #expect(try f.read(chosen, "docs/absolute.md") == "absolute source")
    #expect(try f.read(chosen, "CLAUDE.md").contains("@" + chosen.path + "/docs/absolute.md"))
    #expect(
      !preview.files.contains {
        $0.path.hasSuffix("unrelated.md") || $0.path.hasSuffix("private.md")
      })
  }

  @Test func restoresClaudeImportsBetweenSelectedProjectsWithOverlappingRoots() throws {
    let f = try Fixture()
    let home = try f.directory("source-profile")
    let a = try f.directory("source/A")
    let b = try f.directory("source/B")
    let nested = try f.directory("source/B/nested")
    let unselected = try f.directory("source/C")
    let newA = try f.directory("restore/first/application")
    let newB = try f.directory("restore/second/documentation")
    let newNested = try f.directory("restore/third/extension")
    let destination = try f.directory("destination-profile")
    let output = try f.directory("packages")
    try f.put(
      a, "CLAUDE.md",
      """
      @../B/docs/team.md
      @../B/nested/docs/team.md
      @../C/docs/unselected.md
      """)
    try f.put(b, "docs/team.md", "Sibling instructions\n")
    try f.put(nested, "docs/team.md", "Nested instructions\n")
    try f.put(unselected, "docs/unselected.md", "Unselected instructions\n")

    let package = try ClientBackups.create(
      client: .claudeCode, projects: [a, b, nested], to: output, environment: f.environment(home))
    let archive = try BackupArchive(reading: package)
    #expect(!archive.manifest.entries.contains { $0.path.hasSuffix("unselected.md") })
    try f.remove(f.root.appendingPathComponent("source"))
    try f.remove(home)

    let preview = try ClientBackups.preview(
      package, projects: [a.path: newA, b.path: newB, nested.path: newNested],
      environment: f.environment(destination))
    try ClientBackups.restore(preview)
    let restored = try f.read(newA, "CLAUDE.md")
    let imports = restored.split(separator: "\n").map { String($0.dropFirst()) }
    #expect(
      imports == [
        newB.appendingPathComponent("docs/team.md").path,
        newNested.appendingPathComponent("docs/team.md").path,
        "../C/docs/unselected.md",
      ])
    let sibling = try #require(imports.first)
    let extensionFile = try #require(imports.dropFirst().first)
    #expect(try f.read(URL(fileURLWithPath: sibling)) == "Sibling instructions\n")
    #expect(try f.read(URL(fileURLWithPath: extensionFile)) == "Nested instructions\n")
    #expect(!FileManager.default.fileExists(atPath: newB.appendingPathComponent("nested").path))
  }

  @Test func restoresGeminiCheckpointObjectsAndToolOutputWithoutTheShadowRepository() throws {
    let f = try Fixture()
    let source = try f.directory("source")
    let project = try f.directory("project")
    let target = try f.directory("target")
    let moved = try f.directory("moved")
    let output = try f.directory("output")
    let client = try f.directory("source/.gemini")
    let shadow = try f.directory("source/.gemini/history/example")
    let sh = try DirectoryHandle(at: shadow)
    try BackupGeminiCheckpoints.git(
      ["init", "--quiet", "--initial-branch=main", "--template="], in: sh)
    func commit(_ message: String) throws -> String {
      try BackupGeminiCheckpoints.git(["add", "."], in: sh)
      try BackupGeminiCheckpoints.git(
        [
          "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
          "commit", "--quiet", "-m", message,
        ], in: sh)
      return try BackupGeminiCheckpoints.git(["rev-parse", "HEAD"], in: sh)
    }
    try f.put(shadow, "snapshot.txt", "checkpoint snapshot")
    let sha = try commit("checkpoint")
    try f.put(shadow, "unrelated-object.txt", "exclude unreachable commit")
    let unrelated = try commit("later unrelated commit")
    try f.put(client, "projects.json", f.json(["projects": [project.path: "example"]]))
    try f.put(client, "tmp/example/.project_root", project.path)
    try f.put(client, "tmp/example/tool-outputs/session-id/read_1.txt", "tool output")
    try f.put(
      client, "tmp/example/checkpoints/snapshot.json",
      f.json([
        "commitHash": String(sha.prefix(9)),
        "toolCall": [
          "name": "write_file",
          "args": ["file_path": project.appendingPathComponent("snapshot.txt").path],
        ],
      ]))
    let package = try ClientBackups.create(
      client: .geminiCLI, projects: [project], to: output, environment: f.environment(source))
    try f.remove(source)
    try f.remove(project)
    let native = target.appendingPathComponent(".gemini")
    try f.put(native, "projects.json", f.json(["projects": [moved.path: "destination"]]))
    try f.put(native, "tmp/destination/.project_root", moved.path)
    let env = f.environment(target)
    let preview = try ClientBackups.preview(
      package, projects: [project.path: moved], environment: env)
    try ClientBackups.restore(preview)
    let record = try BackupNativeJSON.object(
      native.appendingPathComponent("tmp/destination/checkpoints/snapshot.json"))
    #expect(record["commitHash"] as? String == sha)
    #expect(try f.read(native, "tmp/destination/checkpoints/snapshot.json").contains(moved.path))
    #expect(
      try f.read(native, "tmp/destination/tool-outputs/session-id/read_1.txt") == "tool output")
    let git = [
      "--git-dir=" + native.appendingPathComponent("history/destination/.git").path,
      "--work-tree=" + moved.path,
    ]
    let working = try DirectoryHandle(at: moved)
    #expect(throws: ClientBackupError.self) {
      try BackupGeminiCheckpoints.git(git + ["cat-file", "-e", unrelated], in: working)
    }
    try BackupGeminiCheckpoints.git(git + ["restore", "--source", sha, "."], in: working)
    try BackupGeminiCheckpoints.git(git + ["clean", "-fd"], in: working)
    #expect(try f.read(moved, "snapshot.txt") == "checkpoint snapshot")

    try f.put(moved, "additional.txt", "existing destination history")
    try BackupGeminiCheckpoints.git(git + ["add", "additional.txt"], in: working)
    try BackupGeminiCheckpoints.git(
      git + [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
        "commit", "--quiet", "-m", "destination commit",
      ], in: working)
    let currentHead = try BackupGeminiCheckpoints.git(git + ["rev-parse", "HEAD"], in: working)
    let second = try ClientBackups.preview(
      package, projects: [project.path: moved], environment: env)
    try ClientBackups.restore(second)
    let restoredHead = try BackupGeminiCheckpoints.git(git + ["rev-parse", "HEAD"], in: working)
    #expect(currentHead == restoredHead)
    #expect(try f.read(moved, "additional.txt") == "existing destination history")
  }

  @Test func relocatesGeminiChatLargerThanTheFormerDocumentLimit() throws {
    let f = try Fixture()
    let source = try f.directory("source")
    let project = try f.directory("project")
    let moved = try f.directory("moved")
    let dest = try f.directory("destination")
    let output = try f.directory("output")
    let client = try f.directory("source/.gemini")
    let chats = try f.directory("source/.gemini/tmp/example/chats")
    let oldHash = FileHash.sha256Hex(data: Data(project.path.utf8))
    let newHash = FileHash.sha256Hex(data: Data(moved.path.utf8))
    try f.put(client, "tmp/example/.project_root", project.path)
    try f.put(client, "projects.json", f.json(["projects": [project.path: "example"]]))
    let chunk = Data(repeating: 0x61, count: 1024 * 1024)
    let prefix = Data("{\"messages\":[{\"type\":\"user\",\"content\":\"".utf8)
    try BackupIO.write("session-large.json", in: DirectoryHandle(at: chats)) { file in
      try file.write(contentsOf: prefix)
      for _ in 0..<65 { try file.write(contentsOf: chunk) }
      try file.write(contentsOf: Data("\"}],\"projectHash\":\"\(oldHash)\"}".utf8))
    }
    let package = try ClientBackups.create(
      client: .geminiCLI, projects: [project], to: output, environment: f.environment(source))
    try f.remove(source)
    try f.remove(project)
    let plan = try ClientBackups.preview(
      package, projects: [project.path: moved], environment: f.environment(dest))
    try ClientBackups.restore(plan)
    let result = dest.appendingPathComponent(".gemini/tmp/example/chats/session-large.json")
    let opened = try FileHandle(forReadingFrom: result)
    defer { try? opened.close() }
    #expect(try opened.read(upToCount: prefix.count) == prefix)
    for _ in 0..<65 { #expect(try opened.read(upToCount: chunk.count) == chunk) }
    #expect(try opened.readToEnd() == Data("\"}],\"projectHash\":\"\(newHash)\"}".utf8))
  }

  private enum PublicationFailure: Error { case injected }

  private func createCodexDB(_ directory: URL, wal: Bool = false) throws -> BackupSQL {
    let root = try DirectoryHandle(at: directory)
    let name = "state_5.sqlite"
    try BackupIO.write(name, in: root) { _ in }
    let db = try BackupSQL(directory.appendingPathComponent(name), writable: true)
    if wal { try db.execute("PRAGMA journal_mode=WAL") }
    try db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT)")
    try db.execute(
      """
      CREATE TABLE thread_attachments (
        thread_id TEXT REFERENCES threads(id), id TEXT, content TEXT, PRIMARY KEY(thread_id,id)
      )
      """)
    try db.execute(
      """
      CREATE TABLE thread_read_receipts (thread_id TEXT PRIMARY KEY REFERENCES threads(id), turn INTEGER)
      """)
    return db
  }
}

private final class Fixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("client-backup-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  deinit { try? remove(root) }

  func directory(_ path: String) throws -> URL {
    let url = root.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func environment(_ home: URL, _ values: [String: String] = [:]) -> RuntimeEnvironment {
    RuntimeEnvironment(projectDirectory: root, homeDirectory: home, environment: values)
  }

  func put(_ base: URL, _ path: String, _ value: String, mode: UInt16 = 0o600) throws {
    try put(base.appendingPathComponent(path), value, mode: mode)
  }

  func put(_ url: URL, _ value: String, mode: UInt16 = 0o600) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  func read(_ base: URL, _ relative: String) throws -> String {
    try read(base.appendingPathComponent(relative))
  }

  func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  func append(_ url: URL, _ value: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(value.utf8))
  }

  func json(_ value: Any) throws -> String {
    String(decoding: try BackupNativeJSON.encode(value), as: UTF8.self)
  }

  func remove(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  func claudeKey(_ url: URL) -> String {
    let name = url.path.replacingOccurrences(
      of: #"[^a-zA-Z0-9]"#, with: "-", options: .regularExpression)
    if name.count <= 200 { return name }
    let unsigned = url.path.utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
    let suffix = String(Int32(bitPattern: unsigned).magnitude, radix: 36)
    return String(name.prefix(200)) + "-" + suffix
  }
}
