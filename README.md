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
    <img src="https://img.shields.io/static/v1?label=platforms&amp;message=macOS%2015%2B%20%7C%20Linux&amp;color=16143D&amp;labelColor=4F4C7A"
      alt="Platforms: macOS 15+ and Linux">
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

- **AgentsDescription**: standard-library-only types for authoring the Swift
  manifest construction vocabulary.
- **AgentsManifest**: parses and statically evaluates `Agents.swift` snapshots
  into declaration IR and source maps, prepares byte-preserving edits, and
  connects the scope declaration to state: read-only `loadDeclaration()` and
  `loadManifest()`, and the declaration writes of the domain modules.
- **AgentsCore**: source parsing and identity, Git requirements, declaration and
  resolved-state models, atomic state storage, bare mirrors and immutable source
  materializations, watch subscriptions, hashing, path safety, process execution
  and agent locations.
- **AgentsSkills**: `SKILL.md` discovery and frontmatter, well-known artifacts,
  installation, updates, removal, listing, initialization and diagnostics. It
  depends on `AgentsCore`, `AgentsManifest` and Yams.
- **AgentsInstructions**: instruction discovery, lifecycle operations, audits,
  managed Markdown blocks, Claude forwarding and named ChatGPT prompts. It uses
  `AgentsCore` for sources, state and transactions, `AgentsManifest` for the
  declaration, and `swift-markdown` for CommonMark structure. Pure text APIs
  remain available separately.
- **AgentsUpdates**: shared preparation, reporting and one recoverable apply
  for all declared skills and instructions in a scope.

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
      .product(name: "AgentsDescription", package: "core"),
      .product(name: "AgentsManifest", package: "core"),
      .product(name: "AgentsCore", package: "core"),
      .product(name: "AgentsSkills", package: "core"),
      .product(name: "AgentsInstructions", package: "core"),
      .product(name: "AgentsUpdates", package: "core"),
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

Project state lives in `.agent/Agents.swift`, `.agent/agents.resolved` and
`.agent/agents.watch`. User state uses the same filenames under `~/.agents/`.
The respective `cache/` directory holds source mirrors and exact content. A
project commits its `Agents.swift` declaration and `agents.resolved` lock; keep
`agents.watch`, `cache/`, `.agents.lock` and `transaction.json` out of version
control.

The declaration records source aliases, requirements, skill selections and
recipients in the [manifest language](Documentation/Reference/Manifest.md).
Tool writes edit only the changed source ranges and keep comments. The version 1
lock records each skill's independent revision or artifact digest, content hash
and agent-to-mode mapping. `link` uses shared cached content, `copy` writes a
directory, and `edit` links a live local source with no requirement or pin.
Local Git installs in `link` and `copy` use committed content.

`AgentsCore` defines the instruction declaration and lock models. Skill
operations preserve the instruction and watch declarations and the locked
instruction records.

Mutating state operations recover interrupted transactions before proceeding and
report `CoreError.transactionRecovered` when the command should be retried. The
durable scope journal covers installations, declaration, lock, watch state and
cache pruning. Corrupt watch state stops scope mutations before any replacement.
Read-only access, including `loadDeclaration()`, `loadManifest()`,
`loadResolved()` and `loadWatch()`, never recovers and reports a pending
transaction with `CoreError.recoveryPending`. A scope with a lock or watch state
but no `Agents.swift` reports `CoreError.missingDeclaration`.

### Skills

`SkillOperations` supplies the consumer workflows:

- `add(_:)` resolves a source and saves its selection and installations. An
  unselected source with several skills returns the available skills for a CLI
  choice. `listOnly` and `fullDepth` support source inspection.
- `updateInstalled(...)` previews declared changes. With `apply: true`, its
  `beforeApply` callback receives differences before targets and state change.
  Unnamed updates reconcile all-member selections; named updates affect only the
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

### Combined updates

`UpdateOperations.preview(...)` returns both kinds under one shared scope lock.
For application, `withPreparedUpdate(...)` prepares both kinds and holds the
writer lock while the consumer renders `update.report` and calls
`update.apply()`. Apply commits both kinds, changed state and pruning together.
The handle is valid only on its preparing thread inside that synchronous
closure and accepts one attempt. Do not re-enter scope operations there.

Skill reports include resolved versions, executable flags, missing-lock status
and per-agent managed membership, independent of physical presence. Combined
`hasChanges` also includes state-only updates. `UpdateApplyError` distinguishes
confirmed unchanged, committed and recovery-required outcomes. See
[combined updates](Documentation/Architecture/Updates.md) for cancellation,
recovery and callback contracts.

### Instructions

An instructions file is one Markdown file in a source's `instructions/` or
`.agents/instructions/` container, subdirectories included, named by its path
there without `.md`. It starts with front matter holding a required
`description` and optional `paths` globs, then a body that begins with one
heading. A project's own files live in `.agent/instructions/` and are selected
by bare name. `InstructionOperations` generates whole target files from them:

- `add(_:)` selects files and writes every target together; source `.` selects
  the project's own files. Writing over a file that agents did not generate
  needs `replace`.
- `list(source:...)` and `listOwn(...)` inspect available files;
  `listManaged(...)` returns locked sections, prompts and physical targets.
- `updateInstalled(...)` previews resolutions, target differences and changed
  ChatGPT prompts. With `apply: true`, a throwing `beforeApply` callback can
  show differences or cancel before files and state change.
- `installResolvedReport(...)` restores the locked renderings. `remove(...)`
  deletes a target that no longer receives sections while it still equals its
  locked rendering.
- `renderChatGPT(prompt:...)` renders locked sections plus a custom append file.
  Prompts are declared with `.instructions(chatGPT:)`.
