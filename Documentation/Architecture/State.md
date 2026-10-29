# State and Source Cache

## Scope Locations

| Scope | Declaration | Lock | Watch state | Cache |
| --- | --- | --- | --- | --- |
| Project | `.agent/agents.json` | `.agent/agents.resolved` | `.agent/agents.watch` | `.agent/cache/` |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | `~/.agents/cache/` |

User paths are relative to `RuntimeEnvironment.homeDirectory`. State files belong
to their scope. A project may commit its declaration and lock; the cache, the
writer lock and the journal stay local. `agents.watch` stores subscription baselines
independently of installed pins; [Watch](Watch.md) describes the operations.

## Declaration

`agents.json` records user intent. `agents` defaults to `codex` and
`claude-code`. Source aliases name exactly one `git`, `local` or `well-known`
location, an optional requirement, and an optional search `path`. A source added
by location keeps the alias already declaring it, or receives its location's last
path component; while another source holds that name, preceding components are
prefixed (`anthropics-skills`), then a number is appended. `sources` may be
omitted.

`agents.json` and `agents.resolved` are written with sorted keys in Prettier's
default JSON layout: two-space indentation, `"key": value`, every non-empty
object expanded, empty containers as `{}` and `[]`, and an array without objects
on one line when it fits in 80 columns. A repository whose Prettier
configuration uses another print width may lay out an array between the two
widths differently. An operation that writes state rewrites either file when
its bytes differ from that layout, even when its content is unchanged. Empty
lock sections such as `"skills": {}` remain, because earlier readers require
them. Journals, `agents.watch` and content hashes keep the encoder's fixed
layout.

```json
{
  "agents": ["codex", "claude-code"],
  "sources": {
    "team": { "git": "github.com/example/skills", "from": "1.0.0" },
    "drafts": { "local": "~/Developer/skills" }
  },
  "skills": {
    "team": { "select": "all", "exclude": ["retired"] },
    "drafts": {
      "select": ["release-notes"],
      "mode": "edit",
      "overrides": { "release-notes": { "agents": ["codex"] } }
    }
  }
}
```

A skill selection is `"all"` or a name array, with optional exclusions,
recipients, mode and per-skill overrides. `all` follows discovery membership on
an unnamed update. Removing a member adds an exclusion. Explicitly named
updates resolve only those members and fail if a requested member is missing.
Skill filesystem identities are unique within a scope across sources.

Requirements encode as `branch`, `revision`, `exact`, `from`, `upToNextMinor`,
or `from` plus `to`. Ranges include their lower bound and exclude their upper
bound. A prerelease requires a prerelease bound with the same major, minor and
patch. With no requirement, resolution chooses the latest semantic-version tag,
then the source's default branch when no version tag exists.

Source IDs are Git `host[:port]/path` with a lowercase host and without user,
scheme or `.git`; `local:` plus an absolute path; or a well-known URL retaining
its scheme. Declaring two aliases for one normalized ID is an error.

