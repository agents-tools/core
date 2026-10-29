# Agents Manifest Contract

## Status

Accepted — language version 1.0.

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

## Motivation

A typed Swift vocabulary provides reusable composition and editor completion
while static interpretation keeps reads independent of arbitrary code execution.
One component construction shape lets groups combine every family. Explicit
conditions and source provenance make deployment and conflicts explainable.

The accepted [Swift manifest](../Decisions/SwiftManifest.md),
[component](../Decisions/AgentComponents.md) and
[approval](../Decisions/ExecutableApproval.md) decisions constrain this contract.

## Proposed Change

Adopt the vocabulary, static grammar, source editing, migration and JSON contract
below. Add the types-only `AgentsDescription` and document/compiler-front-end
`AgentsManifest` library products, with linking and native adapters in an internal
`Components` target. Keep shared IR, source storage, capabilities and transactions
in `AgentsCore`, and orchestration in `AgentsUpdates`.

## Detailed Design

### Construction vocabulary

`AgentsDescription` is a compilable, types-only Swift module. Every manifest
accepted by the static evaluator must type-check against the matching module
with the real Swift compiler, including contextual factories, dictionaries and
literal conversions. Compiler type-checkability is a language 1.0 requirement;
editor integration, including making the module available to SourceKit-LSP, is
outside this contract.

The interface below lists the entire public construction surface. Types conform
to `Sendable` and `Equatable`; factory results are immutable data. Opaque structs
have no public memberwise initializer. Literal-protocol initializers are compiler
entry points, invoked through literals in the manifest grammar. The module uses
the standard library and performs no I/O, registration, resolution or evaluation.
Public names are distinct from top-level standard-library, Foundation and SwiftUI
types so front ends can import those modules together.

Factories and labels follow SwiftPM's authoring shape and the
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
Each component occupies one construction level. Its family-specific fields end
with the same `agents:`, `condition:`, `native:` tail. Payload storage is private.

A **watch subscription** observes changes in a named source independently of
installation. **Install mode** chooses a link to verified cached content (`.link`),
a verified installed copy (`.copy`), or a live local skill link (`.edit`). Edit
mode has no immutable pin or content hash and requires a local source without a
requirement.

#### Root, sources and composition

```swift
public enum Agent: Sendable, Equatable {
  case claudeCode, codex, cursor, geminiCLI, openCode
}
public enum Scope: Sendable, Equatable { case project, user }
public enum Platform: Sendable, Equatable { case macOS, linux }
public enum InstallMode: Sendable, Equatable { case link, copy, edit }

public struct Condition: Sendable, Equatable {
  public static func when(
    agents: [Agent]? = nil, scopes: [Scope]? = nil,
    platforms: [Platform]? = nil
  ) -> Condition
}

public struct Agents: Sendable, Equatable {
  public init(
    defaultAgents: [Agent]? = nil, exports: [String] = [], sources: [Source] = [],
    components: [Component] = [], groups: [ComponentGroup] = [],
    uses: [GroupReference] = [], watch: [String] = []
  )
}

public struct Version: Sendable, Comparable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func == (lhs: Version, rhs: Version) -> Bool
  public static func < (lhs: Version, rhs: Version) -> Bool
}

extension Range where Bound == Version {
  public static func upToNextMajor(from version: Version) -> Range<Version>
  public static func upToNextMinor(from version: Version) -> Range<Version>
}

public struct Source: Sendable, Equatable {
  public static func source(
    name: String, url: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, from: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, exact: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, branch: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, revision: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, from: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, exact: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, branch: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, revision: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source
  public static func source(name: String, index: String, subpath: String? = nil) -> Source
}

public struct ComponentGroup: Sendable, Equatable {
  public static func group(
    name: String, components: [Component] = [], uses: [GroupReference] = [],
    condition: Condition? = nil
  ) -> ComponentGroup
}
public struct GroupReference: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func group(name: String, condition: Condition? = nil) -> GroupReference
  public static func group(
    name: String, source: String, condition: Condition? = nil
  ) -> GroupReference
}
```

There is one `let agents = Agents(...)`, optionally annotated `: Agents`.
Other constants contain reusable values. Source names are lexical aliases, not
output paths. A **discovery root** is the source root with its optional safe
`subpath` applied; component and export discovery start there. Core owns source
identity normalization and requirement resolution.

`Version` uses core's semantic-version validation and precedence. A requirement
is a value: `from: x` and `.upToNextMajor(from: x)` denote
`x ..< (major + 1).0.0`; `.upToNextMinor(from: x)` denotes
`x ..< major.(minor + 1).0`. The upper bounds have no prerelease or build metadata,
even when the lower bound has either. The lower bound retains its prerelease and
metadata. All range forms use the resolver's `isInRange(from:to:)`: build metadata
does not affect precedence, and a prerelease tag additionally needs a bound with
a prerelease and the same major/minor/patch triple. Exact requirements retain
core's full normalized-version matching, including build metadata.

Lowering canonicalizes the `Range<Version>` value. An upper bound equal by SemVer
precedence to `(major + 1).0.0` becomes `SourceRequirement.upToNextMajor`; one
equal to `major.(minor + 1).0` becomes `upToNextMinor`; any other upper bound
becomes `SourceRequirement.range(from:to:)`. The two canonical upper bounds
never coincide. Version strings use core's
normalized description; range equality compares bounds by SemVer precedence,
while exact-version equality includes metadata. Invalid versions, non-increasing
ranges and successor overflow are located `manifest.domain` errors. Candidate
successor bounds are computed with checked arithmetic; a literal range does not
fail merely because a nonmatching candidate successor would overflow.

The canonical printer uses `from:` for a major range,
`.upToNextMinor(from:)` for a minor range and adjacent `"lower"..<"upper"` for
other half-open ranges. `exact:`, `branch:` and `revision:` retain their meanings.
Default latest-tag/default-branch selection remains core's rule. Requirements
apply to Git URL sources and Git-backed local paths only. `.source(name:index:)`
represents the existing well-known index kind and has no Git requirement.
`path:` locates a resource inside a named source or supplies a local source
location; `subpath:` narrows the source's own discovery root.

Source aliases follow the existing nonempty, colon-free string rule, with `.`
reserved for the declaring package. Escapes preserve otherwise valid string
contents. Two aliases for one normalized source identity in a document are errors.
Group and newly introduced named component identifiers are relative slash-separated
names with no empty, `.` or `..` segment, colon, backslash or control character.
Skill and instruction names retain their domain validators. ChatGPT prompt names
retain the existing arbitrary string-key namespace; they are not filesystem paths.
Names must be unique in their respective namespace.

Git URLs are complete transport URLs, as in SwiftPM. A hand-written shorthand is
admitted with `SourceDeclaration` normalization and a `manifest.domain` warning
whose fix-it is the complete URL: `intranet/team` means `https://intranet/team`,
preserving the host; it is not the CLI's owner/repository shorthand. The editor
and migration emit complete URLs using `SourceDeclaration.gitURL`: add `https://`
to host/repository shorthand, preserve existing schemes and preserve complete
SCP-style URLs such as `user@host:path`. Preserving SCP transport syntax also
preserves its remote path interpretation. Identity normalization lowercases the
host, retains an explicit port, trims path slashes and removes a terminal `.git`;
printing preserves the repository suffix.

`exports: ["review"]` exports the group named `review`; export name and group name
are identical. A differently named wrapper group provides a renamed export.
`watch` is a unique array of declared source aliases, with no recipient or condition. Observed
baselines remain in `agents.watch`, not the manifest. Neither exports nor unused
groups cause deployment or subscriptions in a consumer.

#### Literal values and supporting types

