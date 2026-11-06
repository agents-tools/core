import AgentsCore
import AgentsDescription
import Foundation
import Testing

@testable import AgentsManifest

func planned(_ previous: Declaration, _ next: Declaration, in text: String?) throws -> [UInt8]? {
  try DeclarationEditPlan.bytes(
    replacing: previous, with: next, in: text.map { Array($0.utf8) },
    identity: DocumentIdentity("manifest"), environment: projectionEnvironment)
}

private func expectChange(
  _ body: String, to expected: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ update: (inout Declaration) throws -> Void
) throws {
  let result = try changed(body, update)
  #expect(result == expected, sourceLocation: sourceLocation)
}

/// Plans a change to a manifest body and returns the edited body, checked against the intent.
private func changed(_ body: String, _ update: (inout Declaration) throws -> Void) throws -> String
{
  let previous = try projected(body)
  var next = previous
  try update(&next)
  let bytes = try #require(try planned(previous, next, in: manifestHeader + body))
  let text = String(decoding: bytes, as: UTF8.self)
  #expect(text.hasPrefix(manifestHeader))
  let result = String(text.dropFirst(manifestHeader.count))
  let reparsed = try projected(result)
  #expect(ManifestProjection.equivalent(reparsed, next, environment: projectionEnvironment))
  return result
}

private let local = SourceDeclaration(kind: .local, location: "s")

@Suite("Declaration edit planning")
struct EditPlanTests {
  @Test func equivalentSpellingsAndLayoutPlanNoEdit() throws {
    let body = """
      let agents = Agents(defaultAgents:[.codex,.claudeCode],
          sources: [.source(name: "g", url: "github.com/team/skills", "1.2.0" ..< "2.0.0"),
        .source(name: "l", path: "./rules/", subpath: "./skills"),],
        components: [.skills(source: "g", select: ["b", "a"], exclude: [])],
        watch: ["l", "g"])
      """
    let previous = try projected(body)
    var next = previous
    next.agents = [.claudeCode, .codex]
    next.sources["g"] = SourceDeclaration(
      kind: .git, location: "https://GitHub.com/team/skills.git",
      requirement: .upToNextMajor(from: "1.2.0"))
    next.sources["l"] = SourceDeclaration(
      kind: .local, location: "/work/project/rules", path: "skills")
    try next.updateSkills { $0?["g"] = SkillDeclaration(select: .names(["a", "b"])) }
    next.watch = ["g", "l"]
    #expect(try planned(previous, next, in: manifestHeader + body) == nil)
    #expect(try planned(Declaration(), Declaration(), in: nil) == nil)
  }

