# Package Architecture

## Purpose and Consumers

The SwiftPM package `core` provides shared libraries for agent skill management
and instruction text transformations.
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

AgentsInstructions ──> AgentsCore
         │
         └───────> Markdown (swift-markdown) ──> cmark-gfm

AgentsCoreTests ──> AgentsCore
AgentsSkillsTests ──> AgentsSkills, AgentsCore, Yams
AgentsInstructionsTests ──> AgentsInstructions
```

`AgentsCore`, `AgentsSkills`, and `AgentsInstructions` are library products with
matching targets under `Sources/`. Each has a test target under `Tests/`.
Package-private helpers use Swift's `package` access level when needed across targets; other
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
`WellKnownProvider`, and metadata sanitization are internal.

`SkillSourceResolver` dispatches well-known URLs to `WellKnownProvider` and
local/Git sources to core resolution. Well-known discovery supports legacy
`files[]` indexes, v0.2 `skill-md`, and digest-verified archives.

Yams is used only by this module: skill frontmatter and the legacy
`.agent/watched-skills.yaml` loader supplied to `SkillOperations.watches`.
Consumers use that configured watch service for skill workflows. A standalone
`WatchService()` reads the current JSON ledger. Both use the same core watch
bookkeeping and JSON writer.

## AgentsInstructions

`Instructions` validates source bytes into immutable `InstructionSection`
values, assembles or removes managed blocks, detects drift, renders ChatGPT
prompts, and compares source-qualified identities across scopes. The `Markdown`
product from [swift-markdown](https://github.com/swiftlang/swift-markdown)
provides CommonMark structure, semantic inline text, and block line ranges through cmark-gfm.
Only `AgentsInstructions` depends on that product. The adapter retains original
line bytes for splicing; it does not format the parsed tree.

Only top-level headings are target titles or section boundaries. Headings
inside lists and block quotes belong to their containing section. Every source
heading, including container headings, shifts by the target offset and is
checked for level-6 overflow. A source starts with a top-level ATX H1, has no
other H1 anywhere, uses no Setext headings, and cannot end inside a code or HTML
block. Heading identity is the AST heading's `plainText`, trimmed with whitespace
collapsed. Emphasis delimiters and link destinations are absent, entities are
decoded, and code spans retain the backticks supplied by `plainText`. This same
identity controls matching, title detection, and duplicate selection checks;
rendering retains the original source syntax.
Markers count only as top-level, single-line HTML blocks whose complete source
line equals the fixed marker text; indented, quoted, or padded examples are not
markers.

The parser supplies heading levels, start lines, and container ownership.
Splicing uses physical line boundaries. The adapter verifies ATX syntax on the
start line: one through six hashes followed by a space, tab, or end of line,
with at most three leading spaces at the top level. Within AST-confirmed
containers, a small prefix scan locates the opening run after list and quote
prefixes. A top-level Setext span starts after any leading link reference
definitions consumed from its paragraph block. Because those definitions have
no AST nodes, the adapter reparses original physical prefixes and identifies
complete definition-only prefixes by their empty document trees. This also
handles multiline labels, destinations, and titles. Definition lines remain
custom bytes and are excluded from section comparisons and replacement ranges,
including when a selected parent section contains the Setext heading.
A top-level Setext span ends at a physically verified underline:
up to three leading spaces, a nonempty run of the appropriate `=` or `-`, and
optional trailing spaces or tabs. Inline source coordinates are not physical
positions and are never used to slice target bytes. Setext end coordinates are
also unsuitable because they can extend into the next block. Prefix verification
is limited to Setext paragraph blocks that could begin with a reference
definition; CommonMark remains responsible for recognizing the definitions.

Because the AST does not expose fence or HTML closure state, source validation
reparses a continuation token in the terminal block's container and checks
whether it becomes code or HTML. Physical list prefixes become continuation
indentation and quote prefixes remain intact. The token is never emitted.
Final assembly is reparsed and must contain exactly the expected managed block.

A leading UTF-8 BOM is kept separately as file metadata before parsing. Target
assembly and removal restore those bytes at the start, including when the block
is prepended or no custom content remains. The BOM does not count as custom
content or enter the managed block hash. Source hashes include it, while source
rendering omits it. ChatGPT custom content is UTF-8 validated and appended as
original bytes, including any BOM and line endings.

Selected headings are grouped once. Target headings and section boundaries
are indexed in one traversal, with a reverse pass across the six heading
levels. Removal ranges are sorted and applied in a single pass over target
lines; assembly does not scan all headings for each selected section.

Assembly returns bytes, heading offset, the rendered block and its hash,
adoptions, conflicts, a block difference, and whether custom content remains.
The caller chooses whether to replace conflicting custom sections and supplies
the locked heading offset for installation. Existing managed content is
rendered anew; lifecycle callers check drift before deciding to persist it.
Source hashes cover original bytes. Block hashes cover LF-normalized marker
and content lines, including the final LF. Drift detection accepts an optional
reconstructed locked block for a textual difference; a hash alone establishes
drift but cannot recover the old text.

`ClaudeForwarding` renders import blocks and classifies existing project Claude
files from caller-supplied bytes and symbolic-link metadata. Forwarding requires
a standalone, unquoted and unformatted line containing only an equivalent
import of the project's `AGENTS.md` outside code and HTML, with optional
surrounding whitespace, or the tool's managed import block. Paths resolve
relative to the containing file; backslash-escaped spaces are supported.
Inline prose, formatting, and quoted tokens do not suppress the caller's
managed import. A duplicate import is acceptable to ensure loading.

Recognition starts with complete physical lines. Candidate lines are replaced
in memory with unique plain-text tokens, preserving their whitespace and line
endings. A token must parse as direct text in a top-level paragraph to qualify;
code, HTML, headings, containers, and inline formatting cannot establish
forwarding. This verifies context for multiline constructs without using
inline source coordinates or treating an inline-node boundary as a path end.
The probe is never emitted. Malformed managed markers still produce errors.
Callers own ancestor-file warnings, actual filesystem access, declaration and lock updates, and deletion decisions using
the lock's `created` flag. This target performs no I/O.

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
exercise consumer-visible operations. Instruction tests cover source validation,
managed-block assembly and removal, byte preservation, drift, Claude forwarding,
and ChatGPT rendering through public APIs with in-memory fixtures.

Current architecture lives here. `../Proposals/` contains design work;
`../Decisions/`, `../Migrations/`, and `../Archive/` retain historical records
with their original scope. Existing CLI decision records describe the consumer
surface and do not define this package's products.