```swift
public struct SkillSelection: Sendable, Equatable, ExpressibleByArrayLiteral {
  public static var all: SkillSelection { get }
  public init(arrayLiteral elements: String...)
}
public struct SkillOverride: Sendable, Equatable {
  public static func skill(name: String, mode: InstallMode? = nil, agents: [Agent]? = nil) -> SkillOverride
}
public struct SectionReference: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func section(
    name: String, source: String? = nil, condition: Condition? = nil
  ) -> SectionReference
}
public struct ChatGPTPrompt: Sendable, Equatable {
  public static func prompt(
    name: String, sections: [SectionReference], append: String? = nil,
    condition: Condition? = nil
  ) -> ChatGPTPrompt
}
public struct Resource: Sendable, Equatable {
  public static func path(_ path: String, source: String? = nil) -> Resource
}
public struct PromptContent: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func file(_ path: String, source: String? = nil) -> PromptContent
}
public enum RuntimeValue: Sendable, Equatable, ExpressibleByStringLiteral {
  case literal(String)
  case environment(String)
  case secret(String)
  public init(stringLiteral value: String)
}
public struct ExecutableInvocation: Sendable, Equatable {
  public static func executable(
    _ executable: String, arguments: [String] = [],
    environment: [String: RuntimeValue] = [:], workingDirectory: Resource? = nil
  ) -> ExecutableInvocation
}
public indirect enum ConfigurationValue: Sendable, Equatable,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  case string(String)
  case integer(Int)
  case decimal(String)
  case boolean(Bool)
  case null
  case array([ConfigurationValue])
  case object([String: ConfigurationValue])
  public init(stringLiteral value: String)
  public init(integerLiteral value: Int)
  public init(booleanLiteral value: Bool)
  public init(nilLiteral: ())
  public init(arrayLiteral elements: ConfigurationValue...)
  public init(dictionaryLiteral elements: (String, ConfigurationValue)...)
}
public typealias NativeConfiguration = [String: [String: ConfigurationValue]]

public struct MCPTransport: Sendable, Equatable {
  public static func stdio(
    _ executable: String, arguments: [String] = [],
    environment: [String: RuntimeValue] = [:], workingDirectory: Resource? = nil
  ) -> MCPTransport
  public static func streamableHTTP(
    url: String, headers: [String: RuntimeValue] = [:]
  ) -> MCPTransport
  public static func sse(url: String, headers: [String: RuntimeValue] = [:]) -> MCPTransport
}
public enum HookEvent: Sendable, Equatable {
  case beforeTool, afterTool, sessionStart, sessionEnd
  case native(String)
}
public struct PromptParameter: Sendable, Equatable {
  public static func parameter(name: String, description: String, defaultValue: String? = nil) -> PromptParameter
}
public enum PermissionOperation: Sendable, Equatable {
  case read, write, execute
  case tool(String)
}
public struct PermissionRule: Sendable, Equatable {
  public static func allow(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
  public static func ask(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
  public static func deny(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
}
public enum IgnorePurpose: Sendable, Equatable { case context, indexing }
public enum PluginMode: Sendable, Equatable { case native, components }
public enum ComponentKind: Sendable, Equatable {
  case skills, instructions, mcpServer, hook, subagent, command
  case lspServer, permissions, ignore, plugin
}
public enum ComponentReference: Sendable, Equatable {
  case skill(name: String)
  case instruction(name: String)
  case mcpServer(name: String)
  case hook(name: String)
  case subagent(name: String)
  case command(name: String)
  case lspServer(name: String)
  case permissions(name: String)
  case ignore(name: String)
  case plugin(name: String)
}
```

Literal conversions are closed and contextual. `PromptContent`,
`SectionReference`, `GroupReference`, `Version` and `RuntimeValue` accept string literals; `SkillSelection`
accepts string array literals. `ConfigurationValue` accepts strings, signed
64-bit integer literals, booleans, `nil`, arrays and string-keyed dictionaries.
Decimals use `.decimal("1.25")`, with finite JSON-number text; floating-point
literals are outside the grammar. Native configuration is a dictionary keyed
by registry schema ID, with a string-keyed configuration object as each value.
Duplicate decoded keys, compared using Swift String equality including canonical
Unicode equivalence, are domain errors at every dictionary level, even if their
values are equal. There is no user-defined literal conformance or conversion
from an already-typed `String`, `[String]` or dictionary to a wrapper type.

