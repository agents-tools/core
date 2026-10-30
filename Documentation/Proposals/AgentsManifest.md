# Agents Manifest Contract

## Status

Accepted — partially implemented. Language version 1.0, its document editor and
dump, and the `Agents.swift` state integration are implemented; targeting,
source linking, component deployment, approvals and lock version 2 are pending.

## Authors / Owners

- Author: showxu.
- Implementation owner: core; CLI, macOS GUI and skill CLI are consumers.
- Accepting authority: repository owner showxu.

## Summary

`Agents.swift` is source for a non-executing configuration compiler: bounded
grammar recognition, SwiftSyntax parsing and static type checking produce an
agent-independent intermediate
representation (IR); source linking and capability-driven adapters produce native
configuration files. The **deployment ledger**, `agents.resolved`, records exact
source pins, physical artifacts, owned keys/sections and their hashes. Machine
user state separately owns approvals for executable content.

The core repository's complete declaration is:

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  sources: [
    .source(
      name: "agents-tools",
      url: "https://github.com/agents-tools/.github",
      branch: "master",
      subpath: ".agent"
    ),
  ],
  components: [
    .instructions(
      sections: [
        "guide",
        .section(name: "shared/swift-package-route", source: "agents-tools"),
        .section(name: "shared/swift-package-tests", source: "agents-tools"),
      ],
      agents: [.claudeCode, .codex]
    ),
  ]
)
```

A **producer** publishes content or a named group; a **consumer** selects it for
installation. A **recipient** is the agent that will read a component's native
configuration. This consumer narrows an exported group's recipients to Codex,
while its own indexing rule inherits Cursor as its default recipient:

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  defaultAgents: [.cursor],
  sources: [.source(name: "team", path: "./team")],
  components: [
    .ignore(
      name: "build-products", patterns: [".build/"], purpose: .indexing,
      condition: .when(scopes: [.project])
    ),
  ],
  uses: [
    .group(name: "review", source: "team", condition: .when(agents: [.codex])),
  ]
)
```

CLI, GUI and skill CLI send domain edits to one document layer. It maps edits to
source patches, reparses and validates the entire candidate, and passes it to
core's prepare/apply transaction. The manifest owns intent; the ledger owns
resolved deployment facts. Comments and untouched source bytes remain intact.

## Implementation Status

