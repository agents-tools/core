# Instruction Lifecycle

`AgentsInstructions` owns discovery, lifecycle operations and diagnostics.
`Instructions` and `ClaudeForwarding` remain pure text APIs;
`InstructionOperations` connects them to `AgentsCore` state, source cache and
transactions. Consumers own command parsing, presentation and confirmation.

## Sources and Selection

Discovery reads `.md` files directly inside `instructions/` and
`.agents/instructions/`, relative to the source's search `path`. Every unit is
validated by `Instructions.validateSource`. Names are filenames without `.md`;
duplicate names across containers are errors. Nested files are not discovered.

Instructions require Git sources. Local sources identify the repository root;
use `path` to move its search root. Discovery reads committed trees even when
the working tree is dirty. Each section and prompt section has its own revision,
path and original-byte hash. Source instruction directories cannot be targets.

`add(InstructionAddOptions, beforeApply:)` accepts a source alias or string,
optional alias, requirement, search path, ordered names and recipients. With
several units and neither names nor `all`, it returns the units without changing
intent or targets. `listOnly` always inspects. Explicit order is preserved;
`all` adds current units in name order. Add preserves unrelated section and
skill pins. Source aliases remain shared across kinds.

## Targets

| Agent | User file | Project file |
| --- | --- | --- |
| Codex | `$CODEX_HOME/AGENTS.md`, default `~/.codex/AGENTS.md` | `AGENTS.md` |
| Claude Code | `$CLAUDE_CONFIG_DIR/CLAUDE.md`, default `~/.claude/CLAUDE.md` | `AGENTS.md`, plus forwarding when needed |
| Cursor | No file | `AGENTS.md` |
| OpenCode | `$XDG_CONFIG_HOME/opencode/AGENTS.md`, default `~/.config/opencode/AGENTS.md` | `AGENTS.md` |
| Gemini CLI | `~/.gemini/GEMINI.md` | `GEMINI.md` |

Locations come from `RuntimeEnvironment`. Selected agents receive the same
ordered sections. Agents sharing a physical file share one lock entry and one
replacement. Project keys are relative to the project root; user keys are
`~/`-relative to the supplied home. Configured user locations outside home use
absolute keys. Locked destinations must remain registered instruction locations
in the runtime environment; lock contents cannot authorize arbitrary writes.
Configured user containers may resolve through symlinks. Journal validation
opens project descendants without following links.

A root `CLAUDE.md` symlink to `AGENTS.md` needs no write, including before
`AGENTS.md` exists. A recognized standalone import in any project Claude file
also suffices. Otherwise the first existing file in `CLAUDE.md`,
`.claude/CLAUDE.md`, `CLAUDE.local.md` order receives a managed import block:
`@AGENTS.md` or `@../AGENTS.md`, relative to its containing file. No project
Claude file means automatic forwarding. Ancestor files are reported and never
modified.

## Operations and Mutation Contract

| Consumer operation | Behavior |
| --- | --- |
| `list(source:scope:environment:)` | Inspect committed, validated units |
| `listManaged(scope:environment:)` | Return locked sections, prompts and targets, including missing targets |
| `updateInstalled(..., apply:beforeApply:)` | Resolve the declaration and preview or apply all targets together |
| `installResolvedReport(scope:environment:)` | Restore locked pins, targets and offsets without changing state bytes |
| `remove(names:scope:agents:environment:beforeApply:)` | Remove sections from file and prompt selections and lock records |
| `renderChatGPT(prompt:scope:environment:)` | Return locked sections followed by the prompt's current custom file |
| `initializeInstructions(named:directory:)` | Create a validated `<name>.md`, refusing an existing entry |
| `doctor(scope:environment:codexConfiguration:)` | Inspect one scope and compare sections against the other scope |
| `doctor(projectRoots:environment:codexConfiguration:)` | Audit explicit project roots without writing |

An `agents` argument sets the complete instruction recipient list. Removing
names accepts `alias:name` references or unambiguous bare names and removes
those sections from prompts as well. Empty prompts are removed. Other source
declarations and skill records remain available to their owners.

