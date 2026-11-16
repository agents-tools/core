# Package Architecture

## Purpose and Consumers

`core` supplies symbolic agent declarations, source linking, skill and instruction
management, resolved state and recoverable application. Both `agents-tools/cli`
and `skill-cli/cli` consume its public products. Consumers own command parsing,
terminal/UI presentation and executable distribution.

## Target Boundaries

```text
AgentsManifest → AgentsCore, TreeSitterYAML, TreeSitter, Yams
AgentsSkills → AgentsCore, AgentsManifest, Yams
AgentsInstructions → AgentsCore, AgentsManifest, Markdown
Components → AgentsCore, AgentsManifest, AgentsSkills, AgentsInstructions, NativeDocuments, MCP
AgentsUpdates → AgentsCore, AgentsManifest, AgentsSkills, AgentsInstructions
NativeDocuments → AgentsCore, TOMLSemantics, TreeSitterTOML, TreeSitter
TOMLSemantics → Foundation
TreeSitterTOML → (vendored C grammar)
AgentsCore → CPlatform, Crypto
```

`TreeSitterYAML` is an internal C target containing the pinned, unmodified YAML
parser/scanner and headers, with upstream license and per-file provenance.
The runtime is a normal SwiftPM dependency. Consumers never receive parser types.

## NativeDocuments

`NativeDocuments` inspects provided JSON, JSONC and TOML bytes and prepares
ownership-checked regional changes. It preserves no-op bytes, unmanaged content,
comments and exact native semantics, and reparses each complete candidate.
`TOMLSemantics` owns bounded standard TOML validation; `TreeSitterTOML` supplies
pinned concrete locations through the existing Tree-sitter runtime dependency.
These targets are package-only, with no library product or filesystem provider.
See [native documents](NativeDocuments.md) for typed regions, observations,
creation evidence, read-only syntax and cumulative operation budgets.

## AgentsManifest

The frontend reads `.agent/agents.yaml` or the user scope’s `agents.yaml` and
produces complete syntax-independent IR and typed declarations. Admission checks
UTF-8 and unsupported raw line separators before parsing. Tree-sitter supplies
concrete byte ranges under an enforced parser work policy; bounded CST admission
precedes public Yams ordered-node composition. The bundled schema owns field
shapes and generates finite runtime constraints and reference help. Core scalar
resolution preserves string values, integer kind and exact decimal payloads.

`DeclarationDocument` is an immutable validated snapshot with digest-scoped
occurrence handles. `ManifestEdit` carries Core domain values. Its editor changes
owned ranges, preserves unrelated bytes/comments, refreshes source maps and checks
full expected IR. Public changes are domain-valid, including no-op preparations.
`DeclarationEditPlan` privately composes bounded drafts for complete domain changes
and validates final IR, domain and declaring environments before returning bytes.

`ManifestDump` exposes schema version 2, format `yaml`, manifest version 1, typed
IR records and semantic indexed source locations. Parsing, projection, dump and
edit preparation do not resolve sources, read resources or execute programs.

`StateStore` extensions supply declaration reads, loading and edit planning;
`DeclarationAccess.manifest` connects watch operations. All state I/O, evidence,
locks and publication remain in Core. See [state](State.md) and the
[manifest reference](../Reference/Manifest.md).

`ManifestTestProcess` and `ManifestTestSupport` own isolated parser/editing probes
and their resource reports. Package tests cover the complete YAML/domain contract
and the existing state, linking, lifecycle and recovery guarantees.

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
- `Declaration` holds complete typed symbolic manifest intent: ordered component
  and group occurrences, conditions, native values, symbolic group references and
  source declaration directories. It has no serialized form. `ResolvedState`
  defines version 1 skill/instruction state, including instruction sections,
  prompts and physical targets.
- `StateStore` owns scope paths, validation, deterministic lock and watch
  encoding and state persistence. It holds declaration bytes, their evidence,
  the absent-declaration rule and publication without knowing the declaration
  format. `FileLock` serializes state access; `FileTransaction` durably
  journals replacements across installations, state and cache. `FileSnapshot`,
  `FileObjectIdentity` and `DirectoryWriteLease` own content, physical-object
  and temporary directory-write evidence, including directory descendants and
  permission bits. Within the transaction protocol only `DirectoryHandle` calls
  `CPlatform`; it owns verified deletion, durable synchronization,
  inode-checked directory permission updates and typed cross-directory rename
  results. Mutating state access recovers interrupted transactions before
  proceeding, as described in [State and cache](State.md).