| Part | Status and owner |
| --- | --- |
| Construction vocabulary, files and versions, grammar, typing, resource limits, document editing, evaluated dump, diagnostics and conformance | Implemented; specified in the [manifest language reference](../Reference/Manifest.md). |
| `Agents.swift` as scope declaration, deployable subset, declaration writes, absent-declaration rule and requirement comparison | Implemented; specified in [State](../Architecture/State.md#declaration). |
| [Component deployment](#component-deployment), [Targeting](#targeting), [Groups and source linking](#groups-and-source-linking), the `Components` target in [Target Architecture](#target-architecture), [Approvals](#approvals) and [Lock version 2](#lock-version-2-and-ownership-conversion) | Pending; specified below. |

## Motivation

A typed Swift vocabulary provides reusable composition and editor completion
while static interpretation keeps reads independent of arbitrary code execution.
One component construction shape lets groups combine every family. Explicit
conditions and source provenance make deployment and conflicts explainable.

The accepted [Swift manifest](../Decisions/SwiftManifest.md),
[component](../Decisions/AgentComponents.md) and
[approval](../Decisions/ExecutableApproval.md) decisions constrain this contract.

## Proposed Change

Adopt the vocabulary, static grammar, source editing and JSON contract of the
[manifest language reference](../Reference/Manifest.md), and complete deployment
of the whole vocabulary: targeting, group and source linking, native adapters
and executable approval. The types-only `AgentsDescription` and
document/compiler-front-end `AgentsManifest` library products exist; linking and
native adapters belong in an internal `Components` target. Shared IR, source
storage, capabilities and transactions stay in `AgentsCore`, and orchestration in
`AgentsUpdates`.

## Detailed Design

### Language

The [manifest language reference](../Reference/Manifest.md) specifies:

- [construction vocabulary](../Reference/Manifest.md#construction-vocabulary)
  and [domain rules](../Reference/Manifest.md#domain-rules);
- [source files and versions](../Reference/Manifest.md#source-files-and-versions),
  [static grammar](../Reference/Manifest.md#static-grammar),
  [type inference](../Reference/Manifest.md#type-inference-and-literal-conversions)
  and the [admission grammar](../Reference/Manifest.md#normative-admission-grammar);
- [resource limits](../Reference/Manifest.md#resource-limits) and
  [group references](../Reference/Manifest.md#group-references);
- [document editing](../Reference/Manifest.md#document-editing),
  the [evaluated JSON dump](../Reference/Manifest.md#evaluated-json-dump) and
  [diagnostics](../Reference/Manifest.md#diagnostics).

[State](../Architecture/State.md#deployable-subset) specifies the subset that
the state layer deploys; every other active structure is reported as
`manifest.unsupported`. The sections below specify the remaining deployment.

### Component deployment

Deployment gives every vocabulary family its native meaning. The front end
already checks the
[domain rules](../Reference/Manifest.md#domain-rules); the rules below apply when
resolved components are lowered to native configuration.

| Family | Payload semantics |
| --- | --- |
| Skills | Selection, exclusions, installation mode and member overrides preserve membership tracking and item pins. Duplicate names and conflicting members are diagnosed. |
| Instructions | Contributions append sections in traversal order. Prompt names are unique; each prompt has its own ordered sections. |
| MCP server | Stdio, Streamable HTTP and SSE are distinct transports. Transport conversion must be exact; all registrations require approval. |
| Hook | Portable events mean before/after a tool invocation and session start/end. Adapters preserve event and command-result behavior. `.native("event")` uses its single recipient's event grammar. Matchers use its verified grammar. Omitted timeouts retain the native default. Hooks preserve declaration order. |
| Subagent | Description and prompt are portable text. Model/tool names are identifiers validated by the recipient adapter. Omitted tools inherit its default; `[]` requires no tools. |
| Command | A named user-invoked prompt. Parameter tokens appear as literal `${input:name}`; missing required inputs are errors. Substitution is text, not shell evaluation. |
| LSP server | A stdio executable invocation, an extension-keyed `languages` dictionary and initialization options. One extension has one language by construction. Plugin-only recipients get an adapter-generated native plugin recorded in the ledger. |
| Permissions | Ordered last-match rules, with no match inheriting native policy. Read/write patterns are scope-relative globs (`*`, `**`, `?`). Execute/tool patterns use the adapter's verified request representation. Translation must preserve the full policy, including unmanaged rules; otherwise deployment fails. |
| Ignore | Ordered gitignore-style patterns with `!` negation, rooted at scope. Context and indexing are separate purposes, neither an access-denial guarantee. |
| Plugin/extension | Components mode decomposes a pinned container and selects all kinds when `select` is omitted; `[]` selects none. Typed references exclude individual children. Native mode keeps the container unchanged. Native configuration may configure only its registration, not rewrite container content. |

Shell interpretation requires an explicitly declared shell command. Symbolic
environment and secret bindings are resolved by core's machine binding provider
at apply, or emitted as native references where supported. Previews redact
secrets; locks retain binding identity, not values. Secret rotation does not
change command identity. Exported resources, own sections and prompt `append`
paths remain attached to their producer snapshot; exported own sections may be
consumed in either supported scope.

A native schema ID, for example `claude-code/subagent@1`, identifies its agent,
component kind and adapter schema version. Agent identity is not repeated in the
value. Registry validation checks fields, client-version compatibility and the
component's recipients. A schema contributes only to its own agent and cannot
replace portable fields, conditions, resource identities, target paths, owned-key
boundaries or approval metadata. Collisions and unknown schemas/fields/types are
errors for active deployment. A native permission policy can use empty portable
rules when no exact portable translation exists. Native configuration remains
subject to ordinary preview, ownership and approval checks.

Capability validation checks every active agent/component/scope/feature against
the registry; unsupported requests are reported rather than dropped. Inactive
branches still undergo syntax, type and domain checks. Pending executable
approval is separate: apply deploys approved components and reports pending or
refused components as undeployed. Local additions approve their reviewed content
identity through core's mutation API. Imports and group declarations do not
approve transitive or future content.

### Targeting

`defaultAgents` supplies recipients when a component omits `agents`. The language
1.0 fallback is `{claude-code, codex}`. Explicit `agents`, including an empty
array, is the complete recipient set and replaces the default everywhere.
An exported component retains its producer's explicit set; it does not become
an intersection with consumer defaults. When the component omits `agents`, its
declaring document supplies the default, which is captured when exporting it,
including its language-version fallback. A producer omitting `defaultAgents`
publishes to Claude Code and Codex in language 1.0. Consumer defaults never
retarget imported content. The state layer applies this fallback to the
unconditional root components it deploys.

A skill member's explicit override recipients replace its selection's recipients;
otherwise those selection recipients are its default. This is the same fallback
rule. A component discovered without a declaring manifest gets its default from
the enclosing selection. Producer front matter expresses conditions, never a
consumer-editable default. Imported metadata retains those conditions.

For each component or selected member:

```text
requested = explicitAgents ?? defaultAgents
active = requested ∩ agents admitted by every applicable condition
```

For candidate agent `a`, operation scope `s` and explicit platform context `p`,
`when(agents:scopes:platforms:)` is:

```text
(agents == nil OR a belongs to agents)
AND (scopes == nil OR s belongs to scopes)
AND (platforms == nil OR p belongs to platforms)
```

Members within a dimension are OR; dimensions and nested conditions are AND.
A specified empty dimension is false; `.when()` is true. Duplicate members are
domain errors. Applicable conditions include front matter, the component,
its section, every enclosing `ComponentGroup` and every `GroupReference` in its
expansion chain. Group references expose only `condition` for narrowing.
Consumers can add conditions but cannot remove producer conditions or replace
published recipients. Scope selects one operation's destination, not a request
to write multiple scopes. Platform is data supplied to resolution, not a Swift
compile-time conditional.

ChatGPT rendering has no agent recipient. For that destination, project each
condition onto scope/platform dimensions and preserve all those restrictions;
agent dimensions apply to native agent rendering only. Watch has no conditions
and is independent of this algebra.

Registry checks follow targeting. Every unsupported active request is a
capability error with origin and reason; the tool does not silently filter it.
Physical visibility is checked independently: if a shared destination exposes
content to additional agents, prepare reports the extra readers. An explicit
producer-authorized sharing change or a registry-supported private location is
required. Consumers cannot override published restrictions to resolve such a
conflict. Targeting is deployment intent, not filesystem isolation.

### Groups and source linking

A `ComponentGroup` is an inert ordered fragment until selected by a
`GroupReference`; a string literal denotes an unconditional local reference,
equivalent to `.group(name: "review")` for `"review"`. A conditional local
reference uses `.group(name:condition:)`. The root emits its components, then `uses` in order. Each group
emits its components, then recursively its `uses`, depth first. This defines
section, hook and policy contribution order. A source's root components, root
subscriptions and unrelated exports are not imported through a group reference.
The producer's defaults are captured as described under targeting.

`exports: ["review"]` publishes that local group. A consumer writes
`.group(name: "review", source: "team")`. To publish an existing group under a
new name, declare a wrapper `.group(name: "quality", uses:
["review"])` and export `"quality"`. References do not import Swift
symbols. There are no wildcard exports, implicit exports or executable package
initializers. The front end checks
[local group references](../Reference/Manifest.md#group-references), including
in unused declarations.

A source manifest is `<discovery-root>/.agent/Agents.swift`; when the discovery
root itself is `.agent`, it is `<discovery-root>/Agents.swift`. Exactly one lookup
is performed. Conventional repositories need no manifest to provide skills or
instructions; an export request from such a source reports a missing export.
An index export must identify an immutable package artifact containing a manifest.
An index publishing only individual skills cannot satisfy a group reference.

Aliases bind in the document that declares them. Within an exported component,
`source: "rules"` refers to the producer's alias; `.` refers to its package.
Relative local sources in a downloaded package must remain within that snapshot;
absolute, home-relative and escaping producer-local sources are invalid for
remote consumption. Root local sources retain core's existing path rules.
Qualified identity includes normalized source identity, snapshot, discovery root,
group name, component kind and component name. Different discovery roots retain
different namespaces even when they share a repository revision.

Resolve one snapshot per normalized source identity for the export graph,
satisfying all requirements on that source. SemVer constraints intersect; choose
the greatest permitted version. Explicit branch/revision constraints must name
the same commit; mixed version and revision constraints require a matching
permitted tag at that commit. Core owns version ordering and tag tie-breaking.
Resolve dependencies to a complete consistent graph, with deterministic descending
version candidates and normalized-source-ID ordering for equally eligible next
choices; backtrack on incompatible transitive requirements within the link budget.
An unsatisfiable graph reports both dependency paths. Existing direct skill and
section pins remain item-specific and are not upgraded by group resolution.

The ledger records every reference with source identity, discovery root, effective
requirement, exact revision/artifact digest, manifest digest, group name and full
child closure. Non-Git local export packages receive content-addressed snapshots;
explicit edit-mode skill children remain live. `install` restores the recorded
closure without consulting a mutable index or branch. `update` re-resolves the
affected closure and previews changes. Pins are never copied into the manifest.

Cross-source cycle detection follows the active reference stack before
memoization and reports `manifest.group.cycle` with source spans. A diamond is
not a cycle. Repeated references retain occurrence provenance. Conflicting active
payloads for the same named identity and overlapping recipients are
`manifest.group.conflict` errors. Equal named
hooks/policies coalesce at their first position to avoid duplicate execution;
ordered instruction sections retain intentional repetition. Disjoint targeting
may reuse a name.

Skill selections expand to member identities; instruction contributions form
ordered section streams; adapters may aggregate disjoint structured entries.
These explicit aggregations retain every owner. Other collisions on physical
names, paths or keys fail, even across different aliases. Permission aggregation
must preserve the entire ordered policy including unmanaged rules. There is no
last-writer-wins merge or implicit deployment rename. Resolve conflicts through
producer naming, selection/exclusions or conditions.

Linking is bounded by 256 distinct source snapshots, 16,777,216 aggregate
manifest input bytes, 64 active group references, 10,000 component contributions
and 1,000,000 total resolution/evaluation steps, including backtracking. Linked
expanded values also obey the
[expanded-value limits](../Reference/Manifest.md#resource-limits). Source
download and extraction limits remain in core's loader before the linker
receives bytes.

An exported declaration is read-only in a consumer: an edit changes its
`GroupReference.condition` or the producer's own document, never cached source.
After a document edit, prepare re-links affected sources and revalidates
capabilities and targets.

### Examples

#### showxu/skills

The skills repository declares:

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  components: [
    .instructions(
      sections: ["guide", "code-review-rules"],
      agents: [.claudeCode, .codex]
    ),
  ]
)
```

#### Producer

A package at `team` publishes this `team/.agent/Agents.swift`. Its own instruction
sections live under `team/.agent/instructions/`; skills follow source discovery
conventions. The project condition prevents deployment of this group in user scope.

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  exports: ["review"],
  groups: [
    .group(
      name: "review",
      components: [
        .instructions(sections: ["review-principles"], agents: [.claudeCode, .codex]),
        .skills(source: ".", select: ["review"], mode: .copy, agents: [.claudeCode, .codex]),
      ],
      condition: .when(scopes: [.project])
    ),
  ]
)
```

#### Consumer with every component family

This consumer combines local and exported groups. The exported reference selects
Codex from the producer's two recipients; its local subagent runs only on macOS.
The plugin container activates only in user scope. Files, commands, native schema
IDs and source exports are validated during resolution, not accessed by parsing.

```swift
// agents-tools-version: 1.0
import AgentsDescription

let base: [SectionReference] = ["guide"]
let sections = base + [.section(name: "engineering", source: "rules")]
let reviewer: Component = .subagent(
  name: "reviewer",
  description: "Review correctness and tests.",
  prompt: "Check invariants and explain concrete failures.",
  agents: [.claudeCode],
  condition: .when(platforms: [.macOS]),
  native: ["claude-code/subagent@1": ["memory": "project"]]
)

let agents = Agents(
  sources: [
    .source(name: "team", path: "./team"),
    .source(name: "drafts", path: "./draft-skills"),
    .source(name: "rules", url: "https://example.org/team/rules.git", from: "1.2.0"),
    .source(name: "catalog", index: "https://example.org/skills/index.json"),
    .source(name: "vendor", url: "https://example.org/vendor/tools.git", exact: "2.1.0"),
  ],
  components: [
    .skills(
      source: "rules", exclude: ["experimental"], mode: .copy,
      overrides: [.skill(name: "testing", mode: .link, agents: [.codex])]
    ),
    .skills(
      source: "drafts", select: ["draft"], mode: .edit,
      condition: .when(agents: [.claudeCode], scopes: [.project])
    ),
    .instructions(
      sections: sections,
      chatGPT: [.prompt(name: "weekly", sections: base, append: "notes/weekly.md")]
    ),
    .mcpServer(
      name: "workspace",
      transport: .stdio(
        "workspace-tools", arguments: ["serve"],
        environment: ["TOKEN": .secret("workspace-token"), "LOG_LEVEL": "info"]
      ),
      agents: [.claudeCode]
    ),
    .mcpServer(
      name: "reference",
      transport: .streamableHTTP(
        url: "https://example.org/mcp", headers: ["Authorization": .environment("MCP_AUTH")]
      ),
      agents: [.openCode]
    ),
    .hook(
      name: "format", event: .afterTool,
      run: .executable(
        "swift", arguments: ["format", "--in-place", "Sources"],
        workingDirectory: .path("tools", source: "rules")
      ),
      timeoutSeconds: 30, agents: [.claudeCode], condition: .when(scopes: [.project])
    ),
    .command(
      name: "review/change", description: "Review a selected change.",
      prompt: "Review ${input:change} and cite evidence.",
      parameters: [.parameter(name: "change", description: "The change to review.")],
      agents: [.claudeCode]
    ),
    .lspServer(
      name: "swift", run: .executable("sourcekit-lsp"),
      languages: [".swift": "swift"],
      initializationOptions: ["backgroundIndexing": true],
      agents: [.claudeCode], condition: .when(platforms: [.macOS])
    ),
    .permissions(
      name: "private-files",
      rules: [.deny(.read, "secrets/**")],
      agents: [.claudeCode], condition: .when(scopes: [.project])
    ),
    .ignore(
      name: "build-products", patterns: [".build/", "DerivedData/"], purpose: .indexing,
      agents: [.cursor], condition: .when(scopes: [.project])
    ),
    .plugin(
      name: "vendor-tools", path: "plugins/tools", source: "vendor", mode: .native,
      agents: [.claudeCode], condition: .when(scopes: [.user])
    ),
    .plugin(
      name: "shared-tools", path: "plugins/shared", source: "vendor",
      exclude: [.hook(name: "format")], condition: .when(scopes: [.project])
    ),
  ],
  groups: [
    .group(
      name: "review-tools", components: [reviewer],
      uses: [.group(name: "review", source: "team", condition: .when(agents: [.codex]))]
    ),
  ],
  uses: ["review-tools"],
  watch: ["rules", "catalog"]
)
```

## Target Architecture

```text
UTF-8 -> strict lexer + bounded grammar recognizer -> SwiftParser -> iterative tree guard
      -> vocabulary type checking/static evaluation
      -> declaration IR + source map -> source/group linking + discovery
      -> resolved component IR -> capability validation/native adapter lowering
      -> artifact and ledger plan -> state transaction

CLI/GUI/skill CLI -> domain edits -> source patches -> front end again
                 -> expected-IR comparison -> prepare -> transaction
```

[Package Architecture](../Architecture/Package.md) owns the current targets.
Deployment adds or extends:

| Target | Ownership and dependencies |
| --- | --- |
| `AgentsCore` | Adds capability protocols/descriptors, resolved component IR and approval identity. No syntax or adapter-implementation dependency. |
| `Components` | Internal group linker, input-container adapters and native output adapters. Depends on `AgentsCore`, `AgentsManifest`, `AgentsSkills`, `AgentsInstructions`. Uses core source-resolution sessions and registers capability implementations during composition. Agent adapters are types/files, not one target per agent. |
| `AgentsUpdates` | Public prepare/apply orchestration across document edits, domains, components, approvals and one state transaction. Depends on the targets above; front ends consume its workflows. |

Core does not depend on `Components`; descriptions and document editing do not
own a second state store. Public import names retain family identity; the
internal `Components` name reflects its responsibility.

Declaration IR preserves defaults versus explicit values, ordered sections,
conditions and symbolic groups without choosing a host or reading sources.
Resolved IR carries tagged component payloads, logical identity, effective
recipients, content identity and provenance. Neither contains native output
paths. Backend plans add registered physical targets, owned keys/sections,
observed hashes, replacement bytes and adapter verification versions.

Every field's source map records use/definition spans and inherited defaults.
Provenance includes normalized source identity, exact revision/artifact digest,
relative path, input format/adapter version, group and reference chain. Cache
paths are not identity. Coalesced artifacts retain all owners and origins.

Future language versions can add bounded pure functions within the front end's
syntax, typing, evaluation and provenance rules. Their results lower to the same
values and IR. Adapters and the state engine remain independent of expression
syntax; editability remains a document-layer capability.

## State Transaction and Recovery

[State Transaction and Recovery](../Architecture/State.md#state-transaction-and-recovery)
owns the current publication, precondition and recovery guarantees.

### Manifest integration

[Declaration writes](../Architecture/State.md#declaration-writes) own the
publication of validated source bytes, the shared transaction with the ledger,
watch state, native outputs and cache, and the preparation evidence for the
manifest.

### Approvals

Approval identity covers declarations, commands and shipped content, excluding
comments and formatting. Approval is machine-local; a copied ledger disposition
is not authorization on another machine. Apply checks the local approval for the
resolved content identity and reports pending/refused components independently
of source validity.

## Compatibility / Migration Impact

The product reads and writes only `Agents.swift`. It does not read, recognize
or convert the earlier JSON declaration; existing repository and user scopes are
converted once outside the product at release. A scope with a lock or watch state
and no `Agents.swift` reports the missing declaration
([absent declaration](../Architecture/State.md#absent-declaration)).

### Requirement persistence and comparison

[Requirement comparison](../Architecture/State.md#requirement-comparison)
specifies semantic requirement comparison across declarations, edits, the
ledger, update planning, resolution sessions and watch state. Lock version 2
extends it to group resolutions below.

### Lock version 2 and ownership conversion

Version 2 retains exact item-specific source identities, revisions, versions,
artifact coordinates, hashes, section order and installation modes. Content
records refer to unified `deployments` IDs instead of duplicating ownership.
`groupResolutions` records the source/group closure; `components` records resolved
MCP servers, hooks, subagents, commands, LSP servers, permission/ignore policies
and plugins. Empty new collections are present; future unknown versions are refused.

A deployment records registered-root-relative target, artifact kind, owners,
recipients, owned keys/sections, expected content hash, source pins and adapter
format. Whole-file versus managed-section ownership is explicit. For structured
files, hash the owned values and retain formatting-sensitive patch preconditions;
unmanaged keys are not claimed. Local approval dispositions are observations,
not transferable authorization.

Lock conversion derives ownership only from existing install/target records.
Shared skill destinations coalesce only when mode, content and ownership agree.
Instruction records preserve these separate removal rules exactly:

| Existing instruction record | Version-2 ownership and removal |
| --- | --- |
| Generated unit target (`import == nil`) | Whole generated rendering, governed by `blockHash`. When obsolete, delete the file if its current bytes hash to `blockHash`; preserve drifted bytes. Its existing `created: false` does not prevent deletion. |
| Forwarding/import target (`import != nil`) | Managed import block with its marker/hash and the existing `created` flag. Remove the managed block; delete the whole file only when `created` is true and no custom content remains. Otherwise preserve the remaining file. |

Heading offsets, import markers, block hashes and creation provenance retain
their meanings. Missing targets remain missing; drifted targets retain expected
hashes, not hashes of adopted bytes. Lock conversion does not scan and claim
unmanaged native files. No generated unit is reclassified as a non-deletable
custom file, and no forwarding file gains whole-file ownership from a
unit-target rule.

Lock conversion is deterministic for the same old lock and explicit registered
layout. An already-version-2 ledger remains byte-identical when unchanged.
Restoration must address the same original pins and physical targets after
conversion, and removing the last instruction must produce the same deletion or
preservation result as before conversion.

Lock conversion canonicalizes requirements while preserving exact source and
item pins and ownership; an existing version-2 ledger is not upgraded merely to
canonicalize requirements. Requirements in `groupResolutions` follow the
[ledger rule](../Architecture/State.md#requirement-comparison): newly written
records are canonical, existing records keep their bytes, and comparison is
semantic.

## Validation Contract

[Conformance and
Validation](../Reference/Manifest.md#conformance-and-validation) owns the
language, editing and dump validation. The pending parts add tests for condition
narrowing, default capture on export, qualified namespaces, cross-source cycles
and diamonds, conflicting requirements, shared-target exposure and lock
restoration/removal equivalence after lock conversion. Native capability claims
require current client probes.

## Alternatives Considered

- **Parsing in the description module.** A types-only dependency keeps authoring
  and compiler-backed editor support independent of parsing, I/O and state.
- **Syntax in `AgentsCore`.** Shared IR and persistence remain independent of the
  source language; the document front end owns syntax and edits.
- **A public payload wrapper for each component.** Direct typed factories keep one
  construction level while private storage preserves family-specific structure.
- **Different targeting rules for exports.** One explicit-or-default rule plus
  intersected conditions preserves the meaning of a component across packages.
- **Whole-file regeneration.** Exact patches and explicit read-only constructs
  preserve comments, formatting and reviewable local edits.
- **Resolution during dump.** A declaration dump remains deterministic and offline;
  group linking is a separate source operation.

## Related Documentation

- [Agents Manifest Language](../Reference/Manifest.md)
- [Swift Manifest](../Decisions/SwiftManifest.md)
- [Agent Components and Adapters](../Decisions/AgentComponents.md)
- [Executable Component Approval](../Decisions/ExecutableApproval.md)
- [Package Architecture](../Architecture/Package.md)
- [State and Source Cache](../Architecture/State.md)
- [Updates](../Architecture/Updates.md)
- [Product Scope](https://github.com/agents-tools/cli/blob/master/Documentation/Decisions/ProductScope.md)
- [Front Ends](https://github.com/agents-tools/cli/blob/master/Documentation/Decisions/FrontEnds.md)
- [CLI reference](https://github.com/agents-tools/cli/blob/master/Documentation/Reference/CLI.md)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- [Swift Lexical Structure](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/lexicalstructure/)
