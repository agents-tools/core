import CPlatform
import CSQLite
import Foundation

struct BackupRelocation {
  let header: BackupHeader
  let roots: BackupRoots
  let projectMappings: [(String, String)]

  init(header: BackupHeader, roots: BackupRoots) {
    self.header = header
    self.roots = roots
    projectMappings = roots.projects.map { ($0.key, $0.value.path) }.sorted {
      $0.0.count > $1.0.count
    }
  }

  func projectPath(_ value: String) -> String {
    remap(value, from: projectMappings)
  }

  func clientPath(_ value: String) -> String {
    remap(value, from: [(header.sourceClient, roots.client.path)])
  }

  private func remap(_ value: String, from roots: [(String, String)]) -> String {
    for (original, target) in roots {
      if value == original { return target }
      if value.hasPrefix(original + "/") { return target + value.dropFirst(original.count) }
    }
    return value
  }
}

enum BackupNativeJSON {
  static func object(_ url: URL) throws -> [String: Any] {
    guard let object = try value(url) as? [String: Any] else {
      throw ClientBackupError.unsupportedLayout(url.lastPathComponent)
    }
    return object
  }

  static func value(_ url: URL) throws -> Any {
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent())
    return try JSONSerialization.jsonObject(
      with: parent.read(url.lastPathComponent, maximumBytes: 64 * 1024 * 1024))
  }

  static func encode(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  static func mergeMaps(
    _ source: [String: Any], into destination: [String: Any], keys: Set<String>
  ) throws -> [String: Any] {
    var result = destination.merging(source) { _, new in new }
    for key in keys where source[key] != nil && destination[key] != nil {
      guard let incoming = source[key] as? [String: Any],
        let current = destination[key] as? [String: Any]
      else { throw ClientBackupError.unsupportedLayout(key) }
      result[key] = current.merging(incoming) { _, new in new }
    }
    return result
  }

  static func remappedRecords(
    _ records: [String: Any], using mapping: BackupRelocation
  ) throws -> [String: Any] {
    var result: [String: Any] = [:]
    for (path, value) in records {
      let target = mapping.projectPath(path)
      guard result.updateValue(value, forKey: target) == nil else {
        throw ClientBackupError.conflict("project mapping")
      }
    }
    return result
  }

  static func pathFields(
    _ input: [String: Any], using mapping: BackupRelocation
  ) -> (value: [String: Any], changed: Bool) {
    var result = input
    var changed = false
    for key in ["cwd", "projectPath", "originalPath", "rootPath"] {
      if let path = input[key] as? String {
        let target = mapping.projectPath(path)
        if path != target {
          result[key] = target
          changed = true
        }
      }
    }
    for key in ["fullPath", "rollout_path", "rolloutPath"] {
      if let path = input[key] as? String {
        let target = mapping.clientPath(mapping.projectPath(path))
        if path != target {
          result[key] = target
          changed = true
        }
      }
    }
    for key in ["runtime_workspace_roots", "workspace_roots"] {
      if let paths = input[key] as? [String] {
        let mapped = paths.map(mapping.projectPath)
        if mapped != paths {
          result[key] = mapped
          changed = true
        }
      }
    }
    let type = input["type"] as? String
    if let payload = input["payload"] as? [String: Any] {
      if type == "session_meta" || type == "turn_context" {
        let mapped = pathFields(payload, using: mapping)
        if mapped.changed {
          result["payload"] = mapped.value
          changed = true
        }
      }
      if type == "event_msg", payload["type"] as? String == "thread_settings_applied",
        let settings = payload["thread_settings"] as? [String: Any]
      {
        let mapped = pathFields(settings, using: mapping)
        if mapped.changed {
          var next = payload
          next["thread_settings"] = mapped.value
          result["payload"] = next
          changed = true
        }
      }
    }
    return (result, changed)
  }
}

struct BackupRolloutOffsets {
  var thread: String?
  var edits: [(range: Range<Int64>, delta: Int64)] = []

  func translate(_ offset: Int64) throws -> Int64 {
    var diff: Int64 = 0
    for edit in edits {
      if offset <= edit.range.lowerBound { break }
      guard offset >= edit.range.upperBound else {
        throw ClientBackupError.unsupportedLayout("Codex rollout cursor")
      }
      diff += edit.delta
    }
    return offset + diff
  }
}