- `SourceCache` owns bare Git mirrors, requirement resolution, exact snapshots,
  digest-addressed downloads and pruning across skill, instruction and watch
  pins. `SourceResolutionSession` shares disposable exact snapshots between
  domain planners during one update. `StatePrecondition`, `TargetPrecondition`
  and `PathIdentity` validate the rendered generation before application.
  `TransactionOutcome` follows its owning journal through commit and recovery.
  `ProcessRunner` executes synchronous subprocesses. `OwnedDuplexProcess` is a
  separate package-only, nonblocking pipe/process-group owner for bidirectional
  connection tests.
- `WatchOperations` owns source subscriptions, seen baselines, branch tracking
  and file comparisons. `WatchState` defines version 1 of `agents.watch`.
  Skill discovery and artifact loading are injected by `AgentsSkills` through
  `SkillOperations.watchOperations()`, and declaration access by
  `AgentsManifest`. See [Watch](Watch.md) for the public API.
- `AgentRegistry` owns agent skill locations. `RuntimeEnvironment` supplies the
  project root, home directory and environment. Universal agent skill locations
  can be shared, so recipients sharing one directory must agree on install mode.
- `FileHash` hashes tree entries, hidden files and symlink destinations;
  `PathSafety` checks paths and creates filesystem skill identities.

Core has no dependency on manifest syntax, skill discovery, frontmatter, Yams or
Markdown.
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

`OwnedDuplexProcess` takes explicit argv, cwd, environment and PATH. Its CPlatform
spawn closes nonstandard child descriptors and creates a separate process group;
it never inherits transaction locks. The owner closes stdin, waits a finite grace,
signals TERM/KILL while the unreaped leader reserves its identity, and confirms
reap with nonblocking waits. It refuses auto-reaping SIGCHLD configurations and
reports ownership loss or unconfirmed cleanup. Darwin inspects only the reserved
group, under a finite byte bound, to distinguish a zombie-only group before
signalling. It does not operate on unrelated processes or promise ownership of
children that detach into another session/group. `ProcessRunner` owns synchronous
Git/one-shot execution; transaction publication owns filesystem state.

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

## Components

`Components` is an internal target. Its package-only `ComponentLinker` reads a
complete symbolic declaration and explicitly exported producer groups into an
ordered, exact source graph. Root components precede uses; groups follow the
same depth-first order. Producer defaults and frontmatter restrictions determine
recipients together with nested reference and component conditions. Instructions
retain repeated occurrences; identical named hooks and policies coalesce while
retaining their origins. Logical conflicts are checked before artifact lowering.

Core owns frozen Git candidate evidence, exact snapshots, source containment and
the scoped temporary-read session. Export constraints share one version variable
per normalized source; discovery roots remain distinct namespaces. Direct skill
and section pins are independent. Exact annotated Git objects are peeled to commits
before conjunction, candidate selection and snapshot identity. Acquiring a known
object does not enumerate mutable refs or refresh the frozen reference mirror.
The session reuses existing exact cached objects only under existing locks; other mirrors, refs, locks and content remain
temporary. The caller consumes borrowed resources within the linking closure;
cleanup runs on success, error and cooperative cancellation. The synchronous Git
runner completes owned in-flight work before cancellation returns.

An exact view retains the original actual-local source environment independently
of its borrowed content and live-edit eligibility. Local producer aliases resolve
from that source's actual discovery root and home, even with a Git requirement.
Remote-contained local declarations inherit their immutable parent snapshot and
remain subject to lexical and real symlink containment.

