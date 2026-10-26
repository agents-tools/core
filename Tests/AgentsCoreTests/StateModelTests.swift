import Foundation
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
    try store.save(declaration: declaration, resolved: lock)
    let first = try Data(contentsOf: store.resolvedURL)
    let firstDeclaration = try Data(contentsOf: store.declarationURL)
    try store.save(declaration: declaration, resolved: lock)
    #expect(try Data(contentsOf: store.resolvedURL) == first)
    #expect(try Data(contentsOf: store.declarationURL) == firstDeclaration)
    #expect(try store.loadDeclaration() == declaration)
    #expect(try store.loadResolved() == lock)
    #expect(String(decoding: first, as: UTF8.self).contains("\"from\": \"1.0.0\""))
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

  @Test(arguments: [
    #"{"git":"github.com/a/b","local":"/a"}"#,
    #"{"git":"github.com/a/b","from":"1.0.0","exact":"2.0.0"}"#, #"{"local":"/a","to":"2.0.0"}"#,
  ])
  func rejectsAmbiguousSources(_ json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SourceDeclaration.self, from: Data(json.utf8))
    }
  }
}

extension StateModelTests {
  @Test(arguments: [
    #"{"sources":{"same":{"local":"/a"},"same":{"local":"/b"}}}"#,
    #"{"sources":{"same":{"local":"/a"},"sa\u006de":{"local":"/b"}}}"#,
    #"{"sources":{},"skills":{"demo":{"select":"all"},"demo":{"select":[]}}}"#,
    #"{"version":1,"sources":{},"skills":{"demo":{},"demo":{}},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}"#,
    #"{"version":1,"sources":{},"skills":{"demo":{"source":"local:/a","installs":{"codex":"link","codex":"copy"}}},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}"#,
  ])
  func duplicateKeysRejectReadsAndWrites(_ json: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let url = json.contains("version") ? store.resolvedURL : store.declarationURL
    try Data(json.utf8).write(to: url)
    let beforeDeclaration = try Data(contentsOf: store.declarationURL)
    let beforeLock = try Data(contentsOf: store.resolvedURL)
    #expect(throws: CoreError.self) {
      if url == store.resolvedURL {
        _ = try store.loadResolved()
      } else {
        _ = try store.loadDeclaration()
      }
    }
    #expect(throws: CoreError.self) {
      try store.save(declaration: Declaration(), resolved: ResolvedState())
    }
    #expect(try Data(contentsOf: store.declarationURL) == beforeDeclaration)
    #expect(try Data(contentsOf: store.resolvedURL) == beforeLock)
  }

  @Test func rejectsUnknownFieldsInsteadOfDiscardingIntent() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let store = StateStore(scope: .project, environment: RuntimeEnvironment(projectDirectory: root))
    try store.save(declaration: Declaration(), resolved: ResolvedState())
    let bytes = Data(#"{"sources":{},"unexpected":{"intent":true}}"#.utf8)
    try bytes.write(to: store.declarationURL)
    #expect(throws: CoreError.self) { try store.loadDeclaration() }
    #expect(try Data(contentsOf: store.declarationURL) == bytes)
  }
}