A bare section string names the declaring project's own instruction section;
`.section(name: "engineering", source: "rules")` names a source section. A root user-scope
declaration uses named instruction sources. Exported own sections belong to the
producer package and may be consumed in either supported scope. Ordered sections,
Markdown rendering and **front matter** (the structured metadata preceding a
content file's body) retain their domain semantics. ChatGPT is a named prompt
rendering destination, not an `Agent`. Prompt `append` paths remain relative to
the project root in project scope and runtime home in user scope; exported
prompt append paths are attached to the producer snapshot.

Omitted mode inherits the selection mode, then `.link`. Link and copy modes
preserve independent item pins. Omitted skill selection means all discovered
members; `[]` selects none. Exclusions win; overrides do not re-add excluded items.
An override outside an explicit selection is a `manifest.domain` error;
compatibility conversion of inert JSON overrides is defined under migration.
An all-member selection can retain overrides for members not yet discovered.

`path` locates a resource inside the declaring package or a named source
discovery root; `subpath` narrows the source's own root before discovery. Resource
paths are safe relative paths. Project package roots are project directories; a user package root is its
user-state directory. Exported resources remain pinned to their producer.
Absolute resource paths, traversal and escaping symlinks are errors. Source
locations retain their existing absolute/home-relative path support.
Executables are fixed program names or package-relative executable paths, with
separate argument arrays. Shell interpretation requires an explicitly declared
shell command. Symbolic environment and secret bindings are resolved by core's
machine binding provider at apply, or emitted as native references where supported.
Reading and dumping do not fetch values. Previews redact secrets; locks retain
binding identity, not values. Secret rotation does not change command identity.

A native schema ID, for example `claude-code/subagent@1`, identifies its agent,
component kind and adapter schema version. Agent identity is not repeated in the
value. Registry validation checks fields, client-version compatibility and the
component's recipients. A schema contributes only to its own agent and cannot
replace portable fields, conditions, resource identities, target paths, owned-key
boundaries or approval metadata. Collisions and unknown schemas/fields/types are
errors for active deployment. A native permission policy can use empty portable
rules when no exact portable translation exists. Native configuration remains
subject to ordinary preview, ownership and approval checks.

#### Component factories

```swift
public struct Component: Sendable, Equatable {
  public static func skills(
    source: String, select: SkillSelection = .all, exclude: [String] = [],
    mode: InstallMode? = nil, overrides: [SkillOverride] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func instructions(
    sections: [SectionReference] = [], chatGPT: [ChatGPTPrompt] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func mcpServer(
    name: String, transport: MCPTransport,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func hook(
    name: String, event: HookEvent, run: ExecutableInvocation,
    matcher: String? = nil, timeoutSeconds: Int? = nil,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func subagent(
    name: String, description: String, prompt: PromptContent,
    model: String? = nil, tools: [String]? = nil,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func command(
    name: String, description: String, prompt: PromptContent,
    parameters: [PromptParameter] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func lspServer(
    name: String, run: ExecutableInvocation, languages: [String: String],
    initializationOptions: [String: ConfigurationValue] = [:],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func permissions(
    name: String, rules: [PermissionRule],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func ignore(
    name: String, patterns: [String], purpose: IgnorePurpose = .context,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func plugin(
    name: String, path: String, source: String,
    mode: PluginMode = .components, select: [ComponentKind]? = nil,
    exclude: [ComponentReference] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
}
```

| Family | Payload semantics |
| --- | --- |
| Skills | Selection, exclusions, installation mode and member overrides preserve membership tracking and item pins. Duplicate names and conflicting members are diagnosed. |
| Instructions | Contributions append sections in traversal order. Prompt names are unique; each prompt has its own ordered sections. |
| MCP server | Stdio, Streamable HTTP and SSE are distinct transports. HTTP(S) URLs have no embedded credentials or fragments. Transport conversion must be exact; all registrations require approval. |
| Hook | Portable events mean before/after a tool invocation and session start/end. Adapters preserve event and command-result behavior. `.native("event")` requires exactly one explicit agent recipient and uses that agent's event grammar. Matchers use its verified grammar. Timeouts are positive seconds; omission retains the native default. Hooks preserve declaration order. |
| Subagent | Description and prompt are portable text. Model/tool names are identifiers validated by the recipient adapter. Omitted tools inherit its default; `[]` requires no tools. |
| Command | A named user-invoked prompt. Unique parameter names appear as literal `${input:name}` tokens; `$${input:name}` escapes a token. Missing required inputs and undeclared tokens are errors. Substitution is text, not shell evaluation. |
| LSP server | A stdio executable invocation, an extension-keyed `languages` dictionary and initialization options. Each dot-prefixed extension key maps to one language ID; duplicate keys are domain errors, so one extension has one language by construction. Plugin-only recipients get an adapter-generated native plugin recorded in the ledger. |
| Permissions | `.allow(.read, "pattern")`, `.ask(.write, "pattern")` and `.deny(.execute, "pattern")` put the operation before its pattern. Ordered last-match rules, with no match inheriting native policy. Read/write patterns are scope-relative globs (`*`, `**`, `?`). Execute/tool patterns use the adapter's verified request representation. Translation must preserve the full policy, including unmanaged rules; otherwise deployment fails. |
| Ignore | Ordered gitignore-style patterns with `!` negation, rooted at scope. Context and indexing are separate purposes, neither an access-denial guarantee. |
| Plugin/extension | Components mode decomposes a pinned container and selects all kinds when `select` is omitted; `[]` selects none. Typed references exclude individual children. Native mode keeps the container unchanged, requires one explicit recipient in `agents`, and accepts neither selection nor exclusions. Native configuration may configure only its registration, not rewrite container content. |

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
retarget imported content.

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
initializers. Duplicate group/export names and unknown local group names are
errors, including in unused declarations.

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

Cycle detection follows the active local/cross-source reference stack before
memoization and reports the cycle with source spans. A diamond is not a cycle.
Repeated references retain occurrence provenance. Conflicting active payloads
for the same named identity and overlapping recipients are errors. Equal named
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

### Examples

#### showxu/skills

The skills repository's existing declaration converts to:

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

### Files, versions and static grammar

Project source is `.agent/Agents.swift` relative to the explicit project root;
user source is `~/.agents/Agents.swift` relative to core's runtime home. Their
locks remain adjacent `agents.resolved` files. There is no ancestor search or
automatic user/project merge. An absent manifest means an absent declaration.
Existing `agents.json` requires migration; both filenames present is a conflict.

The first line is exactly `// agents-tools-version: 1.0`, at byte zero after an
optional UTF-8 BOM, terminated by LF, CRLF or EOF. General version syntax is
`// agents-tools-version: MAJOR.MINOR`, with the shown spaces, decimal components
without leading zeroes except `0`, and no patch, suffix or trailing whitespace.
A missing, malformed, duplicate or unsupported directive has its own diagnostic.
Directive recognition is lexical: a directive-shaped line comment outside a
string is a duplicate; text inside a string literal is ordinary content.
A 1.0 reader accepts exactly `1.0`. A future reader explicitly declares its support
set. Newer unsupported versions request an upgrade; older unsupported versions
request a supported converter. Language, package, adapter, lock and dump versions
are independent. Editing preserves BOM/newlines; migration emits UTF-8 without BOM.

Exactly one unqualified `import AgentsDescription` precedes top-level initialized,
single-binding `let` declarations. Names use the identifier grammar below, are
unique and cannot shadow vocabulary types. Constants bind in textual order; references to later constants
or themselves fail. There are no modifiers, attributes, wrappers or semicolons.
Every declaration, including unused constants and inactive branches, is checked.
Group-name references are resolved separately and may refer forward.

| Accepted syntax | Rule |
| --- | --- |
| `SourceFileSyntax`, `ImportDeclSyntax`, `VariableDeclSyntax` | The file structure above, with one identifier-pattern binding and initializer per declaration. |
| `StringLiteralExprSyntax` | Single-line and multiline literals from the closed lexical grammar below, with Swift decoding and no interpolation. Contextual `GroupReference` literals denote local groups; this is a type conversion, not an extra grammar production. |
| Integer, Boolean and nil literals | Decimal signed-64 integers with underscore separators, Bool and contextual nil. One unary minus is accepted only immediately adjacent to a decimal integer literal, with no intervening trivia. Other bases, floating literals and other numeric operators fail admission. |
| `ArrayExprSyntax` | Homogeneous arrays or a contextual, whitelisted array-literal conversion. Trailing commas are allowed. Empty literals require contextual type. |
| `DictionaryExprSyntax` | String-literal keys, homogeneous contextual values, or a contextual configuration object. `[:]` is an empty dictionary. Keys are decoded before duplicate detection; key references/interpolation are rejected. |
| `DeclReferenceExprSyntax` | A preceding constant, a vocabulary type as a member/call base, or the permitted operator. |
| Sequence/folded infix expressions | Only left-associative array `+` with exact `[T]` operands, at most 32 terms per additive chain. No concatenation of selections or configuration values, dictionary merging or string concatenation. A single half-open version range is admitted only in the source requirement position defined below; other operators are rejected. |
| `TupleExprSyntax` | One unlabeled expression in parentheses, not tuple values. |
| `MemberAccessExprSyntax` | Listed static factories, static `.all`, and enum cases, qualified or contextual. No instance-property access, subscripts or optional chaining. |
| `FunctionCallExprSyntax` | `Agents(...)`, listed static factories and associated cases, with exact labels and order. Literal-protocol entry points are reached only through literals. No arbitrary functions or trailing closures. |
| Type annotations | `String`, `Int`, `Bool`, named vocabulary types/aliases, `[T]` and `[String: T]`. No explicit Optional annotations, user aliases, qualified/generic/existential/function/metatype syntax. |

Grammar admission precedes SwiftParser and the iterative tree check precedes all
recursive SwiftSyntax processing. The normative productions below and the syntax
node table describe the same constructs, subject to the byte, token, chain and
depth limits below. These limits apply even to unused or inactive
expressions. Parser recovery, missing tokens and unexpected syntax are errors.
Tokens inside accepted nodes are admitted only in the roles above. Constructors create data;
they never invoke Swift compiler code while evaluating a manifest.

#### Type inference and literal conversions

An annotation or parameter type supplies context inward. Otherwise literals,
qualified calls and references synthesize types outward. Without context, a
string is `String`, an integer is `Int`, and a boolean is `Bool`. Arrays infer
from the first element; dictionaries infer from the first value and require all
other values to agree. Empty collections, nil and a leading shorthand member
cannot infer a type alone. Dictionary keys are always strings.

Optional parameter types remain part of the construction API: their context
admits `nil` or injection of a value of the wrapped type. Source annotations use
the non-Optional forms in the grammar; `T?` and `Optional<T>` fail grammar admission.
This does not change the module's public Optional signatures or compiler typing.

In contextual vocabulary types, only the literal conformances declared above
apply. Nested configuration literals propagate `ConfigurationValue` context to
every child. For an Optional parameter with wrapped type `T`, nil means absence;
non-nil values may receive `T` context and Optional injection. For non-Optional `ConfigurationValue`, nil means
configuration null. Signed integer literal conversion follows Swift's literal
semantics and must fit the declared literal type. `.decimal(...)` remains explicit.
No arbitrary user protocol dispatch or conversion of pre-existing typed values
is allowed. In particular, a `String` constant is not implicitly a `PromptContent`
or a `SectionReference`, `GroupReference` or `Version`, and a `[String]` constant is not a `SkillSelection`.

For array `+`, context propagates to both operands when present; otherwise infer
the left array and use its element type for the right array. An expression of
`SkillSelection` or `ConfigurationValue` type is not a Swift array. Constants
must be typed where declared, not inferred backward from later uses. A standalone
component is `let reviewer: Component = .subagent(...)` or a fully qualified
factory call. The evaluator's accepted language is a subset of real Swift typing,
not an alternative type system.

| Diagnostic | Meaning |
| --- | --- |
| `manifest.version.missing`, `.invalid`, `.duplicate`, `.unsupported` | Version selection failed. |
| `manifest.syntax` | Recognizer: a lexical or production violation, including missing/extra imports, juxtaposed identifiers, unsupported prefixes, raw strings, interpolation and malformed literals. SwiftParser syntax/recovery diagnostics can occur only after recognizer acceptance and the tree guard; such a disagreement is also an implementation regression. |
| `manifest.call`, `manifest.type`, `manifest.operator` | After the tree guard: unlisted call/member, incorrect labels/order/type, missing context, integer overflow or non-array use of the admitted `+` operator. The `..<` operator is typed as `Range<Version>` only in its admitted requirement position. Other operators, including closed ranges (`...`), fail admission with a located `manifest.syntax` diagnostic; `ClosedRange<Version>` also has no matching compiler overload. |
| `manifest.reference` | Unknown, forward, self, duplicate or shadowing constant name. |
| `manifest.domain`, `manifest.dictionary.duplicateKey` | Invalid domain value or duplicate decoded dictionary key. |
| `manifest.group.cycle`, `.missing`, `.conflict` | Invalid group/source graph, with the relevant reference chain. |
| `manifest.limit` | Recognizer: byte, token, syntax-storage reservation, comment, delimiter or chain limit. Iterative tree guard: node/depth limit. Later stages: evaluation, expansion, output or other named budget. |

Diagnostics include stable code, severity, message, primary span, related spans
and optional suggested edit. Spans use half-open UTF-8 byte offsets and 1-based
line/UTF-8-byte-column positions. At most 100 diagnostics plus one truncation
notice are produced. Any structural/type/domain error rejects the candidate;
no partial declaration is published.

#### Normative admission grammar

`AgentsManifest` owns a strict lexer and a deterministic recognizer for these
productions. No byte reaches SwiftParser until the complete input snapshot passes
recognition. SwiftParser supplies the lossless tree for editing and diagnostics;
it does not decide which source grammar is admitted. The recognizer does not
resolve constants or evaluate constructors. The subsequent type/domain checks
restrict identifiers and calls to the vocabulary and rules above.

The grammar uses `?` for optional, `*` for repetition and `|` for alternatives;
quoted punctuation denotes source tokens. Trivia may separate tokens except at
explicitly contiguous spellings. `newline` means at least one LF, CRLF or CR in
the separating trivia. The version directive is checked as specified above using
the same lexer's comment/string boundaries, before syntax is handed to SwiftParser.

```ebnf
document       = "import" "AgentsDescription" newline declaration
                 (newline declaration)* EOF ;
declaration    = "let" bareName (":" type)? "=" expression ;
type           = typeName | "[" type "]" | "[" "String" ":" type "]" ;
expression     = primary ("+" primary)* ;
primary        = string | integer | "-" integer | "true" | "false" | "nil"
               | namedValue | array | dictionary | "(" expression ")" ;
namedValue     = sourceCall | callee ("(" arguments? ")")? ;
callee         = bareName | bareName "." name | "." name ;
arguments      = argument ("," argument)* ;
argument       = (name ":")? expression ;
sourceCall     = (".source" | "Source.source") "(" "name" ":" expression ","
                 (("url" | "path") ":" expression
                    ("," requirement)? | "index" ":" expression)
                 ("," "subpath" ":" expression)? ")" ;
requirement    = ("from" | "exact" | "branch" | "revision") ":" expression
               | versionRange | rangeFactory ;
versionRange   = string "..<" string ;
rangeFactory   = (".upToNextMajor" | ".upToNextMinor")
                 "(" "from" ":" expression ")" ;
array          = "[" (expression ("," expression)* ","?)? "]" ;
dictionary     = "[" ":" "]"
               | "[" string ":" expression
                 ("," string ":" expression)* ","? "]" ;
```

`typeName` is exactly `String`, `Int`, `Bool`, or a public vocabulary type/alias
listed under Construction vocabulary. Type existence is checked during recognition. `sourceCall` takes
precedence over the general call production for `.source` and `Source.source`; those spellings cannot bypass it through `callee`. The
`.upToNextMajor` and `.upToNextMinor` callees are reserved to `rangeFactory`,
including its required argument list; other positions fail recognition.
`versionRange` is not a general expression: no grouping, constants, chaining or
other operands are admitted at its position. A range factory is contextual to
this same unlabeled requirement slot. Its argument receives `Version` context;
`from:` and `exact:` on the source also receive `Version` context. The subsequent
checker enforces version typing and domain validation. `callee` is a
syntactic spelling; subsequent vocabulary checking rejects unlisted functions,
instance members, literal-protocol entry points and invalid factory labels.
There is no postfix loop: a callee has at most one member operation and one call,
for a maximum grammatical chain of **2**. The independent postfix-operation
counter has a ceiling of **4** per primary; budget headroom admits no additional
production. No operation attaches to a call result, grouped
expression or subscript. The leading shorthand dot counts as one operation.
These are exactly the construction forms needed by the vocabulary. Parentheses
contain one expression; calls have no trailing comma; collections may have one.
The additive production has at most **32 terms**, with later type checking
requiring array operands. A version range has exactly two literal operands.
No assignment expression or prefix-keyword production exists. An identifier after a completed expression is a syntax error, not an
implicit prefix, argument or declaration.

The lexical grammar is closed:

- An identifier has ASCII head `[A-Za-z_]` and continuation `[A-Za-z_0-9]*`.
  Backticks, `$` names and non-ASCII identifiers are excluded; Unicode remains
  available in string values, including all domain names and paths. `name` excludes
  the reserved spellings listed below. `bareName` additionally excludes `await`,
  `copy`, `consume`, `each` and `unsafe`; those contextual spellings may occur as
  argument labels or member names, including `.copy`. They cannot introduce a
  prefix production or a bare binding/reference/callee in language 1.0.
- `integer` is `[0-9][0-9_]*`. The optional minus is a separate token immediately
  adjacent to its digits and only in the shown primary production. Its preceding
  source character must be ASCII whitespace (space, tab, CR or LF), `(`, `[`, `,`
  or `:`; an adjacent operator or comment terminator cannot precede the sign.
  Range checking follows during typing. There are no floating-point, exponent or
  radix literals;
  decimal configuration values use `.decimal("1.25")`.
- `string` is an ordinary double-quoted single-line literal or a triple-quoted
  multiline literal. Both allow exactly `\0`, `\\`, `\t`, `\n`, `\r`, `\"`, `\'`
  and `\u{H}` escapes, where `H` is one to eight ASCII hex digits naming a Unicode
  scalar (not a surrogate and at most `10FFFF`). Interpolation and escaped newline
  continuation are excluded. A single-line literal contains no unescaped CR/LF.
  A multiline opener is followed immediately by LF, CRLF or CR; its closing
  delimiter is preceded on its line only by spaces. A content line is either
  empty (zero characters before its newline) or starts with the closing delimiter's
  exact space indentation prefix, which Swift decoding removes. Additional leading
  spaces remain content. Whitespace-only lines are nonempty and must carry the
  full prefix. A tab anywhere in a content line's leading whitespace or in the
  closing delimiter's indentation is a syntax error; tabs after the first
  non-whitespace content character remain literal content. These rules apply
  identically to LF, CRLF and CR lines. Unescaped single/double quote runs are
  multiline content; the first
  unescaped triple quote closes it. Unescaped control scalars below U+0020 other
  than tab and multiline CR/LF are rejected. Raw strings do not exist: `#` outside
  string/comment content always fails recognition.
- Trivia is ASCII space, tab, LF, CRLF or CR, an optional BOM at byte zero, `//`
  comments through the next CR/LF or EOF, and `/* ... */` comments with at most
  **20** nested levels. The lexer validates UTF-8 throughout the snapshot. Strings
  and comments are opaque to expression counters. No other whitespace or comment
  form is admitted.
- Source punctuation is `( ) [ ] , : . = + ..<` and the adjacent numeric sign `-`,
  only in the roles in the productions. Callee member spellings contain no trivia
  around their dot; the call opener immediately follows its callee. Both `=` and
  binary `+` require at least one ASCII whitespace character (space, tab, CR or LF)
  immediately on each side. Comments do not substitute for whitespace: every
  comment in an operator-to-operand gap must itself have whitespace immediately
  before and after it. Thus `value /* note */ = -1` is admitted, but `value=0`,
  `value= 0`, `value=-1`, `a+b` and `a/* note */ + b` fail recognition. A located
  `manifest.syntax` diagnostic names the canonical spelling, such as
  `let value = -1` or `left + right`. These adjacency rules make
  Swift operator/member tokenization unambiguous. The single `..<` token is
  admitted only by `versionRange`, with either no whitespace on both sides or
  at least one ASCII whitespace character immediately on both sides. Comments
  in either operand gap must themselves be surrounded by whitespace, as for `+`.
  The canonical operator spelling is `"1.2.0"..<"1.8.0"`; an asymmetric boundary
  reports that spelling in a located `manifest.syntax` diagnostic. A lone `<`
  or `>` is never admitted. Other operators, generic angle
  brackets, braces, attributes, directives, macros and regex literals fail at
  recognition. There is no fallback to SwiftParser recovery.

The exact reserved identifier spellings are:

```text
_ Any Self as associatedtype break case catch class continue default defer deinit
do else enum extension fallthrough false fileprivate for func guard if import in
init inout internal is let nil open operator precedencegroup private protocol public
repeat rethrows return self static struct subscript super switch throw throws true
try typealias var where while
```

The lexer consumes each byte a bounded number of times, without backtracking or
unbounded lookahead. The parser uses at most two tokens of lookahead to distinguish
argument labels and dictionary entries, bounded delimiter frames for nested
productions, and loops for siblings and additive terms. It never speculatively
parses a whole expression and rewinds. Its work, storage, literal validation and
located-diagnostic construction are linear in bounded input size. A failure ends
recognition with a located `manifest.syntax` or `manifest.limit`; SwiftParser is
not called. Accepted grammar structure and spans are retained for differential
validation, independently of the later semantic IR.

#### Expanded-size accounting and resource limits

Admission reads at most 2,097,153 bytes, rejecting the extra byte before decoding,
lexing or parsing; it never allocates an unbounded file buffer. The exact admitted
snapshot is subsequently parsed. The recognizer permits at most 100,000 non-trivia
tokens; the minus and integer count separately, and `..<` counts as one token
plus its two string-literal operands. Range factories count as ordinary calls.
Version values charge their decoded bytes and nodes; range costs include both
endpoints before canonical lowering or serialization. It additionally reserves syntax
storage conservatively as **16 + 4 × (tokens + literal breaks + literal escapes)**,
capped at 100,000 nodes before SwiftParser is invoked. A literal break is each
CR or LF byte inside a string (CRLF counts twice); a literal escape is each
backslash byte inside a string, including escaped backslashes. These extra units
cover the parser's segmentation of multiline/escaped literals. The grammar-derived
reservation covers file and wrapper nodes as well as tokens; the independent
post-parse guard verifies actual counts.
A parser dependency change must revalidate the reservation against every grammar
production. The reservation is a language budget even when an individual input's
actual tree would be smaller; migration preflight applies it too.

Every open `[` or `(` increments a grammar counter before entering the enclosed
production, including type annotations. Square depth above **8** or combined
depth above **20** is `manifest.limit` at the first excess opener. Block-comment
depth above 20, a thirty-third additive term or an excess token/storage reservation
likewise fails before parsing. All other missing, misplaced or unsupported tokens
are `manifest.syntax` at the expected production's location (EOF for missing
input). Unbalanced openers remain counted until rejection; neither trivia nor
parenthesized subexpressions can bypass the counters. No production permits more
than two postfix operations or more than one numeric sign. These grammar bounds
apply equally to unused constants and inactive components.

