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
and prompts, selected native changes, marketplace pin changes, missing-lock status,
`hasChanges` and a
`displayedFingerprint`. Native reports contain the owned symbolic values; complete
shared documents, unrelated siblings, runtime secret values and private freshness
evidence remain internal. `ComponentUpdateChange.symbolicBefore` and `symbolicAfter`
are readable selected configuration, rendered through the native document owner.
Generated-plugin text includes the final target, selected native files and member
content, and frozen resource paths and executable flags. Binding values remain
symbolic references; private deployed bytes and unrelated members are never read
for display. `nil` means the selected value is unavailable; unavailable recorded
skill content is labelled in the projection. Consumers display these strings directly. Equal unmanaged
values do not establish ownership.
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
the consumer closure. Finite skill installation targets for current and previous
slots join this admission union and retain their legacy directory/link intention.
This never repeats a delivered callback or binding provider.
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

## Producer Patches

`UpdateOperations.previewProducerPatches(scope:environment:)` returns a
`ProducerPatchPreview` with exact UTF-8 patch files and typed skip reasons.
Each file includes its safe filename, immutable producer coordinates, base,
repository-relative paths and contributing component selectors. The encoded
report contains the same preview content available to Swift callers. Freshness
evidence stays private to the in-memory preview.

The operation reads the deployed lock, evaluates effective source and
organization policy, and replays qualifying locked resources offline. It follows
recorded copy routes for skills, opaque native plugin trees and the resource
placements of generated native plugins. Direct Git base bytes must match an
exact regular blob in the pinned commit. A package subdirectory is part of the
patch path. For a hosted marketplace release, the selected member, frozen
producer seal and verified archive must agree on the regular entry and its
bytes. These paths are relative to the release payload tree. Forwarded or
ambiguous producer claims need an independent source-path mapping.

The comparison strips a native copy's UTF-8 BOM and converts CRLF to LF.
The source must already have those normalized bytes. Authored comments,
including text resembling a generated header, remain content. Generated
instructions, Antigravity rule frontmatter and headers, and merged configuration
are transformed outputs and are skipped. Routes that deploy a link, local
producers, unavailable path or identity attribution, nonregular files, binary
files, deletions and mode changes have separate skip reasons. A missing or
unverifiable required locked input fails the preview. The standard ledger
limits also bound the native reads, compared paths and combined patch bytes.

Modified copies are compared by origin, base and source path before package
grouping. Identical edits share one diff, with every contributing selector
listed. Divergent edits are reported at each modified copy, while unchanged
copies have no effect. The lexicographically first eligible root owns a shared
diff. Patch files use repository-relative paths and a digest suffix to keep
filenames stable across previews.

`UpdateOperations.exportProducerPatches(_:to:)` writes the reviewed bytes
under a scope read lock. The caller can present a destination picker between
preview and export, then pass its URL directly. On macOS, export keeps any
security-scoped access for the duration of the synchronous call. A default
destination is `patches` under the project directory. Policy, deployed state,
native copy generations and locked resource proofs are checked again before
publication. A pending-only marketplace change is compatible with a preview
whose deployed inputs still match.

