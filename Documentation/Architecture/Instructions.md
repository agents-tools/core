# Instruction Lifecycle

`AgentsInstructions` owns discovery, lifecycle operations and diagnostics.
`Instructions` and `ClaudeForwarding` remain pure text APIs;
`InstructionOperations` connects them to `AgentsCore` state, source cache and
transactions. Consumers own command parsing, presentation and confirmation.

## Instructions Files

`Instructions.validateSource` accepts one file format. The file starts with
front matter between `---` lines: a required `description` and an optional
`paths` list. Front matter is a strict subset of YAML: plain, double-quoted or
single-quoted scalars, and `paths` as a flow list of double-quoted strings or a
block list; unknown or repeated keys are errors. The body, with a leading byte
order mark, line endings and leading and trailing blank lines normalized, starts
with an ATX heading of any level; every other heading is a deeper ATX heading,
and the body does not end inside a code or HTML block. A section's `hash` covers
the original bytes.

`paths` patterns are project-relative and use `*`, `**` as a whole segment, and
`?`. With patterns, the rendered body gets the line "Applies when working on
files matching `…`." after its first heading. `Instructions.directory(for:)`
returns the longest directory shared by the patterns' literal prefixes; a
pattern without wildcards names a file, so its prefix is that file's directory,
and a pattern that starts with a wildcard yields the project root.

## Sources and Selection

Discovery reads `.md` files below `instructions/` and `.agents/instructions/`
of the source's search `path`, recursively. A name is the container-relative
path without `.md`; each segment uses lowercase letters, digits and hyphens.
`AGENTS.md` and `GEMINI.md` are target names, so discovery and watch skip them;
a file another scope generated in a container is never read as an instructions
file. A symbolic link at or below
the search path, an invalid name and a name in both containers are errors.
Instructions require Git sources. Local sources identify the repository root;
use `path` to move its search root. Discovery reads committed trees even when
the working tree is dirty. Each section and prompt section has its own
revision, path and original-byte hash. A container of a local source declared
in the same scope cannot hold a target.

A project's own files live in `.agent/instructions/` and are referenced by bare
name; `.section(name:source:)` in `Agents.swift`, or `alias:name` in operation
arguments, references a declared source. Own files are read from the
working tree as it is. Their lock records have source `.`, the project-relative
path and the hash, and no revision. Resolution and restore read only the named
file, `.agent/instructions/<name>.md`, and so does adding named files, so other
files in the container affect only listing. Restoring a lock fails with `InstructionError.ownChanged` when an
own file's hash changed; update reads the current file.

`add(InstructionAddOptions, beforeApply:)` accepts a source alias or string,
or `.` for own files, plus an optional alias, requirement, search path, ordered
names and recipients. With several units and neither names nor `all`, it
returns the units without changing the scope, including its cache and lock
files. This selection discovery takes the read path and stops if recovery is
pending. `listOnly` always uses that path. A single discovered unit is selected
automatically by its normalized source ID and exact name, separately from
user-entered names. Writer-lock rediscovery must match that identity or fail
with an error asking the caller to retry. Explicit names and `all` enter the
writer path directly. Explicit order is preserved; `all` adds current units in
name order. Add preserves unrelated section and skill pins. Source aliases
remain shared across kinds.

## Targets

| Agent | User file | Project file |
| --- | --- | --- |
| Codex | `$CODEX_HOME/AGENTS.md`, default `~/.codex/AGENTS.md` | `AGENTS.md` |
| Claude Code | `$CLAUDE_CONFIG_DIR/CLAUDE.md`, default `~/.claude/CLAUDE.md` | `AGENTS.md`, plus forwarding when needed |
| Cursor | No file | `AGENTS.md` |
| OpenCode | `$XDG_CONFIG_HOME/opencode/AGENTS.md`, default `~/.config/opencode/AGENTS.md` | `AGENTS.md` |
| Gemini CLI | `~/.gemini/GEMINI.md` | `GEMINI.md` |

Every target is generated in full by `Instructions.render`: the notice line
`Instructions.notice`, a blank line, and the sections in declared order
separated by one blank line, ending with a newline. Rendering rejects two
sections whose first headings share level and whitespace-collapsed text, and
parses the result to confirm that every section's first heading is still a
document heading.

