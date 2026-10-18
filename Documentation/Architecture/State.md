# State and Source Cache

## Scope Locations

| Scope | Declaration | Lock | Watch state | Cache |
| --- | --- | --- | --- | --- |
| Project | `.agent/agents.json` | `.agent/agents.resolved` | `.agent/agents.watch` | `.agent/cache/` |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | `~/.agents/cache/` |

User paths are relative to `RuntimeEnvironment.homeDirectory`. State files belong
to their scope and are local state. `agents.watch` stores subscription baselines
independently of installed pins; [Watch](Watch.md) describes the operations.

## Declaration

`agents.json` records user intent. `agents` defaults to `codex` and
`claude-code`. Source aliases name exactly one `git`, `local` or `well-known`
location, an optional requirement, and an optional search `path`.

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

`instructions` holds recipients, ordered `source:name` section references, and
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
hash. Prompts hold ordered locked sections and optional append paths. Physical
targets record agents, heading offset or import, block hash, and whether the
file was created by the tool. Skill writes retain these records unchanged.
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

Readers and writers serialize through `.agents.lock`. Missing scope and target
ancestry is created with descriptor-relative operations; each parent directory
is fsynced before target mutation, including when an interrupted creator left a
visible directory entry. Empty managed containers can remain after a failed
operation.

A durable `transaction.json` in the scope state directory records target, state
file and pruning replacements before mutation. Paths are relative to named
roots in that scope: `state`, registered agent installation directories, and
registered instruction destinations. Instruction roots permit fixed project
files, configured user files and named Markdown authoring files. The
journal binds the state directory and each used root to its physical location
and filesystem identity. Configured agent containers are resolved at the
registry boundary; recovery opens journal descendants without following links.
Symlinked journals, symlinked descendants, unregistered destinations and journals
copied or moved from another scope location are rejected before replay. All
parents are validated and their directory descriptors retained throughout
recovery. Backup and staging basenames are derived from the transaction ID,
never accepted as arbitrary journal paths.

Backups and staged data are fsynced before applying changes. macOS `fcopyfile`
preserves original bytes, permissions, ACLs and extended attributes in backups
and restores. Data replacements inherit the existing regular file's metadata
from its backup before publication; new files default to `0600`. Final modes
are applied explicitly rather than through the umask.
`renameatx_np(RENAME_SWAP)` atomically exchanges existing directories, files and
links with their replacements; installations always retain a directory entry.
Discarding transaction-owned trees grants owner access through pinned directory
descriptors so read-only backups and staging can be removed. This never changes
the metadata of the installed or restored tree, nor of a backup still needed
for rollback; symbolic links are unlinked without following their destinations.

After a process kill or power loss at any point, the next state access recovers
one consistent generation of targets, declaration, lock, watch state and cache references.
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
cleanup, so the next access repeats reconciliation against the recovered state;
refs needed for rollback remain until that state is durable.

Mirrors are exclusively owned by agents. Each mirror has a per-source lock at
`cache/locks/<source-key>.lock`, created before cloning or first access. All
mirror reads and writes take this lock, including instruction listings and
cached revision inspection. Scope mutations take the scope lock first, then
the mirror lock; mirror access never acquires the scope lock in reverse order.
An instruction listing can therefore populate a mirror before `.agents.lock`
exists while still excluding concurrent recovery and watch mutations.

Git children explicitly inherit the mirror lock descriptor through spawn file
actions; unrelated descriptors remain closed. The parent closes its descriptor
without explicitly unlocking the shared open file description. If the Swift
parent is killed, a surviving Git child keeps the mirror locked until it exits.
Git automatic maintenance is disabled. Recovery must acquire this same mirror
lock before classifying Git `*.lock` files (including `packed-refs.lock`) and
the root `packed-refs.new` staging file as abandoned. Within each mirror it
validates all candidates as regular files through directory descriptors,
without following symlinks, before deleting any candidate. It syncs lock-file
deletions before retrying Git; the pending marker also covers interruption of
this cleanup. Live mirror users and surviving Git children block recovery, so
their Git locks and refs cannot be removed or recreated beneath them.

Each state operation first checks for an abandoned journal under the scope
lock, then validates watch state and finishes pending ref cleanup before
proceeding. An applying journal rolls back every replacement, including watch
baselines; a committed journal
finishes cleanup. Recovery is repeatable if interrupted. Before deleting any
recovery material, both the terminal journal file and its parent directory are
fsynced, even when that phase was already visible on entry. State and backup
files and their parent directories are synced before publishing the terminal
phase. Replayed deletions sync their own parent directories even when the entry
is already absent; a visible unlink alone does not establish durability on that
target's volume. On macOS these barriers also use `F_FULLFSYNC` to request a
storage flush.

Recovery throws `CoreError.transactionRecovered` after completing, reporting
the scope and asking the caller to retry against the recovered generation.
This includes recovery of pending watch refs even when no journal remains.
Skill inventory, previews and doctor also recover. Instruction read operations
instead take an existing shared lock and report pending recovery without
replaying it, so explicit multi-root instruction audits never write. Corrupt
journals stop the operation without guessing a recovery plan. Tests interrupt writers between
rename and parent fsync, interrupt rollback and terminal cleanup, and verify
that a competing reader waits for the recovering process's lock.

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

An update preview, source inspection or diagnostic can fetch into a mirror.
Inspection snapshots are disposable and do not move an installed tree or write
state or targets. Applying prepares all selected content, computes differences,
stages replacements, and commits target changes and state under the scope lock.
Pruning participates in that transaction. Pins referenced by skills, instruction
sections or prompt sections remain cached, as do artifact contents referenced
by watch state and trees containing live edit sources. Pruning opens directory
ancestry without following symlinks and uses
directory-relative enumeration, rename and deletion. It rejects symlinked cache
containers and never recursively follows a link during cleanup.
Mirrors remain available for source history and future resolution. Watch-owned
Git refs retain only revisions still referenced by watch state or installed
pins; obsolete histories can be collected by Git after those refs are released.

Doctor reports missing installs, changed content and broken links, newer
matching Git resolutions, and uncommitted changes in selected local source
paths. `install` restores all recorded recipients and modes without changing
lock bytes. The consuming CLI controls presentation and user interaction.
