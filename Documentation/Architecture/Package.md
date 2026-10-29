# Package Architecture

## Purpose and Consumers

`core` supplies skill and instruction management and instruction text
transformations. Both `agents` in `agents-tools/cli` and `skill` in
`skill-cli/cli` consume this package. Consumers own command trees, argument
parsing, terminal presentation, and executable distribution. The package uses
Swift 6.3 and Swift 6 language mode. It supports macOS 15 or newer and Linux
with glibc 2.34 or newer.

## Products and Dependencies

```text
AgentsDescription (standard library only)
AgentsManifest ──> AgentsDescription, AgentsCore, SwiftSyntax, SwiftParser (swift-syntax)

AgentsUpdates ──> AgentsCore, AgentsSkills, AgentsInstructions, CPlatform

AgentsCore ──> Crypto (swift-crypto), CPlatform

AgentsSkills ──> AgentsCore
      │
      └───────> Yams

AgentsInstructions ──> AgentsCore
         │
         └───────> Markdown (swift-markdown) ──> cmark-gfm

ManifestTestProcess ──> AgentsManifest, AgentsCore, AgentsDescription
AgentsManifestTests ──> AgentsManifest, AgentsDescription, AgentsCore, ManifestTestProcess, SwiftParser, SwiftSyntax

StateTestProcess ──> AgentsCore, AgentsSkills, AgentsInstructions, AgentsUpdates, CPlatform
AgentsCoreTests ──> AgentsCore, StateTestProcess, CPlatform
AgentsSkillsTests ──> AgentsSkills, AgentsCore, AgentsInstructions, Yams, StateTestProcess, CPlatform
AgentsInstructionsTests ──> AgentsInstructions
AgentsUpdatesTests ──> AgentsUpdates, StateTestProcess, CPlatform
```

`AgentsDescription`, `AgentsManifest`, `AgentsCore`, `AgentsSkills`,
`AgentsInstructions` and `AgentsUpdates` are library products with
matching targets under `Sources/`. Tests under `Tests/` include construction
vocabulary and compiler-oracle coverage in `AgentsManifestTests`. Shared
implementation uses `package` access; consumers receive the
workflow APIs and the state and result models they need. `Package.swift` owns
this dependency graph.

`CPlatform` is an internal C target for filesystem and process differences. It
wraps file locks, access checks, atomic directory exchange, directory entry names, durable
synchronization, metadata copying and spawn actions. Linux uses
`renameat2(RENAME_EXCHANGE)`, `fsync`, descriptor-based mode/xattr copying
(including POSIX ACLs) and glibc's
`posix_spawn_file_actions_addclosefrom_np`. Symlink metadata uses no-follow calls
through pinned parent paths in `/proc/self/fd`; Linux symlink modes remain 0777.
Darwin keeps `renameatx_np`, `F_FULLFSYNC`, `fcopyfile` and its spawn inheritance
policy. Business workflows share the same Swift implementation.
Foundation re-exports the platform libc used by the Swift code; `CPlatform`
bridges APIs missing from those overlays.

`AgentsCore` hashes through swift-crypto's `Crypto` product, which delegates to
CryptoKit on Apple platforms and supplies its own implementation on Linux.

## AgentsDescription and AgentsManifest

`AgentsDescription` owns the immutable language 1.0 authoring vocabulary. It uses
only the standard library, with private payload storage and closed literal
conformances. `Scripts/ManifestVocabulary.json` is the construction signature and
literal inventory; `Scripts/generate-manifest-vocabulary.py` generates the public
factories and package-only static registrations together. Contract signature and
compiler-backed fixture tests check that inventory.

`AgentsManifest.DeclarationDocument` compiles supplied UTF-8 bytes without
executing code or reading sources. Version selection, strict lexing and bounded
grammar recognition complete before SwiftParser sees the exact snapshot. An
iterative all-nodes guard precedes syntax inspection and independent projection
comparison. Static typing, occurrence-based expanded-size accounting and offline
domain validation produce `AgentsCore.DeclarationIR` and `DeclarationSourceMap`.
Constants, inactive values and unused groups receive the same checks. Group
references and conditions remain symbolic.

The document retains original bytes, a lossless syntax tree, a byte digest and
snapshot-bound `NodeID` handles. `preparing(_:)` accepts `ManifestEdit` batches,
constructs expected intent, produces disjoint byte patches, reruns the complete
front end and compares the resulting declaration. `DocumentChange` carries both
byte digests, resulting bytes, diagnostics, impacted references and semantic delta
for later orchestration. Source edits do not publish files. Shared constants
require explicit impact acceptance; ambiguous comments or separators are refused.

`ManifestTestProcess` is a test-only executable. Parent watchdogs exercise
admission, parsing, checking and tree teardown, including fixed adversarial forms
and deterministic differential fuzzing. Positive corpus sources are also compiled
as ordinary Swift in the test target and compared using value equality. Parser
baselines and seeds belong to the test corpus, not the runtime language.

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
- `DeclarationIR`, `DeclarationRecord` and `DeclarationValue` hold syntax-independent
  manifest intent; `SourceSpan`, `SourceProvenance` and `DeclarationSourceMap`
  carry document coordinates and origins without syntax or source access.
- `Declaration` and `ResolvedState` define the current stored intent and resolved version 1 state,
  including the complete instruction section, prompt and physical-target models.
