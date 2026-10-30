# State and Source Cache

## Scope Locations

| Scope | Declaration | Lock | Watch state | Cache |
| --- | --- | --- | --- | --- |
| Project | `.agent/Agents.swift` | `.agent/agents.resolved` | `.agent/agents.watch` | `.agent/cache/` |
| User | `~/.agents/Agents.swift` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | `~/.agents/cache/` |

User paths are relative to `RuntimeEnvironment.homeDirectory`. State files
belong to their scope. A project may commit its declaration and lock; the cache,
the writer lock and the journal stay local. `agents.watch` stores subscription
baselines independently of installed pins; [Watch](Watch.md) describes the
operations.

## Declaration

`Agents.swift` records user intent in the [manifest
language](../Reference/Manifest.md). The document is the declaration's only
truth. `AgentsManifest` parses and evaluates its bytes and projects them onto
`AgentsCore.Declaration`, a typed in-memory view of the deployable subset with
no serialized form. `AgentsCore` holds the declaration's bytes and evidence, the
absent-declaration rule and publication, and knows no syntax; `AgentsManifest`
extends `StateStore` with declaration reading, planning and loading. Parse, edit
and subset failures are `ManifestFailure` diagnostics located in the declaration
file.

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  sources: [
    .source(name: "drafts", path: "~/Developer/skills"),
    .source(
      name: "team", url: "https://github.com/example/skills", from: "1.0.0"
    ),
  ],
  components: [
    .skills(
      source: "drafts", select: ["release-notes"], mode: .edit,
      overrides: [.skill(name: "release-notes", agents: [.codex])]
    ),
    .skills(source: "team", exclude: ["retired"]),
  ]
)
```

### Deployable subset

The state layer deploys root `defaultAgents`, `sources` and `watch`, and root
`components` of kinds `.skills` and `.instructions`: at most one skills component
per source alias and one instructions component, with no `condition` on a
component, section or prompt and an empty `native`. Groups and exports may be
declared; unused groups are inert. Every other active structure fails with
`manifest.unsupported` at its location, and nothing is dropped: root `uses`, a
condition, native configuration, another component kind, a second skills
component for one alias, a second instructions component, or
`.skills(source: ".")`. After projection, `Declaration.validate(environment:)`
performs the checks that depend on the runtime environment, such as duplicate
identities after local-path expansion.

`defaultAgents` defaults to `codex` and `claude-code`. Explicit recipients,
including an empty array, replace the default; the projection keeps omitted and
empty recipients distinct. A source added by location keeps the alias already
declaring it, or receives its location's last path component; while another
source holds that name, preceding components are prefixed (`anthropics-skills`),
then a number is appended.

A skill selection is all members, when `select` is omitted or `.all`, or an
explicit name array, with optional exclusions, recipients, mode and per-skill
overrides. An all-member selection follows discovery membership on an unnamed
update. Removing a member adds an exclusion. Explicitly named updates resolve
only those members and fail if a requested member is missing. Skill filesystem
identities are unique within a scope across sources.

Requirements are `branch:`, `revision:`, `exact:`, `from:` (up to the next
major version), `.upToNextMinor(from:)` or a half-open range. Ranges include
their lower bound and exclude their upper bound. A prerelease requires a
prerelease bound with the same major, minor and patch. With no requirement,
resolution chooses the latest semantic-version tag, then the source's default
branch when no version tag exists.

Source IDs are Git `host[:port]/path` with a lowercase host and without user,
scheme or `.git`; `local:` plus an absolute path; or a well-known URL retaining
its scheme. Declaring two aliases for one normalized ID is an error.

The `.instructions` component holds recipients, ordered section references (a
bare string for the project's own instructions, `.section(name:source:)` for a
declared source), and named `chatGPT` prompts with ordered sections and optional
relative `append` paths. `watch` is a unique alias array. Skill operations
preserve both and existing watch-state bytes.

### Absent declaration

| Declaration | Lock or watch state | Behavior |
| --- | --- | --- |
| Absent | Absent | An empty declaration. Reads return empty results; the first write creates `Agents.swift` with no-replace publication. |
| Present | Any | Normal. An absent lock is an empty resolved state: `update` creates it and `install` has nothing to restore. |
| Absent | Present | Every read and write path, including the `load*` accessors, listings, previews, doctor, install, initialization and export, throws `CoreError.missingDeclaration` with the declaration path. Nothing is written, and no `.agents.lock` is created. |

Read paths apply the rule after their pending-recovery check, and writers after
transaction recovery; the check before taking the writer lock runs only when no
journal or pending marker exists. An interrupted first write of the declaration
and lock therefore recovers on the next write instead of reporting a missing
declaration. Watch state counts because its baselines derive from the
declaration; treating a missing declaration as empty would let the next update
remove what was deployed.

### Declaration writes

Every declaration write passes through two entries.
`planDeclaration(_:replacing:prepared:)` in `AgentsManifest` compares the next
declaration with the previous one the operation read from the same prepared
baseline. It returns no change when they are semantically equal, and otherwise
bytes that passed the complete front end and the projection check.
`stageDeclaration(_:in:prepared:)` in `AgentsCore` publishes those bytes in the
operation's transaction, expecting the baseline's evidence for the declaration.
Skill, instruction, watch and update writes use only these entries; adding or
changing a source is a difference in the declaration's sources. A combined
update leaves the declaration unchanged, and `validateBeforePublication` still
checks its evidence.

Planning completes before `beforeApply`, cache retention, a watch's Git fetch
and any staging, so an edit that cannot be addressed exactly fails without side
effects. When the previous declaration differs from the projection of the
baseline bytes, planning fails with `manifest.edit.baseline` rather than
overwriting an external change. Under the scope writer lock, a later writer reads
its own baseline and plans again, so concurrent writers lose no update.

Semantic equality decides whether anything changes:

- sources are equal when identity, requirement and normalized subpath are
  equal, so URL spelling, relative or absolute local paths and range spelling
  never cause a rewrite;
- recipient arrays compare as sets, with omitted and empty distinct;
- omitted and empty exclusions, overrides, prompts, watch lists and skills
  components are equal;
- sections compare in order.

Planning makes minimal document edits and never reorders existing text. A new
source is appended, a changed source is replaced in place, and a removed source
goes after the components that reference it in the same batch. A new skills
component is inserted before the instructions component, or last; a new
instructions component is last. Selections, exclusions, recipients, mode,
overrides, sections, prompts, watch aliases and default recipients change at
argument or element granularity: existing arrays gain and lose elements in
place, an ordered array gains them in order, and sections use a
longest-common-subsequence edit that keeps repetitions. Edits replace only their
target ranges; bytes outside them, comments included, stay unchanged. Constructs
the editor cannot address exactly, such as shared constants, concatenations and
ambiguous comments, fail with `manifest.edit.readOnly`. A batch holds at most
100 requests, and the document is rebuilt from the new bytes before the
remaining difference is planned. The projection of the final document must equal
the intended declaration, or planning fails with `manifest.edit.mismatch`.

Without declaration bytes, planning prints the complete declaration with the
[canonical printer](../Reference/Manifest.md#canonical-printing): sources, skills
components, overrides, prompts, selected names and watch aliases sorted by UTF-8
bytes, recipients deduplicated in agent-ID order, and skills before instructions.
The printed bytes pass the same front end and projection check and are published
with no-replace. A semantically empty declaration creates no file.

One transaction covers the declaration, lock, affected watch state, installation
targets, cache retention and pruning; a declaration-only change uses the same
journal and evidence. The declaration is published only as planned source bytes,
while the lock and watch state keep their own encoders. Preparation records
presence, physical identity and byte digest for the declaration, lock, watch
state and related targets. A changed comment, or another inode with equal bytes,
therefore invalidates a prepared preview, and a declaration created externally
after preparation is an existence conflict that keeps the external file.

### Requirement comparison

Semantic comparison expands range requirements to their bounds; raw case or
encoded-field equality is insufficient. Branch and revision compare their
strings, exact versions compare normalized full versions, and absence keeps its
distinct latest-tag/default-branch policy. Canonical spelling applies to new IR
and newly serialized requirement fields.

| Site | Rule |
| --- | --- |
| Declaration IR and dump | Canonical requirement kinds and normalized version strings; a factory and a literal range with equal bounds compare equal. |
| Declaration writes and `upsertSource` | Semantic values are compared; an equal edit keeps the original source bytes. New or changed nodes print canonically; untouched spelling is retained. |
| `LockedSource.requirement` in the lock | Newly written records use canonical requirements. Existing records keep their bytes and are compared through a semantic view. A requirement-spelling difference alone never changes pins, reports an update or stages a write. |
| Skill and instruction lock producers, combined update conflicts and change detection | Source identity, discovery root and semantic requirement values are compared; equal ranges merge without a conflict. A semantically unchanged lock keeps its original bytes even when another state file changes; a necessary rewrite emits canonical requirements. |
| Resolution-session reuse and cache descriptors | Requirements are keyed by semantic value. Cache identity and materialization keys use source identity and exact revision or artifact digest; restoration uses the stored pins without re-resolving requirements. |
| `agents.watch` | Stores source identities and seen baselines, with no requirement. Re-evaluating an equivalent declaration preserves the subscription and baseline; watch-created lock descriptors follow the lock rule. |

State transactions compare semantic state before choosing any serialization and
never rewrite records on read.

## Lock

`agents.resolved` version 1 has identity-keyed `sources` and `skills`, and an
`instructions` object containing `sections`, `chatgpt` and `targets`.

The lock is written with sorted keys in Prettier's default JSON layout:
two-space indentation, `"key": value`, every non-empty object expanded, empty
containers as `{}` and `[]`, and an array without objects on one line when it
fits in 80 columns. A repository whose Prettier configuration uses another print
width may lay out an array between the two widths differently. A semantically
unchanged lock keeps its original bytes; a changed lock is written in that
layout. Empty lock sections such as `"skills": {}` remain, because earlier
readers require them. Journals, `agents.watch` and content hashes keep the
encoder's fixed layout.

A locked source records its kind, Git URL where applicable, requirement and
search path. A skill records its source ID, its own revision and optional
version, relative directory path, content hash and `installs` mapping agent IDs
to `link`, `copy` or `edit`. Every non-edit item carries an immutable pin.
Updating one skill leaves other item pins unchanged.

Well-known items record an artifact's `type`, `url` and SHA-256 `digest`.
`files` artifacts additionally record every file's URL, path and digest. Their
aggregate digest covers the sorted, deterministically encoded file records.
Restoration reads these recorded URLs or verified digest cache entries and never
reads an index. Missing pins or mismatched content stop restoration.

Instruction section records carry name, source, revision or artifact, path and
hash; a project's own files use source `.`, their project-relative path and
hash, and no revision. Prompts hold ordered locked sections and optional append
paths. Physical targets record agents, heading offset 0 or import, the hash of
the generated file or import block, and `created`, which unit targets always
record as false. Skill writes retain these records unchanged. Instruction
lifecycle writes preserve skill records. Target keys are project relative or
user-home relative; configured user files outside home use absolute keys checked
against the runtime's registered instruction locations.

Maps are key sorted. Unordered selections and agent lists are sorted; section
arrays and each prompt's section order are preserved. Files have a trailing
newline and no timestamps. State and journal JSON must be UTF-8 without a byte
order mark; validation consumes the entire document. Other encodings, invalid
state, duplicate JSON keys at any depth and fields that would be discarded by
decoding cause an error. Tree hashes use length-prefixed paths and typed entry
payloads, including empty directories and symbolic link destinations.

Tree hashes intentionally exclude permissions. Skill update snapshots compare
the any-execute-bit Boolean separately for regular files. Preparation, retention
and transaction staging verify that dimension without changing stored hashes,
pins, the declaration or the version 1 lock and watch schemas.

## State Transaction and Recovery

The scope's `transaction.json` is the sole persistent transaction owner for
installation targets, declaration, lock, watch state, cache publication and
pruning. Its protocol accepts regular files, directories and symbolic links
independently of the declaration format. The declaration is published as the
source bytes its plan produced; the lock keeps its state encoder and watch state
its fixed encoder.

### Preparation and preconditions

Prepare captures presence, physical identity and content digest for declaration,
lock, watch state and affected targets. `TargetPrecondition`, `PathIdentity` and
`StatePrecondition` in `UpdatePreconditions.swift` bind those snapshots and
existing ancestry. Directory target snapshots include descendant identities.
Linked non-edit content is checked separately from its link; live edit content
remains live. Domain plans also validate source content and executable flags.

The scope writer lock covers recovery, preparation, retention and publication.
Recovery runs first. Apply checks the prepared evidence before retention, after
retention at commit entry, and after staging before publication. The journal's
expected preimages are the evidence the plan captured. Watch subscription,
acknowledgment and removal capture declaration, lock and watch state before
contacting Git; that evidence is also the baseline for the lock that pruning
follows. Transactions without a state plan, such as cache publication, do not
implicitly add declaration, lock or watch preconditions. Domain hooks check
related inputs that the journal does not replace. State parsing consumes the
captured raw bytes, so decoded inputs and journal evidence describe the same
generation.

Changed bytes, including declaration comments or whitespace and target comments,
invalidate preparation. Another inode with equal bytes also invalidates a
captured target entry or directory descendant. Apply requires a newly prepared
plan and never rebases an old edit onto changed inputs.

Readers and writers serialize through `.agents.lock`. Missing scope and target
ancestry is created with descriptor-relative operations. Parent directories are
synced before target mutation, including when an interrupted creator left a
visible entry. Empty ancestor directories can remain after a failed operation.
Successful managed directory creation uses mode 0700; files and locks use 0600.
Final file modes are set explicitly rather than inherited from the process
umask. Copies preserve their source modes, ACLs and extended attributes.

Directory permissions, inherited/default ACLs and other filesystem policy must
allow owner access to newly created entries. Core checks that access without
repairing the policy. Permission denial reports the affected path and asks the
owner to check directory permissions and default ACLs. Retrying does not bypass
the denial. Existing user content and metadata are preserved.

### Journal records

Journal format version 1 is independent of the manifest language, lock and watch
versions.
The root records its version, transaction UUID, scope identity, registered root
identities, transaction phase, operations, private containers and disposal
intent. A journal without this version, or with another version, is retained
unchanged. Recovery reports that it was written by another version and must be
recovered with the version that wrote it; it does not guess a compatible replay.

Paths are relative to named roots: scope state, registered agent installation
directories and registered instruction destinations. The journal binds the state
directory, each root and every destination parent to its physical location and
identity. Registry boundaries resolve configured containers; descendants open
without following links. Symlinked journals or descendants, overlapping targets,
unregistered paths and copied or moved journals are rejected before replay.
Directory descriptors remain pinned.

Each operation records its path, install/delete action, expected preimage or
absence, parent identity, private container, sealed staged object, progress and
any conflict reason and retained locations. Object evidence contains device,
inode, type, SHA-256 digest, permission bits and executable status. Directory
evidence includes child identities and digests. Data replacements inherit the
existing regular file's metadata. Undo restores the original object and its
metadata.

Each used target parent has one private container with a UUID-derived name and
mode 0700 on the same filesystem as its targets. The journal records the name
before `mkdir`, then records the container's physical identity before inserting
anything. Probes, extraction work and staging stay inside it. An identified
container owns all construction before publication: incomplete objects can be
disposed of as a whole without individual ownership evidence. Another writer has
no ownership claim on content inserted into this private transaction storage. An
unidentified container may only be removed with `rmdir` when empty; a nonempty
one is an unresolved conflict.

Construction is sealed once, and sealing is its only journal write. Snapshot and
content verification consume the same read bytes, and check the expected content
hash and executable flags. `ready` and that snapshot become durable together.
Changes after sealing are conflicts; recovery never refreshes a sealed snapshot
to adopt changed content.

Container entries are named by operation index and slot. `staged` holds a
creation's private staging. `exchanged` holds an exchange's private staging
until publication, then the displaced preimage, and after undo the published
object exchanged back out. `deleted` holds the object a deletion moved aside,
and `withdrawn` holds a published creation that undo moved aside. Displaced
preimages, the contents of `deleted` and `withdrawn`, and published objects are
user data. Their identity and digest remain mandatory evidence even inside a
private container. A container holding such slot objects receives complete
terminal disposal evidence after their expected distribution has been verified.

| Progress | Durable evidence and possible distribution |
| --- | --- |
| `queued` | Expected preimage and container name; construction is private and unsealed. |
| `ready` | Verified staged snapshot for an install; no publication intent. |
| `publishing` | Publication and temporary directory-write intent; objects can be prepared or installed. |
| `applied` | Rename parents and original directory modes synced; postimage and preimage verified. |
| `restoring` | Undo and temporary directory-write intent; installed or reverted objects can be present. |
| `restored` | Undo parents and original modes synced; restored target and remaining slot objects verified. |
| `cancelled` | Original modes restored; publication did not consume private staging. |

One operation-type/progress table defines every expected target and recovery
slot. Publication validation, rollback classification and disposal preparation
use that table. Before durable disposal intent, every expected slot object must
exist and match; absence cannot be treated as completed disposal.

Journal publication orders the new journal file barrier before rename, then the
parent directory barrier. Ordinary preimage files are synced once with their
parent barrier; tree synchronization syncs file contents and concentrates each
level's directory barrier after its children. On macOS a synchronization barrier
also uses `F_FULLFSYNC` to request a storage flush.

### Publication and concurrent writers

Atomic exchange and no-replace rename are checked before modifying any target,
preimage or state file. Before this check the transaction can only create
missing ancestry, its journal and its private containers. Probes run on
container objects on the actual publication device. A successful result is
cached by `st_dev` only for the rest of that commit; every commit probes its
devices again, because a device number can be reused after an unmount.
Unsupported primitives remove the journal and containers; empty missing ancestry
may remain. There is no replacing-rename fallback, including for declaration,
lock and watch creation.

Only `EINVAL`, `ENOSYS`, `ENOTSUP` and `EOPNOTSUPP` mean unsupported. `EEXIST`
and `ENOTEMPTY` mean an existence conflict. Other failures retain their errno
and system reason. Probes and publication use the same classification.

| Expected destination | Publication |
| --- | --- |
| Absent | Persist the sealed inode and digest, then move it from the container with Darwin `renameatx_np(RENAME_EXCL)` or Linux `renameat2(RENAME_NOREPLACE)`. A concurrent creator keeps its bytes and inode. |
| Existing | Recheck the preimage, then exchange it with staging using Darwin `RENAME_SWAP` or Linux `RENAME_EXCHANGE`. The displaced object stays inside the container and is compared before confirmation. A mismatched preimage is retained as a conflict. |
| Deletion | Move the entry without replacement into the container's `deleted` slot, then verify its physical identity and digest. Disposal verifies that evidence again. |

Each operation checks its preimage before and again after its publication intent
becomes durable; a preparation already stale before the intent cancels from
`ready` without leasing or moving any object. Publication intent is durable
before rename. Both container and target parent are synced before `applied`
becomes durable. Replacement always retains a directory entry at the
installation path. The operation's complete target and recovery-object
distribution must match before confirmation and again before the commit marker.
The scope lock excludes cooperating writers; the atomic protocol also preserves
objects changed by editors that ignore it.

Read-only directory targets retain their final modes. Darwin and Linux require
write access to a directory to move it between parents, because the rename
updates its `..` entry. Before granting owner-write on a recorded inode,
`publishing` or `restoring` intent and the original permission bits are
durable. The transaction syncs the temporary mode, performs the atomic rename,
then restores and syncs the original mode before recording `applied`, `restored`
or `cancelled`. Only the recorded mode or that mode plus owner-write is admitted
while intent is active. Other modes and other inodes remain conflicts; ACL and
ownership denials are reported rather than bypassed.

### Recovery outcomes

Every mutating state operation first checks for an abandoned journal under the
scope lock, validates watch state and finishes pending reference cleanup before
proceeding. Recovery never reads the declaration: journal and watch-reference
recovery complete even when `Agents.swift` does not parse, and orphaned mirror
locations come from watch state and the lock, then from the mirror's origin.
Journal recovery selects and syncs a consistent generation before watch
reconciliation can release any ref. Pending watch-reference recovery also
reports `CoreError.transactionRecovered` when no journal remains. Retained refs
remain available while a journal conflict is unresolved.

Recovery treats any observed `transaction.json` as possibly renamed without its
directory barrier: before granting permissions, renaming objects or deleting any
resource it syncs that file and its parent, including on retry. A lone unstarted
`transaction.new` owns no object and is discarded directly. An applying journal
reverses verified publications in reverse order. A committed journal completes
terminal disposal. Physical identity and digest distinguish a transaction's
publication even after rename but before `applied`. Another inode with identical
bytes remains external. Missing or changed evidence causes an unresolved
conflict; names and equal bytes never establish ownership. Other verified
operations can roll back while conflicted objects remain available.

Replacement undo exchanges a retained preimage only with the verified published
object and verifies the displaced object. An external replacement before or
during undo leaves both available versions and stops recovery. Deleted entries
return with no-replace rename, preserving an occupied original name. Creation
undo moves only a verified published object into its `withdrawn` slot and checks
it there. A retry recognizing an interrupted reverse rename repeats both parent
barriers before recording restoration.

Interrupted permission changes are restored by recorded inode, independently of
payload rollback. Changed payload bytes remain available. Restoration repeats the
mode barrier even when the original mode is already visible. A recorded directory
inode missing from every location the operation/progress table allows, or a mode
outside the original/temporary pair, leaves an unresolved conflict with the
original mode and intent retained.

Before disposal the journal persists terminal `committed` or `rolledBack` state
and the complete recovery-object evidence. A commit disposes immediately after
sealing that evidence; recovery first revalidates every target and container
against it. A separate global disposal intent then becomes durable. Only after
that intent may missing objects or descendants mean interrupted disposal.
Changed identities, digests or unexpected descendants in sealed disposal
evidence remain conflicts. Unpublished private construction is disposed of by
verified container identity. Links are never followed during deletion. Owner
access may be granted to directories being disposed of without changing
installed or restored metadata. Absent entries still receive a parent barrier.

Conflicts retain `transaction.json`, the available target objects and private
containers holding user data in their slots. Each conflicting entry records the
reason and scope-relative recovery locations. Doctor lists those reasons and
locations and asks for owner action; it does not promise that another write will
resolve them or provide a conflict-resolution command.

Recovery can itself be interrupted and repeated. Successful recovery reports
`CoreError.transactionRecovered` and callers retry the whole preparation.
Outcomes distinguish unchanged, committed and unresolved recovery and belong to
their journal UUID: recovering a cache publication cannot mark a later combined
update committed. Failure after a commit marker can still be unresolved if
recovery material changed. A committed failure is never described as rollback.

The public `StateStore.loadResolved()` and `loadWatch()` in `AgentsCore` and
`loadDeclaration()` and `loadManifest()` in `AgentsManifest` are read-only, as
described below. `loadDeclaration()` returns the deployable projection;
`loadManifest()` returns the complete `DeclarationDocument` without subset
projection, or `nil` when no declaration exists.

### Read-only access

Non-applying skill and instruction operations, listings, previews, watch status
and watch diff take an existing shared lock, report pending recovery and never
replay it or create state files. With no lock, inspection rechecks for a new
lock or recovery marker before returning either its result or its error. A
writer causes that attempt to be discarded and retried under the shared lock.
Writers create the scope lock before mutation and never remove it.

The `load*` accessors follow the same rules and never create `.agents.lock`.
Pending journals and watch-reference markers stop inspection with
`CoreError.recoveryPending`, which carries the recovery diagnostic; a mutating
operation on the scope performs the recovery. The absent-declaration rule
applies after this check. Doctor distinguishes pending automatic recovery from
an unresolved conflict requiring owner action, and skips checks needing a
consistent generation. Skill doctor uses `pending-recovery` or
`unresolved-transaction`; instruction doctor uses `pendingRecovery` or
`unresolvedTransaction`. Explicit multi-root instruction audits never write.
Corrupt or foreign-version journals remain available rather than being replayed.

### Watch references and mirror locks

Mirror Git invocations pass `-c core.fsync=objects,reference,pack-metadata` and
`-c core.fsyncMethod=fsync`; durability settings never rewrite configuration.
Mirror configuration must be a regular file, checked before invoking Git. Before
a Git acknowledgment publishes watch state, existing object bytes and object
directory entries are flushed as well. The retained ref, its parent, Git config
and HEAD, and mirror/cache directory entries are synced before the scope journal
can commit the baseline. This orders durable Git content before the durable
watch reference; power loss cannot publish a baseline ahead of its retained
content.

Before preparing a watch ref or changing watch/lock pins, the scope writes and
syncs `watch-refs.pending`. Under the scope lock, reconciliation runs only after
the transaction has committed or journal recovery has selected and synced a
consistent generation. It removes only `refs/agents-watch/<revision>` refs no
longer named by watch state, skills, instruction sections or prompt sections.
Loose-ref parents and packed refs are synced before the pending marker is
removed and its parent synced. The marker survives interrupted preparation or
cleanup, so the next mutating access repeats reconciliation against the
recovered state; refs needed for rollback remain until that state is durable.

Mirrors are exclusively owned by agents. Each mirror has a per-source lock at
`cache/locks/<source-key>.lock`, created before cloning or first access. All
mirror reads and writes take this lock, including instruction listings and
cached revision inspection. Doctor uses only existing mirror locks; when one is
absent, cached revision inspection falls back to remote refs without creating
it. Scope mutations take the scope lock first, then the mirror lock; mirror
access never acquires the scope lock in reverse order. An instruction listing
can therefore populate a mirror before `.agents.lock` exists while still
excluding concurrent recovery and watch mutations.

Pending Git ref cleanup can leave mirror Git lock files that prevent safe fetch.
Recovery takes the mirror lock and validates and syncs their cleanup before Git
can proceed.

Git children explicitly inherit a duplicate of the mirror lock descriptor
allocated at 3 or above with `F_DUPFD_CLOEXEC`. Spawn file actions inherit that
duplicate without changing the parent's close-on-exec flags. Output pipe sources
also use descriptors above the standard streams before redirection; closed stdin
is connected to `/dev/null` in the child. Unrelated descriptors remain closed,
and the parent closes the temporary duplicates immediately after spawning. The
parent closes its lock descriptor without explicitly unlocking the shared open
file description. If the Swift parent is killed, a surviving Git child keeps the
mirror locked until it exits. Git automatic maintenance is disabled. Recovery
must acquire this same mirror lock before classifying Git `*.lock` files
(including `packed-refs.lock`) and the root `packed-refs.new` staging file as
abandoned. Within each mirror it validates all candidates as regular files
through directory descriptors, without following symlinks, before deleting any
candidate. It syncs lock-file deletions before retrying Git; the pending marker
also covers interruption of this cleanup. Live mirror users and surviving Git
children block recovery, so their Git locks and refs cannot be removed or
recreated beneath them.

Git runs with terminal and Git Credential Manager prompting disabled while
preserving the rest of the inherited environment. Failures identify the action
and source location rather than its mirror, staging or extraction paths; see
[process execution and errors](Package.md#process-execution-and-errors) for the
consumer error contract.

## Materialization and Installation

Git materializations, downloaded artifact bytes and expanded artifact trees use
private journal-owned staging. Exact Git commits are extracted there; expanded
artifacts are checked against their locked tree hash. Copied trees are hashed
through pinned directory descriptors and verified before publication. Files,
metadata and directory entries are synced before atomic publication of the final
cache name. Git extraction work also belongs to the journal, so recovery
cleans an incomplete copy or extraction without retaining a partial final
directory just because the lock references its pin. Cache publication completes
before the installation transaction references that content.

Each scope's cache contains:

```text
cache/
  mirrors/<source-key>.git/
  materialized/<source-key>/<full-revision>/
  artifacts/<sha256-hex>
  artifact-content/<sha256-hex>/
  locks/
