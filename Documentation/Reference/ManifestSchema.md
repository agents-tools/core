# Manifest Field Shapes

Generated from `Sources/AgentsManifest/Resources/agents.schema.json`.

## Declaration

Version 1 declaration of symbolic sources, components and groups. Parsing validates supplied YAML without resolving sources, reading referenced resources or running programs. Unknown fixed fields and null optional fields are errors; omitted collections are empty unless a field says otherwise. Core diagnostics also enforce YAML scalar kinds, numeric identity and domain relationships that general JSON Schema cannot express.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `version` | yes | `1` | Required manifest version, written as the plain integer 1. Core rejects decimal spelling such as 1.0 even when a JSON Schema validator treats it as an integer. |
| `defaultAgents` |  | sequence of agent (at most 10000 items) | Default recipients for components that omit agents. Omission defaults to codex and claude-code; an empty list selects no recipients. Component overrides and conditions further determine effective targets.<br>Examples: <code>["codex", "claude-code"]</code>, <code>[]</code> |
| `sources` |  | name → source (at most 10000 properties) | Source aliases local to this declaration, retained in declaration order. References use these keys; aliases must be nonempty, must not be . or contain a colon, and must identify distinct normalized sources. Omission or an empty mapping declares none. |
| `components` |  | sequence of component (at most 10000 items) | Direct component declarations, retained in order and checked even when their conditions select no targets. Omission or an empty sequence declares none. |
| `groups` |  | name → group (at most 10000 properties) | Named reusable groups, retained in declaration order. Defining a group does not activate it; uses selects it and exports makes it available to importers. Unused groups are still validated. |
| `uses` |  | sequence of use (at most 10000 items) | Group references expanded in declaration order. Omission or an empty sequence activates no groups. Local reference cycles are errors, including in inactive groups. |
| `exports` |  | sequence of string (at most 10000 items) | Names of local groups available to importing declarations, retained in order. Every name must name a declared group and occur once. Omission or an empty sequence exports none. |
| `watch` |  | sequence of string (at most 10000 items) | Source aliases subscribed independently of installations. Names must be unique and refer to declared source aliases. Omission and an empty sequence are equivalent; watch order has set-like semantics. |

## agent

Recipient identifier. Support for deploying an individual component is checked by its consuming operation; accepting the identifier does not imply every component is supported by that client.

`codex` / `claude-code` / `cursor` / `gemini-cli` / `opencode`

## condition

Intersecting restrictions on recipients, scope and platform. Omitted dimensions impose no restriction; an explicit empty dimension matches nothing. Nested group, use, component and section conditions combine by intersection, without removing inactive intent from the declaration.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `agents` |  | sequence of agent (at most 10000 items) | Only these recipients remain eligible. Omission leaves recipients unrestricted; an empty list matches none. Duplicate recipients are errors. |
| `scopes` |  | sequence of `project` / `user` (at most 10000 items) | Only these installation scopes match. Omission allows either scope; an empty list matches neither. Duplicate scopes are errors. |
| `platforms` |  | sequence of `macos` / `linux` (at most 10000 items) | Only these operating systems match. Omission allows either platform; an empty list matches neither. Duplicate platforms are errors. |

## resource

A resource path with an optional source alias. It remains symbolic during declaration reads; linking resolves and confines it to the selected source root.

Examples: <code>{"path": "prompts/review.md", "source": "team"}</code>

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `path` | yes | string | Required relative resource path within the selected source. Absolute paths, home expansion and parent traversal are not allowed. |
| `source` |  | string | Alias declared in this document. Omission or . uses the current declaring source; imported declarations retain their own source context. |

## section

One instruction section reference. Section sequences retain their declared order and occurrences; the referenced content is read only by the consuming operation.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `name` | yes | string | Instruction name relative to its instruction container, without .md. Nested names use / separators. |
| `source` |  | string | Source alias for this section. Omission or . selects the declaring source's own instructions; root user instructions require a named source when linking. |
| `condition` |  | condition | Additional restrictions for this section, intersected with enclosing conditions. Omission imposes no additional restriction. |

## binding

A literal string or a symbolic local environment/secret binding. Declaration reads preserve the binding without looking up values. Only the consuming operation resolves bindings; they are not source-provided literals.

Examples: <code>"literal text"</code>, <code>{"env": "SERVICE_TOKEN"}</code>, <code>{"secret": "service-token"}</code>