`instructions` holds recipients, ordered section references (`alias:name`, or a
bare name for the project's own instructions), and
named `chatgpt` prompts with ordered sections and optional relative `append`
paths. `watch` is a unique alias array. Skill operations preserve both fields
and existing watch-state bytes.

## Lock

`agents.resolved` version 1 has identity-keyed `sources` and `skills`, and an
`instructions` object containing `sections`, `chatgpt` and `targets`.

A locked source records its kind, Git URL where applicable, requirement and
search path. A skill records its source ID, its own revision and optional
version, relative directory path, content hash and `installs` mapping agent IDs
to `link`, `copy` or `edit`. Every non-edit item carries an immutable pin.
Updating one skill leaves other item pins unchanged.

Well-known items record an artifact's `type`, `url` and SHA-256 `digest`.
`files` artifacts additionally record every file's URL, path and digest. Their
aggregate digest covers the sorted, deterministically encoded file records.
Restoration reads these recorded URLs or verified digest cache entries and
never reads an index. Missing pins or mismatched content stop restoration.

Instruction section records carry name, source, revision or artifact, path and
hash; a project's own files use source `.`, their project-relative path and hash,
and no revision. Prompts hold ordered locked sections and optional append paths.
Physical targets record agents, heading offset 0 or import, the hash of the
generated file or import block, and `created`, which unit targets always record
as false. Skill writes retain these records unchanged.
Instruction lifecycle writes preserve skill records. Target keys are project
relative or user-home relative; configured user files outside home use absolute
keys checked against the runtime's registered instruction locations.

Maps are key sorted. Unordered selections and agent lists are sorted; section
arrays and each prompt's section order are preserved. Files have a trailing
newline and no timestamps. State and journal JSON must be UTF-8 without a byte
order mark; validation consumes the entire document. Other encodings, invalid
state, duplicate JSON keys at any depth and
fields that would be discarded by decoding cause an error. Tree hashes use
length-prefixed paths and typed entry payloads, including empty
directories and symbolic link destinations.

Tree hashes intentionally exclude permissions. Skill update snapshots compare
the any-execute-bit Boolean separately for regular files. Preparation,
retention and transaction staging verify that dimension without changing
stored hashes, pins or the version 1 declaration, lock and watch schemas.

## State Transaction and Recovery

The scope's existing `transaction.json` is the sole persistent transaction owner
for target changes, declaration, lock, watch state, cache publication and pruning.
The protocol accepts regular files, directories and symbolic links independently
of the declaration format. Declaration and lock retain their state encoders;
watch state retains its fixed encoder.

### Preparation and preconditions

Prepare records presence, physical identity and content digest for declaration,
lock, watch state and affected targets. `UpdatePreconditions` binds final entries
and existing ancestry; state snapshots also record bytes through their digest.
Skill and instruction plans validate source snapshots, target content and
executable flags. The scope writer lock covers recovery, preparation, retention
and publication. Recovery runs first. Apply re-reads preparation conditions before
retention and again immediately before publication, including after transaction
staging. Any changed bytes, including declaration whitespace or comments in a
rendered target, or another inode with equal bytes invalidates that preparation.
Apply requires a newly prepared plan rather than rebasing an old edit.

Readers and writers serialize through `.agents.lock`. Missing scope and target
ancestry is created with descriptor-relative operations; each parent directory
is fsynced before target mutation, including when an interrupted creator left a
visible directory entry. Empty managed containers can remain after a failed
operation.

Managed directories are created with mode 0700 and files/locks with mode 0600.
Directory permissions, inherited/default ACLs and other filesystem policy must
allow the owner to use newly created entries. Core checks access without changing
that policy. Permission denial stops the operation with the affected path and a
message to check directory permissions and default ACLs; retries remain denied
until the environment is corrected. This is a filesystem requirement, not a
transaction recovery case. Existing user content and metadata are preserved.

Journal paths are relative to named roots in that scope: `state`, registered
agent installation directories and registered instruction destinations.
Instruction roots permit fixed project files, configured user files and named
Markdown files in the project's own instructions container. The journal binds the
state directory, each used root and every destination parent to its physical
location and filesystem identity. Configured agent containers resolve at the
registry boundary; descendants open without following links. Symlinked journals,
symlinked descendants, unregistered destinations, overlapping targets and journals
copied or moved from another location are rejected before replay. Directory
descriptors remain pinned. Recovery names derive from the transaction UUID and
entry index, never from arbitrary paths in journal input.

Each operation records its expected presence and preimage, staged object and
intended postimage before publication. Object evidence includes device, inode,
entry type, SHA-256 digest and executable status; directory snapshots include
child identities and digests. Staging and extraction scratch have recorded
ownership and are sealed before publication. The journal records per-operation
`queued`, `verifying`, `ready`, `publishing`, `applied`, `restoring`, `restored` or `cancelled`
progress, plus cleanup evidence and unresolved conflicts. File contents,
metadata, read preimages, journal records and parent directories are synchronized
in dependency order. Data replacements inherit the existing regular file's metadata. Copies
preserve modes, ACLs and extended attributes on macOS and Linux; rollback restores
the retained original object and its metadata.

### Publication and concurrent writers

Before changing any destination, capability checks require atomic exchange and
atomic no-replace rename. Filesystem probes use recorded private objects within
the same journal; unsupported primitives fail before any destination publication.
There is no replacing-rename fallback for managed destinations, including newly
created declaration, lock and watch files.

| Expected destination | Publication |
| --- | --- |
| Absent | Persist staging identity and digest, then publish with `renameat2(RENAME_NOREPLACE)` on Linux or `renameatx_np(RENAME_EXCL)` on macOS. An existence conflict preserves the concurrent creator's bytes and inode. |
| Existing | Revalidate the exact read preimage and atomically exchange it with staging. Retain the displaced object, read and compare its identity and digest, and retain it as the rollback preimage. Unexpected content is a conflict preimage and cannot count as a successful replacement. |
| Deletion | Revalidate the preimage and move it without replacement into the journal's unique quarantine. Verify the quarantined object's identity and digest before confirming the operation or disposing of it. |

Publication intent is durable before the atomic operation. The destination parent
is synchronized before `applied` is persisted. The retained preimage and the
published object must both match before a replacement is confirmed. Every
postimage is checked again before the commit marker. The scope lock excludes
cooperating writers; these publication checks also preserve objects changed by
editors that ignore the lock.

### Recovery outcomes

An applying journal reverses verified publications in reverse order. A committed
journal completes terminal cleanup. Recovery uses recorded physical identity and
digest, including when a process died between rename and recording `applied`.
Another inode with identical bytes remains external. Missing or changed evidence
leaves an unresolved conflict rather than establishing ownership by name or
content equality. Other verified operations can roll back while conflicted
objects and their journal remain available for owner resolution.

Replacement rollback exchanges the retained preimage only with the verified
transaction-owned postimage and verifies the displaced object again. If an
external writer changes the destination before or during restoration, both
available versions remain and recovery stops. Deletion restoration uses atomic
no-replace rename; an occupied original name remains untouched. Creation rollback
moves only the verified published object into quarantine and verifies it there;
it never unlinks an external creator's object. A reverse rename is synchronized
even when a retry recognizes that it already happened.

Before deleting staging, probes, scratch or preimages, the journal persists a
terminal `committed` or `rolledBack` phase with each disposal object's identity
and digest. The observed terminal journal and its parent are synchronized even
when the phase was already visible on entry. Per-entry discard intent is durable
before deletion. Cleanup verifies ownership, records descendant evidence and
accepts only already removed descendants on retry; changed or newly introduced
objects remain conflicts. Discarded directories may receive owner access through
pinned descriptors without changing the installed or restored tree's metadata.
Symbolic links are removed without following their destinations. Parent deletion
barriers also run for already absent entries. On macOS synchronization also uses
`F_FULLFSYNC` to request a storage flush.

Recovery is repeatable across interruption. The next recovering state access
reports `CoreError.transactionRecovered` after it establishes a consistent
generation; callers retry the whole preparation. Outcome tracking belongs to the
transaction UUID: recovering a cache publication cannot mark a later combined
update committed. Failures distinguish confirmed unchanged, confirmed committed
and unresolved recovery. A commit marker alone does not establish successful
cleanup: changed recovery evidence after that marker reports unresolved recovery
and retains the journal and remaining recovery material. A committed failure
must not be described as rollback.

### Read-only access

Non-applying skill and instruction operations, listings, previews, watch status
and watch diff take an existing shared lock, report pending recovery and never
replay it or create state files. When the lock is absent, inspection reads and
then checks for a newly created lock or recovery marker before returning either
its result or its error. If a writer appeared, inspection discards that attempt
and retries under the shared lock. Writers create the scope lock before mutation
and never remove it. Pending journals and watch-reference cleanup markers cause
`CoreError.invalidState`; doctor reports one pending-recovery diagnostic per
affected scope and skips checks requiring a consistent generation. Explicit
multi-root instruction audits never write. Corrupt journals stop recovery without
guessing a plan.

### Watch references and mirror locks

Mirror Git invocations pass `-c core.fsync=objects,reference,pack-metadata` and
`-c core.fsyncMethod=fsync`; durability settings never rewrite configuration.
Mirror configuration must be a regular file, checked before invoking Git.
Before a Git acknowledgment publishes watch state, existing object bytes and
object directory entries are flushed as well. The retained ref, its parent,
Git config and HEAD, and mirror/cache directory entries are synced before the
scope journal can commit the baseline. This orders durable Git content before
the durable watch reference; power loss cannot publish a baseline ahead of its
retained content.

Before preparing a watch ref or changing watch/lock pins, the scope writes and
syncs `watch-refs.pending`. Under the scope lock, reconciliation runs only after
the transaction has committed or journal recovery has selected and synced a
consistent generation. It removes only `refs/agents-watch/<revision>` refs no
longer named by watch state, skills, instruction sections or prompt sections.
Loose-ref parents and packed refs are synced before the pending marker is
removed and its parent synced. The marker survives interrupted preparation or
cleanup, so the next mutating access repeats reconciliation against the recovered
state; refs needed for rollback remain until that state is durable.

Mirrors are exclusively owned by agents. Each mirror has a per-source lock at
`cache/locks/<source-key>.lock`, created before cloning or first access. All
mirror reads and writes take this lock, including instruction listings and
cached revision inspection. Doctor uses only existing mirror locks; when one is
absent, cached revision inspection falls back to remote refs without creating it.
Scope mutations take the scope lock first, then the mirror lock; mirror access never acquires the scope lock in reverse order.
An instruction listing can therefore populate a mirror before `.agents.lock`
exists while still excluding concurrent recovery and watch mutations.

Git children explicitly inherit a duplicate of the mirror lock descriptor
allocated at 3 or above with `F_DUPFD_CLOEXEC`. Spawn file actions inherit that
duplicate without changing the parent's close-on-exec flags. Output pipe sources
also use descriptors above the standard streams before redirection; closed stdin
is connected to `/dev/null` in the child. Unrelated descriptors remain closed,
and the parent closes the temporary duplicates immediately after spawning.
The parent closes its lock descriptor without explicitly unlocking the shared
open file description. If the Swift
parent is killed, a surviving Git child keeps the mirror locked until it exits.
Git automatic maintenance is disabled. Recovery must acquire this same mirror
lock before classifying Git `*.lock` files (including `packed-refs.lock`) and
the root `packed-refs.new` staging file as abandoned. Within each mirror it
validates all candidates as regular files through directory descriptors,
without following symlinks, before deleting any candidate. It syncs lock-file
deletions before retrying Git; the pending marker also covers interruption of
this cleanup. Live mirror users and surviving Git children block recovery, so
their Git locks and refs cannot be removed or recreated beneath them.

Git runs with terminal and Git Credential Manager prompting disabled while
preserving the rest of the inherited environment. Failures identify the action
and source location rather than its mirror, staging or extraction paths; see
[process execution and errors](Package.md#process-execution-and-errors) for the
consumer error contract.

Each mutating state operation checks for an abandoned journal under the scope
lock, validates watch state and finishes pending reference cleanup before
proceeding. Recovery of pending watch references also reports
`CoreError.transactionRecovered` when no journal remains. Retained refs remain
available while any journal conflict is unresolved.

## Materialization and Installation

Git materializations, downloaded artifact bytes and expanded artifact trees use
private journal-owned staging. Exact Git commits are extracted there; expanded
artifacts are checked against their locked tree hash. Copied trees are hashed
through pinned directory descriptors and verified before publication. Files,
metadata and directory entries are synced before atomic publication of the
final cache name. Git extraction scratch also belongs to the journal, so
recovery cleans an incomplete copy or extraction without retaining a partial
final directory just because the lock references its pin. Cache publication
completes before the installation transaction references that content.

Each scope's cache contains:

```text
cache/
  mirrors/<source-key>.git/
  materialized/<source-key>/<full-revision>/
  artifacts/<sha256-hex>
  artifact-content/<sha256-hex>/
  locks/
```

A source key combines a readable prefix and the SHA-256 of its normalized ID.
A source has one bare mirror; requirement resolution reads its refs and tags.
Exact trees are extracted with Git archive and contain no repository metadata.
Read-only revision inspection uses local Git reads or remote ref advertisements
with the same requirement selection policy, without fetching or populating caches.
Consumers of the same source and revision share a materialized directory.

`link` points an agent's skill entry at verified cached content. `copy` installs
that content as a directory and rejects links escaping the installed subtree.
Links to content within the same project or user state root are relative, so
moving that root preserves them; external live edit links are absolute.
`edit` points directly at a live local skill
without pin or hash and requires a source without a requirement. Local
non-Git directories support edit mode. Git-backed link and copy operations read
committed trees, including when the source has uncommitted changes.

An update preview or source listing can fetch into a mirror.
Inspection snapshots are disposable and do not move an installed tree or write
state or targets. Skill and instruction `add` discover choices through the read
path when no names or `all` are supplied, and for `listOnly`. Their discovery
uses disposable mirrors and locks, leaving the scope unchanged. Exact cached
commits can be extracted under an existing mirror lock without fetching. Pending
recovery stops selection discovery before source access. An automatic single-item
addition carries the normalized source ID and exact discovered name into the
writer path separately from user-entered names. Rediscovery must match that
identity or fail with an error asking the caller to retry; its content and pin
can refresh. Explicit names and `all` enter the writer path directly.
Applying prepares all selected content, computes differences,
stages replacements, and commits target changes and state under the scope lock.
Combined updates share a source-resolution session and baseline across skills
and instructions. The coordinator merges their owned records and rejects
incompatible source records and overlapping targets before exposing an apply
handle. It holds the writer lock while the consumer renders, revalidates
state-file bytes/presence and target/source identities, then retains pinned
content before the combined journal starts. Live edit content remains live;
its source identity and usable metadata are checked instead of a content pin.

After retention, preconditions are checked again. One transaction queues
physical skill targets, instruction/forwarding targets, changed declaration
and lock files, and pruning against the merged lock and existing watch state.
Paths are sorted within target groups. No-change combined apply returns
receipts without rewriting state. Cancellation before apply publishes no
targets, state or retained trees; fetched mirror objects and the scope
container/lock may remain.

Commit outcome tracking is bound to the combined journal's UUID. Recovering
a separate cache publication cannot claim that the combined generation
committed. An uncertain commit-marker write is classified by validated
recovery. `UpdateApplyError` distinguishes confirmed unchanged and committed
generations from unresolved recovery, including failures during enclosing
watch-reference cleanup. A committed error must not be described as rollback.
After process death the next writer recovers and raises
`CoreError.transactionRecovered`; consumers retry the whole preparation.
Previews reject pending recovery without replay. See [Updates](Updates.md)
for the public handle and error contracts.

Pruning participates in that transaction. Pins referenced by skills, instruction
sections or prompt sections remain cached, as do artifact contents referenced
by watch state and trees containing live edit sources. Pruning opens directory
ancestry without following symlinks and uses
directory-relative enumeration, rename and deletion. It rejects symlinked cache
containers and never recursively follows a link during cleanup.
Mirrors remain available for source history and future resolution. Watch-owned
Git refs retain only revisions still referenced by watch state or installed
pins; obsolete histories can be collected by Git after those refs are released.

Both doctors inspect cached objects, local Git refs or remote ref advertisements
without fetching or populating caches. Local Git status disables optional locks
to avoid index refresh writes. Skill doctor reports pending recovery as a
`DoctorCheck` with ID `pending-recovery` and warning status. It also reports
missing installs, changed content and broken links, newer matching Git resolutions, and uncommitted changes in selected local source
paths. `install` restores all recorded recipients and modes without changing
lock bytes. The consuming CLI controls presentation and user interaction.
