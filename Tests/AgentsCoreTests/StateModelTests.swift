import AgentsManifest
import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite("Declared state")
struct StateModelTests {
  @Test func validatesOwnInstructionRecordsAndReferences() throws {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    func lock(_ section: LockedSection) -> ResolvedState {
      ResolvedState(instructions: LockedInstructions(sections: [section]))
    }
    #expect(throws: Never.self) {
      try lock(
        LockedSection(
          name: "guide", source: ".", path: ".agent/instructions/guide.md", hash: digest)
      )
      .validate()
    }
    #expect(throws: (any Error).self) {
      try lock(
        LockedSection(
          name: "guide", source: ".", revision: String(repeating: "b", count: 40),
          path: ".agent/instructions/guide.md", hash: digest)
      ).validate()
    }
    #expect(throws: (any Error).self) {
      try lock(LockedSection(name: "guide", source: ".", path: "guide.md", hash: digest)).validate()
    }
    #expect(throws: (any Error).self) {
      try lock(
        LockedSection(
          name: "Guide", source: ".", path: ".agent/instructions/Guide.md", hash: digest)
      )
      .validate()
    }
    let environment = RuntimeEnvironment(
      projectDirectory: URL(fileURLWithPath: "/project"),
      homeDirectory: URL(fileURLWithPath: "/home"),
      environment: [:])
    let source = SourceDeclaration(kind: .git, location: "github.com/owner/repo")
    for references in [["guide"], ["epd/review", "rules:auto-review/swift"]] {
      #expect(throws: Never.self) {
        try Declaration(
          sources: ["rules": source], instructions: InstructionsDeclaration(sections: references)
        ).validate(environment: environment)
      }
    }
    for reference in ["Guide", "rules:Review", "missing:review", "rules:", "a//b", "a:b:c"] {
      #expect(throws: (any Error).self) {
        try Declaration(
          sources: ["rules": source], instructions: InstructionsDeclaration(sections: [reference])
        ).validate(environment: environment)
      }
    }
  }

  @Test func roundTripsCompleteStateDeterministically() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let environment = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"), environment: [:])
    let store = StateStore(scope: .project, environment: environment)
    let source = SourceDeclaration(
      kind: .git, location: "github.com/owner/repo", requirement: .upToNextMajor(from: "1.0.0"))
    let id = try source.identity(environment: environment)
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let section = LockedSection(
      name: "rules", source: id, revision: String(repeating: "b", count: 40),
      path: "instructions/rules.md", hash: digest)
    let declaration = Declaration(
      sources: ["rules": source], skills: ["rules": SkillDeclaration(select: .all)],
      instructions: InstructionsDeclaration(
        sections: ["rules:b", "rules:a"],
        chatgpt: [
          "prompt": PromptDeclaration(sections: ["rules:b", "rules:a"], append: "custom.md")
        ]), watch: ["rules"])
    let lock = ResolvedState(
      sources: [id: LockedSource(kind: .git, url: source.gitURL, requirement: source.requirement)],
      skills: [
        "demo": LockedSkill(
          source: id, revision: String(repeating: "b", count: 40), version: "1.0.0",
          path: "skills/demo", hash: digest, installs: ["codex": .link])
      ],
      instructions: LockedInstructions(
        sections: [section],
        chatgpt: ["prompt": LockedPrompt(sections: [section], append: "custom.md")],
        targets: [
          "AGENTS.md": LockedTarget(
            agents: [.codex], headingOffset: 1, blockHash: digest, created: false),
          "CLAUDE.md": LockedTarget(
            agents: [.claudeCode], import: "AGENTS.md", blockHash: digest, created: false),
        ]))
    try store.save(declaration: declaration, ledger: ledgerFixture(lock))
    let first = try Data(contentsOf: store.resolvedURL)
    let firstDeclaration = try Data(contentsOf: store.declarationURL)
    try store.save(declaration: declaration, ledger: ledgerFixture(lock))
    #expect(try Data(contentsOf: store.resolvedURL) == first)
    #expect(try Data(contentsOf: store.declarationURL) == firstDeclaration)
    // The document spells the Git location as a URL; the projection keeps its meaning.
    #expect(
      ManifestProjection.equivalent(
        try store.loadDeclaration(), declaration, environment: environment))
    #expect(try store.loadResolved() == lock)
    #expect(
      try store.loadLedger().sourceUses.contains { $0.requirement == .upToNextMajor(from: "1.0.0") }
    )
  }

  @Test func rejectsCorruptionWithoutReplacingFiles() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let declaration = try Data(contentsOf: store.declarationURL)
    let bad = Data(#"{"version":1,"pins":[]}"#.utf8)
    try bad.write(to: store.resolvedURL)
    #expect(throws: CoreError.self) {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    }
    #expect(try Data(contentsOf: store.resolvedURL) == bad)
    #expect(try Data(contentsOf: store.declarationURL) == declaration)
  }

  @Test func sourceIDsIncludeProviderAndRejectDuplicateAliases() throws {
    let environment = RuntimeEnvironment(
      projectDirectory: URL(fileURLWithPath: "/project"),
      homeDirectory: URL(fileURLWithPath: "/home/test"),
      environment: ["XDG_STATE_HOME": "/elsewhere"])
    let first = SourceDeclaration(kind: .git, location: "https://user@GitHub.com/owner/repo.git")
    let second = SourceDeclaration(kind: .git, location: "git@github.com:owner/repo")
    #expect(try first.identity(environment: environment) == "github.com/owner/repo")
    #expect(throws: CoreError.self) {
      try Declaration(sources: ["a": first, "b": second]).validate(environment: environment)
    }
    #expect(
      try SourceDeclaration(kind: .git, location: "ssh://git@EXAMPLE.com:2222/a/b.git").identity(
        environment: environment) == "example.com:2222/a/b")
    #expect(
      try SourceDeclaration(kind: .local, location: "~/rules").identity(environment: environment)
        == "local:/home/test/rules")
    #expect(
      try SourceDeclaration(kind: .wellKnown, location: "https://example.com").identity(
        environment: environment) == "https://example.com")
    #expect(
      StateStore(scope: .user, environment: environment).resolvedURL.path
        == "/home/test/.agents/agents.resolved")
  }
}

