<p align="center">
  <a href="https://github.com/agents-tools/core">
    <img src=".github/assets/logo/logo.svg" width="160" alt="core logo">
  </a>
</p>

<h1 align="center">core</h1>

<p align="center">
  Swift libraries behind agents and skill: sources, locks, skills, instructions
  and watch.
</p>

<p align="center">
  <a href="https://github.com/agents-tools/core/actions/workflows/ci.yml">
    <img
      src="https://github.com/agents-tools/core/actions/workflows/ci.yml/badge.svg?branch=master"
      alt="CI">
  </a>
  <a href="Package.swift">
    <img src="https://img.shields.io/static/v1?label=Swift&amp;message=6.3%2B&amp;color=16143D&amp;labelColor=4F4C7A"
      alt="Swift 6.3+">
  </a>
  <a href="Package.swift">
    <img src="https://img.shields.io/static/v1?label=platforms&amp;message=macOS%2013%2B&amp;color=16143D&amp;labelColor=4F4C7A"
      alt="Platforms: macOS 13+">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/static/v1?label=license&amp;message=MIT&amp;color=16143D&amp;labelColor=4F4C7A" alt="License: MIT">
  </a>
</p>

<p align="center">
  <a href="#overview">Overview</a> ·
  <a href="#quick-look">Quick look</a> ·
  <a href="#install">Install</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="#contributing">Contributing</a> ·
  <a href="#license">License</a>
</p>

## Overview

Declare sources and recipients, resolve exact content into a lock, and apply
skill and instruction changes through recoverable transactions. Independent
watch subscriptions compare upstream changes without changing installations.