- `StateStore` owns scope paths, validation, deterministic encoding and state
  persistence. `FileLock` serializes state access; `FileTransaction` durably
  journals replacements across installations, state and cache. Mutating state
  access recovers interrupted transactions before proceeding, as described in
  [State and cache](State.md).
- `SourceCache` owns bare Git mirrors, requirement resolution, exact snapshots,
  digest-addressed downloads and pruning across skill, instruction and watch pins.
  `SourceResolutionSession` shares disposable exact snapshots between domain
  planners during one update. `StatePrecondition` and `PathIdentity` validate
  the rendered generation before application. `TransactionOutcome` follows
  its owning journal through commit and recovery.
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

Update results include old/new resolved versions, full revisions, hashes and
typed file entries with bytes and executable flags. `membership` reports the
old/new managed mode or absence for every affected agent, sorted by raw value;
paths are physical installation paths with the final entry unfollowed. Shared
paths retain distinct recipient rows and one physical diff. `lockMissing`
means the before membership is unrecorded, not that files were absent.
`installed` is a post-apply receipt. Persistent hashes exclude permissions;
equal hashes do not suppress mode-only changes.

The optional `beforeApply` callback runs before any replacement, and a thrown
error cancels the operation. The extracted `SkillUpdatePlan` validates state
and target preconditions around content retention, including execute flags.
Prepared, cached and staged skill content must agree in bytes and mode.
A CLI auditing several projects calls `doctor` with an explicit environment
for each root.

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

`Instructions` validates instructions files into immutable `InstructionSection`
values, renders generated targets and ChatGPT prompts, recognizes generated
files by their notice, finds local links, detects drift of Claude import blocks,
and compares source-qualified identities across scopes. The `Markdown` product
from [swift-markdown](https://github.com/swiftlang/swift-markdown) provides
CommonMark structure, semantic inline text, and block line ranges through
cmark-gfm. Only `AgentsInstructions` depends on that product. The adapter
retains original line bytes; it does not format the parsed tree.

`InstructionFrontMatter` reads the fixed front matter, a strict YAML subset with
a required `description` and optional `paths`. The body keeps its source syntax:
it starts with a top-level ATX heading of any level, every other heading,
including container headings, is a deeper ATX heading, and it cannot end inside
a code or HTML block. Heading identity is the AST heading's `plainText`, trimmed
with whitespace collapsed, plus its level; it controls duplicate checks within a
target. Rendering inserts the `paths` line after the first heading and never
changes heading levels. A rendered target is reparsed, and every section's first
heading must remain a document heading.

Because the AST does not expose fence or HTML closure state, source validation
reparses a continuation token in the terminal block's container and checks
whether it becomes code or HTML. Physical list prefixes become continuation
indentation and quote prefixes remain intact. The token is never emitted.

Link inspection walks the AST for links, images and raw HTML outside code, and
reads reference definitions, which have no AST nodes, from lines outside code
blocks. It reports destinations that are relative, absolute or `file:` URLs,
decoded and without query or fragment; lifecycle callers resolve them against
the checkout being written.

A leading UTF-8 BOM in a source is metadata: source hashes include it, while
rendering omits it. ChatGPT custom content is UTF-8 validated and appended as
original bytes, including any BOM and line endings. Source hashes cover
original bytes; a target's hash covers its rendered bytes.

Markers count only as top-level, single-line HTML blocks whose complete source
line equals the fixed marker text; indented, quoted, or padded examples are not
markers. They delimit only the managed import block in a project Claude file,
whose hash covers LF-normalized marker and content lines.

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

## AgentsUpdates

`UpdateOperations.preview` plans all declared skills, instruction targets and
prompts under one shared scope lock. `withPreparedUpdate` holds one writer
lock through preparation and the synchronous consumer closure. Its
`PreparedUpdate` exposes an immutable `CombinedUpdateReport` and applies once;
retained or reused handles fail before I/O after closure exit. Reports cannot
be reconstructed into applicable plans.

Package-visible `SkillUpdatePlan` and `InstructionUpdatePlan` own discovery,
reports, preconditions, retention and staging for their domains. Standalone
updates use those same plans and preserve the other domain. Neither domain
depends on the other or on `AgentsUpdates`. The composition target merges
owned records and commits both kinds, changed state and cache pruning in one
`FileTransaction`; the skill-only consumer need not link Markdown.

See [combined updates](Updates.md) for callback restrictions, state-only
changes, cancellation, failure dispositions and recovery.

## Validation and Documentation

Core tests cover source identities, declarations, lock validation, deterministic
state, transactions, concurrency, requirements, mirrors, snapshots, hashes and
agent paths. Skill tests cover discovery, artifact formats and the full declared
lifecycle, including public consumer calls and failed-operation preservation.
Fixtures create isolated homes and explicit Git initial branches and remove
their temporary roots. Instruction tests cover the instructions file format,
generation, link checks, Claude forwarding and ChatGPT rendering through public
APIs with in-memory fixtures. Lifecycle tests cover pinned sources, own
instructions, nested and physical targets, transactional writes, ownership
stops, lost locks, prompts, deletion, export and read-only multi-root audits.

[State and cache](State.md) describes persisted data and lifecycle invariants.
`../Proposals/` holds design work; `../Decisions/`, `../Migrations/` and
`../Archive/` retain historical records with their original scope.
