# Package Architecture

## Purpose and Consumers

`core` supplies skill and instruction management and instruction text
transformations. Both `agents` in `agents-tools/cli` and `skill` in
`skill-cli/cli` consume this package. Consumers own command trees, argument
parsing, terminal presentation, and executable distribution. The package uses
Swift 6.3, Swift 6 language mode, and a macOS 13 minimum deployment platform.

## Products and Dependencies

```text
AgentsSkills ──> AgentsCore
      │
      └───────> Yams

AgentsInstructions ──> AgentsCore
         │
         └───────> Markdown (swift-markdown) ──> cmark-gfm

StateTestProcess ──> AgentsCore
AgentsCoreTests ──> AgentsCore, StateTestProcess
AgentsSkillsTests ──> AgentsSkills, AgentsCore, Yams, StateTestProcess
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
- `SourceArgument` splits a source argument into its location and typed
  selectors, such as `owner/repo@branch:main@path:skills@skill:pdf`. Labels are
  `branch`, `revision`, `ref` (a revision), `exact`, `from` (next major),
  `minor` (next minor), `path` and `skill`; each kind appears at most once.
  Selectors start at the first `@` followed by a label and `:`, so SSH locations
  keep their `@`, and values are percent-decoded. A selection resolves the
  location to a declared alias or a parsed source. Selectors and explicit
  options must agree with each other and replace the branch and path that a
  hosted tree URL implies. Skill add and source listing add `@skill:` to the named
  skills; instruction add and watch add reject it.
- `SourceRequirement` expresses branch, revision, exact version, next-major,
  next-minor and half-open version ranges. Semantic-version comparison governs
  Git tag selection, including prerelease bounds.
- `Declaration` and `ResolvedState` define intent and resolved version 1 state,
  including the complete instruction section, prompt and physical-target models.
- `StateStore` owns scope paths, validation, deterministic encoding and state
  persistence. `FileLock` serializes state access; `FileTransaction` durably
  journals replacements across installations, state and cache. Mutating state
  access recovers interrupted transactions before proceeding, as described in
  [State and cache](State.md).
- `SourceCache` owns bare Git mirrors, requirement resolution, exact snapshots,
  digest-addressed downloads and pruning across skill, instruction and watch pins.
  `ProcessRunner` executes subprocesses.
- `WatchOperations` owns source subscriptions, seen baselines, branch tracking
  and file comparisons. `WatchState` defines version 1 of `agents.watch`.
  Skill discovery and artifact loading are injected by `AgentsSkills` through
  `SkillOperations.watchOperations()`. See [Watch](Watch.md) for the public API.
- `AgentRegistry` owns agent skill locations. `RuntimeEnvironment` supplies the
  project root, home directory and environment. Universal agent skill locations
  can be shared, so recipients sharing one directory must agree on install mode.
- `FileHash` hashes tree entries, hidden files and symlink destinations;
  `PathSafety` checks paths and creates filesystem skill identities.

Core has no dependency on skill discovery, frontmatter, Yams or Markdown.
`AgentsInstructions` owns instruction text transformations and lifecycle.
`InstructionLocations` supplies fixed target locations to lifecycle and journal
validation.

### Process Execution and Errors

All package Git calls use `ProcessRunner.git`, which overlays
`GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` on the inherited child
environment. Other variables and the caller's environment are preserved;
credential helpers that provide credentials without prompting remain available.
The same policy applies to ordinary subprocesses and Git children inheriting
mirror locks.

A nonzero Git exit throws public `GitError`. Its `operation` is a public
`GitError.Operation` enum identifying the kind of Git work, with a `description`
that supplies the user-facing action phrase. `source` identifies the source
location or URL, and `stderr` contains diagnostic lines with progress removed and
internal cache or extraction paths replaced by that source. `description`
combines these into a user-facing message. Source context is supplied at each
call site; orphaned mirror cleanup reads the clone's origin URL.

Consumers should display `description` and supply any remedy appropriate to their
workflow by matching `operation`. For example, `case .resolveRevision(let revision)`
identifies a failed commit lookup and carries the requested reference or object ID
before Git's commit peeling suffix. A `watch seen` request for `missing-revision`
therefore carries `.resolveRevision(revision: "missing-revision")`. `command`
retains the executable and argument array unchanged, and `exitCode` records Git's
status; both are for debugging only. Consumers must not classify failures by
inspecting arguments, exit codes, or diagnostic text. Non-Git process failures
continue to use `CoreError.commandFailed`; process launch errors retain their
underlying platform error.

## AgentsSkills

`SkillOperations` is the public lifecycle surface:

| Operation | Consumer API |
| --- | --- |
| Add or inspect a source | `add(_:)`, `AddOptions`, `AddOutcome` |
| List managed records | `listManaged(scope:agents:environment:)` |
| Inventory installed directories | `listInstalled(scope:agents:environment:)` |
| Remove recipients or skills | `remove(...)`, `removableSkillNames(...)` |
| Preview or apply declared updates | `updateInstalled(...)`, `UpdateResult`, `SkillFileChange`, `SkillFileEntry` |
| Restore exact installations | `installResolvedReport(scope:environment:)` |
| Initialize a skill | `initializeSkill(named:directory:)` |
| Diagnose a scope | `doctor(scope:agents:environment:)` |

`SkillLifecycle` coordinates discovery, temporary preparation, verified cache
content and transactions. Before a mutation, declaration, lock and watch state are validated.
Preparation completes before installed paths are replaced; every item in a
restoration must be available and verified. Installation has no agent or mode
argument because those choices belong to the lock. Only paths the scope's lock
already manages are replaced: a directory, file or resolvable link at a new
target is left untouched and the operation fails with `CoreError.invalidSkill`
naming the path. Dangling or looping links hold no content and are replaced.

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

Non-applying skill operations use an existing shared scope lock without creating
state files or replaying recovery. Listings and previews fail when a transaction
is pending; doctor reports one `pending-recovery` warning and skips that scope's
state-dependent checks. Doctor compares upstream revisions without fetching or
populating caches. Applying lifecycle operations hold the writer lock and recover
abandoned transactions before accessing state. `listManaged` includes missing
records for diagnosis; `listInstalled` returns present skills with valid frontmatter, including
unmanaged candidates from each agent's scan roots. Omitted agent filters list or
remove all recipients. Declaration defaults supply recipients for additions and
selections that have no explicit recipients.

`add` discovers choices through the read path for `listOnly` and when neither
names nor `all` are supplied. Selection discovery leaves the scope, caches and
lock files unchanged and stops when recovery is pending. An automatic single-item
addition carries its normalized source ID and exact discovered name separately
from user-entered names. Writer-lock rediscovery must match that identity or fail
with an error asking the caller to retry. Content can refresh for the same identity.
Explicit names and `all` use the writer path directly.

Skill initialization is an authoring write: it takes the writer path and recovers
pending transactions when scope state exists, without creating absent scope state.

Update previews use the same physical target mapping as application. Each change
contains typed entry snapshots, so deletions, empty directories, symbolic link
destinations and file contents can all be presented before applying.

## AgentsInstructions

`InstructionOperations` discovers committed instruction units and supplies add,
list, update, install, remove, ChatGPT render, initialization and read-only doctor
workflows. It composes the text APIs below with scope state and journaled writes.
See [Instruction lifecycle](Instructions.md) for consumer APIs, target mapping,
lost-lock recovery and diagnostics.

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
`InstructionOperations` owns ancestor-file warnings, filesystem access,
declaration and lock updates, and deletion decisions using the lock's `created`
flag. The `Instructions` and `ClaudeForwarding` text APIs perform no I/O.

## Validation and Documentation

Core tests cover source identities, declarations, lock validation, deterministic
state, transactions, concurrency, requirements, mirrors, snapshots, hashes and
agent paths. Skill tests cover discovery, artifact formats and the full declared
lifecycle, including public consumer calls and failed-operation preservation.
Fixtures create isolated homes and explicit Git initial branches and remove
their temporary roots. Instruction tests cover source validation, managed-block
assembly and removal, byte preservation, drift, Claude forwarding, and ChatGPT
rendering through public APIs with in-memory fixtures. Lifecycle tests cover
pinned sources, physical targets, transactional writes, conflict stops, lost
locks, prompts, deletion ownership and read-only multi-root audits.

[State and cache](State.md) describes persisted data and lifecycle invariants.
`../Proposals/` holds design work; `../Decisions/`, `../Migrations/` and
`../Archive/` retain historical records with their original scope.
