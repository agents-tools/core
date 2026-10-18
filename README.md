# core

Shared Swift libraries for managing agent skills and their sources. The package
provides the engine for `agents` in `agents-tools/cli` and for `skill` in
`skill-cli/cli`. The consumers own command parsing, terminal output, and their
executable releases; integration with these libraries happens in those
repositories.

## Modules

- **AgentsCore**: source parsing and identity, requirements and semantic
  versions, process and Git execution, hashing, path safety, agent registry,
  resolved-state storage, and watch bookkeeping.
- **AgentsSkills**: `SKILL.md` discovery and frontmatter, well-known skill
  sources, installation, listing, removal, updates, restoration, initialization,
  and diagnostics. It depends on `AgentsCore` and Yams.

`SkillOperations` exposes skill workflows. `SkillOperations.watches` supplies
watch operations with support for both the current JSON ledger and legacy YAML
ledgers. Pass a `RuntimeEnvironment` to select the project, home directory, and
environment used by an operation. Supported agents are Codex, Claude Code,
Cursor, Gemini CLI, and OpenCode.

## Dependency

Requires Swift 6.3 or newer and macOS 13 or newer, using Swift 6 language mode.
Add the package and the products needed by your target:

```swift
// In your Package.swift:
dependencies: [
  .package(url: "https://github.com/agents-tools/core.git", branch: "master")
],
targets: [
  .executableTarget(
    name: "YourCLI",
    dependencies: [
      .product(name: "AgentsCore", package: "core"),
      .product(name: "AgentsSkills", package: "core"),
    ]
  )
]
```

For local development, use `.package(path: "../core")` instead of the remote
dependency. Pin a reviewed revision when reproducibility is required.

```swift
import AgentsCore
import AgentsSkills

let environment = RuntimeEnvironment()
let skills = try SkillOperations.listManaged(
  scope: .project,
  agents: [.codex],
  environment: environment
)
```

## Development

```bash
swift build
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
swift build -c release
xcrun swift-format lint --configuration .swift-format --recursive Package.swift Sources Tests
git diff --check
```

Tests are organized by the module they exercise in `Tests/AgentsCoreTests` and
`Tests/AgentsSkillsTests`. Public workflow tests import the libraries normally
to check the API available to consumers.

See [package architecture](Documentation/Architecture/Package.md) for module
ownership, API entry points, and persisted-state behavior, and the
[documentation index](Documentation/README.md) for rationale and proposals.
