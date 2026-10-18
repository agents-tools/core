# Package Architecture

## Purpose and Consumers

`core` supplies skill management and instruction text transformations for
`agents-tools/cli` and `skill-cli/cli`.
Those repositories own command trees, argument parsing, terminal presentation,
and executable distribution. The package uses Swift 6.3, Swift 6 language mode,
and a macOS 13 minimum deployment platform.

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
matching targets under `Sources/` and test targets under `Tests/`. Shared
implementation uses `package` access; consumers receive the
workflow APIs and the state and result models they need. `Package.swift` owns
this dependency graph.

## AgentsCore

- `SourceParser` and `ParsedSource` parse local paths, Git URLs and HTTP indexes.
  `SourceDeclaration` owns normalized source identity and discovery roots.
- `SourceRequirement` expresses branch, revision, exact version, next-major,
  next-minor and half-open version ranges. Semantic-version comparison governs
  Git tag selection, including prerelease bounds.
- `Declaration` and `ResolvedState` define intent and resolved version 1 state,
  including the complete instruction section, prompt and physical-target models.
- `StateStore` owns scope paths, validation, deterministic encoding and state
  persistence. `FileLock` serializes writers; `FileTransaction` stages
  replacements and rolls them back on operation errors. State files are
  replaced with an atomic rename.
- `SourceCache` owns bare Git mirrors, requirement resolution, exact snapshots,
  digest-addressed downloads and pruning across skill and instruction pins.
  `ProcessRunner` executes subprocesses.
- `AgentRegistry` owns agent skill locations. `RuntimeEnvironment` supplies the
  project root, home directory and environment. Universal agent skill locations
  can be shared, so recipients sharing one directory must agree on install mode.
- `FileHash` hashes tree entries, hidden files and symlink destinations;
  `PathSafety` checks paths and creates filesystem skill identities.

Core has no dependency on skill discovery, frontmatter, Yams or Markdown.
`AgentsInstructions` owns instruction text transformations. Instruction lifecycle
integration and watch subscriptions are separate work; the state model defines
their declaration and lock fields and watch-state path.

## AgentsSkills

`SkillOperations` is the public lifecycle surface:

| Operation | Consumer API |
| --- | --- |
| Add or inspect a source | `add(_:)`, `AddOptions`, `AddOutcome` |
| List managed records | `listManaged(scope:agents:environment:)` |
| Inventory installed directories | `listInstalled(scope:agents:environment:)` |
| Remove recipients or skills | `remove(...)`, `removableSkillNames(...)` |
| Preview or apply declared updates | `updateInstalled(...)`, `UpdateResult`, `SkillFileChange` |
| Restore exact installations | `installResolvedReport(scope:environment:)` |
| Initialize a skill | `initializeSkill(named:directory:)` |
| Diagnose a scope | `doctor(scope:agents:environment:)` |

`SkillLifecycle` coordinates discovery, temporary preparation, verified cache
content and transactions. Before a mutation, both state files are validated.
Preparation completes before installed paths are replaced; every item in a
restoration must be available and verified. Installation has no agent or mode
argument because those choices belong to the lock.

Update results include old and new hashes and revisions and per-file bytes for
CLI diff presentation. The optional `beforeApply` callback runs before any
replacement, and a thrown error cancels the operation. A CLI auditing several
projects calls `doctor` with an explicit environment for each root.

`Discovery` retains root skills, direct children, conventional containers,
plugin and marketplace manifests, recursive fallback and `fullDepth` discovery.
Named selections are searched at full depth when updated. `WellKnownProvider`
reads file-list indexes, skill Markdown and digest-verified archives. It records
immutable artifact coordinates; restoration uses those coordinates directly.
Yams is confined to skill metadata parsing in this module.

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

## Validation and Documentation

Core tests cover source identities, declarations, lock validation, deterministic
state, transactions, concurrency, requirements, mirrors, snapshots, hashes and
agent paths. Skill tests cover discovery, artifact formats and the full declared
lifecycle, including public consumer calls and failed-operation preservation.
Fixtures create isolated homes and explicit Git initial branches and remove
their temporary roots. Instruction tests cover source validation, managed-block
assembly and removal, byte preservation, drift, Claude forwarding, and ChatGPT
rendering through public APIs with in-memory fixtures.

[State and cache](State.md) describes persisted data and lifecycle invariants.
`../Proposals/` holds design work; `../Decisions/`, `../Migrations/` and
`../Archive/` retain historical records with their original scope.
