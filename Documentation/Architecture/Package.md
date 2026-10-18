# Package Architecture

## Purpose and Consumers

The SwiftPM package `core` provides the shared engine for agent skill management.
Its consumers are `agents` in `agents-tools/cli` and `skill` in `skill-cli/cli`.
Those repositories own their command trees, argument parsing, terminal output,
and executable distribution. Their dependency integration is separate work.

The package uses Swift tools version 6.3, Swift 6 language mode, and a macOS 13
minimum deployment platform.

## Products and Dependencies

```text
AgentsSkills ──> AgentsCore
      │
      └───────> Yams

AgentsCoreTests ──> AgentsCore
AgentsSkillsTests ──> AgentsSkills, AgentsCore, Yams
```

Both `AgentsCore` and `AgentsSkills` are library products with matching targets
under `Sources/`. Each has a test target under `Tests/`. Package-private helpers
use Swift's `package` access level when needed across targets; other
implementation details are internal or private.

## AgentsCore

- `SourceParser`, `ParsedSource`, and `SourceType` describe source syntax and
  identity. `SourceRequirement` expresses requirement intent; internal semantic
  version logic selects eligible Git tags.
- `SourceResolver` resolves local and Git sources, current source pins, and
  watched baselines. `ResolvedSource` carries checkout and revision information.
- `Git` and `ProcessRunner` execute subprocesses and manage checkouts.
- `FileHash` and `PathSafety` provide content hashing and path validation.
- `AgentID`, `RuntimeEnvironment`, install enums, and `AgentRegistry` describe
  supported agents and their filesystem locations.
- `InstallLockStore` owns resolved-state persistence and compatibility decoding.
  `LockFile`, `SourcePin`, `PinState`, `PinnedSkill`, and `InstallationPin` are the
  existing persisted model, including skill installation records.
- `WatchService` owns watch paths, baselines, head refresh, review cursors, and
  review packets. Its `WatchLedgerStore` reads and writes JSON and can receive
  a package-local loader for legacy state.
- `CoreError` is the shared error model.

Core source resolution has no dependency on skill discovery or installation.
The persisted schema and agent registry retain their existing skill fields and
paths; their ownership does not require importing the skill module.

## AgentsSkills

`SkillOperations` is the public workflow entry point:

| Feature | API |
| --- | --- |
| Add or inspect a source | `add(_:)` with `AddOptions`; `listOnly` inspects discovery results |
| List managed skills | `listManaged(scope:agents:environment:)` |
| Inventory installed directories | `listInstalled(scope:agents:environment:)` |
| Remove | `removableSkillNames(...)` and `remove(...)` |
| Check or apply updates | `updateInstalled(...)` and `updateFromWatch(...)` |
| Restore resolved installations | `installResolvedReport(scope:environment:)` |
| Initialize | `initializeSkill(named:directory:)` |
| Diagnose | `doctor(scope:agents:environment:)` |
| Watch and review | `watches`, a configured `AgentsCore.WatchService` |

The returned models expose skills, installation results and health, skipped
restorations, update results, and doctor checks. `Discovery`, `Installer`,
`WellKnownProvider`, metadata sanitization, and skill-path helpers are internal.

`SkillSourceResolver` dispatches well-known URLs to `WellKnownProvider` and
local/Git sources to core resolution. Well-known discovery supports legacy
`files[]` indexes, v0.2 `skill-md`, and digest-verified archives.

Yams is used only by this module: skill frontmatter and the legacy
`.agent/watched-skills.yaml` loader supplied to `SkillOperations.watches`.
Consumers use that configured watch service for skill workflows. A standalone
`WatchService()` reads the current JSON ledger. Both use the same core watch
bookkeeping and JSON writer.

## Runtime State

Operations take `RuntimeEnvironment` explicitly. The default environment uses
the process working directory, home directory, and environment variables.

Resolved state, source caches, canonical installed copies, and agent projections
are separate concerns. Project scope uses `.agent/skills.resolved`,
`.agent/cache`, and `.agents/skills`. User scope uses
`$XDG_STATE_HOME/skills/skills.resolved` or `$HOME/.agents/skills.resolved` and
canonical installed copies under `$HOME/.agents/skills`.

For storage compatibility, the user cache namespace remains `skill-cli` under
`$XDG_CACHE_HOME`, `$HOME/Library/Caches` on macOS, or `$HOME/.cache` elsewhere.
`InstallScope.global` and the existing lock and ledger encodings also retain
their persisted spelling. Source resolution and restoration retain their current
requirement-selection and checkout behavior.

Install modes are managed symlink projections (`symlink`), physical copies
(`copy`), and live links to unpinned local sources (`edit`). Universal agents use
canonical storage directly; native-only agents receive projections. Edit mode
rejects remote sources, requirements, and watch-based installation.

Watch state is project-local in `.agent/skills-state.json`. A watched install
uses its reviewed commit or baseline. Refresh updates the current head without
advancing review cursors; explicit review operations advance those cursors.

## Validation and Documentation

Core tests cover source parsing and resolution, semantic versions, paths,
hashing, lock persistence, agent locations, and watch bookkeeping. Skill tests
cover discovery, frontmatter, providers, installation workflows, diagnostics,
and legacy YAML integration. Public workflow tests use ordinary imports to
exercise consumer-visible operations.

Current architecture lives here. `../Proposals/` contains design work;
`../Decisions/`, `../Migrations/`, and `../Archive/` retain historical records
with their original scope. Existing CLI decision records describe the consumer
surface and do not define this package's products.