- `doctor(...)` checks missing, drifted and unowned locked targets, changed own
  files, links, scope duplication, Claude forwarding, Codex overrides and the
  project size budget, newer matching source revisions and uncommitted sources.
  Its `projectRoots` overload audits explicit projects without writing.
- `export(projectRoots:...)` reads the user lock and the given projects' locks
  into a mapping of targets to sections, without writing.
- `initializeInstructions(named:environment:)` creates a valid file skeleton in
  the project's `.agent/instructions/`.

A target is a notice line followed by the sections in declared order. A section
with `paths` gets a line naming its patterns and, in project scope, is written
to the `AGENTS.md` of the directory the patterns share. Project recipients
share `AGENTS.md` except Gemini CLI, which uses `GEMINI.md`. Claude project
files receive only a managed import when forwarding is needed. User locations
honor `CODEX_HOME`, `CLAUDE_CONFIG_DIR` and `XDG_CONFIG_HOME`; Codex and Claude
use separate files. Codex diagnostics accept effective discovery settings from
the consumer, including trusted project configuration overrides.

Claude forwarding recognizes standalone, unquoted and unformatted imports of
that project's `AGENTS.md` outside code and HTML, including managed import
blocks. Inline mentions do not suppress the caller's managed import block;
a duplicate import is acceptable to ensure the instructions load.

See [instruction lifecycle](Documentation/Architecture/Instructions.md) for API
contracts, target paths, read-only inspection and deletion rules.

## Requirements

- Swift 6.3 or newer, using Swift 6 language mode.
- macOS 15 or newer, as declared in [Package.swift](Package.swift), or Linux
  with glibc 2.34 or newer, `/proc` mounted and a filesystem supporting file
  `flock`, atomic directory exchange, POSIX ACLs and extended attributes.
- Git and `tar`; ZIP artifacts also require `unzip` (including `zipinfo`).
- Directory permissions, inherited/default ACLs and other filesystem policy must
  allow the owner to read/write created files and read/write/search created
  directories. Core does not repair access policy; denied operations stop with
  the affected path and a permission diagnostic. Correct the environment before
  retrying.

## Documentation

- [Documentation index](Documentation/README.md): documentation areas and
  placement.
- [Package architecture](Documentation/Architecture/Package.md): products,
  module boundaries and public workflows.
- [State and cache](Documentation/Architecture/State.md): declarations, resolved
  state, transactions and installation invariants.
- [Instruction lifecycle](Documentation/Architecture/Instructions.md):
  instructions files, generated targets, prompts and diagnostics.
- [Watch API](Documentation/Architecture/Watch.md): subscriptions, comparisons
  and seen baselines.
- [Combined updates](Documentation/Architecture/Updates.md): reports, preparation,
  one-use handles and transaction outcomes.
- [Release checklist](Documentation/Reference/Release.md): package releases and
  downstream updates.
- [Changelog](CHANGELOG.md): unreleased and published consumer-facing changes.

## Contributing

Read the [organization contributing guide][contributing] and the
[maintenance change flow][maintenance] before submitting changes. Run the
[development checks](#development) for the candidate you submit.

### Development

The generation commands in `.github/swift-package.json` run on the last
compiler entry's runner, using `python3` and the toolchain's `swift format`.
They regenerate into temporary directories and compare committed bytes.
`swift test` checks contract signatures and the complete compiler-backed fixture
inventory without invoking these generators.

Run the package's build, test, generation and formatting checks:

```bash
swift build
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME \
  -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
swift build -c release
python3 Scripts/generate-manifest-vocabulary.py --check
python3 Scripts/generate-manifest-fixtures.py --check
swift format lint --strict --configuration .swift-format \
  --recursive Package.swift Sources Tests
```

By default, publication tests kill each operation at representative points, and
kill recovery at durable steps from each seeded interruption. When changing the
transaction protocol, also kill at every recorded point:

```bash
env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME \
  -u XDG_STATE_HOME -u XDG_CACHE_HOME AGENTS_PUBLICATION_MATRIX=full \
  swift test --filter PublicationTests
```

The required checks are `policy / policy` and `validate / result`, provided by
full-SHA-pinned reusable workflows from `agents-tools/github-workflows`.
Source policy validates PR titles, new commit messages and added lines.
[Package validation configuration](.github/swift-package.json) selects Xcode
26.6 on `macos-26` and a digest-pinned official Swift Linux container. macOS and
Linux validation run the Debug and Release test suites with the default
publication matrix; the full publication matrix is not part of CI. macOS also
runs a release build and strict formatting with `.swift-format` over
`Package.swift`, `Sources` and `Tests`. The test suites include subprocess
recovery tests. The configuration owns the Linux compiler version and image
digest. Tests also require Perl, which is included by the Linux image's Git
dependencies.

Render and check the committed
[social preview](.github/assets/social-preview/social-preview.png) locally with
the github-readme-design toolchain against `agents-tools/.github`'s DESIGN,
fonts and catalog, using this repository's framework logo. Follow the
[local renderer commands](https://github.com/showxu/skills/blob/master/skills/github-readme-design/references/renderers.md)
and [repository inputs](Documentation/Reference/Presentation.md#social-preview),
then commit the resulting assets.

All workflows run on branch pushes and PRs; only source policy reruns on PR
title edits. They also support manual dispatch; source policy validates the
selected ref's head commit. See the
[shared workflow reference][workflow-integration] for configuration and callers.

## License

core is available under the [MIT License](LICENSE).

[contributing]:
  https://github.com/agents-tools/.github/blob/master/CONTRIBUTING.md
[maintenance]:
  https://github.com/agents-tools/.github/blob/master/MAINTENANCE.md#change-flow
[workflow-integration]:
  https://github.com/agents-tools/github-workflows#configuration