Immediately after parsing, an **iterative, non-recursive** walk checks all syntax
nodes, including collections, tokens, missing nodes and unexpected nodes, in the
all-nodes view. The root has depth 1; depth above **128** or more than **100,000**
nodes is `manifest.limit`. Reserve stack/node budget before enqueueing children;
compute failure offsets from cached byte lengths during the walk. Do not call
recursive visitors, `hasError`, diagnostic generation, tree descriptions, source
mapping, equality or evaluation before this guard succeeds. The same rule applies
to transformed/folded trees: build/check them iteratively before recursive use.
The tree ceiling is independent of source delimiter depth and leaves room for
SwiftSyntax's wrapper nodes. Evaluation retains its separate frame/work limits.

No manifest input within the byte limit may crash or hang the hosting process,
including the GUI. Invalid and over-budget input must end in a bounded diagnostic
without writes or partial IR publication. This is a required implementation and
release invariant, not a conclusion inferred from `maximumNestingLevel` or a
finite set of passing examples. Parser construction, error inspection, tree
lifetime/teardown and every consumer of syntax are included in the invariant.

The square-bracket ceiling is **8**, independently of the general delimiter
ceiling of **20**. The complete manifest examples in this contract reach depth
3. Fixed family fields, excluding recursive configuration values and arbitrary
nested array constants, reach depth 5: root groups, components, ChatGPT prompts,
sections, then a section condition's recipient array.
Eight leaves three levels of syntax-depth margin over that fixed structure.
`ConfigurationValue` is recursive, so its vocabulary has no intrinsic finite
nesting maximum; its expanded values remain limited to depth 64. Named constants
allow deeper configuration values to be assembled without deep source nesting,
subject to all expansion budgets. This separates authoring depth from value depth
and caps square-bracket ambiguity before parser recovery. The parser's own
nesting option remains defense in depth, not a parse-time bound.