### Alternative 1

Literal text, used exactly as supplied. Strings resembling binding syntax are not interpolated.

string

### Alternative 2

Symbolic local environment binding; no value is captured in the declaration.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `env` | yes | string | Name of an environment variable resolved locally by the consuming operation. |

### Alternative 3

Symbolic local secret binding; no value is captured in the declaration.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `secret` | yes | string | Name of a secret resolved locally by the consuming operation's binding provider. |

## prompt

Inline prompt text or a reference to a prompt file. Declaration reads do not read the file. Command input tokens use ${input:name}; $${input:name} escapes a literal token.

### Alternative 1

Inline prompt body, including any literal newlines.

string

### Alternative 2

Prompt body read from a resource by the consuming operation.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `file` | yes | resource | Resource containing the prompt body, resolved in its declaring source context. |

## run

A declared invocation, preserved as data until a consuming operation explicitly uses it. It does not contain a shell command line.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `executable` | yes | string | Required program name or relative executable path. A bare name is resolved by the consuming operation; paths containing / are source resources. Reading the declaration never starts the program. |
| `arguments` |  | sequence of string (at most 10000 items) | Arguments in invocation order, passed as individual strings. Omission or an empty sequence supplies no arguments. |
| `environment` |  | name → binding (at most 10000 properties) | Environment variable names mapped to literals or local bindings. Omission or an empty mapping supplies no declared entries; reading the declaration does not resolve bindings. |
| `workingDirectory` |  | resource | Working directory resource, resolved by the consuming operation. Omission leaves the directory unspecified in the declaration. |
| `executableSource` |  | string | Source alias for a resource executable path. Omission uses the declaring source; a bare PATH command cannot specify a source. |

## transport

MCP connection declaration: a local stdio invocation, Streamable HTTP or SSE. Parsing neither starts a server nor opens a connection.

### Alternative 1

Local MCP server invocation over standard input/output.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `stdio` | Selects the local stdio transport. |
| `executable` | yes | string | Required program name or relative executable path. A bare name is resolved by the consuming operation; paths containing / are source resources. Reading the declaration never starts the program. |
| `arguments` |  | sequence of string (at most 10000 items) | Arguments in invocation order, passed as individual strings. Omission or an empty sequence supplies no arguments. |
| `environment` |  | name → binding (at most 10000 properties) | Environment variable names mapped to literals or local bindings. Omission or an empty mapping supplies no declared entries; reading the declaration does not resolve bindings. |
| `workingDirectory` |  | resource | Working directory resource, resolved by the consuming operation. Omission leaves the directory unspecified in the declaration. |
| `executableSource` |  | string | Source alias for a resource executable path. Omission uses the declaring source; a bare PATH command cannot specify a source. |

### Alternative 2

Remote MCP endpoint with optional literal or locally bound headers.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `streamableHTTP` / `sse` | Selects Streamable HTTP or SSE transport. |
| `url` | yes | string | Required HTTP or HTTPS endpoint with a host and no embedded credentials or fragment. |
| `headers` |  | name → binding (at most 10000 properties) | HTTP header names mapped to literals or local bindings. Omission or an empty mapping supplies no declared headers. Values remain unresolved during declaration reads. |

## event

Portable hook event or a client-native event name. A native event requires exactly one explicit component recipient.

### Alternative 1

Portable event mapped by the target client adapter.

`beforeTool` / `afterTool` / `sessionStart` / `sessionEnd`

### Alternative 2

Client-specific hook event; support is checked by the consuming adapter.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `native` | yes | string | Event name in the selected client's vocabulary; the component must explicitly target exactly one agent. |

## operation

Portable permission operation or a named client tool operation. Interpretation belongs to the target client adapter.

### Alternative 1

Portable file-read, file-write or program-execution operation.

`read` / `write` / `execute`

### Alternative 2

Named tool operation interpreted by the target client.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `tool` | yes | string | Tool identifier to which the rule applies. |

## rule

One permission rule. Rules retain declaration order; the target client determines enforcement semantics.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `effect` | yes | `allow` / `ask` / `deny` | Allow, ask for confirmation, or deny the matching operation in the target client. |
| `operation` | yes | operation | Portable operation or named client tool to match. |
| `pattern` | yes | string | Match pattern interpreted for the operation by the target adapter. Read and write patterns must be safe relative resource paths. |

## parameter

