// Generated from Tests/AgentsManifestTests/Fixtures. Run Scripts/generate-manifest-fixtures.py.

import AgentsDescription
import Foundation

#if canImport(SwiftUI)
  import SwiftUI
#endif

struct CompiledManifestFixture {
  let name: String
  let agents: Agents
  let constants: [String: ConstructionValue]
}

func compiledFixtures() -> [CompiledManifestFixture] {
  [
    compiledConsumerExample(),
    compiledCoreExample(),
    compiledExportedGroup(),
    compiledInstructionRecipients(),
    compiledLiteralCoverage(),
    compiledMigrationEdgeExample(),
    compiledProducerExample(),
    compiledRecipientConditions(),
    compiledRequirementValues(),
    compiledRequirementsExample(),
    compiledSectionConcatenation(),
    compiledSharedRules(),
    compiledSketchExample(),
    compiledSkillsExample(),
    compiledTeamConfiguration(),
    compiledVersionCollections(),
    compiledVocabularyDepthExample(),
  ]
}

private func compiledConsumerExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let base: [SectionReference] = ["guide"]
  let sections = base + [.section(name: "engineering", source: "rules")]
  let reviewer: Component = .subagent(
    name: "reviewer",
    description: "Review correctness and tests.",
    prompt: "Check invariants and explain concrete failures.",
    agents: [.claudeCode],
    condition: .when(platforms: [.macOS]),
    native: ["claude-code/subagent@1": ["memory": "project"]]
  )

  let agents = Agents(
    sources: [
      .source(name: "team", path: "./team"),
      .source(name: "drafts", path: "./draft-skills"),
      .source(name: "rules", url: "https://example.org/team/rules.git", from: "1.2.0"),
      .source(name: "catalog", index: "https://example.org/skills/index.json"),
      .source(name: "vendor", url: "https://example.org/vendor/tools.git", exact: "2.1.0"),
    ],
    components: [
      .skills(
        source: "rules", exclude: ["experimental"], mode: .copy,
        overrides: [.skill(name: "testing", mode: .link, agents: [.codex])]
      ),
      .skills(
        source: "drafts", select: ["draft"], mode: .edit,
        condition: .when(agents: [.claudeCode], scopes: [.project])
      ),
      .instructions(
        sections: sections,
        chatGPT: [.prompt(name: "weekly", sections: base, append: "notes/weekly.md")]
      ),
      .mcpServer(
        name: "workspace",
        transport: .stdio(
          "workspace-tools", arguments: ["serve"],
          environment: ["TOKEN": .secret("workspace-token"), "LOG_LEVEL": "info"]
        ),
        agents: [.claudeCode]
      ),
      .mcpServer(
        name: "reference",
        transport: .streamableHTTP(
          url: "https://example.org/mcp", headers: ["Authorization": .environment("MCP_AUTH")]
        ),
        agents: [.openCode]
      ),
      .hook(
        name: "format", event: .afterTool,
        run: .executable(
          "swift", arguments: ["format", "--in-place", "Sources"],
          workingDirectory: .path("tools", source: "rules")
        ),
        timeoutSeconds: 30, agents: [.claudeCode], condition: .when(scopes: [.project])
      ),
      .command(
        name: "review/change", description: "Review a selected change.",
        prompt: "Review ${input:change} and cite evidence.",
        parameters: [.parameter(name: "change", description: "The change to review.")],
        agents: [.claudeCode]
      ),
      .lspServer(
        name: "swift", run: .executable("sourcekit-lsp"),
        languages: [".swift": "swift"],
        initializationOptions: ["backgroundIndexing": true],
        agents: [.claudeCode], condition: .when(platforms: [.macOS])
      ),
      .permissions(
        name: "private-files",
        rules: [.deny(.read, "secrets/**")],
        agents: [.claudeCode], condition: .when(scopes: [.project])
      ),
      .ignore(
        name: "build-products", patterns: [".build/", "DerivedData/"], purpose: .indexing,
        agents: [.cursor], condition: .when(scopes: [.project])
      ),
      .plugin(
        name: "vendor-tools", path: "plugins/tools", source: "vendor", mode: .native,
        agents: [.claudeCode], condition: .when(scopes: [.user])
      ),
      .plugin(
        name: "shared-tools", path: "plugins/shared", source: "vendor",
        exclude: [.hook(name: "format")], condition: .when(scopes: [.project])
      ),
    ],
    groups: [
      .group(
        name: "review-tools", components: [reviewer],
        uses: [.group(name: "review", source: "team", condition: .when(agents: [.codex]))]
      )
    ],
    uses: ["review-tools"],
    watch: ["rules", "catalog"]
  )
  return CompiledManifestFixture(
    name: "ConsumerExample.swift.txt", agents: agents,
    constants: [
      "base": base.constructionValue,
      "sections": sections.constructionValue,
      "reviewer": reviewer.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledCoreExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    sources: [
      .source(
        name: "agents-tools",
        url: "https://github.com/agents-tools/.github",
        branch: "master",
        subpath: ".agent"
      )
    ],
    components: [
      .instructions(
        sections: [
          "guide",
          .section(name: "shared/swift-package-route", source: "agents-tools"),
          .section(name: "shared/swift-package-tests", source: "agents-tools"),
        ],
        agents: [.claudeCode, .codex]
      )
    ]
  )
  return CompiledManifestFixture(
    name: "CoreExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledExportedGroup() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    exports: ["review"],
    groups: [
      .group(
        name: "review",
        components: [
          .instructions(sections: ["review-principles"], agents: [.claudeCode, .codex]),
          .skills(source: ".", select: ["review"], mode: .copy, agents: [.claudeCode, .codex]),
        ],
        condition: .when(scopes: [.project])
      )
    ]
  )
  return CompiledManifestFixture(
    name: "ExportedGroup.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledInstructionRecipients() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    components: [
      .instructions(
        sections: ["guide", "code-review-rules"],
        agents: [.claudeCode, .codex]
      )
    ]
  )
  return CompiledManifestFixture(
    name: "InstructionRecipients.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledLiteralCoverage() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let text: PromptContent = "Review invariants."
  let section: SectionReference = "guide"
  let local: GroupReference = "review"
  let selection: SkillSelection = ["review", "testing"]
  let configuration: ConfigurationValue = [
    "string": "value", "integer": -1, "boolean": true, "null": nil,
    "array": [1, "two", false, nil], "object": ["enabled": true], "decimal": .decimal("1.25"),
  ]
  let environment: [String: RuntimeValue] = ["LEVEL": "info", "TOKEN": .secret("token")]
  let emptySelection: SkillSelection = []
  let emptyObject: ConfigurationValue = [:]
  let emptyArray: ConfigurationValue = []
  let emptyTools: Component = .subagent(
    name: "empty-tools", description: "No tools", prompt: "Read", tools: [])
  let invocation: ExecutableInvocation = .executable(
    "server", environment: environment, workingDirectory: .path("tools", source: "vendor"))
  let runtime: RuntimeValue = .literal("literal")
  let scalar: ConfigurationValue = .string("x")
  let integer: ConfigurationValue = .integer(-9_223_372_036_854_775_808)
  let boolean: ConfigurationValue = .boolean(false)
  let null: ConfigurationValue = .null
  let array: ConfigurationValue = .array([scalar, integer, boolean, null])
  let object: ConfigurationValue = .object(["array": array])
  let agents = Agents(
    exports: ["review"],
    sources: [.source(name: "team", path: "team"), .source(name: "vendor", path: "vendor")],
    components: [
      .mcpServer(name: "tools", transport: .stdio("server", environment: environment)),
      .mcpServer(name: "sse", transport: .sse(url: "https://example.org/events")),
      .command(name: "review", description: "Review", prompt: text),
      .instructions(sections: [section]),
      .skills(
        source: "team", select: selection,
        overrides: [.skill(name: "review", mode: .copy, agents: [.codex])]),
      .lspServer(
        name: "swift", run: invocation, languages: [".swift": "swift"],
        initializationOptions: ["config": configuration]),
      .permissions(
        name: "policy",
        rules: [
          .allow(.read, "Sources/**"), .ask(.write, "**"), .deny(.execute, "rm *"),
          .deny(.tool("fetch"), "*"),
        ]),
      .plugin(
        name: "tools", path: "plugins/tools", source: "vendor",
        select: [
          .skills, .instructions, .mcpServer, .hook, .subagent, .command, .lspServer, .permissions,
          .ignore, .plugin,
        ],
        exclude: [
          .skill(name: "a"), .instruction(name: "a"), .mcpServer(name: "a"), .hook(name: "a"),
          .subagent(name: "a"), .command(name: "a"), .lspServer(name: "a"), .permissions(name: "a"),
          .ignore(name: "a"), .plugin(name: "a"),
        ]),
      .hook(name: "native", event: .native("Event"), run: invocation, agents: [.codex]),
      .ignore(
        name: "context", patterns: [], purpose: .context, agents: [],
        condition: .when(scopes: [.project, .user], platforms: [.macOS, .linux])),
      emptyTools,
    ],
    groups: [.group(name: "review")],
    uses: [local, .group(name: "review", condition: .when(agents: [.codex]))]
  )
  return CompiledManifestFixture(
    name: "LiteralCoverage.swift.txt", agents: agents,
    constants: [
      "text": text.constructionValue,
      "section": section.constructionValue,
      "local": local.constructionValue,
      "selection": selection.constructionValue,
      "configuration": configuration.constructionValue,
      "environment": environment.constructionValue,
      "emptySelection": emptySelection.constructionValue,
      "emptyObject": emptyObject.constructionValue,
      "emptyArray": emptyArray.constructionValue,
      "emptyTools": emptyTools.constructionValue,
      "invocation": invocation.constructionValue,
      "runtime": runtime.constructionValue,
      "scalar": scalar.constructionValue,
      "integer": integer.constructionValue,
      "boolean": boolean.constructionValue,
      "null": null.constructionValue,
      "array": array.constructionValue,
      "object": object.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledMigrationEdgeExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    sources: [
      .source(name: "source", path: "./drafts", from: "1.2.0"),
      .source(
        name: "source-2",
        path: "./more",
        .upToNextMinor(from: "1.2.0")
      ),
      .source(name: "source-3", url: "https://example.org/rules.git"),
    ],
    components: [
      .skills(
        source: "source",
        overrides: [
          .skill(
            name: "future",
            agents: [.openCode]
          )
        ]
      ),
      .skills(
        source: "source-3",
        select: ["a"],
        overrides: [
          .skill(
            name: "a",
            mode: .copy,
            agents: [.codex]
          )
        ]
      ),
      .instructions(
        sections: [
          "guide",
          .section(name: "rule", source: "source-3"),
        ],
        chatGPT: [
          .prompt(
            name: "",
            sections: [
              .section(name: "rule", source: "source-3")
            ]
          )
        ]
      ),
    ],
    watch: ["source-3"]
  )
  return CompiledManifestFixture(
    name: "MigrationEdgeExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledProducerExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    exports: ["review"],
    groups: [
      .group(
        name: "review",
        components: [
          .instructions(sections: ["review-principles"], agents: [.claudeCode, .codex]),
          .skills(source: ".", select: ["review"], mode: .copy, agents: [.claudeCode, .codex]),
        ],
        condition: .when(scopes: [.project])
      )
    ]
  )
  return CompiledManifestFixture(
    name: "ProducerExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledRecipientConditions() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    defaultAgents: [.cursor],
    sources: [.source(name: "team", path: "./team")],
    components: [
      .ignore(
        name: "build-products", patterns: [".build/"], purpose: .indexing,
        condition: .when(scopes: [.project])
      )
    ],
    uses: [
      .group(name: "review", source: "team", condition: .when(agents: [.codex]))
    ]
  )
  return CompiledManifestFixture(
    name: "RecipientConditions.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledRequirementValues() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let majorFrom: Source = .source(
    name: "rules", url: "https://example.org/rules.git", from: "1.2.0")
  let majorHelper: Source = .source(
    name: "rules", url: "https://example.org/rules.git", .upToNextMajor(from: "1.2.0"))
  let majorRange: Source = .source(
    name: "rules", url: "https://example.org/rules.git", "1.2.0"..<"2.0.0")
  let minorHelper: Source = .source(
    name: "rules", url: "https://example.org/rules.git", .upToNextMinor(from: "1.2.0"))
  let minorRange: Source = .source(
    name: "rules", url: "https://example.org/rules.git", "1.2.0"..<"1.3.0")
  let prereleaseFrom: Source = .source(
    name: "rules", url: "https://example.org/rules.git", from: "1.2.3-beta.1+build.7")
  let prereleaseHelper: Source = .source(
    name: "rules", url: "https://example.org/rules.git",
    .upToNextMajor(from: "1.2.3-beta.1+build.7"))
  let prereleaseRange: Source = .source(
    name: "rules", url: "https://example.org/rules.git", "1.2.3-beta.1+build.7"..<"2.0.0")
  let prereleaseMinor: Source = .source(
    name: "rules", url: "https://example.org/rules.git",
    .upToNextMinor(from: "1.2.3-beta.1+build.7"))
  let prereleaseMinorRange: Source = .source(
    name: "rules", url: "https://example.org/rules.git", "1.2.3-beta.1+build.7"..<"1.3.0")
  let localLiteral: GroupReference = "review"
  let localFactory: GroupReference = .group(name: "review")
  let agents = Agents(
    exports: ["review"],
    sources: [majorFrom],
    components: [
      .plugin(name: "tools", path: "tools", source: "rules", exclude: [.hook(name: "format")])
    ],
    groups: [.group(name: "review")],
    uses: [localLiteral]
  )
  return CompiledManifestFixture(
    name: "RequirementValues.swift.txt", agents: agents,
    constants: [
      "majorFrom": majorFrom.constructionValue,
      "majorHelper": majorHelper.constructionValue,
      "majorRange": majorRange.constructionValue,
      "minorHelper": minorHelper.constructionValue,
      "minorRange": minorRange.constructionValue,
      "prereleaseFrom": prereleaseFrom.constructionValue,
      "prereleaseHelper": prereleaseHelper.constructionValue,
      "prereleaseRange": prereleaseRange.constructionValue,
      "prereleaseMinor": prereleaseMinor.constructionValue,
      "prereleaseMinorRange": prereleaseMinorRange.constructionValue,
      "localLiteral": localLiteral.constructionValue,
      "localFactory": localFactory.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledRequirementsExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let minimum: Version = "1.2.0"
  let review: ComponentGroup = .group(
    name: "review",
    components: [
      .skills(source: ".", overrides: [.skill(name: "review", mode: .copy)]),
      .instructions(
        sections: [.section(name: "guide", source: ".")],
        chatGPT: [.prompt(name: "weekly", sections: ["guide"])]
      ),
      .command(
        name: "review", description: "Review a change", prompt: .file("review.md", source: "."),
        parameters: [
          .parameter(name: "change", description: "Change identifier", defaultValue: "HEAD")
        ]
      ),
      .hook(
        name: "format", event: .afterTool,
        run: .executable("swift", workingDirectory: .path("Sources", source: "."))
      ),
    ]
  )
  let agents = Agents(
    exports: ["review"],
    sources: [
      .source(name: "major", url: "https://example.org/major.git", from: minimum),
      .source(name: "exact", url: "https://example.org/exact.git", exact: "1.2.0"),
      .source(name: "branch", url: "https://example.org/branch.git", branch: "main"),
      .source(name: "revision", url: "https://example.org/revision.git", revision: "abc123"),
      .source(name: "range", url: "https://example.org/range.git", "1.2.0"..<"2.0.0"),
      .source(name: "minor", url: "https://example.org/minor.git", .upToNextMinor(from: "1.2.0")),
      .source(
        name: "explicit-major", url: "https://example.org/explicit.git",
        .upToNextMajor(from: minimum)),
      .source(name: "local-major", path: "./major", from: "1.2.0"),
      .source(name: "local-exact", path: "./exact", exact: "1.2.0"),
      .source(name: "local-branch", path: "./branch", branch: "main"),
      .source(name: "local-revision", path: "./revision", revision: "abc123"),
      .source(name: "local-range", path: "./range", "1.2.0"..<"2.0.0", subpath: "tools"),
      .source(name: "local-minor", path: "./minor", .upToNextMinor(from: "1.2.0")),
      .source(name: "local-explicit-major", path: "./explicit", .upToNextMajor(from: "1.2.0")),
      .source(name: "unversioned", url: "https://example.org/unversioned.git"),
      .source(name: "local", path: "./local"),
      .source(name: "catalog", index: "https://example.org/index.json", subpath: "tools"),
    ],
    groups: [review, .group(name: "quality", uses: ["review"])],
    uses: ["quality", .group(name: "review", source: "major")]
  )
  return CompiledManifestFixture(
    name: "RequirementsExample.swift.txt", agents: agents,
    constants: [
      "minimum": minimum.constructionValue,
      "review": review.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledSectionConcatenation() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let base: [SectionReference] = ["guide"]
  let sections = base + [.section(name: "engineering", source: "rules")]
  let reviewer: Component = .subagent(
    name: "reviewer",
    description: "Review correctness and tests.",
    prompt: "Check invariants and explain concrete failures.",
    agents: [.claudeCode],
    condition: .when(platforms: [.macOS]),
    native: ["claude-code/subagent@1": ["memory": "project"]]
  )

  let agents = Agents(
    sources: [
      .source(name: "team", path: "./team"),
      .source(name: "drafts", path: "./draft-skills"),
      .source(name: "rules", url: "https://example.org/team/rules.git", from: "1.2.0"),
      .source(name: "catalog", index: "https://example.org/skills/index.json"),
      .source(name: "vendor", url: "https://example.org/vendor/tools.git", exact: "2.1.0"),
    ],
    components: [
      .skills(
        source: "rules", exclude: ["experimental"], mode: .copy,
        overrides: [.skill(name: "testing", mode: .link, agents: [.codex])]
      ),
      .skills(
        source: "drafts", select: ["draft"], mode: .edit,
        condition: .when(agents: [.claudeCode], scopes: [.project])
      ),
      .instructions(
        sections: sections,
        chatGPT: [.prompt(name: "weekly", sections: base, append: "notes/weekly.md")]
      ),
      .mcpServer(
        name: "workspace",
        transport: .stdio(
          "workspace-tools", arguments: ["serve"],
          environment: ["TOKEN": .secret("workspace-token"), "LOG_LEVEL": "info"]
        ),
        agents: [.claudeCode]
      ),
      .mcpServer(
        name: "reference",
        transport: .streamableHTTP(
          url: "https://example.org/mcp", headers: ["Authorization": .environment("MCP_AUTH")]
        ),
        agents: [.openCode]
      ),
      .hook(
        name: "format", event: .afterTool,
        run: .executable(
          "swift", arguments: ["format", "--in-place", "Sources"],
          workingDirectory: .path("tools", source: "rules")
        ),
        timeoutSeconds: 30, agents: [.claudeCode], condition: .when(scopes: [.project])
      ),
      .command(
        name: "review/change", description: "Review a selected change.",
        prompt: "Review ${input:change} and cite evidence.",
        parameters: [.parameter(name: "change", description: "The change to review.")],
        agents: [.claudeCode]
      ),
      .lspServer(
        name: "swift", run: .executable("sourcekit-lsp"),
        languages: [".swift": "swift"],
        initializationOptions: ["backgroundIndexing": true],
        agents: [.claudeCode], condition: .when(platforms: [.macOS])
      ),
      .permissions(
        name: "private-files",
        rules: [.deny(.read, "secrets/**")],
        agents: [.claudeCode], condition: .when(scopes: [.project])
      ),
      .ignore(
        name: "build-products", patterns: [".build/", "DerivedData/"], purpose: .indexing,
        agents: [.cursor], condition: .when(scopes: [.project])
      ),
      .plugin(
        name: "vendor-tools", path: "plugins/tools", source: "vendor", mode: .native,
        agents: [.claudeCode], condition: .when(scopes: [.user])
      ),
      .plugin(
        name: "shared-tools", path: "plugins/shared", source: "vendor",
        exclude: [.hook(name: "format")], condition: .when(scopes: [.project])
      ),
    ],
    groups: [
      .group(
        name: "review-tools", components: [reviewer],
        uses: [.group(name: "review", source: "team", condition: .when(agents: [.codex]))]
      )
    ],
    uses: ["review-tools"],
    watch: ["rules", "catalog"]
  )
  return CompiledManifestFixture(
    name: "SectionConcatenation.swift.txt", agents: agents,
    constants: [
      "base": base.constructionValue,
      "sections": sections.constructionValue,
      "reviewer": reviewer.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledSharedRules() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    sources: [
      .source(
        name: "agents-tools",
        url: "https://github.com/agents-tools/.github",
        branch: "master",
        subpath: ".agent"
      )
    ],
    components: [
      .instructions(
        sections: [
          "guide",
          .section(name: "shared/swift-package-route", source: "agents-tools"),
          .section(name: "shared/swift-package-tests", source: "agents-tools"),
        ],
        agents: [.claudeCode, .codex]
      )
    ]
  )
  return CompiledManifestFixture(
    name: "SharedRules.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledSketchExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    defaultAgents: [.cursor],
    sources: [.source(name: "team", path: "./team")],
    components: [
      .ignore(
        name: "build-products", patterns: [".build/"], purpose: .indexing,
        condition: .when(scopes: [.project])
      )
    ],
    uses: [
      .group(name: "review", source: "team", condition: .when(agents: [.codex]))
    ]
  )
  return CompiledManifestFixture(
    name: "SketchExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledSkillsExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    components: [
      .instructions(
        sections: ["guide", "code-review-rules"],
        agents: [.claudeCode, .codex]
      )
    ]
  )
  return CompiledManifestFixture(
    name: "SkillsExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}

private func compiledTeamConfiguration() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  // A team repository's .agent/Agents.swift.
  // Everything here is a declaration: agents reads it, never runs it.

  let reviewer: Component = .subagent(
    name: "reviewer",
    description: "Review correctness and tests.",
    prompt: "Check invariants and explain concrete failures.",
    agents: [.claudeCode]
  )

  let agents = Agents(
    // Components without their own `agents:` go to these.
    defaultAgents: [.claudeCode, .codex],

    sources: [
      .source(
        name: "org", url: "https://github.com/acme/.github", branch: "main", subpath: ".agent"),
      .source(name: "rules", url: "https://example.org/team/rules.git", from: "1.2.0"),
      .source(name: "drafts", path: "./draft-skills"),
    ],

    components: [
      // AGENTS.md / CLAUDE.md, assembled from sections.
      .instructions(
        sections: [
          "guide",
          .section(name: "shared/swift-package-route", source: "org"),
        ]
      ),

      // Every skill from `rules` except one; Codex gets `testing` as a link.
      .skills(
        source: "rules", exclude: ["experimental"], mode: .copy,
        overrides: [.skill(name: "testing", mode: .link, agents: [.codex])]
      ),

      // Work-in-progress skills, only for Claude Code in this project.
      .skills(
        source: "drafts", select: ["draft"], mode: .edit,
        condition: .when(agents: [.claudeCode], scopes: [.project])
      ),

      .mcpServer(
        name: "workspace",
        transport: .stdio(
          "workspace-tools", arguments: ["serve"],
          environment: ["TOKEN": .secret("workspace-token"), "LOG_LEVEL": "info"]
        )
      ),

      .hook(
        name: "format", event: .afterTool,
        run: .executable("swift", arguments: ["format", "--in-place", "Sources"]),
        timeoutSeconds: 30, agents: [.claudeCode], condition: .when(scopes: [.project])
      ),

      .lspServer(
        name: "swift", run: .executable("sourcekit-lsp"),
        languages: [".swift": "swift"],
        agents: [.claudeCode], condition: .when(platforms: [.macOS])
      ),

      .permissions(
        name: "private-files",
        rules: [.deny(.read, "secrets/**")],
        condition: .when(scopes: [.project])
      ),

      .ignore(
        name: "build-products", patterns: [".build/", "DerivedData/"], purpose: .indexing,
        agents: [.cursor]
      ),

      reviewer,
    ],

    // Re-check these sources for updates.
    watch: ["rules"]
  )
  return CompiledManifestFixture(
    name: "TeamConfiguration.swift.txt", agents: agents,
    constants: [
      "reviewer": reviewer.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledVersionCollections() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let versions: [Version] = ["1.2.3"]
  let namedVersions: [String: Version] = ["stable": "1.2.3"]
  let version: Version = "1.2.3"
  let referencedVersions: [Version] = [version]
  let agents = Agents()
  return CompiledManifestFixture(
    name: "VersionCollections.swift.txt", agents: agents,
    constants: [
      "versions": versions.constructionValue,
      "namedVersions": namedVersions.constructionValue,
      "version": version.constructionValue,
      "referencedVersions": referencedVersions.constructionValue,
      "agents": agents.constructionValue,
    ])
}

private func compiledVocabularyDepthExample() -> CompiledManifestFixture {
  // agents-tools-version: 1.0

  let agents = Agents(
    groups: [
      .group(
        name: "review",
        components: [
          .instructions(
            chatGPT: [
              .prompt(
                name: "review",
                sections: [
                  .section(name: "guide", condition: .when(agents: [.codex]))
                ]
              )
            ]
          )
        ]
      )
    ]
  )
  return CompiledManifestFixture(
    name: "VocabularyDepthExample.swift.txt", agents: agents,
    constants: [
      "agents": agents.constructionValue
    ])
}
