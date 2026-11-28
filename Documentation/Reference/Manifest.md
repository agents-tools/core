# YAML Manifest

A project declares intent in `.agent/agents.yaml`; user intent lives in
`~/.agents/agents.yaml`. Producers publish the same canonical filename under
`.agent/`, or `agents.yaml` when the producer root is itself `.agent`.
`agents.resolved` remains tool-owned JSON.

```yaml
version: 1
sources:
  team: {url: https://github.com/example/config, requirement: {from: "1.0.0"}}
components:
  - {kind: skills, source: team, select: [review], agents: [codex]}
  - kind: instructions
    sections: [{name: common}]
    chatgpt:
      review: {sections: [{name: common}], append: prompts/review.md}
groups:
  checks:
    components: [{kind: ignore, name: private, patterns: [private/**]}]
uses: [{group: checks}]
exports: [checks]
```

The source [JSON schema](../../Sources/AgentsManifest/Resources/agents.schema.json)
is the field-shape owner. [Generated field help](ManifestSchema.md) lists supported
shapes, field descriptions, examples and schema-owned collection bounds. The finite compiler
rejects unsupported validation keywords, values and combinations; its generated
rules enforce the accepted constraints. Parser and decoded-value safety budgets
apply independently of these field constraints.
Unknown fixed fields, decoded duplicate keys and invalid scalar
kinds are errors. Domain validation also checks unused groups and inactive
components. References remain symbolic until linking; declaration reads never
resolve sources, access resources or execute component programs.

Git requirements also apply to local Git repositories declared with `path`;
their local source identity and declaring environment remain unchanged.
Aliases can share a repository by selecting distinct `subpath` discovery roots.
The source alias on each section selects its discovery root.

## Values and Ordering

Sources, groups, components, uses, exports, prompt sections and named ChatGPT
prompts retain order and occurrences. Ordinary dictionaries and NativeValue
objects have unordered domain semantics while their untouched document spelling
is preserved. Omitted recipients/condition dimensions inherit or impose no
restriction; explicit empty lists select nothing. Omitted `select` means all;
`select: []` selects none. Watch omission and an empty list are equivalent, and
watch order is set-like. Ordinary optional fields do not accept null.

Scalar resolution follows YAML 1.2 Core. `yes`, `on` and dates are strings;
quoted and block scalars are strings. Integer fields require representable plain
integers. Native values also admit finite decimals, arrays, objects and null.
Every decimal is written as `!!float "<exact JSON-number text>"`; integer-shaped
payloads, negative zero, exponent spelling and trailing zeroes retain identity.
This tag is permitted only on NativeValue scalars. `<<` is an ordinary data key.

Core diagnostics are authoritative for YAML admission, scalar kinds, numeric
identity and domain relationships. General JSON Schema treats `1.0` as a
mathematical integer and cannot preserve decimal lexical identity.

UTF-8, a leading BOM, LF/CRLF, block and flow collections and all ordinary scalar
styles are supported. Raw NEL, line separator and paragraph separator characters
are rejected before either parser; use double-quoted escapes `\u0085`,
`\u2028` and `\u2029` to retain those exact characters. Anchors, aliases,
directives, complex keys, multiple documents and other tags are rejected.

## Package-manager Lifecycle

The optional `lifecycle` mapping defines ordered action arrays for
`pre-install`, `post-install`, `pre-update`, `post-update`,
`pre-uninstall`, `post-uninstall`, and `pre-compile`. Repeated entries
are separate actions. The user manifest and consuming project manifest can
each declare actions. Administrators can supply version 1 JSON files in
`/etc/agents/lifecycle.d` with a `scripts` mapping of the same shape.
Administrator files run in filename order, followed by the user and project
declarations.

```yaml
version: 1
lifecycle:
  pre-install:
    - type: command
      run: 'printf "%s\n" "Preparing package installation"'
      timeout: 10
  post-install:
    - type: http
      url: https://example.invalid/lifecycle
      headers:
        X-Build: "${BUILD_ID}"
      timeout: 5
```

