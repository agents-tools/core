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
`ManifestEdit` and digest-scoped document handles. Skill removal uses recorded
membership while preserving authored all-member selections and their exclusions;
new upstream members are admitted by update, not by removal.

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
`InstructionOperations.renderChatGPT` verifies locked sections and reads the current
consumer-owned append file at export. Update and install do not require that file;
producer-owned append resources remain frozen at their selected source.
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

## Public Inspection and Interactive Consumers

`UpdateOperations.inspect` captures the Manifest document (including typed values,
source maps and NodeIDs), complete declaration, v2 source/component/occurrence/group
and resource descriptions, deployments, watch state and recovery diagnostics under
one admitted read footprint. Public record IDs join these immutable descriptions;
logical selections remain independent of revisions and temporary directories.
The report excludes retained content objects and complete native file bytes.
Deployment drift compares owned content or validates the physical private receipt.
An unverified observation is explicit. `readLocations` contains actual state,
source, retained resource and deployment URLs, including missing leaves.

A pending journal returns recovery diagnostics without reading inconsistent
configuration. Inspection does not recover, resolve sources, call a provider or
create persistent files. It is suitable for App refresh and filesystem invalidation.

Pass a component's `selection` in `UpdateRequest.selections` to update or remove
that logical component. An occurrence selects that contribution when it is the
sole contribution; a coalesced component requires complete-component selection or
a typed declaration-reference edit. The captured document/ledger generation is
revalidated before linking. Bare names that match multiple logical components
report ambiguity. Unselected components keep their recorded projection and pins.

`UpdateOperations.discover` resolves an explicit complete declaration, including
exported groups, in B's temporary source session without native lowering. It
returns symbolic descriptions, all exact source revisions, stable identities and
actual local read locations. `ComponentDiscovery.updateRequest()` carries the
captured declaration identity and discovered graph fingerprint into preparation;
a changed source fails before callback delivery. File enumeration and native input
conversion remain with their domain/import owners.

`SourceImportOperations.inspect` consumes an explicit existing importer profile,
root, document, selection and supplied resource locations. Its immutable report
preserves producer coordinates, pins/integrity, ordered sources, selections,
bindings, unconverted diagnostics, resource preservation obligations and foreign
deployment claims. `updateRequest(in:)` merges admitted canonical intent into the
captured scope declaration. Preparation rereads the same inputs, compares the
proposal, captures their private freshness evidence and validates it again around
publication. Unresolved conversion/binding diagnostics stop submission; foreign
claims do not establish ownership. Input content that would overwrite its own
local authoring source requires independent preservation before submission.

Pass D's `RuntimeBindingProvider` as `bindingProvider:` to public
`withPreparedUpdate`, `perform` or full `restore`. Preparation and preview never
call it. The provider resolves bounded data only during private staging. Native
reports separate intended recipients from the verified physical object's reader
union and retain sensitivity from an existing shared receipt, including when the
selected change has no bindings.

`UpdateOperations.perform` returns `UpdateCompletion` after the whole synchronous
operation and outer cleanup have returned. It preserves the result/error and
`unchanged`, `rolledBack`, `committed` or `recoveryRequired` disposition, reports
recovery before callback delivery, and includes pending recovery/cleanup evidence.
A durable commit remains committed when cleanup is pending. Render the disposition
before deciding whether to retry. The terminal value is Sendable when its consumer
result is Sendable; the prepared handle is always invalidated before it returns.

```swift
let displayed = try UpdateOperations.preview(request, environment: environment)
let completion = UpdateOperations.perform(request, environment: environment,
  bindingProvider: bindings
) { prepared in
  try prepared.apply(ifUnchangedFrom: displayed.displayedFingerprint)
}
```

The closure runs on one thread and must not await. A UI may await the completed
operation's result, refresh a changed candidate and reprepare for confirmation.
Agents CLI restores the full scope once with `UpdateOperations.restore`; domain
consumers continue using their restricted lifecycle methods.

Watch consumers can pass a displayed `WatchStatus` to `WatchOperations.seen`.
The existing writer revalidates both normalized source identity and the exact Git
commit or artifact digest map before retention and watch-state publication. A
redirected alias or changed content requires refresh. Status and diff never deploy
configuration.
