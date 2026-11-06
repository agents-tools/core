# Watch Subscriptions

`AgentsCore.WatchOperations` manages subscriptions independently of installation
intent and pins. `Agents.swift` lists subscribed source aliases in the `watch:`
argument of `Agents(...)`; `agents.watch` records a seen baseline per normalized
source ID. Subscribing
installs nothing, and removing a subscription preserves source declarations,
skill selections, locked records and installed content.

## Consumer API

Both CLI consumers can construct `SkillOperations.watchOperations()` from
`AgentsSkills`. It supplies the existing skill discovery rules and well-known
loader to `AgentsCore`. Callers implementing another content provider can use
`WatchOperations.init(discoverSkills:fetchArtifacts:)` after `import
AgentsManifest`; that module provides the initializer because it also supplies
the declaration access that core receives by injection. This keeps frontmatter,
skill discovery, artifact format parsing and manifest syntax in their owning
modules; core has no dependency on `AgentsManifest`, `AgentsSkills`, Yams or
instruction rendering.

Every operation accepts `scope` and `RuntimeEnvironment`:

| Operation | Behavior |
| --- | --- |
| `add(_:alias:requirement:path:scope:environment:)` | Resolve an alias or source location, declare it if needed, subscribe and record current content as seen. Returns `WatchChange`. |
| `status(scope:environment:)` | Return sorted `WatchStatus` values for all subscribed sources. |
| `diff(_:name:kind:scope:environment:)` | Inspect one subscribed source, optionally filtering item name and kind. Returns file bytes and entry metadata for presentation by the caller. |
| `seen(_:revision:scope:environment:)` | Acknowledge the current head or resolve a supplied Git revision to a full commit ID. Well-known sources accept no revision argument. Returns `WatchChange`. |
| `remove(_:scope:environment:)` | Remove the alias from `watch` and delete its baseline without changing installations. Returns `WatchChange` without a baseline. |

`WatchChange` has `alias`, the normalized `sourceID` and `seen`, the
acknowledged `WatchSeen` baseline or `nil` after removal, so callers need no
separate declaration read. Existing
subscriptions can be addressed by alias, normalized source ID or source
location. Repeating `add` records current content as seen. Missing subscriptions,
invalid revisions and missing baseline content produce errors. A local directory
must be a Git repository to be subscribed.

`WatchStatus` contains the alias, source ID, seen and current baselines, commit
count for Git, and changed items. `WatchItemChange` identifies `skill`,
`instructions` or well-known `artifact`, with `new`, `changed` or `removed`
status, paths or digests, and a file count. File changes retain before/after
bytes, executable mode, symbolic link destinations and empty directories.
Unchanged items are omitted. A name can exist in both skills and instructions;
the optional kind filter disambiguates it.

Git comparisons discover skills in disposable snapshots through the supplied
discovery function. Instruction units are Markdown files below
`instructions/` or `.agents/instructions/`, subdirectories included, named by
their container-relative path without `.md`.
The declared search path applies to both. Duplicate instruction names are an
error. Watch compares source bytes without validating, rendering or installing
instruction sections. Uncommitted working-tree content is ignored.

## Baselines and Storage

```json
{
  "version": 1,
  "sources": {
    "github.com/example/skills": { "seen": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" },
    "https://example.com": { "seen": { "demo": "sha256:…" } }
  }
}
```

Git subscriptions follow the declared branch when present, otherwise the
source's default branch. Installation version and revision requirements do not
select the watched head. Commit count is the number of commits reachable from
the current head but not the seen revision, including after divergent history.
Acknowledged commits and their mirror refs are made durable before watch state
is committed. Per-invocation Git fsync options cover objects and references
without rewriting configuration; symlinked mirror configurations are rejected
before invoking Git. Explicit barriers also flush existing objects and parent
directory entries.
Force-pushes and Git garbage collection cannot discard seen content. After a
durable acknowledgment or removal, obsolete watch-owned refs are released unless
an installed skill, instruction section or prompt section still pins that
revision. A durable pending marker makes ref cleanup repeatable after an
interruption, following journal recovery so rollback baselines stay reachable.
Mirrors remain available for source history and future resolution; Git may
collect histories after their last retention ref is released.

Mirrors are exclusively owned by agents. Each source has a lock at
`cache/locks/<source-key>.lock`, created before its mirror's first use. Every
mirror operation holds that lock, including cloning, fetching, listing,
cached revision inspection, extraction, retention and recovery. State mutations
acquire the scope lock before the mirror lock; inspection can use the mirror
lock even when no scope lock file exists.

Git children explicitly inherit a duplicate of the mirror lock's descriptor
above the standard streams, so redirecting output cannot replace the lock even
when the host has closed stdout or stderr. Closing the parent's descriptor does
not unlock the shared open file description, so a
surviving Git child continues excluding recovery after its Swift parent is
killed. Git automatic maintenance is disabled. Recovery acquires the same
mirror lock before treating `*.lock` files, including `packed-refs.lock`, and
the root `packed-refs.new` staging file as abandoned. It validates each mirror's
candidates as regular files through contained directory ancestry without
following symlinks, durably removes them, then retries ref cleanup. The pending
marker makes interrupted lock removal repeatable. Live listings and Git
children keep recovery waiting until their mirror access ends.

Well-known baselines map artifact names to digests. Files artifacts use the
same aggregate digest as the lock: SHA-256 of deterministically encoded file
records sorted by path, including each file's URL and digest. Archive and
Markdown artifacts use their downloaded-byte digest. A changed artifact digest
is reported even when expanded file contents are identical. Expanded baseline
contents remain in the digest-addressed cache while referenced by watch state;
skill lifecycle pruning respects those references.

`StateStore.loadWatch()` reads and validates the baseline without recovery or
writes. Writes that do not replace watch state preserve its bytes. JSON is
sorted, timestamp-free, UTF-8 without a BOM and newline-terminated. Duplicate
keys, malformed input, unknown non-null fields, unsupported versions and invalid
revisions or digests are errors. Subscriptions cannot repeat an alias.

Add, seen and remove hold the scope writer lock and recover interrupted
transactions and pending ref cleanup before proceeding. They capture declaration,
lock and watch evidence before contacting Git. Add and remove plan the
`Agents.swift` change at that point, so a declaration the editor cannot change
fails before any fetch; seen leaves the declaration unchanged. Add and seen
prepare cached content before publishing its baseline. Declaration and watch
replacements and cache pruning commit through the existing scope transaction
journal, expecting the captured evidence; recovery follows the same retry
contract as other mutating state operations. Every scope
mutation checks watch state after transaction recovery, and corrupt watch state
blocks mutations before fetching, cache publication, installation or state
replacement.

Status and diff take an existing shared scope lock without creating state files
or replaying recovery. When a first writer creates the scope lock during an
unlocked read, inspection discards that attempt, including any error, and
retries under the shared lock. A pending transaction journal or watch-ref
cleanup marker fails inspection with `CoreError.recoveryPending`. Inspection
leaves pending cleanup and retained refs untouched for the next mutating
operation to recover. Status and diff may fetch into mirrors under each mirror's
lock and download current index artifacts for inspection. They use disposable
snapshots and memory, leave retained artifact content unchanged, and do not
write declaration, lock, watch state, installations or source working trees.
Scheduling and diff rendering belong to consumers.