The evaluator may store immutable values as a DAG, but all limits are measured
as if each reference were expanded by value. Each value carries a checked cost
summary: expanded node count, decoded string/key bytes, canonical encoded byte
count, maximum depth and source-origin count. For a container, costs are its own
cost plus the sum of each child's costs **for every occurrence**. Reusing a
constant twice adds its full cost twice, including all descendants. An alias
inherits the referenced cost; memoization does not discount expansion.

Compute costs bottom-up with checked, saturating arithmetic capped at the limit
plus one. Before concatenation, reference insertion, group expansion or any output
allocation, combine the summaries and reject an oversized result. No descendant
walk, copying, formatting, map expansion or equality comparison occurs first.
This rejects exponential reuse such as repeated `array([previous, previous])`
while that value is constructed, even when its underlying storage is small.
Every constant must fit individually; totals count every top-level definition
and every root occurrence, including inactive and unused values.

Encoded-size summaries include repeated dictionary keys, string escaping,
punctuation, indentation and trailing newline. Before writing a dump or generated
source, reserve its complete bounded size from those summaries. When formatting
context changes indentation, use a checked worst-case bound or recompute the
summary over the bounded structure before emitting bytes. Locations and provenance
are separately budgeted and included in the final dump's size reservation.

| Resource | Language 1.0 bound |
| --- | --- |
| Input | 2,097,152 UTF-8 bytes per manifest, enforced by bounded reading before grammar admission, decoding or parsing; invalid UTF-8 fails. |
| Admission | Linear lexer and grammar recognizer; 100,000 tokens; syntax reservation `16 + 4 × (tokens + literal breaks + literal escapes) ≤ 100,000`; square depth 8; combined square/parenthesis depth 20; comment depth 20; postfix-operation budget 4 (the grammar uses at most 2); one adjacent numeric sign; additive chain 32 terms. Failures reject before SwiftParser. |
| Parser/tree | `maximumNestingLevel: 20` in every build configuration. Iterative guard: depth 128 (root 1), 100,000 syntax nodes including tokens and excluding trivia, before any recursive processing. |
| Evaluator | 64 active expression/reference frames; 100,000 work steps per document. Every visited expression, lookup, produced node and concatenation element costs a step. |
| Expanded values | 100,000 nodes and 16,777,216 decoded string/key bytes across the document's values, charged by occurrence, with 10,000 entries per array/dictionary and maximum expanded value depth 64, including referenced descendants. |
| Linking | 256 distinct source snapshots, 16,777,216 aggregate manifest input bytes, 64 active group references, 10,000 component contributions and 1,000,000 total resolution/evaluation steps, including backtracking. Linked expanded values also obey the node/string limits above. |
| Source maps | 100,000 location records, 1,000,000 total origin spans and 16,777,216 encoded bytes; repeated origins count repeatedly. Reserve before expanding a reference's map. |
| Output | 33,554,432 bytes for the entire dump including locations/diagnostics; generated manifest source still obeys the 2,097,152-byte input limit. |
| Comparison/edit batch | 200,000 expanded node-pair visits per full comparison; 1,000,000 aggregate steps and 100 requests per edit batch. Operand cost summaries are checked before comparison starts. |

A work budget is charged before executing a step; exhaustion is a diagnostic,
not an invitation to return a truncated model. Comparisons can use identity or
memoization only after verifying expanded operand bounds. Diagnostics and JSON
escaping are bounded operations. Source download/extraction limits remain in
core's loader before the linker receives bytes. Cancellation is separate from
language semantics. Fuzzing and adversarial reuse tests cover every bounded
consumer of values, not just the parser.

### Document editing

`AgentsManifest.DeclarationDocument` owns original bytes, syntax, declaration IR,
source maps, diagnostics, editability and the original byte digest. Domain edits
use the same vocabulary names as authored values; lowering converts them to core
IR. Snapshot node handles are separate from persistent component identities.

```swift
public struct DeclarationDocument: Sendable {
  public init(bytes: [UInt8], identity: DocumentIdentity) throws
  public var declaration: DeclarationIR { get }
  public var diagnostics: [ManifestDiagnostic] { get }
  public func editability(of node: NodeID) -> Editability
  public func preparing(_ edits: [ManifestEdit]) throws -> DocumentChange
}
public enum ManifestEdit: Sendable {
  case setDefaultAgents([Agent]?)
  case upsertSource(Source)
  case removeSource(alias: String)
  case insertComponent(Component, into: ContainerID, at: InsertionPosition)
  case replaceComponent(NodeID, with: Component)
  case removeComponent(NodeID)
  case moveComponent(NodeID, into: ContainerID, at: InsertionPosition)
  case setSkillSelection(NodeID, SkillSelection)
  case upsertSkillOverride(NodeID, SkillOverride)
  case removeSkillOverride(NodeID, name: String)
  case insertSection(SectionReference, into: NodeID, at: InsertionPosition)
  case removeSection(NodeID)
  case moveSection(NodeID, at: InsertionPosition)
  case upsertPrompt(NodeID, ChatGPTPrompt)
  case removePrompt(NodeID, name: String)
  case upsertGroup(ComponentGroup)
  case removeGroup(name: String)
  case insertGroupReference(GroupReference, into: ContainerID, at: InsertionPosition)
  case removeGroupReference(NodeID)
  case setExports([String])
  case setWatch([String])
  case setDictionaryEntry(NodeID, key: String, value: StaticValue)
  case removeDictionaryEntry(NodeID, key: String)
  case replaceConstant(NodeID, with: StaticValue, acceptingUses: [NodeID])
}
```

`NodeID` is an opaque handle bound to the document digest. `ContainerID` addresses
the root or a group. `InsertionPosition` is `.first`, `.last`, `.before(NodeID)`
or `.after(NodeID)`. `StaticValue` is the bounded checked algebra of literals,
collections and vocabulary values, not raw Swift text. Dictionary value edits
must match the target's inferred value type. Whole-component replacement covers
recipients, conditions and all family-specific fields.

The document applies requests in order to construct the expected complete IR,
checks their complete impact and budgets, and produces disjoint byte patches.
`DocumentChange` contains the original digest, patches, resulting bytes/digest,
expected declaration, impacted references, diagnostics and semantic delta.
Only the document layer constructs it. `AgentsUpdates` incorporates it in prepare;
front ends never save source independently.

| Construct | Editability |
| --- | --- |
| Direct literal/factory argument | Replace the exact value range; retain outer trivia. |
| Direct array literal | Insert, remove and move identifiable elements, preserving order. |
| Direct dictionary literal | Set/remove a decoded key's value or entry; preserve unrelated entries and their order/comments. |
| Direct root/group/component construction | Insert missing arguments in signature order and remove/replace unambiguous arguments. |
| Constant reference | Readable with all references identified. Only explicit `replaceConstant` changes its definition, accepting the complete impacted reference set. |
| Concatenation/assembled value | Readable; expanded element edits are read-only. An independently addressed literal leaf or explicitly replaced constant can be edited with its full impact accepted. |
| Exported declaration | Read-only in a consumer. Edit its `GroupReference.condition` or the producer's own document, never cached source. |
| Ambiguous trivia or separators | `manifest.edit.readOnly` with a span and reason; no regeneration fallback. |

Removing referenced sources/groups requires a complete batch that repairs the
references. Stale handles, overlaps, incomplete impact and mismatched results have
separate `manifest.edit.stale`, `.overlap`, `.impact`, `.mismatch` diagnostics.

Comments follow SwiftSyntax trivia ownership:

1. Standalone comments immediately above a node with no separating blank line
   belong to that node; a dictionary key and value form one entry node.
2. Comments beginning on a node's or its comma's line belong to that preceding
   node, including multiline block comments.
3. Comments inside an expression or between it and its comma belong to it.
4. Comments separated from the next node by a blank line belong to the container.
   The preamble and version directive belong to the file.