Both [agents](https://github.com/agents-tools/cli) and
[skill](https://github.com/skill-cli/cli) consume this package. Consumers own
command parsing, terminal output and executable distribution.

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

## Quick look

In a fresh project with a valid `review` skill at `skills/review/SKILL.md`, link
the live source for Codex and list the installed skills:

```swift
import AgentsCore
import AgentsSkills

let environment = RuntimeEnvironment()
_ = try SkillOperations.add(AddOptions(
  source: "./skills", agents: [.codex], skillNames: ["review"],
  mode: .edit, environment: environment
))
let installed = try SkillOperations.listInstalled(
  agents: [.codex], environment: environment
)
print(installed.map(\.name).joined(separator: ", ")) // review
```

## Install

Add the package and the products your target uses to `Package.swift`:

```swift
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

No tagged release is available yet. Use `branch: "master"` until tagged releases
are published, then replace the branch dependency with a tagged release
requirement. Pin a reviewed revision when reproducibility is required. Use
`.package(path: "../core")` for local integration.

## Usage

### State and lifecycle

Project state lives in `.agent/agents.json`, `.agent/agents.resolved` and
`.agent/agents.watch`. User state uses the same filenames under `~/.agents/`.
The respective `cache/` directory holds source mirrors and exact content. State
is local to its scope and should be ignored by version control.

The declaration records source aliases, requirements, skill selections and
recipients. The version 1 lock records each skill's independent revision or
artifact digest, content hash and agent-to-mode mapping. `link` uses shared
cached content, `copy` writes a directory, and `edit` links a live local source
with no requirement or pin. Local Git installs in `link` and `copy` use
committed content.

`AgentsCore` defines the instruction declaration and lock models. Skill
operations preserve the instruction and watch declarations and the locked
instruction records.

Mutating state operations recover interrupted transactions before proceeding and
report `CoreError.transactionRecovered` when the command should be retried. The
durable scope journal covers installations, declaration, lock, watch state and
cache pruning. Corrupt watch state stops scope mutations before any replacement.

### Skills

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
  `initializeSkill(named:directory:)` provide inventory, diagnostics and
  authoring.

Pass `RuntimeEnvironment` to select the project, home directory and environment.
Default recipients for additions are Codex and Claude Code. Supported agents
also include Cursor, Gemini CLI and OpenCode. Listing and removal without an
agent filter cover every recipient. Update previews include physical removals,
entry types and symbolic link destinations. Installed inventory validates skill
metadata and excludes missing entries; managed inventory retains those records
for diagnosis.

### Watch

`WatchOperations` subscribes to sources independently of installations. Create
it with `SkillOperations.watchOperations()` to use the package's skill discovery
and well-known artifact formats. `add` declares and subscribes a source,
`status` reports commits and new/changed/removed skills and instruction units,
and `diff` provides typed before/after file contents. `seen` acknowledges the
current head or a specified Git revision; `remove` drops only the subscription
and baseline. Git subscriptions follow the declared branch or default branch,
even when installations use a version requirement. Well-known subscriptions
compare artifact digests and retain seen content for later diffs. Status and
diff leave declaration, lock, watch state and installed content unchanged.

### Instructions

`InstructionOperations` manages ordered sections from committed `.md` files
under a source's `instructions/` or `.agents/instructions/` search root:

- `add(_:)` selects sections and writes every recipient together. Conflicting
  custom sections stop the operation unless `replace` is enabled.
- `list(source:...)` inspects a source; `listManaged(...)` returns locked
  sections, prompts and physical targets.
- `updateInstalled(...)` previews resolutions, target differences and changed
  ChatGPT prompts. With `apply: true`, a throwing `beforeApply` callback can
  show differences or cancel before files and state change.
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

Claude forwarding recognizes standalone, unquoted and unformatted imports of
that project's `AGENTS.md` outside code and HTML, including managed import
blocks. Inline mentions do not suppress the caller's managed import block;
a duplicate import is acceptable to ensure the instructions load.

See [instruction lifecycle](Documentation/Architecture/Instructions.md) for API
contracts, target paths, read-only inspection and deletion rules.

## Requirements

- Swift 6.3 or newer, using Swift 6 language mode.
- macOS 13 or newer, as declared in [Package.swift](Package.swift).

## Documentation

- [Documentation index](Documentation/README.md): documentation areas and
  placement.
- [Package architecture](Documentation/Architecture/Package.md): products,
  module boundaries and public workflows.
- [State and cache](Documentation/Architecture/State.md): declarations, resolved
  state, transactions and installation invariants.
- [Instruction lifecycle](Documentation/Architecture/Instructions.md): section
  selection, targets, prompts and diagnostics.
- [Watch API](Documentation/Architecture/Watch.md): subscriptions, comparisons
  and seen baselines.
- [Release checklist](Documentation/Reference/Release.md): package releases and
  downstream updates.
- [Changelog](CHANGELOG.md): unreleased and published consumer-facing changes.

## Contributing

Read the [organization contributing guide][contributing] and the
[maintenance change flow][maintenance] before submitting changes. Run the
[development checks](#development) for the candidate you submit.

### Development

Run the package's build, test, release and formatting checks:

```bash
swift build
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME \
  -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
swift build -c release
xcrun swift-format lint --strict --configuration .swift-format \
  --recursive Package.swift Sources Tests
git diff --check origin/master
```

The required checks are `policy / policy` and `validate / swift-package`,
provided by full-SHA-pinned reusable workflows from `agents-tools/.github`.
Source policy validates PR titles, new commit messages and added lines. Swift
validation runs strict formatting, debug build, tests with the environment
overrides above unset, release build and a diff check on `macos-26`.

The `presentation / presentation` job checks the committed
[social preview](.github/assets/social-preview/social-preview.png) against the
standard's DESIGN, fonts, catalog and this repository's framework logo. See
[presentation reproduction](Documentation/Reference/Presentation.md#social-preview).
It calls the shared presentation workflow without executable inputs. Its required
context is activated separately after a passing real PR run.

All workflows run on branch pushes and PRs; only source policy reruns on PR
title edits. They also support manual dispatch; source policy validates the
selected ref's head commit. See the organization
[workflow integration guide][workflow-integration] for the shared interfaces
and pin update process.

## License

core is available under the [MIT License](LICENSE).

[contributing]:
  https://github.com/agents-tools/.github/blob/master/CONTRIBUTING.md
[maintenance]:
  https://github.com/agents-tools/.github/blob/master/MAINTENANCE.md#change-flow
[workflow-integration]:
  https://github.com/agents-tools/.github/blob/master/Documentation/Reference/WorkflowIntegration.md
