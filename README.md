# core

Swift libraries for managing agent skills from declared sources and transforming
instruction text. The package provides the engine for `agents` in
`agents-tools/cli` and `skill` in `skill-cli/cli`. Those consumers own command
parsing, terminal output and executable distribution.

## Modules

- **AgentsCore**: source parsing and identity, Git requirements, declaration and
  resolved-state models, atomic state storage, bare mirrors and immutable source
  materializations, hashing, path safety, process execution and agent locations.
- **AgentsSkills**: `SKILL.md` discovery and frontmatter, well-known artifacts,
  installation, updates, removal, listing, initialization and diagnostics. It
  depends on `AgentsCore` and Yams.
- **AgentsInstructions**: in-memory validation and rendering of instruction
  sources, managed Markdown blocks, drift reports, Claude forwarding, and
  ChatGPT prompts. It uses `AgentsCore` for hashing and `swift-markdown` for
  CommonMark structure; callers own files and instruction lifecycle state.

`AgentsCore` defines the instruction declaration and lock models. Instruction
lifecycle integration and watch subscriptions are separate implementation work.
Skill operations preserve the instruction and watch declarations and the locked
instruction records.

Claude forwarding recognizes standalone, unquoted and unformatted imports of
that project's `AGENTS.md` outside code and HTML, including managed import
blocks. Inline mentions do not suppress the caller's managed import block;
a duplicate import is acceptable to ensure the instructions load.

## State and Lifecycle

Project state lives in `.agent/agents.json` and `.agent/agents.resolved`. User
state lives in `~/.agents/agents.json` and `~/.agents/agents.resolved`. The
respective `cache/` directory holds source mirrors and exact content. State is
local to its scope and should be ignored by version control.

The declaration records source aliases, requirements, skill selections and
recipients. The version 1 lock records each skill's independent revision or
artifact digest, content hash and agent-to-mode mapping. `link` uses shared
cached content, `copy` writes a directory, and `edit` links a live local
source with no requirement or pin. Local Git installs in `link` and `copy`
use committed content.

`SkillOperations` supplies the consumer workflows:

- `add(_:)` resolves a source and saves its selection and installations. An
  unselected source with several skills returns the available skills for a CLI
  choice. `listOnly` and `fullDepth` support source inspection.
- `updateInstalled(...)` previews declared changes. With `apply: true`, its
  `beforeApply` callback receives differences before targets and state change.
  Unnamed updates reconcile `select: "all"`; named updates affect only the
  requested members.
- `installResolvedReport(...)` restores the lock's pins, agents and modes.
  Missing pins and digest mismatches fail the operation.
- `remove(...)` changes intent and installations together. Removing an `all`
  member records an exclusion; unused materializations are pruned.
- `listManaged(...)`, `listInstalled(...)`, `doctor(...)` and
  `initializeSkill(named:directory:)` provide inventory, diagnostics and authoring.

Pass `RuntimeEnvironment` to select the project, home directory and environment.
Default recipients for additions are Codex and Claude Code. Supported agents also
include Cursor, Gemini CLI and OpenCode. Listing and removal
without an agent filter cover every recipient. Update previews include physical
removals, entry types and symbolic link destinations. Installed inventory validates
skill metadata and excludes missing entries; managed inventory retains those
records for diagnosis.

State operations recover interrupted transactions before proceeding and report
`CoreError.transactionRecovered` when the command should be retried. The durable
scope journal covers installations, declaration, lock and cache pruning.

## Dependency

Requires Swift 6.3 or newer and macOS 13 or newer, using Swift 6 language mode.

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
      .product(name: "AgentsInstructions", package: "core"),
    ]
  )
]
```

Use `.package(path: "../core")` for local integration. Pin a reviewed revision
when reproducibility is required.

```swift
import AgentsCore
import AgentsSkills

let environment = RuntimeEnvironment()
let preview = try SkillOperations.updateInstalled(
  scope: .project, environment: environment
)
let skills = try SkillOperations.listManaged(
  scope: .project, agents: [.codex], environment: environment
)
```

## Development

```bash
swift build
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
swift build -c release
xcrun swift-format lint --configuration .swift-format --recursive Package.swift Sources Tests
git diff --check origin/master
```

Tests are organized in `Tests/AgentsCoreTests`, `Tests/AgentsSkillsTests`, and
`Tests/AgentsInstructionsTests`. Filesystem tests use isolated runtime homes and
disposable local Git fixtures with explicit initial branches; instruction tests
use in-memory fixtures. Public API tests import the libraries normally.

See [package architecture](Documentation/Architecture/Package.md),
[state and cache](Documentation/Architecture/State.md), and the
[documentation index](Documentation/README.md).