A command action selects one of `bash`, `command` or `run`. It may supply
an `env` mapping of string overrides. A webhook supplies an HTTPS `url`
and may supply `headers` and `allowedEnvVars`. Header values can reference
`$NAME` and `${NAME}` from the invocation's environment. Credential-like
names require an exact match in that action's `allowedEnvVars` sequence.
The optional `timeout` is a whole number of seconds from 1 through 300.
The default is 30 seconds.

Commands run in the confirmed operation's project root or, for user scope,
in the user home. The shell gets an event JSON object on stdin and runs with
the user's access. It may invoke mutable checkout files outside the reviewed
digest. Webhooks receive the same event JSON by HTTPS POST. Review project
actions locally before enabling that project. See the [confirmed operation
contract](../Architecture/Updates.md#package-manager-lifecycle).

## Marketplace Packages

A package root names a catalog, package and SemVer requirement. The root
alias is local to the declaring scope. Relative catalog paths are anchored
at the project directory or the user home for user-scoped roots.

```yaml
version: 1
packages:
  team-start:
    catalog: {kind: directory, location: "./team-catalog"}
    package: starter
    requirement: {from: "1.2.0", to: "2.0.0"}
    selections:
      - package: shared-tools
        member: {kind: skills, name: review}
        targets: [codex, claude-code]
```

`exact` matches the complete version, including build metadata. `from` alone
sets an exclusive upper bound at the next major version, including when the
lower major is zero. `upToNextMinor` sets an exclusive bound at the next minor
version. `from` with `to` gives an inclusive lower and exclusive upper bound.
A range admits a prerelease only when one of its bounds is a prerelease with
the same major, minor and patch. A root can also specify `version` for an exact installation.

A member selection identifies a logical member by kind and name. It defaults
to the root's catalog. Use an explicit portable Git `catalog` to select a
member from another reachable catalog. An empty or omitted selection list
records package requirements with no enabled members for that root. The
union of all requesting roots' recipients controls deployment. New members
need a selection in the declaration to receive targets.

The portable bundle's `BundlePackage.dependencies` list is authoritative at
publication and acquisition. Each dependency defaults to the publishing
catalog and can specify an explicit remote Git catalog. Catalog identity
includes Git subpath. A resolution uses one discovery ref per catalog.

Use `MarketplaceOperations.resolve` to discover available versions and
members, then `previewResolution` and `withPreparedResolution` to publish
the reviewed changes. `reconcile` resolves hand-edited roots and can
reconstruct a missing lock. A targeted `upgrade` prefers newer eligible
versions in that root's reachable graph. `remove` uses the committed graph
and drops only the removed root's contribution. Frozen `UpdateOperations.restore`
uses the recorded graph and embedded producer material.

## Instruction recipients

Set `recipients` on an ordered instruction section to select exactly where it
is rendered. Omit it to inherit the component's `agents` or the declaration's
`defaultAgents`. An empty list selects no outputs. The six local agent IDs
can share a list with `chatgpt-app` and `gemini-app`, which produce Markdown
for copying. Scope and platform conditions constrain every recipient. Agent
conditions constrain the local agents.

```yaml
components:
  - kind: instructions
    sections:
      - {source: team/rules, name: code-review, recipients: [codex, chatgpt-app]}
      - {source: team/rules, name: writing, recipients: [chatgpt-app, gemini-app]}
```

## Antigravity

Include `antigravity` in the component's recipients or declaration defaults.
Use section conditions when recipients need different instructions. Here `team`
is an existing source alias.

```yaml
components:
  - kind: instructions
    agents: [codex, antigravity]
    sections:
      - {source: team, name: code-review, condition: {agents: [codex]}}
      - {source: team, name: general-review, condition: {agents: [antigravity]}}
```

| Component | Project | User |
| --- | --- | --- |
| Instructions | `.agents/rules/<rule>.md` | `~/.gemini/config/rules/<rule>.md` |
| Skills | `.agents/skills/<skill>/SKILL.md` | `~/.gemini/config/skills/<skill>/SKILL.md` |
| MCP | `.agents/mcp_config.json` | `~/.gemini/config/mcp_config.json` |
| Hooks | `.agents/hooks.json` | `~/.gemini/config/hooks.json` |

Project skill selections can share one physical skill with other recipients.
Removal keeps the directory while a recipient still owns it. Distinct contents
at a shared skill destination conflict. In `agy`, skills in the CLI-specific
user directories can take precedence over the common user directory.

MCP names own individual `mcpServers`
entries. Antigravity supports stdio and Streamable HTTP, with remote endpoints
written as `serverUrl`. The adapter accepts `disabled`, `enabledTools` and
`disabledTools`, plus `authProviderType: google_credentials` for remote servers.
Binding materialization uses the normal private Core update path. Registry
choices requiring symbolic environment references are unavailable because the
target profile has no documented interpolation syntax. An explicit workspace
selection permits Core to create `.agents/`.
[Customization discovery](https://antigravity.google/docs/customization-discovery) ·
[Skills](https://antigravity.google/docs/skills) · [MCP](https://antigravity.google/docs/mcp)

Use `event: {kind: native, value: PreToolUse}` for a hook whose program understands
Antigravity's JSON input and output. The supported native names are `SessionStart`,
`PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation` and `Stop`. Only
tool events accept a matcher. Matchers use Antigravity tool names and the
supported subset of literal names, alternatives, anchors and trailing `.*`.
`timeoutSeconds` is emitted in seconds. The component name owns one top-level
hook entry. Identical declarations can share that entry. Conflicting declarations
or a handwritten entry with the same name require resolution before applying.
[Hooks](https://antigravity.google/docs/hooks) ·
[APM target matrix](https://microsoft.github.io/apm/reference/targets-matrix/#antigravity) ·
[Rule rendering and limits](../Architecture/Instructions.md#antigravity-rules)

## Edits and Source Maps

`DeclarationDocument` exposes complete IR and semantic JSON Pointer locations:
`sources.team` maps to `/sources/0`, its key to `/sources/0/name`, and nested
group components to `/groups/0/components/...`. Handles belong to one digest.
`ManifestEdit` accepts Core domain values and prepares bytes without writing.
Agents App uses these document and edit APIs for configuration editing. Save
operations preserve YAML text and scalar identity through the prepared edits.

Editing a named source uses `replaceSource(sourceNode, with: replacement)`, where
`sourceNode` is captured from `/sources/<index>` in the current document snapshot.
The replacement retains collection position and rewrites typed references to the
old alias, including declaration `watch`, root and unused-group references,
executable sources and independent working-directory sources. Native data and
other strings remain unchanged. Same-alias replacement updates the definition;
new sources use `upsertSource`. Handles and the expected document digest must come
from the same snapshot. Invalid final source kinds, modes or aliases are rejected;
persisted Watch source-identity keys are outside document editing.

No-op changes return exact bytes. Changed fields and collection entries preserve
unrelated bytes. Adjacent leading comments and same-line trailing comments belong
to their item; moves carry them. Deletion retains comments unless explicitly
owned by a replaced value. Blank-separated headers belong to their container.
Special layouts that cannot be changed precisely fail before publication.

Complete declaration planning composes private parser/schema-checked drafts,
refreshes occurrence ranges and verifies full expected IR at every step. Final
domain and environment validation precede returning any candidate bytes.
Public documents and public prepared changes never expose unchecked drafts.

## Bounds and Dump

Input is bounded at 2,097,152 bytes; CSTs at 100,000 nodes/depth 128; decoded
values at 100,000 nodes/depth 64, 10,000 entries per container and 16,777,216
string bytes. Parser-stage progress callbacks enforce an additional measured
work bound before CST traversal. Scalar scanning remains input-byte bounded;
these are work limits, not a claim of a fixed allocation bound.

Source maps admit 100,000 locations, 1,000,000 origins and 16,777,216 encoded
bytes. Dump output is bounded at 33,554,432 bytes. Public edit batches admit 100
requests, with 200,000 comparison pairs and 1,000,000 editing steps. Private
composition retains finite total work and bounded internal batches.

`ManifestDump` uses schema version 2, `format: "yaml"`, manifest version 1,
source digest, complete typed IR and indexed locations. Decimal records retain
`{kind: "decimal", value: "<exact text>"}`; arbitrary native object keys cannot
collide with this dump-only envelope.
