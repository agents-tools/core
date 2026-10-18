<p align="center">
  <img src="Documentation/Assets/Logo.svg" width="160" alt="core logo">
</p>

<h1 align="center">core</h1>

Swift libraries for managing agent skills and instructions from declared
sources. The package provides the engine for `agents` in
`agents-tools/cli` and `skill` in `skill-cli/cli`. Those consumers own command
parsing, terminal output and executable distribution.

## Modules

- **AgentsCore**: source parsing and identity, Git requirements, declaration and
  resolved-state models, atomic state storage, bare mirrors and immutable source
  materializations, watch subscriptions, hashing, path safety, process execution
  and agent locations.
- **AgentsSkills**: `SKILL.md` discovery and frontmatter, well-known artifacts,
  installation, updates, removal, listing, initialization and diagnostics. It
  depends on `AgentsCore` and Yams.
- **AgentsInstructions**: instruction discovery, lifecycle operations, audits,
  managed Markdown blocks, Claude forwarding and named ChatGPT prompts. It uses
  `AgentsCore` for sources, state and transactions, and `swift-markdown` for
  CommonMark structure. Pure text APIs remain available separately.

`AgentsCore` defines the instruction declaration and lock models.
Skill operations preserve the instruction and watch declarations and the locked
instruction records.

Claude forwarding recognizes standalone, unquoted and unformatted imports of
that project's `AGENTS.md` outside code and HTML, including managed import
blocks. Inline mentions do not suppress the caller's managed import block;
a duplicate import is acceptable to ensure the instructions load.

## State and Lifecycle

Project state lives in `.agent/agents.json`, `.agent/agents.resolved` and
`.agent/agents.watch`. User state uses the same filenames under `~/.agents/`. The
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

`WatchOperations` subscribes to sources independently of installations. Create
it with `SkillOperations.watchOperations()` to use the package's skill discovery
and well-known artifact formats. `add` declares and subscribes a source, `status`
reports commits and new/changed/removed skills and instruction units, and `diff`
provides typed before/after file contents. `seen` acknowledges the current head
or a specified Git revision; `remove` drops only the subscription and baseline.
Git subscriptions follow the declared branch or default branch, even when
installations use a version requirement. Well-known subscriptions compare
artifact digests and retain seen content for later diffs. Status and diff leave
declaration, lock, watch state and installed content unchanged.

Mutating state operations recover interrupted transactions before proceeding and report
`CoreError.transactionRecovered` when the command should be retried. The durable
scope journal covers installations, declaration, lock, watch state and cache
pruning. Corrupt watch state stops scope mutations before any replacement.

`InstructionOperations` manages ordered sections from committed `.md` files
under a source's `instructions/` or `.agents/instructions/` search root:

- `add(_:)` selects sections and writes every recipient together. Conflicting
  custom sections stop the operation unless `replace` is enabled.
- `list(source:...)` inspects a source; `listManaged(...)` returns locked sections,
  prompts and physical targets.
- `updateInstalled(...)` previews resolutions, target differences and changed
  ChatGPT prompts. With `apply: true`, a throwing `beforeApply` callback can show
  differences or cancel before files and state change.
- `installResolvedReport(...)` restores locked sections, offsets and targets.
  `remove(...)` preserves custom content and deletes empty files only when their
  lock records that the tool created them.
- `renderChatGPT(prompt:...)` renders locked sections plus a custom append file
  without markers. Prompts live in `instructions.chatgpt`.
- `doctor(...)` checks drift, scope duplication, Claude forwarding, Codex
  overrides and size limits, newer matching source revisions and uncommitted
  sources. Its `projectRoots` overload audits explicit projects without writing.
- `initializeInstructions(named:directory:)` creates a valid source skeleton.

Project recipients share `AGENTS.md` except Gemini CLI, which uses `GEMINI.md`.
Claude project files receive only a managed import when forwarding is needed.
User locations honor `CODEX_HOME`, `CLAUDE_CONFIG_DIR` and `XDG_CONFIG_HOME`;
Codex and Claude use separate files. Lost-lock update reports the comparison;
apply reconstructs the lock without claiming ownership of pre-existing files.
Codex diagnostics accept effective discovery settings from the consumer,
including trusted project configuration overrides.
See [instruction lifecycle](Documentation/Architecture/Instructions.md) for API
contracts, target paths, read-only inspection and deletion rules.

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
let watch = SkillOperations.watchOperations()
let changes = try watch.status(scope: .project, environment: environment)
```

See [package architecture](Documentation/Architecture/Package.md),
[state and cache](Documentation/Architecture/State.md), the
[watch API](Documentation/Architecture/Watch.md), and the
[documentation index](Documentation/README.md).

## Development

Run the package's build, test, release and formatting checks:

```bash
swift build
swift test
swift build -c release
xcrun swift-format lint --strict --configuration .swift-format --recursive Package.swift Sources Tests
```