  @Test func defaultAgentsChangeByElementOrWholeArgument() throws {
    let body = """
      let agents = Agents(
        // recipients
        defaultAgents: [.codex /* keep */, .openCode],
        watch: []
      )
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(
          // recipients
          defaultAgents: [.claudeCode, .codex /* keep */],
          watch: []
        )
        """
    ) { $0.agents = [.codex, .claudeCode] }
    expectManifestFailure("manifest.edit.readOnly") { try changed(body) { $0.agents = nil } }
    try expectChange(
      "let agents = Agents(defaultAgents: [.codex], watch: [])",
      to: "let agents = Agents(defaultAgents: nil, watch: [])"
    ) { $0.agents = nil }
    try expectChange(
      "let agents = Agents(watch: [])",
      to: "let agents = Agents(defaultAgents: [.codex, .cursor], watch: [])"
    ) { $0.agents = [.cursor, .codex] }
  }

  @Test func sourcesAppendReplaceInPlaceAndLeaveWithTheirReferences() throws {
    let body = """
      let agents = Agents(
        sources: [
          // team
          .source(name: "team", url: "https://e.org/t", branch: "main"), // pin
          .source(name: "s", path: "s"),
        ],
        components: [
          .skills(source: "s"),
        ],
        watch: ["s"]
      )
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(
          sources: [
            // team
            .source(name: "team", url: "https://e.org/t", revision: "abc123"), // pin
            .source(name: "s", path: "s"),
            .source(name: "new", url: "https://github.com/a/new"),
          ],
          components: [
            .skills(source: "s"),
          ],
          watch: ["s"]
        )
        """
    ) {
      $0.sources["team"]?.requirement = .revision("abc123")
      $0.sources["new"] = SourceDeclaration(kind: .git, location: "github.com/a/new")
    }
    try expectChange(
      body,
      to: """
        let agents = Agents(
          sources: [
            // team
            .source(name: "team", url: "https://e.org/t", branch: "main"), // pin
          ],
          components: [
          ],
          watch: []
        )
        """
    ) {
      $0.sources["s"] = nil
      try $0.setSkills(nil)
      $0.watch = nil
    }
  }

  @Test func newSkillsComponentsPrecedeInstructionsOrAppend() throws {
    let body = """
      let agents = Agents(
        sources: [.source(name: "a", path: "a"), .source(name: "b", path: "b")],
        components: [
          // rules
          .instructions(sections: ["guide"]),
        ]
      )
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(
          sources: [.source(name: "a", path: "a"), .source(name: "b", path: "b")],
          components: [
            .skills(
              source: "a",
              select: ["x"]
            ),
            .skills(source: "b"),
            // rules
            .instructions(sections: ["guide"]),
          ]
        )
        """
    ) {
      try $0.setSkills([
        "b": SkillDeclaration(select: .all), "a": SkillDeclaration(select: .names(["x"])),
      ])
    }
    try expectChange(
      "let agents = Agents(sources: [.source(name: \"a\", path: \"a\")])",
      to: """
        let agents = Agents(
          sources: [.source(name: "a", path: "a")],
          components: [
            .skills(source: "a"),
          ]
        )
        """
    ) { try $0.setSkills(["a": SkillDeclaration(select: .all)]) }
  }

  @Test func selectionSwitchesAndNameEditsKeepOrder() throws {
    let body = """
      let agents = Agents(
        sources: [.source(name: "s", path: "s")],
        components: [
          .skills(source: "s", select: ["a", "c" /* c */, "e"]),
        ]
      )
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(
          sources: [.source(name: "s", path: "s")],
          components: [
            .skills(source: "s", select: ["b", "c" /* c */, "d", "e"]),
          ]
        )
        """
    ) { try $0.updateSkills { $0?["s"]?.select = .names(["b", "c", "d", "e"]) } }
    expectManifestFailure("manifest.edit.readOnly") {
      try changed(body) { try $0.updateSkills { $0?["s"]?.select = .all } }
    }
    let plain = """
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
        .skills(source: "s", select: .all),
      ])
      """
    try expectChange(
      plain,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          .skills(source: "s", select: ["y", "z"]),
        ])
        """
    ) { try $0.updateSkills { $0?["s"]?.select = .names(["z", "y"]) } }
    try expectChange(
      plain.replacingOccurrences(of: ".all", with: "[\"a\"]"),
      to: plain
    ) { try $0.updateSkills { $0?["s"]?.select = .all } }
  }

  @Test func excludeAgentsAndModeAreArgumentEdits() throws {
    let body = """
      let agents = Agents(
        sources: [.source(name: "s", path: "s")],
        components: [
          .skills(
            // all team skills
            source: "s",
            mode: .copy
          ),
        ]
      )
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(
          sources: [.source(name: "s", path: "s")],
          components: [
            .skills(
              // all team skills
              source: "s",
              exclude: ["x"],
              mode: nil,
              agents: []
            ),
          ]
        )
        """
    ) {
      try $0.updateSkills { $0?["s"]?.exclude = ["x"] }
      try $0.updateSkills { $0?["s"]?.mode = nil }
      try $0.updateSkills { $0?["s"]?.agents = [] }
    }
    try expectChange(
      """
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
        .skills(source: "s", exclude: ["a", "c"], agents: [.codex]),
      ])
      """,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          .skills(source: "s", exclude: ["b", "c"], mode: .link, agents: [.claudeCode, .codex]),
        ])
        """
    ) {
      try $0.updateSkills { $0?["s"]?.exclude = ["b", "c"] }
      try $0.updateSkills { $0?["s"]?.agents = [.codex, .claudeCode] }
      try $0.updateSkills { $0?["s"]?.mode = .link }
    }
  }

  @Test func overridesAreUpsertedAndRemovedByName() throws {
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
        .skills(source: "s", select: ["a", "b"], overrides: [
          .skill(name: "a", mode: .copy), // copy a
          .skill(name: "b"),
        ]),
      ])
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          .skills(source: "s", select: ["a", "c"], overrides: [
            .skill(name: "a", mode: .copy), // copy a
            .skill(
              name: "c",
              agents: [.codex]
            ),
          ]),
        ])
        """
    ) {
      try $0.updateSkills {
        $0?["s"]?.overrides = [
          "a": SkillOverride(mode: .copy), "c": SkillOverride(agents: [.codex]),
        ]
      }
      try $0.updateSkills { $0?["s"]?.select = .names(["a", "c"]) }
    }
  }

  @Test func instructionsComponentsAreAddedRemovedAndRetargeted() throws {
    try expectChange(
      """
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
        // skills
        .skills(source: "s"),
      ])
      """,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          // skills
          .skills(source: "s"),
          .instructions(
            sections: ["guide"]
          ),
        ])
        """
    ) { try $0.setInstructions(InstructionsDeclaration(sections: ["guide"])) }
    let body = """
      let agents = Agents(components: [
        // rules
        .instructions(sections: ["guide"], agents: [.codex]),
      ])
      """
    try expectChange(body, to: "let agents = Agents(components: [\n])") {
      try $0.setInstructions(nil)
    }
    try expectChange(
      body,
      to: """
        let agents = Agents(components: [
          // rules
          .instructions(sections: ["guide"], agents: [.cursor]),
        ])
        """
    ) { try $0.updateInstructions { $0?.agents = [.cursor] } }
  }

  @Test func sectionsFollowTheLongestCommonSubsequenceAndKeepDuplicates() throws {
    let body = """
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
        .instructions(sections: [
          "a", // first a
          "b",
          "a",
          .section(name: "c", source: "s"),
        ]),
      ])
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          .instructions(sections: [
            "a", // first a
            "x",
            "a",
            .section(name: "c", source: "s"),
            "a",
            "y",
          ]),
        ])
        """
    ) { try $0.updateInstructions { $0?.sections = ["a", "x", "a", "s:c", "a", "y"] } }
    try expectChange(
      body,
      to: """
        let agents = Agents(sources: [.source(name: "s", path: "s")], components: [
          .instructions(sections: [
            "b",
          ]),
        ])
        """
    ) { try $0.updateInstructions { $0?.sections = ["b"] } }
  }

  @Test func promptsAreUpsertedAndRemovedByName() throws {
    let body = """
      let agents = Agents(components: [
        .instructions(chatGPT: [
          .prompt(name: "daily", sections: ["guide"]), // daily
          .prompt(name: "weekly", sections: ["guide"]),
        ]),
      ])
      """
    try expectChange(
      body,
      to: """
        let agents = Agents(components: [
          .instructions(chatGPT: [
            .prompt(
              name: "daily",
              sections: ["guide", "notes"]
            ), // daily
            .prompt(
              name: "monthly",
              sections: [],
              append: "notes/monthly.md"
            ),
          ]),
        ])
        """
    ) {
      try $0.updateInstructions {
        $0?.chatgpt = [
          "daily": PromptDeclaration(sections: ["guide", "notes"]),
          "monthly": PromptDeclaration(sections: [], append: "notes/monthly.md"),
        ]
      }
    }
  }

  @Test func watchChangesByElementOrWholeArgument() throws {
    let sources =
      "sources: [.source(name: \"a\", path: \"a\"), .source(name: \"b\", path: \"b\"), .source(name: \"c\", path: \"c\")]"
    try expectChange(
      "let agents = Agents(\n  \(sources),\n  watch: [\"a\", \"c\"] // watched\n)",
      to: "let agents = Agents(\n  \(sources),\n  watch: [\"b\", \"c\"] // watched\n)"
    ) { $0.watch = ["b", "c"] }
    try expectChange(
      "let agents = Agents(sources: [.source(name: \"a\", path: \"a\")])",
      to: "let agents = Agents(sources: [.source(name: \"a\", path: \"a\")], watch: [\"a\"])"
    ) { $0.watch = ["a"] }
  }

  @Test func sharedConstantsAndCommentedReplacementsAreReadOnly() throws {
    let constant = """
      let picked: SkillSelection = ["a"]
      let agents = Agents(sources: [.source(name: "s", path: "s")], components: [.skills(source: "s", select: picked)])
      """
    let previous = try projected(constant)
    var next = previous
    try next.updateSkills { $0?["s"]?.select = .names(["a", "b"]) }
    expectManifestFailure("manifest.edit.readOnly") {
      try planned(previous, next, in: manifestHeader + constant)
    }
    let commented = """
      let agents = Agents(sources: [.source(name: "s", /* pinned */ url: "https://e.org/s.git", branch: "main")])
      """
    let source = try projected(commented)
    var moved = source
    moved.sources["s"]?.requirement = .branch("next")
    expectManifestFailure("manifest.edit.readOnly") {
      try planned(source, moved, in: manifestHeader + commented)
    }
  }

  @Test func largeChangesAreSplitIntoReplannedBatches() throws {
    var next = Declaration()
    for alias in (0..<150).map({ "s\($0)" }).sorted(by: utf8Less) {
      next.sources[alias] = SourceDeclaration(kind: .local, location: alias)
    }
    var batches: [Int] = []
    let bytes = try #require(
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: next,
        in: Array((manifestHeader + "let agents = Agents()").utf8),
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: {
          batches.append($0.count)
          return $0
        }))
    #expect(batches == [150, 50, 0])
    let result = try DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest"))
    #expect(result.declaration.sources.count == 150)
  }

  @Test func previousMustDescribeTheDocument() throws {
    let body = "let agents = Agents(sources: [.source(name: \"s\", path: \"s\")])"
    let stale = Declaration(sources: ["s": local, "t": local])
    expectManifestFailure("manifest.edit.baseline") {
      try planned(stale, stale, in: manifestHeader + body)
    }
    expectManifestFailure("manifest.edit.baseline") {
      try planned(Declaration(sources: ["s": local]), Declaration(), in: nil)
    }
  }

  @Test func plannerOmissionsFailTheFinalComparison() throws {
    var next = Declaration(sources: ["s": local])
    next.watch = ["s"]
    expectManifestFailure("manifest.edit.mismatch") {
      try DeclarationEditPlan.bytes(
        replacing: Declaration(), with: next,
        in: Array((manifestHeader + "let agents = Agents()").utf8),
        identity: DocumentIdentity("manifest"), environment: projectionEnvironment,
        planning: { Array($0.dropLast()) })
    }
  }

  @Test func repeatedEditsOfACommentedManifestKeepUnrelatedBytes() throws {
    var body = """
      // Team manifest: keep this header.
      let agents = Agents(
        // Recipients for everything below.
        defaultAgents: [.claudeCode, .codex],
        sources: [
          // Shared team skills.
          .source(name: "team", url: "https://github.com/team/skills", from: "1.0.0"),
          // Local drafts stay editable.
          .source(name: "drafts", path: "./drafts"),
        ],
        components: [
          // Everything from the team.
          .skills(
            // pinned upstream
            source: "team"
          ),
          // Drafts linked for editing.
          .skills(source: "drafts", mode: .edit),
          // House rules.
          .instructions(
            sections: [
              "guide", // first
              .section(name: "rules", source: "team"),
            ]
          ),
        ],
        // Watched for upstream changes.
        watch: ["team"]
      )
      // trailing note

      """
    let kept = [
      "// Team manifest: keep this header.\nlet agents = Agents(\n",
      "  // Recipients for everything below.\n  defaultAgents: [.claudeCode, .codex],\n",
      "    // Shared team skills.\n    .source(name: \"team\", url: \"https://github.com/team/skills\", from: \"1.0.0\"),\n",
      "    // Everything from the team.\n    .skills(\n      // pinned upstream\n      source: \"team\"",
      "    // House rules.\n    .instructions(\n      sections: [\n        \"guide\", // first\n",
      "        .section(name: \"rules\", source: \"team\"),\n",
      "  // Watched for upstream changes.\n  watch: [",
      ")\n// trailing note\n",
    ]
    func expectKept(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
      var remainder = text[...]
      for segment in kept {
        guard let range = remainder.range(of: segment) else {
          Issue.record("missing unchanged bytes: \(segment)", sourceLocation: sourceLocation)
          return
        }
        remainder = remainder[range.upperBound...]
      }
    }
    let steps: [(inout Declaration) throws -> Void] = [
      { try $0.updateSkills { $0?["team"]?.exclude = ["deprecated"] } },
      {
        $0.sources["extra"] = SourceDeclaration(kind: .git, location: "github.com/team/extra")
        try $0.updateSkills { $0?["extra"] = SkillDeclaration(select: .names(["one"])) }
      },
      {
        try $0.updateInstructions { $0?.sections.append("extra:style") }
        try $0.updateInstructions { $0?.agents = [.codex] }
      },
      { $0.watch?.append("extra") },
      {
        $0.sources["drafts"] = nil
        try $0.updateSkills { $0?["drafts"] = nil }
      },
      {
        try $0.updateInstructions {
          $0?.chatgpt = ["weekly": PromptDeclaration(sections: ["guide"])]
        }
      },
    ]
    for step in steps {
      body = try changed(body, step)
      expectKept(body)
    }
    #expect(!body.contains("drafts"))
    #expect(
      body == """
        // Team manifest: keep this header.
        let agents = Agents(
          // Recipients for everything below.
          defaultAgents: [.claudeCode, .codex],
          sources: [
            // Shared team skills.
            .source(name: "team", url: "https://github.com/team/skills", from: "1.0.0"),
            .source(name: "extra", url: "https://github.com/team/extra"),
          ],
          components: [
            // Everything from the team.
            .skills(
              // pinned upstream
              source: "team",
              exclude: ["deprecated"]
            ),
            .skills(
              source: "extra",
              select: ["one"]
            ),
            // House rules.
            .instructions(
              sections: [
                "guide", // first
                .section(name: "rules", source: "team"),
                .section(name: "style", source: "extra"),
              ],
              chatGPT: [
                .prompt(
                  name: "weekly",
                  sections: ["guide"]
                ),
              ],
              agents: [.codex]
            ),
          ],
          // Watched for upstream changes.
          watch: ["extra", "team"]
        )
        // trailing note

        """)
  }
}