In project scope, sections are grouped by `directory`: each group renders into
the `AGENTS.md`, or `GEMINI.md`, of that directory, which must already exist.
No component of a nested target's directory may be a symbolic link or `.git`,
or hold another repository or worktree.
User scope renders all sections into each recipient's file. Project keys are
relative to the project root, and a nested key names `AGENTS.md` or `GEMINI.md`
in a directory outside any `.git` and the top-level `.agent`; user keys are `~/`-relative to the
supplied home, and configured user locations outside home use absolute keys.
Locked destinations must remain registered instruction locations in the
runtime environment; lock contents cannot authorize arbitrary writes.
Configured user containers may resolve through symlinks. Journal validation
opens project descendants without following links.

A file is owned when `Instructions.isOwned` finds it blank or finds the notice
on its first line; a lock entry alone does not make a file owned. A planned
write over an existing file that is not owned marks the change `foreign`; add,
update apply, combined apply, remove and install stop with
`InstructionError.unownedTargets` unless `replace` is set, which install does
not offer. A locked target that
no longer receives sections is deleted while its bytes equal the locked
rendering and kept otherwise. Unit targets lock `headingOffset: 0`,
`created: false` and the rendered file's hash as `blockHash`.

Links in a rendered target are checked by `Instructions.localLinks`: links,
images, autolinks and reference definitions outside code with a destination
that is relative, absolute or a `file:` URL, and raw HTML `href` and `src`
attributes. A local destination must resolve, from the target file, to an
existing regular file inside the checkout being written and outside any nested
repository or worktree; user targets accept no local destination. Problems stop
the operation with `InstructionError.invalidLinks`.

A root `CLAUDE.md` symlink to `AGENTS.md` needs no write, including before
`AGENTS.md` exists. A recognized standalone import in any project Claude file
also suffices. Otherwise, when the root `AGENTS.md` is a target, the first
existing file in `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md` order
receives a managed import block: `@AGENTS.md` or `@../AGENTS.md`, relative to
its containing file. No project Claude file means automatic forwarding.
Ancestor files are reported and never modified. Claude Code reads a nested
`AGENTS.md` only while no Claude file exists at the project root or in that
directory, unless that directory's Claude file imports it; nested Claude files
are not modified, and doctor reports one that hides a generated target.

## Operations and Mutation Contract

| Consumer operation | Behavior |
| --- | --- |
| `list(source:scope:environment:)` | Inspect committed, validated files of a source |
| `listOwn(environment:)` | Inspect the project's own files in the working tree |
| `listManaged(scope:environment:)` | Return locked sections, prompts and targets, including missing targets |
| `updateInstalled(..., apply:replace:beforeApply:)` | Resolve the declaration and preview or apply all targets together |
| `installResolvedReport(scope:environment:)` | Restore locked renderings without changing state bytes |
| `remove(names:scope:agents:environment:beforeApply:)` | Remove sections from file and prompt selections and lock records |
| `renderChatGPT(prompt:scope:environment:)` | Return locked sections followed by the prompt's current custom file |
| `initializeInstructions(named:environment:)` | Create a validated `.agent/instructions/<name>.md` with front matter, refusing an existing entry |
| `doctor(scope:environment:codexConfiguration:)` | Inspect one scope and compare sections against the other scope |
| `doctor(projectRoots:environment:codexConfiguration:)` | Audit explicit project roots without writing |
| `export(projectRoots:environment:)` | Map the user scope's and each root's locked targets to their sections without writing |

An `agents` argument sets the complete instruction recipient list. A name to
remove that equals a declared reference, such as an own file's bare name or
`alias:name`, selects that reference; another bare name must match exactly one
source reference. Removal also removes those sections from prompts. Empty
prompts are removed. Other source declarations and skill records remain
available to their owners.

Export maps a user target to every locked section from the lock alone. A
project section's placement needs its `paths`, read from the working tree or
the cache without fetching; a section whose content is unavailable is listed as
unplaced.

Planning validates required content before applying. Reports include old and
new section records, target before/after bytes and recipients, drift, foreign
targets, a missing-lock status and changed prompt names.
`InstructionTargetChange.beforeAgents` is nil when the previous lock has no target
entry; `afterAgents` is empty when the target is no longer managed. Both recipient
arrays are sorted by agent raw value. `agentsChanged` compares those recipients,
while `changed` compares file bytes. `InstructionUpdateReport.hasChanges` is the
consumer's update predicate: it compares the planned declaration and lock, target
bytes, and a missing lock with targets. This includes section ordering and pins,
target recipients and prompt pins even when rendered bytes are identical.
A recipient change such as Codex to Cursor is reported even when both use the
same unchanged `AGENTS.md`.
The optional throwing `beforeApply` callback runs before replacements so a
consumer can show differences or cancel. Target bytes are checked again after
the callback; intervening edits stop the commit. Update also revalidates state
bytes/presence, target ancestry and all Claude forwarding decision inputs
before and after retention. `InstructionUpdatePlan` supplies package-visible
planning, validation, retention and staging to both standalone updates and
`AgentsUpdates`; the latter commits both kinds together as described in
[Updates](Updates.md).