`SkillSnapshotReader` and `InstructionSnapshotReader` consume already selected
views without independently resolving or retaining sources. Actual local edit
skills preserve their live paths. Skill keys, exclusions and overrides use canonical
semantic names while resource paths and display names retain their source spelling.
An all-selection includes members from their effective override views, admits live-only
members only when that view is selected, and omits missing effective-view members;
named selections still require their members. Named own-instruction reads validate only
the selected path and its ancestors, while full enumeration remains strict.
Remote-contained local sources inherit the producer snapshot. Existing skill-index formats supply skill artifacts, and do
not define an export-package format.

The linked result records relative resource evidence, source requirements,
reference and contribution occurrences, provenance and exact dependency pins.
Its protected projection compares other domains' payloads, resource hashes,
recipients and pins; source sharing alone does not imply a changed projection.
Producer-owned children report `notEditableHere` with producer and reference
coordinates. The ledger freeze seam captures complete durable inputs within the source session.
Versioned replay produces verified artifacts and owned-region intentions; its
compatibility renderer table contains only existing formats. Test process formats
are supplied explicitly and are absent from production registration. These
package seams do not publish state.
The existing public lifecycle operations still enforce their deployment subset.

Root package resources use the project directory in project scope and the
user-state directory in user scope. Explicit sources retain their declaring
environment. Root user instructions require named sources, while imported
producer groups retain their own sections. Consumer-owned prompt append references
are metadata anchored to the project or, for root user declarations, runtime home.
Linking and freezing do not open these export-only inputs. Public export reads their
current bytes with lexical and real containment checks; missing or unreadable content
fails export without a frozen-byte fallback. Producer-owned append content remains
anchored to the selected immutable source and is a frozen replay resource. Installation
replay reads only its recorded resources and does not open consumer append references.

The package-only `MCPConnectionRunner` performs one explicit connection test on
already-bound ephemeral values. Only Components links the exact official MCP SDK;
SDK models do not enter public APIs. The SDK Client owns automatic initialization
and typed tools/list requests. A bounded receive admission gate validates the
negotiated version before initialized is sent, and discovery runs only when the
server declares tools. There are no business tool, resource, prompt, sampling or
elicitation handlers; SDK logging is no-op.

The selected transport is stdio, Streamable HTTP, or legacy SSE. Stdio frames
nonblocking owned pipes and discards counted stderr. HTTP uses one ephemeral
Foundation/FoundationNetworking data-delegate session with incremental JSON/SSE
admission, owned session/version headers and bounded SSE resumption without POST
replay. Legacy SSE waits for its same-origin endpoint event before posting. No
cookie/cache/credential store or OAuth flow is used; redirects and legacy
endpoints cannot transfer headers to another origin or downgrade transport.

A monotonic total deadline includes preparation and all requests; a request
budget cannot extend it. Input, frame, cumulative input/output, stderr, queued
payload, discovery pages/tools/text and redirect/resume bounds are finite and
validated before I/O. Overflow is a structured failure or incomplete discovery,
not a successful dropped message. Cancellation and every terminal path abort I/O,
disconnect Client and join the owned work. Finite process/URLSession cleanup
budgets are additional to the protocol deadline. Unconfirmed cleanup prevents
complete success. Internal outcomes contain bounded private text values for the
caller to redact; they have no automatic serialized representation.

`MCPTestProcess` and the owned loopback HTTP fixture exercise real wire, process,
origin, deadline and resource-cleanup behavior in ComponentsTests. They do not
use external services or execute configured third-party clients.

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
agent paths. Transaction fault tests interrupt every publication and recovery
stage, including concurrent creation of an absent destination and external
replacement of existing targets and recovery paths. Skill tests cover
discovery, artifact formats and the full declared lifecycle, including public
consumer calls and failed-operation preservation.
Fixtures create isolated homes and explicit Git initial branches and remove
their temporary roots. Instruction tests cover the instructions file format,
generation, link checks, Claude forwarding and ChatGPT rendering through public
APIs with in-memory fixtures. Lifecycle tests cover pinned sources, own
instructions, nested and physical targets, transactional writes, ownership
stops, lost locks, prompts, deletion, export and read-only multi-root audits.

[State and cache](State.md) describes persisted data and lifecycle invariants.
`../Proposals/` holds design work; `../Decisions/`, `../Migrations/` and
`../Archive/` retain historical records with their original scope.