/// JSONL session bodies can be large, so each pass retains just one record.
enum BackupJSONL {
  static func lines(_ url: URL, _ visit: (Data, Bool) throws -> Void) throws {
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    var remainder = Data()
    while let next = try reader.read(upToCount: BackupIO.chunkSize), !next.isEmpty {
      var start = next.startIndex
      while let end = next[start...].firstIndex(of: 0x0a) {
        remainder.append(contentsOf: next[start..<end])
        try visit(remainder, true)
        remainder.removeAll(keepingCapacity: true)
        start = next.index(after: end)
      }
      remainder.append(contentsOf: next[start...])
      guard remainder.count <= 64 * 1024 * 1024 else {
        throw ClientBackupError.unsupportedLayout(url.lastPathComponent)
      }
    }
    if !remainder.isEmpty { try visit(remainder, false) }
  }

  static func record(_ line: Data, path: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      throw ClientBackupError.unsupportedLayout(path)
    }
    return value
  }

  static func remap(
    _ url: URL, to output: FileHandle,
    transform: ([String: Any]) throws -> (value: [String: Any], changed: Bool)
  ) throws -> BackupRolloutOffsets {
    var offsets = BackupRolloutOffsets()
    var offset: Int64 = 0
    try lines(url) { bytes, newline in
      let end = offset + Int64(bytes.count) + (newline ? 1 : 0)
      var rendered = bytes
      if !bytes.isEmpty && bytes != Data([0x0d]) {
        let record = try record(bytes, path: url.lastPathComponent)
        if record["type"] as? String == "session_meta",
          let payload = record["payload"] as? [String: Any], let id = payload["id"] as? String
        {
          offsets.thread = id
        }
        let remapped = try transform(record)
        if remapped.changed {
          rendered = try BackupNativeJSON.encode(remapped.value)
          if bytes.last == 0x0d { rendered.append(0x0d) }
          offsets.edits.append((offset..<end, Int64(rendered.count - bytes.count)))
        }
      }
      if newline { rendered.append(0x0a) }
      try output.write(contentsOf: rendered)
      offset = end
    }
    return offsets
  }

  static func merge(
    incoming: URL, existing: URL, to output: FileHandle, index: Bool, mapping: BackupRelocation
  ) throws {
    func key(_ bytes: Data) throws -> String {
      if index {
        let record = try record(bytes, path: "session_index.jsonl")
        guard let id = record["id"] as? String, !id.isEmpty else {
          throw ClientBackupError.unsupportedLayout("session_index.jsonl")
        }
        return id
      }
      return FileHash.sha256Hex(data: bytes)
    }
    var incomingKeys = Set<String>()
    try lines(incoming) { bytes, _ in
      if !bytes.isEmpty { incomingKeys.insert(try key(bytes)) }
    }
    func write(_ bytes: Data) throws {
      try output.write(contentsOf: bytes)
      try output.write(contentsOf: Data([0x0a]))
    }
    try lines(existing) { bytes, _ in
      if try !bytes.isEmpty && !incomingKeys.contains(key(bytes)) {
        try write(bytes)
      }
    }
    try lines(incoming) { bytes, _ in
      guard !bytes.isEmpty else { return }
      let value = try record(bytes, path: incoming.lastPathComponent)
      let remapped = BackupNativeJSON.pathFields(value, using: mapping)
      try write(remapped.changed ? BackupNativeJSON.encode(remapped.value) : bytes)
    }
  }
}

enum BackupNativeDatabase {
  private static let sharedTables: Set<String> = [
    "threads", "thread_dynamic_tools", "thread_spawn_edges", "thread_sections",
    "thread_read_receipts", "thread_attachments", "thread_artifacts", "thread_goals",
    "thread_goal_continuation_deferrals", "projects", "project_roots", "stage1_outputs",
    "project_idempotency_keys", "session_model_ids",
  ]
  private static let destinationTables: Set<String> = [
    "_sqlx_migrations", "backfill_state", "rollout_migration_state", "remote_control_enrollments",
    "external_agent_config_imports", "sqlite_sequence", "logs", "agent_jobs", "agent_job_items",
    "rollout_migration_skipped_rollouts",
    "jobs", "state_metadata", "thread_history_metadata",
  ]

  private struct Table {
    let name: String
    let sql: String
    let columns: [String]
    let primaryKey: [String]
  }