```

A source key combines a readable prefix and the SHA-256 of its normalized ID. A
source has one bare mirror; requirement resolution reads its refs and tags.
Exact trees are extracted with Git archive and contain no repository metadata.
Read-only revision inspection uses local Git reads or remote ref advertisements
with the same requirement selection policy, without fetching or populating
caches. Consumers of the same source and revision share a materialized
directory.

`link` points an agent's skill entry at verified cached content. `copy` installs
that content as a directory and rejects links escaping the installed subtree.
Links to content within the same project or user state root are relative, so
moving that root preserves them; external live edit links are absolute. `edit`
points directly at a live local skill without pin or hash and requires a source
without a requirement. Local non-Git directories support edit mode. Git-backed
link and copy operations read committed trees, including when the source has
uncommitted changes.

An update preview or source listing can fetch into a mirror. Inspection
snapshots are disposable and do not move an installed tree or write state or
targets. Skill and instruction `add` discover choices through the read path when
no names or `all` are supplied, and for `listOnly`. Their discovery uses
disposable mirrors and locks, leaving the scope unchanged. Exact cached commits
can be extracted under an existing mirror lock without fetching. Pending
recovery stops selection discovery before source access. An automatic
single-item addition carries the normalized source ID and exact discovered name
into the writer path separately from user-entered names. Rediscovery must match
that identity or fail with an error asking the caller to retry; its content and
pin can refresh. Explicit names and `all` enter the writer path directly.
Applying prepares all selected content, computes differences, stages
replacements, and commits target changes and state under the scope lock.
Combined updates share a source-resolution session and baseline across skills
and instructions. The coordinator merges their owned records and rejects
incompatible source records and overlapping targets before exposing an apply
handle. It holds the writer lock while the consumer renders, revalidates
state-file bytes/presence and target/source identities, then retains pinned
content before the combined journal starts. Live edit content remains live; its
source identity and usable metadata are checked instead of a content pin.

After retention, preconditions are checked again. One transaction queues
physical skill targets, instruction/forwarding targets, changed declaration and
lock files, and pruning against the merged lock and existing watch state. Paths
are sorted within target groups. No-change combined apply returns receipts
without rewriting state. Cancellation before apply publishes no targets, state
or retained trees; fetched mirror objects and the scope container/lock may
remain.

Commit outcome tracking is bound to the combined journal's UUID. Recovering a
separate cache publication cannot claim that the combined generation committed.
An uncertain commit-marker write is classified by validated recovery.
`UpdateApplyError` distinguishes confirmed unchanged and committed generations
from unresolved recovery, including failures during enclosing watch-reference
cleanup. A committed error must not be described as rollback. After process
death the next writer recovers and raises `CoreError.transactionRecovered`;
consumers retry the whole preparation. Previews reject pending recovery without
replay. See [Updates](Updates.md) for the public handle and error contracts.

Pruning participates in that transaction. Pins referenced by skills, instruction
sections or prompt sections remain cached, as do artifact contents referenced by
watch state and trees containing live edit sources. Pruning opens directory
ancestry without following symlinks and uses directory-relative enumeration,
rename and deletion. It rejects symlinked cache containers and never recursively
follows a link during deletion. Mirrors remain available for source history and
future resolution. Watch-owned Git refs retain only revisions still referenced
by watch state or installed pins; obsolete histories can be collected by Git
after those refs are released.

Both doctors inspect cached objects, local Git refs or remote ref advertisements
without fetching or populating caches. Local Git status disables optional locks
to avoid index refresh writes. Skill doctor reports pending recovery as a
`DoctorCheck` with ID `pending-recovery` and warning status. An unresolved
transaction uses `unresolved-transaction` and lists retained recovery locations.
It also reports missing installs, changed content and broken links, newer
matching Git resolutions and uncommitted changes in selected local source paths.
`install` restores all recorded recipients and modes without changing lock
bytes. The consuming CLI controls presentation and user interaction.