extension StateModelTests {
  @Test(arguments: [
    #"{"version":1,"sources":{},"skills":{"demo":{},"demo":{}},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}"#,
    #"{"version":1,"sources":{},"skills":{"demo":{"source":"local:/a","installs":{"codex":"link","codex":"copy"}}},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}"#,
  ])
  func duplicateKeysRejectReadsAndWrites(_ json: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    try Data(json.utf8).write(to: store.resolvedURL)
    let beforeDeclaration = try Data(contentsOf: store.declarationURL)
    let beforeLock = try Data(contentsOf: store.resolvedURL)
    #expect(throws: CoreError.self) { _ = try store.loadResolved() }
    #expect(throws: CoreError.self) {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    }
    #expect(try Data(contentsOf: store.declarationURL) == beforeDeclaration)
    #expect(try Data(contentsOf: store.resolvedURL) == beforeLock)
  }
}

private func ledgerFixture(_ model: ResolvedState) throws -> ResolvedLedger {
  var ledger = ResolvedLedger()
  func source(_ identity: String, revision: String?, version: String?) -> String {
    let record = model.sources[identity]!
    let id = identity + ":" + (revision ?? "live") + ":" + (version ?? "")
    ledger.sources[id] = LedgerSource(
      kind: record.kind, transport: record.url,
      location: record.kind == .local
        ? .init(kind: .absolute, path: String(identity.dropFirst(6))) : nil,
      revision: revision ?? "live", version: version)
    ledger.sourceUses.append(
      .init(source: id, root: record.path ?? ".", requirement: record.requirement))
    return id
  }
  func occurrence(_ id: String, source: String) {
    ledger.occurrences.append(
      .init(
        declaringSource: source, manifestPath: ".agent/agents.yaml", id: ledger.occurrences.count,
        component: id, dependencies: [source], condition: .init(DeclarationCondition()),
        recipients: ledger.components[id]!.recipients, consumerEditable: true))
  }
  for (name, skill) in model.skills {
    let sid = source(skill.source, revision: skill.revision, version: skill.version)
    let rid = "skill:" + name
    ledger.resources[rid] = .init(
      kind: .git, source: sid, path: skill.path!, hash: skill.hash!,
      entries: [.init(path: ".", kind: .directory, executable: false)])
    ledger.components[rid] = .init(
      declaringSource: sid, source: sid, root: ".", kind: "skills", name: name,
      revision: skill.revision, version: skill.version,
      payload: .init(object: ["mode": .init(skill.installs.values.first!.rawValue)]),
      conditions: [], recipients: skill.installs.keys.compactMap(AgentID.init(rawValue:)),
      chatGPT: false, resources: [rid])
    occurrence(rid, source: sid)
  }
  var sectionOwners: [String] = []
  func section(_ record: LockedSection, prompt: String? = nil, append: String? = nil) {
    let sid = source(record.source, revision: record.revision, version: record.version)
    let id = "section:" + String(ledger.components.count)
    let rid = id + ":resource"
    ledger.resources[rid] = .init(
      kind: .git, source: sid, path: record.path, hash: record.hash,
      entries: [.init(path: ".", kind: .file, executable: false, byteCount: 0)])
    var payload = ["name": LedgerValue(record.name), "sourceHash": .init(record.hash)]
    payload["prompt"] = prompt.map { .init($0) }
    var resources = [rid]
    if let append {
      let aid = id + ":append"
      ledger.resources[aid] = .init(
        kind: .git, source: sid, path: append, hash: record.hash,
        entries: [.init(path: ".", kind: .file, executable: false, byteCount: 0)])
      resources.append(aid)
    }
    ledger.components[id] = .init(
      declaringSource: sid, source: sid, root: ".", kind: "instructions", name: record.name,
      revision: record.revision, version: record.version, payload: .init(object: payload),
      conditions: [],
      recipients: prompt == nil ? [.codex, .claudeCode] : [], chatGPT: prompt != nil,
      resources: resources)
    occurrence(id, source: sid)
    if prompt == nil { sectionOwners.append(id) }
  }
  for item in model.instructions.sections { section(item) }
  for (name, prompt) in model.instructions.chatgpt {
    for item in prompt.sections { section(item, prompt: name, append: prompt.append) }
  }
  #if os(macOS)
    let platform = "macos"
  #else
    let platform = "linux"
  #endif
  for (path, target) in model.instructions.targets {
    let id = "target:" + path
    let route = target.import == nil ? "agents/instructions@1" : "agents/claude-import@1"
    ledger.deployments.append(
      .init(
        id: id, target: .init(kind: .registered, root: "project", path: path), route: route,
        owners: sectionOwners,
        recipients: target.agents, ownership: target.import == nil ? .generated : .importBlock,
        expectedHash: target.blockHash,
        created: target.created, importReference: target.import, headingOffset: target.headingOffset
      ))
    ledger.lowerings.append(
      .init(
        id: id, format: route, inputs: sectionOwners, resources: [], deployments: [id],
        layout: .init(), platform: platform, artifacts: []))
  }
  return ledger
}