A named command input. Parameter names must be unique within the command; inline prompt tokens must refer to declared parameters.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `name` | yes | string | Input token name used in ${input:name}. It must be nonempty and contain no }, colon or NUL. |
| `description` | yes | string | User-facing explanation of the input requested by the command. |
| `defaultValue` |  | string | Optional literal default input text. Omission leaves the default unspecified; an empty string is an explicit empty default. |

## promptDeclaration

A named ChatGPT prompt composed from ordered instruction sections and an optional append file. Names are the keys in chatgpt; omission of sections means an empty sequence.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `sections` |  | sequence of section (at most 10000 items) | Instruction sections in rendering order, including repeated references. Omission or an empty sequence supplies none. |
| `append` |  | string | Relative file appended to the prompt by the consuming operation. In project scope it uses the declaring source; in user scope it is relative to the user home directory. Omission appends no file. |
| `condition` |  | condition | Additional scope/platform restrictions for this named prompt. Omission imposes no additional restriction. |

## override

Per-skill recipient and installation-mode overrides. The mapping key is the skill name and must belong to an explicit selection when one is supplied.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `agents` |  | sequence of agent (at most 10000 items) | Recipients for this skill instead of component/default recipients. Omission inherits; an empty list selects no recipients. Enclosing conditions still restrict the result. |
| `mode` |  | `link` / `copy` / `edit` | Installation mode for this skill instead of the component mode. Omission inherits. edit requires a live local source without a requirement. |

## requirement

One Git selection policy, also applicable to local Git repositories. Version requirements select semantic-version tags; a resolved lock records the exact revision. Reading the declaration never performs resolution.

Examples: <code>{"from": "1.2.0"}</code>, <code>{"from": "1.2.0", "to": "2.0.0"}</code>, <code>{"branch": "main"}</code>

### Alternative 1

Track the named Git branch.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `branch` | yes | string | Track the named Git branch. |

### Alternative 2

Select the specified Git revision.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `revision` | yes | string | Select the specified Git revision. |

### Alternative 3

Select exactly this semantic version tag.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `exact` | yes | string | Select exactly this semantic version tag. |

### Alternative 4

Inclusive semantic-version lower bound, below the next major version.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `from` | yes | string | Inclusive semantic-version lower bound, below the next major version. |

### Alternative 5

Inclusive semantic-version lower bound, below the next minor version.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `upToNextMinor` | yes | string | Inclusive semantic-version lower bound, below the next minor version. |

### Alternative 6

Semantic-version interval with an inclusive lower bound and exclusive upper bound. The lower bound must be less than the upper bound.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `from` | yes | string | Inclusive semantic-version lower bound. |
| `to` | yes | string | Exclusive semantic-version upper bound, greater than from. |

## source

Exactly one Git URL, local path or well-known skill index per alias. subpath narrows the discovery root. No source is accessed while reading the declaration.

### Alternative 1

Git repository selected by a transport URL and optional requirement.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `url` | yes | string | Git transport URL. Complete URLs avoid canonicalization warnings; normalized repository identities must be distinct across aliases. |
| `subpath` |  | string | Safe relative discovery path inside the source. Omission uses the source root; it cannot escape that root. |
| `requirement` |  | requirement | Git selection policy. Omission leaves the source without an explicit requirement; resolution and exact locking belong to the consuming operation. |

### Alternative 2

Local source interpreted using the directories of its declaring environment.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `path` | yes | string | Local path, relative to the declaring project directory unless absolute or home-relative. A requirement selects committed content from a local Git repository; edit mode requires no requirement. |
| `subpath` |  | string | Safe relative discovery path inside the source. Omission uses the source root; it cannot escape that root. |
| `requirement` |  | requirement | Git selection policy. Omission leaves the source without an explicit requirement; resolution and exact locking belong to the consuming operation. |

### Alternative 3

Well-known skill index accessed only during source-consuming operations.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `index` | yes | string | HTTP or HTTPS well-known skill index URL, without embedded credentials or fragment. Git requirements do not apply to this source kind. |
| `subpath` |  | string | Safe relative discovery path inside the source. Omission uses the source root; it cannot escape that root. |

## componentReference

