# Configuration Lifecycle

`AgentsUpdates` owns configuration update, declaration edit, removal and locked
restore for one project or user scope. It composes the complete YAML declaration,
linked source graph, resolved ledger, domain rendering and native regional edits.
Consumers own command parsing, presentation and completion output.

## Requests and Reports

`UpdateRequest.operation` selects source update, locked restore, typed YAML edits,
a complete declaration replacement, or removal. `kinds` restricts the component
domains and `names` restricts members. A restricted operation protects the other
recorded components' pins, payloads, resources and effective recipients. A change
that requires a wider operation reports `requiresCombinedUpdate` before publishing.
Producer-owned children cannot be edited as consumer declarations; their diagnostic
identifies the producer and group reference. Root occurrence edits use
`ManifestEdit` and digest-scoped document handles.

`UpdateOperations.preview(_:scope:environment:)` returns a serializable
`CombinedUpdateReport`. It uses existing shared locks and never creates persistent
scope, cache or native coordination locks, changes refs, retains content, recovers a
journal, invokes a binding provider or runs source programs. Existing exact cached
objects may be read under their existing locks. Missing objects, downloads,
extraction and their locks remain temporary and are cleaned on success, failure
and cancellation. A first writer invalidates an unlocked inspection attempt.

Reports include skill membership and typed file differences, instruction targets
and prompts, selected native changes, missing-lock status, `hasChanges` and a
`displayedFingerprint`. Native reports contain the owned symbolic values; complete
shared documents, unrelated siblings, runtime secret values and private freshness
evidence remain internal. Equal unmanaged values do not establish ownership.
`hasChanges` includes declaration and ledger changes even when target bytes agree.

The versioned display fingerprint covers the operation and selection, complete
candidate declaration and ledger, exact pins, resources, locked renderer/layout,
ownership, actual destinations and stable access semantics. It excludes temporary
paths and inodes, random IDs, timestamps, runtime secret values and complete native
preimage digests. Repeated preparation of the same candidate and environment has
the same fingerprint. This is a presentation comparison, not an authorization token.

## Preparation and Application

`withPreparedUpdate(_:scope:environment:_:)` acquires the request and pending-journal
footprint before the scope writer lock. Source linking can discover a larger
footprint; preparation releases the locks and readmits the union before delivering
the consumer closure. This never repeats a delivered callback or binding provider.
It captures declaration, ledger and watch together, links and freezes one paired
source result, lowers it and aggregates contributions by physical destination.
Shared native files receive one aggregated regional edit with all logical owners.

The closure receives `PreparedUpdate.report` and `apply(ifUnchangedFrom:)`. Any
apply attempt consumes the handle. It has no public initializer, serialization or
`Sendable` conformance. It is valid only on its preparing thread inside the
synchronous closure; exit invalidates retained handles and releases all borrowed
source/replay resources. Do not re-enter scope operations, await, or dispatch the
handle. Render the supplied report directly.

A UI may preview without holding a writer lock, then prepare on a worker thread
and pass the displayed fingerprint to `apply(ifUnchangedFrom:)`. A changed
fingerprint requires a refreshed report. Matching fingerprints still execute all
private freshness, ownership, permission, binding and publication checks.

Application validates the captured state, targets, linked inputs and forwarding
decisions. Live skill contents stay live while their source identity and valid
metadata remain required. It retains the complete ledger/watch closure, stages
resources, selected deployments, declaration, ledger, receipts and pruning, and
commits through one `FileTransaction`. Required literal bindings are resolved only
inside Core's private staged render. Ordinary application never starts an MCP
server, hook, plugin or model call.

Returning or throwing before apply cancels publication. A caller error after a
successful apply does not undo the commit. A no-change apply returns receipts
without rewriting state.

## Exact Restore and Domain APIs

`UpdateOperations.restore(scope:environment:)` restores the complete locked
deployment in one transaction. Restore acquires resources and runs the locked
format/layout; it does not link mutable producer declarations, choose current
refs or select a newer adapter. Missing resources, unknown renderers, output
mismatches and incompatible platforms fail before publication. Embedded resources
support cold reconstruction without the authoring tree. Live skills retain their
explicit authoring location. Native restore preserves unmanaged regions.

`SkillOperations` and `InstructionOperations` retain their type identities.
Their add, update, remove and restore methods are public extensions in
`AgentsUpdates`; consumers calling them must depend on and import `AgentsUpdates`
as well as the domain product. Discovery, frontmatter and text rendering stay in
the domain modules. Skill-only restore and update apply only the skill domain.
`InstructionOperations.renderChatGPT` renders the locked prompt resources.
Watch remains a separate subscription API. Add inspection returns source-relative `Skill.path` and `Skill.skillFile` coordinates, never paths into a released snapshot.

## Failure and Recovery

Handle misuse fails before I/O. Apply failures are `UpdateApplyError` with the
underlying error and a disposition:

| Disposition | Established result |
| --- | --- |
| `unchanged` | No publication, or validated rollback |
| `committed` | The generation committed; a later failure still makes the operation fail |
| `recoveryRequired` | Recovery could not establish a consistent generation |

Preparation errors retain their original type. Domain convenience APIs also unwrap unchanged apply failures; committed and recovery-required failures retain their disposition. Commit-marker publication can
precede a cleanup error, so callers must inspect the disposition before retrying.
The next writer recovers an abandoned journal and raises
`CoreError.transactionRecovered`; retry the whole preparation. Read-only access
reports pending recovery. Recovery uses sealed physical evidence and never invokes
linkers, renderers or binding providers. See [State](State.md) for durability and
concurrent-writer guarantees.

```swift
import AgentsUpdates

let receipt = try UpdateOperations.withPreparedUpdate { update in
  render(update.report)
  return try update.apply()
}
renderCompletion(receipt)
```

`render` and `renderCompletion` belong to the consumer. Completion is reported only
after the closure returns.
