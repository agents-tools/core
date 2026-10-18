# Watch Subscriptions

`AgentsCore.WatchOperations` manages subscriptions independently of installation
intent and pins. `agents.json` lists subscribed source aliases in `watch`;
`agents.watch` records a seen baseline per normalized source ID. Subscribing
installs nothing, and removing a subscription preserves source declarations,
skill selections, locked records and installed content.

## Consumer API

Both CLI consumers can construct `SkillOperations.watchOperations()` from
`AgentsSkills`. It supplies the existing skill discovery rules and well-known
loader to `AgentsCore`. Callers implementing another content provider can use
`WatchOperations.init(discoverSkills:fetchArtifacts:)` directly. This keeps
frontmatter, skill discovery and artifact format parsing in their owning module;
core has no dependency on `AgentsSkills`, Yams or instruction rendering.

Every operation accepts `scope` and `RuntimeEnvironment`:

| Operation | Behavior |
| --- | --- |
| `add(_:alias:requirement:path:scope:environment:)` | Resolve an alias or source location, declare it if needed, subscribe and record current content as seen. Returns `WatchSeen`. |
| `status(scope:environment:)` | Return sorted `WatchStatus` values for all subscribed sources. |
| `diff(_:name:kind:scope:environment:)` | Inspect one subscribed source, optionally filtering item name and kind. Returns file bytes and entry metadata for presentation by the caller. |
| `seen(_:revision:scope:environment:)` | Acknowledge the current head or resolve a supplied Git revision to a full commit ID. Well-known sources accept no revision argument. |
| `remove(_:scope:environment:)` | Remove the alias from `watch` and delete its baseline without changing installations. |

Existing subscriptions can be addressed by alias, normalized source ID or source
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
discovery function. Instruction units are Markdown files directly inside
`instructions/` or `.agents/instructions/`, named by their filename stem.
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

Well-known baselines map artifact names to digests. Files artifacts use the
same aggregate digest as the lock: SHA-256 of deterministically encoded file
records sorted by path, including each file's URL and digest. Archive and
Markdown artifacts use their downloaded-byte digest. A changed artifact digest
is reported even when expanded file contents are identical. Expanded baseline
contents remain in the digest-addressed cache while referenced by watch state;
skill lifecycle pruning respects those references.

`StateStore.loadWatch()` reads and validates the baseline. `save` accepts an
optional `watch` value; omitting it preserves existing watch bytes. JSON is
sorted, timestamp-free, UTF-8 without a BOM and newline-terminated. Duplicate
keys, malformed input, unknown non-null fields, unsupported versions and invalid
revisions or digests are errors. Subscriptions cannot repeat an alias.

Watch operations hold the scope file lock. Add and seen prepare cached content
before publishing its baseline. Declaration and watch replacements and cache
pruning commit through the existing scope transaction journal; recovery follows
the same retry contract as other state operations. Every scope operation checks
watch state after transaction recovery, and corrupt watch state blocks mutations
before fetching, cache publication, installation or state replacement.

Status and diff may fetch into mirrors and download current index artifacts for
inspection. They use disposable snapshots and memory, leave retained artifact
content unchanged, and do not write declaration, lock, watch state, installations
or source working trees. Scheduling and diff rendering belong to consumers.