A typed member reference used to exclude one component from a plugin expansion. The singular skill and instruction kinds identify individual members.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `skill` / `instruction` / `mcpServer` / `hook` / `subagent` / `command` / `lspServer` / `permissions` / `ignore` / `plugin` | Kind of the individual plugin member to exclude. |
| `name` | yes | string | Relative member name within the plugin, paired with kind to identify the exclusion. Duplicate kind/name exclusions are errors. |

## component_skills

Select skills from a source and declare their recipients and installation modes.

Examples: <code>{"kind": "skills", "source": "team", "select": ["review"], "agents": ["codex"]}</code>

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `skills` | Selects the skills component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `source` | yes | string | Required source alias, or . for the current declaring source. Source resolution occurs only in the consuming operation. |
| `select` |  | one of: `all`, sequence of string (at most 10000 items) | all or omission selects all discovered skills; a name sequence selects those skills. An empty sequence selects none. Selection is combined with exclude and per-skill overrides. |
| `exclude` |  | sequence of string (at most 10000 items) | Skill names removed from the selection. Omission or an empty sequence excludes none. |
| `mode` |  | `link` / `copy` / `edit` | link shares cached content, copy creates an installed directory, and edit links live local content. Omission defaults to link. edit requires a local source without a requirement or pin. |
| `overrides` |  | name → override (at most 10000 properties) | Skill names mapped to recipient/mode overrides. Omission or an empty mapping supplies none; omitted override fields inherit the component settings. |
| `path` |  | string | Optional discovery path relative to the selected filesystem source view. Narrows discovery without changing containment. Not supported for index sources. |

## component_instructions

Compose instruction targets and named ChatGPT prompts from ordered section references.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `instructions` | Selects the instructions component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `sections` |  | sequence of section (at most 10000 items) | Instruction sections in rendering order. Omission or an empty sequence supplies none; repeated references retain their occurrences. |
| `chatgpt` |  | name → promptDeclaration (at most 10000 properties) | Named ChatGPT prompts retained in declaration order, separate from agent-targeted sections. Omission or an empty mapping declares none. |

## component_mcpServer

Declare a named MCP server connection without starting or contacting it.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `mcpServer` | Selects the mcpServer component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `transport` | yes | transport | Required MCP transport and its unresolved connection settings. |

## component_hook

Declare a named event-triggered invocation without executing it.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `hook` | Selects the hook component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `event` | yes | event | Required portable or native hook event. Native events require exactly one explicit component recipient. |
| `run` | yes | run | Required invocation performed when the target client triggers this hook. Declaration reads never execute it. |
| `matcher` |  | string | Optional target-client matcher text. Omission leaves matching unspecified; support and interpretation belong to the adapter. |
| `timeoutSeconds` |  | integer ≥ 1 | Positive plain integer timeout in seconds. Omission leaves the timeout unspecified. Core rejects decimal spellings such as 1.0 and out-of-range integers. |

## component_subagent

Declare a named subagent with a description and prompt body.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `subagent` | Selects the subagent component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `description` | yes | string | User-facing explanation of when to use this subagent. |
| `prompt` | yes | prompt | Required inline prompt or prompt-file reference. File contents are not read during declaration parsing. |
| `model` |  | string | Optional target-client model identifier. Omission leaves model selection unspecified. |
| `tools` |  | sequence of string (at most 10000 items) | Optional target-client tool names. Omission leaves the tool list unspecified; an empty sequence is an explicit empty list. |

## component_command

Declare a named prompt command and its input parameters.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `command` | Selects the command component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `description` | yes | string | User-facing explanation of this prompt command. |
| `prompt` | yes | prompt | Required inline prompt or prompt-file reference. ${input:name} refers to a declared parameter; $${input:name} is literal text. |
| `parameters` |  | sequence of parameter (at most 10000 items) | Inputs in declaration order. Omission or an empty sequence declares none. Names must be unique and inline prompt tokens must refer to these names. |

## component_lspServer

Declare a named language server invocation and extension-to-language mapping.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `lspServer` | Selects the lspServer component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `run` | yes | run | Required language server invocation, retained as data until used by the consuming operation. |
| `languages` | yes | name → string (at most 10000 properties) | File extensions, including a leading dot, mapped to nonempty language identifiers. An empty mapping declares no extension associations.<br>Examples: <code>{".swift": "swift"}</code> |
| `initializationOptions` |  | name → NativeValue (at most 10000 properties) | Native values passed as language server initialization options. Omission or an empty mapping supplies none. Values retain Core integer/decimal kind and exact decimal text; !!float "1.00" explicitly marks a decimal. Null and nested arrays/objects are data, not runtime bindings. |