  static func adapt(
    _ incoming: URL, destination: URL?, name: String, using mapping: BackupRelocation,
    rolloutOffsets: [String: BackupRolloutOffsets]
  ) throws -> URL {
    do {
      let source = try BackupSQL(incoming, writable: true)
      try source.verify()
      try source.disableTriggers()
      let tables = try tables(source)
      if name.hasPrefix("state") {
        guard let threads = tables.first(where: { $0.name == "threads" }),
          ["id", "cwd", "rollout_path"].allSatisfy(threads.columns.contains)
        else { throw ClientBackupError.unsupportedLayout(name) }
        try rewrite(source, table: "threads", column: "rollout_path", mapping.clientPath)
        try rewrite(source, table: "threads", column: "cwd", mapping.projectPath)
        if tables.contains(where: { $0.name == "project_roots" && $0.columns.contains("path") }) {
          try rewrite(source, table: "project_roots", column: "path", mapping.projectPath)
        }
      }
      if name.hasPrefix("thread_history_"), !rolloutOffsets.isEmpty {
        for (table, column) in [
          ("thread_history_projection_state", "next_rollout_byte_offset"),
          ("thread_turns", "rollout_byte_offset"),
          ("thread_turns", "rollout_end_byte_offset"),
        ] {
          if let schema = tables.first(where: { $0.name == table }) {
            guard schema.columns.contains("thread_id"), schema.columns.contains(column) else {
              throw ClientBackupError.unsupportedLayout(name)
            }
            try rewriteOffsets(source, table: table, column: column, offsets: rolloutOffsets)
          }
        }
      }
      try source.execute("PRAGMA journal_mode=DELETE")
    }

    guard let destination else { return incoming }
    let target = try BackupSQL(destination, writable: true)
    try target.verify()
    try target.disableTriggers()
    let attach = BackupSQL.absoluteFileURL(incoming).absoluteString + "?mode=ro"
    try target.execute("ATTACH DATABASE ? AS incoming", [.text(attach)])
    let sourceTables = try tables(target, schema: "incoming")
    let targetTables = try tables(target)
    guard sourceTables.map(\.sql) == targetTables.map(\.sql),
      try triggerDefinitions(target, schema: "incoming")
        == triggerDefinitions(target, schema: "main")
    else {
      throw ClientBackupError.unsupportedLayout(name)
    }
    try target.execute("PRAGMA foreign_keys=ON")
    try target.execute("BEGIN IMMEDIATE")
    try target.execute("PRAGMA defer_foreign_keys=ON")
    for table in sourceTables {
      if destinationTables.contains(table.name) { continue }
      let identifier = quote(table.name)
      let columns = table.columns.map(quote)
      let insert = columns.joined(separator: ",")
      let key = table.primaryKey.map(quote).joined(separator: ",")
      let updates = table.columns.filter { !table.primaryKey.contains($0) }.map {
        "\(quote($0))=excluded.\(quote($0))"
      }.joined(separator: ",")
      guard !key.isEmpty, sharedTables.contains(table.name) || table.columns.contains("thread_id")
      else {
        try target.rows(
          "SELECT 1 FROM (SELECT * FROM incoming.\(identifier) EXCEPT SELECT * FROM main.\(identifier)) LIMIT 1"
        ) { _ in throw ClientBackupError.unsupportedLayout(name + "/" + table.name) }
        continue
      }
      if table.columns.contains("thread_id"), !table.primaryKey.contains("thread_id") {
        let sameKey = table.primaryKey.map {
          "current.\(quote($0))=archived.\(quote($0))"
        }.joined(separator: " AND ")
        try target.rows(
          """
          SELECT 1 FROM main.\(identifier) current JOIN incoming.\(identifier) archived
            ON \(sameKey)
          WHERE current.thread_id IS NOT archived.thread_id LIMIT 1
          """
        ) { _ in throw ClientBackupError.conflict(name + "/" + table.name) }
      }
      let differences = table.columns.filter { !table.primaryKey.contains($0) }.map {
        "\(identifier).\(quote($0)) IS NOT excluded.\(quote($0))"
      }.joined(separator: " OR ")
      let update = updates.isEmpty ? "NOTHING" : "UPDATE SET " + updates + " WHERE " + differences
      let sql = """
        INSERT INTO main.\(identifier)(\(insert))
        SELECT \(insert) FROM incoming.\(identifier) WHERE true
        ON CONFLICT(\(key)) DO \(update)
        """
      try target.execute(sql)
    }
    try target.execute("COMMIT")
    try target.rows("PRAGMA foreign_key_check") { _ in
      throw ClientBackupError.conflict(name)
    }
    try target.execute("DETACH DATABASE incoming")
    try target.execute("PRAGMA journal_mode=DELETE")
    try target.verify()
    return destination
  }

  static func requireClosed(_ url: URL) throws {
    guard let parent = try BackupIO.directory(url.deletingLastPathComponent()) else { return }
    for suffix in ["-wal", "-shm", "-journal"] {
      guard try parent.info(url.lastPathComponent + suffix) == nil else {
        throw ClientBackupError.conflict(url.path + suffix)
      }
    }
  }