5. Delete/move operations carry owned comments. Value replacement preserves outer
   comments; whole-node replacement refuses if internal comments cannot be mapped
   to retained fields. Unowned comments remain in place.
6. Empty containers become `[]` or `[:]` only when their interiors are whitespace.
   Container comments survive; ambiguous mixed layouts or comment-only insertion
   sites are read-only.

New nodes use the shortest canonical type-correct spelling. `Agents(...)` is the
only ordinary initializer in manifest expressions; nested values use leading-dot
factories. Sources use `.source(name:url:)`, `.source(name:path:)` or
`.source(name:index:)`, and references use `source:`.
Requirement values use the canonical printer defined under Construction vocabulary. Literal conformances provide strings
for prompts, own sections, local group references and versions, array literals for explicit skill
selections, and JSON-style configuration literals. Dictionary literals and
direct factories construct the remaining values. Existing unmodified expressions keep their spelling. New text uses
the container's consistent indentation, newline and comma style; absent evidence,
use two spaces, LF and trailing commas in multiline collections. Argument order
follows signatures; root insertion order is `defaultAgents`, `exports`, `sources`,
`components`, `groups`, `uses`, `watch`. `upsertSource(Source)` preserves the
complete requirement value. Fresh node layout follows the deterministic migration printer;
existing surrounding style takes precedence. Conflicting local style is an
editability diagnostic, not permission to reformat the file.

The editor and migration printer emit one ASCII space on each side of `=` and
`+`, with adjacent sign/digits for negative integers: `let value = -1`. A value
replacement re-checks both joins with the unchanged source, including neighboring
comments, against the lexical rules before it becomes a patch. For example,
replacing `0` in `[/* note */0]` emits ` -1` inside that value's replacement range,
producing `[/* note */ -1]` while preserving all bytes outside the range. The
editor never joins a sign to `=` or to a comment terminator. A source that already
fails recognition, such as `let value=0`, cannot receive a domain edit. If a safe
boundary cannot be represented in the authorized patch range, preparation fails
with an editability diagnostic. The complete candidate passes recognition again
before SwiftParser is invoked; a failed check publishes no patch or source bytes.

The invariants are byte-exact no-op return, byte preservation outside disjoint
patch ranges, and full reparse/type-check/evaluation/domain validation before
commit. The resulting complete IR must equal the expected IR, including inactive
groups and exports; only source positions and trivia are excluded. Prepare then
re-links affected sources and revalidates capabilities/targets. All stages use the
expanded-size budgets. BOM, final-newline presence and unrelated bytes survive.

Range replacement re-checks both operator/operand boundaries and the containing
source requirement slot. A complete replacement uses the canonical requirement
printer, including changing the argument label when its range category changes. A leaf endpoint edit preserves surrounding trivia only if the
result still meets balanced spacing and comment rules; otherwise include the
necessary whitespace in the explicit patch or report `manifest.edit.readOnly`
when comment ownership is ambiguous. Re-run admission, typing and expected-IR
comparison before publishing any edit.

### Evaluated JSON dump

`agents manifest dump --json` reads and evaluates only the local declaration.
It does not resolve external groups, fetch sources/secrets, inspect native files
or compile/run the manifest. Conditional branches and group references remain
symbolic. Successful stdout is one UTF-8 JSON object with sorted keys, two-space
indentation and a trailing LF. Invalid input exits 1 with stderr diagnostics and
no partial success object.

The root has `schemaVersion: 1`, `kind: "manifest"`, `languageVersion: "1.0"`,
`sourceDigest`, `declaration`, `locations` and `diagnostics`. The digest is
`sha256:` plus 64 lowercase hexadecimal digits over the original bytes.
`declaration` has `defaultAgents`, `exports`, `sources`, `components`, `groups`,
`uses` and `watch`. Default arrays are empty, Optional absence is null, and
explicit empty recipients remain distinct from inheritance.

A component encodes directly as `{ "kind": "mcpServer", "name": "workspace",
"transport": { ... }, "agents": ["claude-code"], "condition": null,
"native": {} }`. There is no payload wrapper. The remaining schema is determined
by the vocabulary as follows:

- Tagged families encode `{kind, ...fields}`. Component/transport kinds are
  their factory names. `ExecutableInvocation` is `kind: "executable"` with executable,
  arguments, environment and workingDirectory. `.group(name:)` references encode
  kind `local`; `.group(name:source:)` references encode kind `exported`, with
  name and condition. An exported reference always has a non-null source; a local
  reference has none (encoded as null). Conditions encode their
  three dimensions without a kind. Permission rules encode
  `{kind: "allow" | "ask" | "deny", operation, pattern}`; their two unlabeled
  factory arguments use the keys `operation` and `pattern`. LSP `languages`
  encodes an object mapping extension keys to language-ID strings.
- A source has `kind: "git" | "local" | "index"`, name, location (`url`, `path` or
  `index`, matching its factory field), subpath and requirement. A `path:` source
  with a requirement remains kind `local`. Requirement is null or an
  object with exactly one of `branch`, `revision`, `exact`, `from`, `upToNextMinor`,
  or `from` plus `to`, matching core's `SourceRequirement` encoding. Version values encode
  as normalized version strings. Every range value encodes its canonical
  requirement kind: `from`,
  `upToNextMinor`, or `from`/`to`, regardless of its construction spelling.
- Groups, skill overrides, ChatGPT prompts, prompt parameters and resources encode
  their factory fields without a factory-name tag; the resource's unlabeled
  subject uses key `path`. Arrays/dictionaries encode as JSON collections,
  with defaults supplied.
  Exports and watch are string arrays. An instruction section is always an object
  with name, source and condition, even when authored as a string.
- Skill selection encodes `"all"` or an array of names. Prompt content is
  `{kind: "literal", value: <string>}` or `{kind: "file", path, source}`.
  Runtime values similarly use literal/environment/secret and value. Literal
  spelling and explicit equivalent cases have identical evaluated output.
- Payload-free enum cases are strings, except mixed enums always use tagged
  objects. Associated values retain labels; a single unlabeled payload uses
  `value`. Typed component references use kind and name. Configuration values
  retain kind and value tags, including nested arrays/objects; null has only kind,
  and decimal values remain strings to prevent numeric rounding.
- Agent IDs are `claude-code`, `codex`, `cursor`, `gemini-cli`, `opencode`;
  platforms are `macos`, `linux`; other enum spellings are unchanged.

Components, group references, sections, hooks, permission rules, ignore patterns,
arguments and prompt parameters preserve order. Definitions of sources/groups,
exports, watch, named prompts and overrides sort by name; recipients, exclusions
and explicit skill selections sort by canonical identity. Dictionary keys sort
by decoded UTF-8 bytes. Typed plugin exclusions sort by kind then name.
Constants are substituted by value within the checked expansion budget.

A location has `pointer` (JSON Pointer into the normalized declaration), `span`,
`origins`, `defaulted` and `editability`. Spans have document `"manifest"`, start/end
byte offsets and starting line/column. A use's span identifies the use site;
origins include definitions. Missing fields anchor to their containing construction
with defaulted true. Editability has kind `direct`, `sharedConstant` or `readOnly`,
plus relevant stable reason and impacted-reference spans. Locations sort by
pointer then start offset; runtime node handles are not serialized.

Diagnostics have code, severity, message, span and related spans, sorted by
position then code. No timestamps, cache paths or resolved secrets are emitted.
Readers ignore unknown object keys but reject unsupported schema versions and
unknown semantic discriminants. Changed meanings or new discriminants require
a new schema version; optional metadata additions do not. Source digest/locations
may change with comments while declaration stays equal. Entire output and map
size are reserved before serialization under the expanded-size budgets.

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

| Target | Ownership and dependencies |
| --- | --- |
| `AgentsDescription` | Public immutable construction vocabulary and literal conformances; standard library only. |
| `AgentsCore` | Agent-independent declaration/resolved IR, source identity, requirements, provenance/span values, capability protocols/descriptors, approval identity, cache, locks and transactions. No syntax or adapter-implementation dependency. |
| `AgentsManifest` | Version selection, strict lexer and grammar recognizer, iterative tree guard, static symbol/type checking and evaluation, diagnostics, source maps, lowering to IR and source editing. Depends on `AgentsDescription`, `AgentsCore`, SwiftSyntax and SwiftParser. No deployment/resolution I/O. |
| `AgentsSkills` | Existing skill discovery, metadata and materialization; depends on `AgentsCore` and Yams. |
| `AgentsInstructions` | Existing instruction discovery, lifecycle and Markdown transformations; depends on `AgentsCore` and swift-markdown. |
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

These guarantees extend [State and Source Cache](../Architecture/State.md) when
implemented. The existing journal remains the sole persistence owner. Validated
source bytes replace declaration re-encoding; lock/watch retain their encoders.
One transaction includes source, ledger, affected watch state, native artifacts,
cache retention and pruning. Source-only changes use the same protocol.

Prepare records presence, physical identity and byte digest for the manifest,
ledger, watch state and relevant targets, plus source snapshot identities.
Under the scope writer lock, recover first, re-read/compare preconditions before
retention and again immediately before publication. A changed comment invalidates
a preview even when semantics are equal. Apply never rebases a stale source patch.
Descriptor-relative operations retain validated ancestors and reject symlinked or
unregistered paths. Staging, backups, journal records and parent directories follow
the existing fsync/metadata rules.