## component_permissions

Declare a named ordered collection of client permission rules.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `permissions` | Selects the permissions component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `rules` | yes | sequence of rule (at most 10000 items) | Permission rules in declaration order. An empty sequence declares no rules. Enforcement belongs to the target client. |

## component_ignore

Declare a named collection of context or indexing ignore patterns.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `ignore` | Selects the ignore component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `patterns` | yes | sequence of string (at most 10000 items) | Ignore patterns in declaration order, interpreted by the target client for the selected purpose. An empty sequence declares none. |
| `purpose` |  | `context` / `indexing` | context excludes content from model context; indexing excludes it from indexing. Omission defaults to context; support is checked by the consuming adapter. |

## component_plugin

Declare a plugin resource for native installation or component expansion.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `kind` | yes | `plugin` | Selects the plugin component shape. |
| `agents` |  | sequence of agent (at most 10000 items) | Explicit component recipients. Omission inherits the declaring document's defaultAgents; an empty list selects none. Conditions further restrict effective recipients. |
| `condition` |  | condition | Additional restrictions intersected with enclosing group/use conditions. Omission imposes no additional restriction; inactive components remain validated and preserved. |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) | Client-schema identifiers mapped to native field mappings. Omission or an empty mapping supplies no native fields. Values are data, never environment/secret bindings: strings, representable integers, finite decimals, booleans, null, arrays and objects. Core preserves integer/decimal kind and exact decimal text; !!float "1.00" explicitly retains decimal identity, which general JSON Schema cannot validate. Objects have unordered domain semantics and << is an ordinary key. |
| `name` | yes | string | Required relative component name, retained as its symbolic identity. Nested names use / separators; empty, . and .. segments are not allowed. |
| `source` | yes | string | Required source alias, or . for the declaring source, containing the plugin resource. |
| `path` | yes | string | Required safe relative plugin resource path within the selected source. |
| `mode` |  | `native` / `components` | components (the default) expands plugin members. native installs the vendor plugin for exactly one explicit recipient and forbids select and nonempty exclude. |
| `select` |  | sequence of `skills` / `instructions` / `mcpServer` / `hook` / `subagent` / `command` / `lspServer` / `permissions` / `ignore` / `plugin` (at most 10000 items) | Component kinds to include during components-mode expansion. Omission leaves kinds unrestricted; an empty sequence selects none. Duplicate kinds are errors. |
| `exclude` |  | sequence of componentReference (at most 10000 items) | Typed individual members removed from components-mode expansion. Omission or an empty sequence excludes none. Each kind/name pair must be unique. |

## component

One component declaration, selected by its required kind. All fields are checked even when the component is inactive; target-client support is evaluated by the consuming operation.

### Alternative 1

component_skills

### Alternative 2

component_instructions

### Alternative 3

component_mcpServer

### Alternative 4

component_hook

### Alternative 5

component_subagent

### Alternative 6

component_command

### Alternative 7

component_lspServer

### Alternative 8

component_permissions

### Alternative 9

component_ignore

### Alternative 10

component_plugin

## use

Activate a local group or an exported group from a source. Uses retain order and occurrences; nested conditions intersect and source aliases remain local to their declaring document.

Examples: <code>{"group": "checks"}</code>, <code>{"group": "checks", "source": "team"}</code>

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `group` | yes | string | Required group name. Without source it must name a local group; a named source must export the group before linking can use it. |
| `source` |  | string | Alias of the producer exporting this group. Omission selects a local group; . addresses the current source. Remote source aliases are not rebound in the importing document. |
| `condition` |  | condition | Additional restrictions for this expansion, intersected with group and enclosing conditions. Omission imposes no additional restriction. |

## group

A reusable group of direct components and nested uses. Definition alone does not activate it. Local use cycles are rejected, and unused or inactive contents are still validated.

| Field | Required | Shape | Description |
| --- | --- | --- | --- |
| `components` |  | sequence of component (at most 10000 items) | Direct components retained in declaration order. Omission or an empty sequence contributes none. |
| `uses` |  | sequence of use (at most 10000 items) | Nested group uses expanded in declaration order. Omission or an empty sequence references none. |
| `condition` |  | condition | Restrictions intersected with each importing use and nested component/section condition. Omission imposes no additional restriction. |