Planning validates required content before applying. Reports include old and
new section records, target before/after bytes, drift, custom-section adoptions
and conflicts, block differences, missing-lock status and changed prompt names.
The optional throwing `beforeApply` callback runs before replacements so a
consumer can show differences or cancel. Target bytes are checked again after
the callback; intervening edits stop the commit. Add throws conflict differences
unless `replace` is enabled. Update previews conflicts and applies newly resolved
content. Install restores drift but stops on a conflicting custom section.

Mutations hold the scope writer lock and use the durable journal for instruction
files, forwarding files, declaration, lock and cache pruning. Exact source
materializations are verified and published through cache transactions before
the target/state transaction. The journal has fixed project instruction paths,
configured user instruction roots and an authoring root restricted to named
Markdown files. Initialization uses a project state lock and journal in the
supplied directory without creating a declaration or resolved file.

Read operations take an existing shared scope lock without creating one or
replaying recovery. Pending recovery stops inspection; a mutating state
operation recovers it and asks the caller to retry. Source inspection and update
preview may fetch mirror objects and use disposable snapshots, but never
publish materializations, declaration, lock or targets. Doctor reads remote ref
advertisements but does not fetch objects or create files, including in projects
with no state directory.

Install reconstructs and verifies locked blocks before replacement, using
recorded heading offsets even if custom titles changed. Update recomputes
offsets. Removing the last section removes its block and deletes a file only
when its previous lock says `created: true` and no custom content remains.
Without a lock entry a file is never deleted. Lost-lock update reports the
comparison; apply adopts identical blocks or replaces differing content and
records existing files as `created: false`.

## ChatGPT Prompts

`instructions.chatgpt.<name>` has ordered `sections` and an optional scope-relative
`append` file. Update locks prompt sections with file targets. Reports list
prompts whose section content, order, membership or append path changed. A
revision change with identical section hashes alone does not mark a prompt
changed. Append files remain live owner content; their independent edits do not
require a lock update.

Render verifies locked hashes, keeps source heading levels, omits markers and
appends the custom file's bytes. It fails without locked sections or if an append
path escapes the scope through a symlink. It never writes to ChatGPT.

## Diagnostics

Doctor reports missing or drifted blocks, malformed targets, missing locks,
custom-section adoptions and conflicts using cached locked content, duplicate
source-qualified sections across scopes, Claude forwarding and ancestor
problems, and uncommitted selected local source paths. Git status uses
`--no-optional-locks` to avoid index refresh writes. File and ChatGPT prompt pins
are compared with matching source revisions using the declaration's current
requirements (or locked requirements when a source is no longer declared).
`sourceUpdateAvailable` identifies differing pins and affected prompt names;
it does not imply that section bytes have changed. Local Git reads and remote
`ls-remote` advertisements share the cache resolver's branch and semantic-version
selection policy, including annotated tags. No mirror or snapshot is written.
Unresolvable sources produce `sourceResolutionFailed`, including remote revision
expressions not present in advertised refs. Full immutable remote revision IDs
cannot advance and are compared directly; doctor does not fetch to verify their
availability or validate upstream content.

Codex checks report a nonempty `AGENTS.override.md` hiding managed content and
sum loaded instruction bytes and separators along the global and
root-to-project chain, honoring `project_root_markers` (default `.git`) and
`project_doc_fallback_filenames`. With no root marker, only the project directory
is checked. Consumers supply `CodexInstructionConfiguration` with the effective
byte limit, fallback filenames and root markers after resolving Codex trust,
profiles and policy. Multi-root audit accepts a configuration resolver per root.
The TOML initializer can merge trusted layers in precedence order, preserving
omitted settings; trust decisions and layer selection belong to the consumer.
Trusted `.codex/config.toml` layers override user settings, with the closest to
the working directory taking precedence, following
[Codex configuration rules](https://learn.chatgpt.com/docs/config-file/config-advanced).
Without supplied settings, doctor reads top-level `$CODEX_HOME/config.toml`,
defaulting to 32 KiB. Table fields and multiline string contents cannot override
it; invalid budgets produce a diagnostic. Discovery
follows the [Codex instruction guide](https://developers.openai.com/codex/guides/agents-md).

Multi-root audit deduplicates explicit roots, reports unavailable or pending
scopes without repairing them, and continues with other roots. It never
searches the user's filesystem for projects.