### Publication and concurrent writers

The transaction must read the exact preimage of any committed replacement.
Presence checks alone never authorize a blind overwrite. Each journal operation
records its expected presence/identity/hash, transaction-owned staging identity
and intended postimage before publication:

| Expected destination | Atomic operation and conflict handling |
| --- | --- |
| Absent | Publish with atomic no-replace semantics: Linux `renameat2(RENAME_NOREPLACE)`, macOS `renamex_np(RENAME_EXCL)` or a descriptor-relative/link-based equivalent with the same guarantee. A concurrent creator causes an existence conflict; its bytes and identity remain untouched. Ordinary replacing rename is never a fallback. |
| Existing | Revalidate the read preimage, exchange atomically with staging and retain the displaced object. Read/compare that displaced object before confirming publication. Unexpected bytes are preserved as a conflict preimage; the operation cannot commit as a successful replacement. |
| Deletion | Move the entry into unique journal-owned quarantine without replacing another entry; verify its identity/digest before destructive cleanup. Unexpected content remains recoverable, and restoration uses no-replace semantics if the original name is occupied. |

For an absent destination, the staged inode identity and content digest are
recorded durably before no-replace publication. After successful publication,
sync the destination's parent before marking the operation applied. Recovery
classifies the destination using that recorded physical identity and digest,
not just its filename or equal content. In a link-based implementation it also
accounts for the retained staging link until cleanup.

If another file appeared and publication failed, the transaction rolls back its
other verified changes, preserves the concurrent file, and reports a conflict.
During migration, `agents.json` remains available or is restored through the
same protected rollback; the tool does not accept the newly appeared Swift file
as its own migration output. If a crash occurred before recording publication's
result, recovery can recognize its own published inode. Any other inode, even
with equal bytes, is external and must be preserved. Missing/changed evidence
produces an unresolved conflict rather than guessed ownership.

Recovery verifies exchanged/quarantined preimages even if a crash preceded the
conflict marker. An unexpected preimage is never disposable staging. Restoring a
preimage may replace only the verified transaction-owned postimage; if an external
writer changed that path again, retain both versions and stop for owner resolution.
Creation rollback removes only its verified transaction-owned object; it never
unlinks a concurrent creator's file. Unsupported atomic primitives cause failure
before mutation. These rules also protect creation/replacement of the ledger and
other transaction destinations; there is no unguarded creation path.

### Recovery outcomes and approvals

An applying journal restores the previous verified generation; a committed journal
finishes cleanup. Conflicted journals retain all data needed for resolution.
Backup/staging cleanup requires both a durable terminal phase and verified
ownership. Read-only operations report pending recovery and never replay it.
Recovery remains repeatable across interruption and reports
`CoreError.transactionRecovered`; consumers retry preparation. Outcome reporting
distinguishes unchanged, committed and unresolved recovery, including failures
after the commit marker. The scope lock serializes cooperating tools; the
publication rules protect retained data when external editors ignore that lock.

Approval identity covers declarations, commands and shipped content, excluding
comments and formatting. Approval is machine-local; a copied ledger disposition
is not authorization on another machine. Apply checks the local approval for the
resolved content identity and reports pending/refused components independently
of source validity.

## Compatibility / Migration Impact

### Field mapping

`agents migrate` validates the existing strict JSON declaration and converts its
intent without fetching, re-resolving pins or inferring installed recipients.

| JSON | Swift construction |
| --- | --- |
| `agents` | `Agents(defaultAgents: [...])`; omitted remains inheritance, explicit empty remains empty. |
| `sources.<alias>.git` | `.source(name: <alias>, url: <value>, ...)`. |
| `sources.<alias>.local` | `.source(name: <alias>, path: <value>, ...)`. |
| `sources.<alias>.well-known` | `.source(name: <alias>, index: <value>, ...)`. |
| `sources.<alias>.path` | `subpath:` unchanged. |
| `branch`, `revision`, `exact` | Corresponding source factory label. |
| `from`, `to` | Decode the lower bound and optional upper bound, canonicalize the range value, then print `from:`, the minor-range factory or the unlabeled literal range as appropriate. |
| `upToNextMinor` | The unlabeled `.upToNextMinor(from: "version")` requirement. |
| `skills.<alias>` | `.skills(source: <alias>, ...)` in components. |
| `select: "all"` | Omit `select`; explicit names become a string array literal, including `[]`. |
| `exclude` | String array, omitted when empty. |
| Skill `agents`, `mode` | Corresponding fields; omission preserves inheritance. |
| `overrides.<name>` | `.skill(name: ..., mode: ..., agents: ...)`, subject to the explicit inert-override rule below. |
| `instructions` | One `.instructions(...)` after skill selections; missing object means no contribution. |
| `instructions.agents` | `agents:` on that component, preserving explicit recipient intent. |
| `instructions.sections[]` | Bare name becomes a string literal; `alias:name` becomes `.section(name: "name", source: "alias")`. Preserve order and repetitions. |
| `instructions.chatgpt.<name>` | `.prompt(name: ..., sections: ..., append: ...)` in `chatGPT`. Names and per-prompt section order remain exact. |
| Prompt `append` | Unchanged string, with existing project-root/user-home interpretation. |
| `watch[]` | Source alias strings in `watch`, with no condition. |
| Missing sources/skills/prompts/watch | Empty collections, with default-valued arguments omitted. |

Unknown JSON fields, duplicate object keys, invalid UTF-8 and declarations invalid
under the existing validators remain errors. Every currently valid declaration
whose converted manifest fits the language budgets has a deterministic conversion.
Migration preflights all applicable language budgets, including parsing, evaluation,
expansion and output, before starting a state transaction. If any limit is exceeded, it reports `migration.limit`
with the limiting budget and leaves the original declaration, ledger, watch state
and native files untouched. The compatibility transformations below handle valid
JSON that differs from the manifest's domain rules; exceeding a resource budget
never triggers truncation or partial migration.

### Compatibility transformations

Two explicit transformations precede printing and are included in the migration
result's ordered diagnostics:

1. For an explicit skill selection, an override whose name is not in `select` is
   provably inert under existing lifecycle behavior. Remove it from the converted
   declaration and report `migration.inertOverride` with its original JSON Pointer,
   full value and reason. Preserve overrides for selected names, including excluded
   selected names, and all overrides of an all-member selection. No override is
   removed merely because discovery does not currently find its member.
2. Rename a source alias `.` to the first unused name in `source`, `source-2`,
   `source-3`, and so on, considering all original aliases. Report
   `migration.sourceAliasRenamed` with old/new aliases. Rewrite its source entry,
   skill-selection key, watch references and explicit `.:name` section references
   in both native instructions and ChatGPT prompts. Bare section names still mean
   own sections and are not rewritten. Normalized source identities and pins do
   not change.

Diagnostics sort by original JSON Pointer and code. They are returned in preview
and apply reports; conversion never silently discards the removed override or
hides a rename. The compatibility projection compares effective selections,
recipients, modes, ordered content, subscriptions and source identities after
applying precisely those reported transformations. Apart from them, explicit
versus inherited intent and every field above are preserved. No groups, native
settings or additional approvals are synthesized.

### Deterministic source and migration transaction

Git locations use the legacy `SourceDeclaration` identity normalization described
under Construction vocabulary, including single-label hosts and SCP-style SSH
locations. Local paths remain paths. Migration and the JSON-to-IR compatibility
path canonicalize requirement values identically to Swift lowering. A legacy
`from`/`to` pair may therefore print as `from:` or a minor-range factory. This
preserves the selected tag set and every exact ledger pin.

The same validated JSON, language version and compatibility transformations
produce identical source bytes and diagnostic records. Emit the version line,
import, one blank line, then `let agents = Agents(...)`; two-space indentation,
LF, no BOM and one final newline. Assignment and array concatenation use one
ASCII space on each side of `=` and `+`; negative literals use an adjacent sign
and digits, as in `let value = -1`. Strings use ordinary quotes; escape quotes,
backslashes, LF, CR and tab, and encode other controls as lowercase Swift
`\u{...}`. Preserve other Unicode scalars without normalization.

Use literal prompts/sections/selections/dictionaries and direct factories.
Omit default-valued arguments, retaining explicit Optional values that distinguish
inheritance. Signature order determines labels. Sort aliases, selection/override
names, prompt names, watch names and recipient IDs by canonical UTF-8 identity;
keep instruction and per-prompt section order. A collection of scalar literals or
payload-free enum members fits inline when the complete line, including indentation
and comma, is at most 80 UTF-8 bytes; otherwise expand it. Collections containing
factory/initializer calls are multiline. A call with only scalar arguments fits
inline under the same limit; calls with collections/nested calls are multiline.
Multiline collections have trailing commas; call arguments have none after the
last argument. Empty collections are `[]` or `[:]`. No formatting pass touches
an already migrated manifest.

