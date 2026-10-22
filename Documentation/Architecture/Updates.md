# Combined Updates

`AgentsUpdates` composes the skill and instruction planners for one project or
user scope. It updates all declared skills, instruction recipients and named
ChatGPT prompts. Named skill selection and instruction recipient overrides
belong to the standalone APIs. Consumers own rendering and completion output.

## Reports and Preparation

`UpdateOperations.preview(scope:environment:)` returns `CombinedUpdateReport`
under one existing shared scope lock. It never returns an applicable handle,
retains source trees, writes state or replays recovery. Mirror fetching and
disposable snapshots are allowed. If a first writer appears during an
unprotected inspection, the result or error is discarded and inspection
retries under the shared lock.

`UpdateOperations.withPreparedUpdate(scope:environment:_:)` acquires the
writer lock, recovers pending work before reading the baseline, and prepares
both kinds before calling the consumer. Shared pinned sources use one exact
snapshot per normalized identity and effective declaration, so source movement
between domain planners cannot produce different pins for the same source.
Independent sources are not promised a simultaneous upstream snapshot.

The combined lock takes skills from the skill plan and instruction records
from the instruction plan. It merges compatible source updates and retained
baseline records, preserves declaration and watch data, and validates the
complete prospective state. Applying preparation checks ownership and physical
path collisions before the closure. Preview can report prospective membership
that an applying preparation rejects as unmanaged.

The report contains `scope`, `skills`, `instructions`, `lockMissing` and
`hasChanges`. The last includes normalized lock changes, physical differences
and required missing-lock reconstruction. An empty unconfigured scope is
unchanged. Section ordering and identical-content prompt repins can require
application even without changed target bytes or changed prompt names.

Skill results expose old/new versions from the resolved records, full revisions
and hashes. Versions remain nil for absent sides, edit installations,
well-known artifacts and Git resolutions without a selected version tag.
`SkillFileEntry.file(Data, executable: Bool)` uses the same any-execute-bit rule
as watch. Directories and links keep their own entry types; a symlink's mode is
not its destination's mode. Persistent content hashes do not include mode.

Each result's `membership` has one `SkillMembershipChange` per agent in the
union of previous and prospective installations, sorted by agent raw value.
`SkillMembership` is `.absent` or `.installed(mode:)`. These are managed
membership states, independent of physical presence. Rows use physical paths
with resolved parents and unfollowed final entries. Agents sharing a path
retain separate rows while physical changes remain deduplicated. Unchanged
results include membership too; `installed` retains its post-apply meaning.

A missing `agents.resolved` makes the before membership unrecorded and
`lockMissing` true. A correct existing live link can therefore have added
membership and no physical diff. It still fails applying preparation's
unmanaged-content guard. A locked but missing target remains installed on the
before side. If both record and selection are lost, no removal is invented.
Loss of resolved state is distinct from replacing the never-removed writer
lock file.

## Handle Lifetime and Application

The closure receives a `PreparedUpdate` with a report and `apply()`. The handle
has no public initializer, serialization or `Sendable` conformance. Its
internal plan is separate from the report. Any apply attempt consumes it;
inactive, repeated or wrong-thread use fails before I/O. Closure exit
invalidates retained handles and releases their disposable planning resources.

The writer lock remains held through preparation, rendering and apply. The
closure must stay synchronous on its preparing thread and must not re-enter
scope operations, await work, or dispatch the handle. In particular, reading
a separate output inventory can deadlock. Render the supplied report and
apply or return. An interactive pause holds off other scope users; a UI that
needs a long pause should preview first and prepare/display a fresh plan when
ready to apply.

Returning or throwing before apply cancels without publishing targets, state
or retained content. A caller error after successful apply does not undo it.
Applying revalidates declaration/resolved/watch bytes and presence, target
entries, execute flags, links, path ancestry, instruction bytes and forwarding
decision inputs. Live source identities and usable skill metadata are checked;
their contents remain live. Pinned content is retained and verified, then
preconditions are rechecked before one transaction stages both kinds, changed
state and pruning. Copy staging and pinned-link destinations are verified
against prepared bytes and execute flags before publication.

`UpdateApplyResult` contains the rendered `report` and `installedSkills`
receipts. A no-change apply returns receipts without rewriting state.
Standalone skill and instruction updates use the same domain planners and
staging functions, with their existing callback signatures and domain isolation.

## Failure and Recovery

Handle misuse throws `CoreError.invalidState` before I/O. Failures during plan
validation or application throw `UpdateApplyError`, preserving
`underlyingError` and an `UpdateApplyDisposition`:

| Disposition | Established result |
| --- | --- |
| `unchanged` | No combined target/state publication, or validated rollback |
| `committed` | The new combined generation is confirmed; a later failure still makes the operation fail |
| `recoveryRequired` | Recovery could not establish a consistent completed generation |

Errors before preparation finishes and caller errors retain their original
types. A commit error does not itself imply rollback: publication of the
committed marker can precede a cleanup error. Outcome tracking follows the
owning journal through validated recovery, including enclosing scope cleanup,
and does not infer disposition from journal-file presence. Cache-only
publication journals cannot claim the combined update committed.

The next applying operation recovers an abandoned transaction and raises
`CoreError.transactionRecovered`. Consumers retry the entire preparation and
render its fresh report. Read-only preview rejects pending recovery. The
existing journal, descriptor-relative path checks, metadata preservation and
fsync barriers supply the durability guarantees described in [State](State.md).
The lock remains advisory: preconditions detect changes made while rendering
but do not provide compare-and-swap against editors racing the final check.

## Consumer Example

```swift
import AgentsUpdates

let receipt = try UpdateOperations.withPreparedUpdate { update in
  render(update.report)
  return try update.apply()
}
renderCompletion(receipt)
```

`render` and `renderCompletion` are consumer-owned functions. Consumers should
render the combined report once before applying, use `hasChanges` for the
no-change decision, and report completion only after the closure returns.
Serialized reports are presentation values, not offline approval tokens.