The export reports one output directory and its written, reused and failed
files. It reuses regular files with identical bytes and preserves occupied
filenames on collision. An empty preview creates no directory. Installed
paths, scope state, policy files and producer trees are excluded as destinations.
Retrying the same preview after a collision reuses files already written if the
inputs still match. Apply the patch from the producer repository root at the
recorded commit, or from the extracted exact release tree.
See [APM's producer patch reference](https://microsoft.github.io/apm/reference/cli/export-patch/).

## Exact Restore and Domain APIs

`UpdateOperations.restore(scope:environment:)` restores the complete locked
deployment in one transaction. Restore admits package declarations against their
committed pins and contribution closure before acquiring resources. It runs the locked
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

`ScopeInspection.inventory(format:createdAt:)` returns distributable JSON from
the captured lock evidence. Select `.cycloneDX` for CycloneDX 1.6 or `.spdx` for
SPDX 2.3. Pass a Foundation `Date` for reproducible bytes. Without a date,
`cycloneDXInventory()` and `.cycloneDX` omit the timestamp, while SPDX uses the
current UTC time. Both formats require a scope free of pending recovery and
marketplace intent errors.

The inventory records locked versions and revisions, captured resource
checksums, and marketplace release archive digests. The resource evidence labels
file and tree SHA-256 separately. CycloneDX nests source components and uses
`agents:contains` references for additional memberships. SPDX uses `CONTAINS`
relationships and `NOASSERTION` for unknown package licenses. GitHub and Bitbucket
package URLs use their registered types. Other Git hosts use the registered `git`
type with the host and repository path. A subpath is included where the lock
identifies one package root. Origins exclude authentication and local filesystem
locations.

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

Finite source and import additions use the package `UpdateOperations.captureAddition`
seam. It accepts explicit declaration additions and a captured `ScopeInspection`,
returning no candidate for an empty or source-only selection. Composition preserves
existing source aliases, groups, uses, defaults and direct occurrences. Alias/group
conflicts and pending authored changes require resolution rather than a broader
update. All existing pins and protected projections remain fixed while the selected
addition links; its fingerprint is captured after composition. The request retains
Core path identity, scope/root mappings, declaration absence or digest and baseline
state evidence. Another destination, changed evidence or a modified candidate
requires a refreshed inspection. Ordinary preparation repeats these checks before
offering its synchronous handle. Existing authored whole-graph discovery remains
an explicit complete-graph workflow.

`SourceImportOperations.inspect` consumes an explicit existing importer profile,
root, document, selection and supplied resource locations. Its immutable report
preserves producer coordinates, pins/integrity, ordered sources, selections,
bindings, unconverted diagnostics, resource preservation obligations and foreign
deployment claims. `updateRequest(in:)` merges admitted canonical intent into the
captured scope declaration. Preparation rereads the same inputs, compares the
proposal, captures their private freshness evidence and validates it again around
publication. Unresolved conversion/binding diagnostics stop submission; foreign
claims do not establish ownership. Import requests use destination-bound finite
addition protection; admitted canonical bindings cannot clear independent raw
preservation/rewrite requirements. Input content that would overwrite its own
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

`CombinedUpdateReport.readLocations`, discovery and scope inspection expose durable
state, source, own-instruction, resource and deployment inputs, including absent
leaves introduced by an unsaved declaration. `inspectOwnInstructions` and
`inspectChatGPTExport` pair their results with their owner-computed read locations.
Export reads the consumer appendix at export time; an absent appendix is allowed
while installing, but must exist when explicitly exported.

Initialization uses a pure `describeInstructionsInitialization` or
`describeProjectSkillInitialization` and then `UpdateOperations.initialize`.
The immutable description contains the exact file/template and captured existing
project identity. `describeSkillInitialization(directory:)` is explicit standalone
authoring and can select a new direct child of an existing parent. Apply holds
that observed root through the lower domain's sole transaction. Registered roots
removed or replaced after description are never recreated. Existing URL-returning
initializers use the same lower writer; consumers needing terminal evidence use
the description/completion API. A committed operation with pending cleanup stays
committed; durable rollback stays rolled back even with pending cleanup. Earlier
recovery failure has unchanged current disposition and pending recovery evidence.
No executing resource or borrowed descriptor outlives the synchronous return.

`WatchOperations.previewAdd` and `previewRemove` produce immutable confirmation
requests with a stable fingerprint, selected source/content and read locations.
Add resolves Git in disposable storage or uses the existing verified index reader;
preview never retains content, changes scope files or recovers. `apply(preview)`
revalidates scope state and exact content in the existing subscription writer.
`UpdateOperations.performWatch(preview)` returns that writer's outer
`UpdateCompletion<WatchChange>` without nesting a transaction. Subscriptions do
not deploy native targets or skills.

Watch consumers can pass a displayed `WatchStatus` to `WatchOperations.seen`.
The existing writer revalidates both normalized source identity and the exact Git
commit or artifact digest map before retention and watch-state publication. A
redirected alias or changed content requires refresh. Status and diff never deploy
configuration.

Concrete native contributions are decoded from their sealed F artifacts inside
replay's resource lifetime. Composition resolves D's closed routes and descriptor
physical identities before grouping logical owners. A shared document receives
one regional preparation, including protected MCP and native component siblings.
Reader and sensitivity evidence covers the physical object; selection controls
which runtime bindings may be requested. Ordinary changes preserve an unselected
private region using its verified receipt, without replaying its provider.

Public prompt export renders locked sections in their recorded order and retains
producer append resources. A recorded consumer `localAppend` is read from its
current contained file only during export. Update, install and locked recovery do
not read that mutable consumer file.

`SourceImportInspection.producerRevision` is optional. Documentation-backed native
profiles retain an unavailable upstream revision as `nil`; their
`specificationStatus` remains available. Import requests rebase producer-local
source coordinates into the captured declaration while retaining the proposal's
input freshness evidence and conversion/binding diagnostics.

A consumer presenting authored YAML occurrences can use the captured document's
`node(at:)`, verify `editability(of:)`, and submit a typed `ManifestEdit` through
`UpdateRequest.operation.edit`, with `expectedDeclarationDigest`. This addresses
the selected authored node; it does not infer a producer child's ownership from a
recorded occurrence index. The node and expected digest reject stale reuse.


## Package-manager Lifecycle

`LifecycleOperations.list`, `validate`, `simulate` and the declaration and
enablement previews are read-only. Discovery uses the admitted administrator
directory and the user and consuming-project `StateStore` declarations.
Administrator source errors withhold all starts. User and project source errors
withhold their own actions. Shell output and HTTP response bodies are omitted
from reports. Reviewed enablement definitions retain authored values for the
local confirmation UI.

`UpdateOperations.previewLifecycle` requires a caller-supplied operation intent.
`InstructionOperations.previewCompilation` uses the instruction update
request. Marketplace resolution, lock-only and frozen deployment and bundle
import expose lifecycle previews for their existing operation routes.
`UpdateOperations.perform(_:)` consumes the review's in-memory confirmation,
runs eligible pre actions, reprepares and attempts the reviewed package write,
then runs eligible post actions after successful completion. Submission again
returns the in-progress or recorded result. A fresh review supports an
intentional repeat. Recovery does not replay effects.

Project enablement binds the complete canonical subtree digest to the physical
root and canonical path. Receipts live in `~/.agents/lifecycle/receipts.json`
with owner-private access. Receipt replacement serializes updates across roots.
Each grant or revoke advances the selected root's revision. The project handoff
lock orders revocation against a command spawn or webhook resume. Each action
start checks current source provenance, authority, applicable policy and
receipt. Set `APM_NO_SCRIPTS=1` to suppress starts for one invocation.

Pre action failures are advisory. Stale input, rollback, cancellation and
pending recovery prevent post starts. Production webhooks may settle during
package application. Reports distinguish OS handoff, confirmed HTTP success,
HTTP rejection and unknown delivery. Explicit execute-test waits for each
response and uses the same eligibility gate.