One transaction creates `Agents.swift`, upgrades an existing ledger as needed and
removes `agents.json`. Creation uses the no-replace protocol above. Existing native
files, cache content and watch-state bytes do not change. A missing ledger stays
missing. Repeating migration after success is unchanged. Both declaration files
present is a conflict; Swift source with a version-1 lock permits a lock-only
migration. Normal commands report required migration rather than converting
implicitly. A failed migration retains a recoverable original declaration and
never treats a concurrent file as generated output.

### Requirement persistence and comparison

Canonicalization applies to new IR and new serialized requirement fields.
Semantic comparison of existing range requirements expands them to bounds;
raw enum-case equality or raw requirement JSON equality is insufficient. Branch
and revision compare their strings; exact versions compare normalized full
versions; absence retains its distinct latest-tag/default-branch policy.

| Site | Contract |
| --- | --- |
| Declaration IR, JSON compatibility projection and dump | Canonical requirement kinds and normalized version strings; comparisons use range-value equality. A factory, literal range and legacy JSON denoting equal bounds compare equal. |
| Document edits and `upsertSource` | Compare semantic values; an equal edit returns original source bytes. New or changed nodes print canonically; untouched spelling is retained. |
| `LockedSource.requirement` in the deployment ledger and requirements in `groupResolutions` | Newly written records use canonical requirements. Reading existing records preserves their bytes and builds a semantic comparison view. A requirement-spelling difference alone never changes pins, reports an update or stages a write. |
| Lock version 1 to version 2 conversion | Canonicalize requirements while preserving exact source/item pins and ownership. An existing version-2 ledger is not upgraded merely to canonicalize requirements. |
| Skill/instruction lock producers, combined update-plan conflict and change detection | Compare source identity, discovery root and semantic requirement values; merge equal ranges without a conflict. If the complete resulting ledger is semantically unchanged, keep its original bytes even when another state file changes. A necessary ledger rewrite emits canonical requirements. |
| Resolution-session reuse and cache descriptors | Key requirement comparisons by semantic value, not case spelling. Cache identity/materialization keys continue to use source identity and exact revision/artifact digest; restore uses the stored pins without requirement re-resolution. |
| `agents.watch` | Stores source identities and `seen` revision/artifact digests, no requirement kind. Migration retains its bytes. Re-evaluating an equivalent declaration preserves the subscription and baseline; watch-created lock descriptors follow the ledger rule. |

These rules extend the existing requirement comparisons in source argument
selection, source resolution sessions and combined update planning. They do not
rewrite historical records on read. State transactions compare semantic state
before choosing any serialization and retain the original ledger bytes on a no-op.

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

Migration derives ownership only from existing install/target records. Shared
skill destinations coalesce only when mode, content and ownership agree.
Instruction records preserve these separate removal rules exactly:

| Existing instruction record | Version-2 ownership and removal |
| --- | --- |
| Generated unit target (`import == nil`) | Whole generated rendering, governed by `blockHash`. When obsolete, delete the file if its current bytes hash to `blockHash`; preserve drifted bytes. Its existing `created: false` does not prevent deletion. |
| Forwarding/import target (`import != nil`) | Managed import block with its marker/hash and the existing `created` flag. Remove the managed block; delete the whole file only when `created` is true and no custom content remains. Otherwise preserve the remaining file. |

Heading offsets, import markers, block hashes and creation provenance retain their
meanings. Missing targets remain missing; drifted targets retain expected hashes,
not hashes of adopted bytes. Migration does not scan and claim unmanaged native
files. Source-alias renaming changes no normalized ledger identity. No generated
unit is reclassified as a non-deletable custom file, and no forwarding file gains
whole-file ownership from a unit-target rule.

Lock conversion is deterministic for the same old lock and explicit registered
layout. An already-version-2 ledger remains byte-identical when unchanged.
Restoration must address the same original pins and physical targets after
conversion, and removing the last instruction must produce the same deletion or
preservation result as before conversion.

## Validation Contract

Every Swift code block, including interface and editor-API blocks, must pass
`swiftc -parse`; signature-only interface blocks use `swiftc -frontend -parse`
with `.swiftinterface` inputs so getter declarations are parsed in interface mode.
Positive fixtures compile against `AgentsDescription` and their
compiled values match static evaluation under plain value equality, including
equal range forms and string-literal group references. Compiler-required literal conformances and evaluator
registrations are checked against the same signature inventory. Negative fixtures
cover unsupported syntax, contextual typing, duplicate dictionary keys, budgets
and spans. No accepted static value may fail real Swift type checking.

Adversarial tests run every input in a subprocess with a parent watchdog and
assert normal completion without signals, crashes or unbounded memory growth.
Fixed regressions include balanced/unbalanced square nests, mixed square/call
nests, dictionaries, nested shorthand calls and parentheses, brace nests, generic
types `A<A<...B...>>`, ambiguous `a<a<...b`, and long member, numeric-prefix,
force-unwrap, call, subscript and `+` chains. Include the small generic-type form,
200,000-operation chains, and repeated `copy`, `await`, `consume`, `each` and
`unsafe` before an operand, all within the byte limit. Raw-string boundary cases
include `#"""#` followed by dangerous declarations and a comment containing
`"""#`; rejection occurs at the first hash, before SwiftParser sees that snapshot.
All forbidden forms must fail recognition. Bounded grammar forms must complete
parsing and the tree guard normally. Explicit synthetic deep/wide trees exercise
the iterative node/depth rejection independently of admission.

Literal/trivia cases cover ordinary escapes, multiline indentation and quote
runs, malformed Unicode escapes, raw delimiters, interpolation and nested comments.
Include absent/asymmetric whitespace and comments on both sides of `=` and `+`,
numeric signs at every permitted and forbidden boundary, and negative value
replacement with byte preservation through editor preparation. Multiline cases
distinguish empty, short whitespace-only and fully indented lines; cover mixed
indentation, leading tabs, closing-delimiter tabs and CRLF line endings. Operator
rejections assert both the diagnostic location and its canonical spelling.
Verify contextual words in permitted label/member positions as well as rejected
bare/prefix uses, juxtaposed identifiers, non-ASCII identifier rejection, and
Unicode string content. Check exact byte, delimiter, comment, additive, token,
syntax-reservation and actual-tree boundaries with located diagnostics. Rejections
assert zero SwiftParser calls. All complete examples pass recognition, the tree
guard, syntax checks and real compiler type checking.

CI runs **differential fuzzing**, not merely crash testing. Each run includes at
least 256 generated grammar constructions, 128 arbitrary token sequences, 128
injected disallowed-token cases and 256 mutations of generated sources, with
recorded deterministic seeds. Vary declaration/type structure, call labels,
array/dictionary nesting, literal boundaries, contextual words, comments,
truncation and near-limit input sizes. The recognizer itself must never crash or
exceed the per-case watchdog, whether it accepts or rejects an input.

For **every accepted input**, SwiftParser must produce an error-free tree whose
projection equals the recognizer's: declaration kind/name/span, type structure,
call labels and nesting, member/reference structure, arrays/dictionaries,
parentheses/additive expressions and exact literal spellings and UTF-8 spans.
Wrapper nodes and trivia are excluded from this projection. Compare independently
constructed projections; using SwiftParser to supply either recognizer decisions
or its expected structure would invalidate the test. Any parse error, unexpected
tree-budget failure or structural/literal disagreement is a test failure. Retain
and minimize counterexamples. Scheduled fuzzing extends the same bounded corpus.

Each input must finish admission, parsing, iterative checking, syntax-error
inspection and tree teardown, when reached, within **2 seconds wall-clock** in
the release test configuration on each required CI runner, separately from
compiler build time. The release configuration is the shipped front end, so it is
the performance gate. CI runs both the debug and release test configurations on
macOS and Linux. The debug configuration runs the same inputs with a 30-second
watchdog that detects hangs; unoptimized dependencies make its timings a hang
check, not the performance gate. The parent watchdog covers the entire child
lifetime; a timeout or signal fails the test, never counts as a successful
rejection. Record runner/toolchain identity, seeds, stage, token
and tree counts and timings. These are regression gates, not permission to relax
language limits on slower machines. Every SwiftParser dependency or host-toolchain
update reruns the fixed and fuzz suites at the candidate version and compares
with the recorded baseline. A crash, hang, deadline violation, incorrect stage or differential disagreement
blocks the update and release. All guards apply in every build configuration.

Tests also cover condition narrowing, default capture on export, namespaces,
cycles/diamonds, conflicting requirements, shared-target exposure, byte-preserving
edits, comment ownership, deterministic dumps, compatibility transformations and
lock restoration/removal equivalence. Resource tests include exponential constant
reuse in unused declarations, dumping, source maps and comparison.
Range differential cases cover balanced/unbalanced spacing, comment adjacency,
misplacement, chained and closed ranges, nonliteral endpoints and replacement
boundaries; admitted cases must match SwiftParser's structure, and semantically
accepted cases must type-check against the types module. Fuzzing runs
with fixed budgets on macOS and Linux. Native capability claims require current
client probes. Fault tests interrupt every publication/recovery stage, including
concurrent creation of an absent destination and external replacement of both
existing targets and recovery paths.

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