Mutations hold the scope writer lock and use the durable journal for instruction
files, forwarding files, declaration, lock and cache pruning. Exact source
materializations are verified and published through cache transactions before
the target/state transaction. The journal has fixed project instruction paths,
nested project `AGENTS.md` and `GEMINI.md` paths, configured user instruction
roots and new top-level named Markdown files in `.agent/instructions/`.
Initialization uses the project's state lock and journal without creating a
declaration or resolved file.

Read operations take an existing shared scope lock without creating one or
replaying recovery. Pending recovery stops listings and previews. Doctor reports
one `pendingRecovery` diagnostic per affected scope, explains that the next command
changing that scope will recover it, and skips checks requiring consistent state
from that scope. A pending other scope suppresses cross-scope comparisons while
the current scope can still be audited. A mutating state operation recovers the
transaction and asks the caller to retry. Source inspection and update
preview may fetch mirror objects and use disposable snapshots, but never
publish materializations, declaration, lock or targets. Doctor and export read
remote ref advertisements at most and do not fetch objects or create files,
including in projects with no state directory.

Install renders the locked sections into the locked targets and Claude import
files, verifies every rendering against its locked hash before replacement, and
restores drifted files; it never recomputes forwarding or placement, and a
locked Claude import file the owner deleted stays deleted. Lost-lock update
reports the comparison; apply keeps identical files, replaces differing
generated files, takes over others only with `replace`, and records targets as
`created: false`. Without a lock entry a file is never deleted.

## ChatGPT Prompts

`.instructions(chatGPT: [.prompt(name:sections:append:)])` declares a named
prompt with ordered `sections` and an optional scope-relative `append` file.
Update locks prompt sections with file targets. Reports list prompts whose
section content, order, membership or append path changed. A
revision change with identical section hashes alone does not mark a prompt
changed. Append files remain live owner content; their independent edits do not
require a lock update.

Render verifies locked hashes, renders sections as in targets without the
notice, and appends the custom file's bytes. It fails without locked sections or
if an append path escapes the scope through a symlink. It never writes to
ChatGPT.

## Diagnostics

Doctor reports missing targets, drifted targets, locked targets that agents
does not own, own files changed since the lock (including those only prompts
use), links in the locked renderings that no longer resolve, invalid targets, missing locks, duplicate
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
expressions not present in advertised refs. Full object IDs are resolved through
`^{commit}` in the existing mirror under an existing mirror lock. When the mirror
or its lock is missing, inspection uses advertised refs without creating either.
Without a cached object, an advertised tag's peeled target must be verifiable as
a cached commit or an advertised branch head;
otherwise inspection reports an unresolved source. Doctor does not fetch to
resolve missing objects or validate upstream content.

Codex checks follow how Codex loads instructions. The user file is loaded
separately without a size limit; a non-blank `AGENTS.override.md` beside it
hides a managed user file. In project scope, each chain runs from the nearest
directory with a `project_root_markers` entry (default `.git`), or only the
directory itself without one, down to the project directory and to each
directory holding a generated `AGENTS.md`. In every directory of a chain, the
first regular file among `AGENTS.override.md`, `AGENTS.md` and
`project_doc_fallback_filenames` is loaded, even when empty, so an existing
override hides a managed `AGENTS.md`. A chain's budget counts loaded file bytes,
skips whitespace-only files and adds no separators. Consumers supply
`CodexInstructionConfiguration` with the effective byte limit, fallback filenames
and root markers after resolving Codex trust, profiles and policy. Multi-root
audit accepts a configuration resolver per root. The TOML initializer can merge
trusted layers in precedence order, preserving omitted settings; trust decisions
and layer selection belong to the consumer.
Trusted `.codex/config.toml` layers override user settings, with the closest to
the working directory taking precedence, following
[Codex configuration rules](https://learn.chatgpt.com/docs/config-file/config-advanced).
Without supplied settings, doctor reads top-level `$CODEX_HOME/config.toml`,
defaulting to 32 KiB. Table fields and multiline string contents cannot override
it; invalid budgets produce a diagnostic. Discovery
follows the [Codex instruction guide](https://developers.openai.com/codex/guides/agents-md).

Multi-root audit and export deduplicate explicit roots, report unavailable or
pending scopes without repairing them, and continue with other roots. They never
search the user's filesystem for projects.