  private static func quote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func tables(_ db: BackupSQL, schema: String = "main") throws -> [Table] {
    try db.rows("SELECT 1 FROM \(schema).sqlite_schema WHERE type='view'") { _ in
      throw ClientBackupError.unsupportedLayout("Codex SQLite schema")
    }
    _ = try triggerDefinitions(db, schema: schema)
    var tables: [Table] = []
    try db.rows(
      "SELECT name,sql FROM \(schema).sqlite_schema WHERE type='table' ORDER BY name"
    ) { row in
      let name = try BackupSQL.text(row, 0)
      let definition = try BackupSQL.text(row, 1)
      guard definition.uppercased().hasPrefix("CREATE TABLE ") else {
        throw ClientBackupError.unsupportedLayout("Codex SQLite table")
      }
      var columns: [String] = []
      var key: [Int64: String] = [:]
      try db.rows("PRAGMA \(schema).table_xinfo(\(quote(name)))") { column in
        guard try BackupSQL.integer(column, 6) == 0 else {
          throw ClientBackupError.unsupportedLayout("Codex SQLite column")
        }
        let name = try BackupSQL.text(column, 1)
        columns.append(name)
        let rank = try BackupSQL.integer(column, 5)
        if rank > 0 { key[rank] = name }
      }
      tables.append(
        Table(
          name: name, sql: definition, columns: columns,
          primaryKey: key.keys.sorted().compactMap { key[$0] }))
    }
    return tables
  }

  private static func triggerDefinitions(_ db: BackupSQL, schema: String) throws -> [String] {
    let supported = [
      "threads_created_at_ms_after_insert": "threads",
      "threads_updated_at_ms_after_insert": "threads",
      "threads_created_at_ms_after_update": "threads",
      "threads_updated_at_ms_after_update": "threads",
      "threads_recency_at_after_insert": "threads",
      "thread_realtime_items_projection_cleanup": "thread_history_projection_state",
    ]
    var definitions: [String] = []
    try db.rows(
      "SELECT name,tbl_name,sql FROM \(schema).sqlite_schema WHERE type='trigger' ORDER BY name"
    ) { row in
      let name = try BackupSQL.text(row, 0)
      guard try supported[name] == BackupSQL.text(row, 1) else {
        throw ClientBackupError.unsupportedLayout("Codex SQLite trigger")
      }
      definitions.append(try BackupSQL.text(row, 2))
    }
    return definitions
  }

  private static func rewriteOffsets(
    _ db: BackupSQL, table: String, column: String, offsets: [String: BackupRolloutOffsets]
  ) throws {
    let table = quote(table)
    let column = quote(column)
    var changes: [[BackupSQL.Value]] = []
    try db.rows("SELECT DISTINCT thread_id,\(column) FROM \(table) WHERE \(column) IS NOT NULL") {
      row in
      let id = try BackupSQL.text(row, 0)
      guard let rollout = offsets[id] else { return }
      let old = try BackupSQL.integer(row, 1)
      let replacement = try rollout.translate(old)
      if replacement != old { changes.append([.text(id), .integer(old), .integer(replacement)]) }
    }
    if changes.isEmpty { return }
    try db.execute(
      """
      CREATE TEMP TABLE offset_mapping (
        thread TEXT NOT NULL, old INTEGER NOT NULL, new INTEGER NOT NULL, PRIMARY KEY(thread,old)
      )
      """)
    for change in changes { try db.execute("INSERT INTO offset_mapping VALUES (?,?,?)", change) }
    let match = "thread=\(table).thread_id AND old=\(table).\(column)"
    try db.execute(
      """
      UPDATE \(table) SET \(column) = (SELECT new FROM offset_mapping WHERE \(match))
      WHERE EXISTS (SELECT 1 FROM offset_mapping WHERE \(match))
      """)
    try db.execute("DROP TABLE offset_mapping")
  }

  private static func rewrite(
    _ db: BackupSQL, table: String, column: String, _ mapping: (String) -> String
  ) throws {
    let table = quote(table)
    let column = quote(column)
    var updates: [(String, String)] = []
    try db.rows("SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL") { row in
      let source = try BackupSQL.text(row, 0)
      let target = mapping(source)
      if source != target { updates.append((source, target)) }
    }
    if updates.isEmpty { return }
    // One UPDATE prevents a destination that is itself an original root from being remapped twice.
    try db.execute("CREATE TEMP TABLE path_mapping (old TEXT PRIMARY KEY, new TEXT NOT NULL)")
    for (source, target) in updates {
      try db.execute("INSERT INTO path_mapping VALUES (?,?)", [.text(source), .text(target)])
    }
    try db.execute(
      """
      UPDATE \(table)
      SET \(column) = (SELECT new FROM path_mapping WHERE old=\(table).\(column))
      WHERE \(column) IN (SELECT old FROM path_mapping)
      """)
    try db.execute("DROP TABLE path_mapping")
  }
}
