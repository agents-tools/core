# Manifest Field Shapes

Generated from `Sources/AgentsManifest/Resources/agents.schema.json`.

## Declaration

| Field | Required | Shape |
| --- | --- | --- |
| `version` | yes | `1` |
| `defaultAgents` |  | sequence of agent (at most 10000 items) |
| `sources` |  | name → source (at most 10000 properties) |
| `components` |  | sequence of component (at most 10000 items) |
| `groups` |  | name → group (at most 10000 properties) |
| `uses` |  | sequence of use (at most 10000 items) |
| `exports` |  | sequence of string (at most 10000 items) |
| `watch` |  | sequence of string (at most 10000 items) |

## agent

`codex` / `claude-code` / `cursor` / `gemini-cli` / `opencode`

## condition

| Field | Required | Shape |
| --- | --- | --- |
| `agents` |  | sequence of agent (at most 10000 items) |
| `scopes` |  | sequence of `project` / `user` (at most 10000 items) |
| `platforms` |  | sequence of `macos` / `linux` (at most 10000 items) |

## resource

| Field | Required | Shape |
| --- | --- | --- |
| `path` | yes | string |
| `source` |  | string |

## section

| Field | Required | Shape |
| --- | --- | --- |
| `name` | yes | string |
| `source` |  | string |
| `condition` |  | condition |

## binding

one of: string, mapping, mapping

## prompt

one of: string, mapping

## run

| Field | Required | Shape |
| --- | --- | --- |
| `executable` | yes | string |
| `arguments` |  | sequence of string (at most 10000 items) |
| `environment` |  | name → binding (at most 10000 properties) |
| `workingDirectory` |  | resource |

## transport

one of: mapping, mapping

## event

one of: `beforeTool` / `afterTool` / `sessionStart` / `sessionEnd`, mapping

## operation

one of: `read` / `write` / `execute`, mapping

## rule

| Field | Required | Shape |
| --- | --- | --- |
| `effect` | yes | `allow` / `ask` / `deny` |
| `operation` | yes | operation |
| `pattern` | yes | string |

## parameter

| Field | Required | Shape |
| --- | --- | --- |
| `name` | yes | string |
| `description` | yes | string |
| `defaultValue` |  | string |

## promptDeclaration

| Field | Required | Shape |
| --- | --- | --- |
| `sections` |  | sequence of section (at most 10000 items) |
| `append` |  | string |
| `condition` |  | condition |

## override

| Field | Required | Shape |
| --- | --- | --- |
| `agents` |  | sequence of agent (at most 10000 items) |
| `mode` |  | `link` / `copy` / `edit` |

## requirement

one of: mapping, mapping, mapping, mapping, mapping, mapping

## source

one of: mapping, mapping, mapping

## componentReference

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `skill` / `instruction` / `mcpServer` / `hook` / `subagent` / `command` / `lspServer` / `permissions` / `ignore` / `plugin` |
| `name` | yes | string |

## component_skills

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `skills` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `source` | yes | string |
| `select` |  | one of: `all`, sequence of string (at most 10000 items) |
| `exclude` |  | sequence of string (at most 10000 items) |
| `mode` |  | `link` / `copy` / `edit` |
| `overrides` |  | name → override (at most 10000 properties) |

## component_instructions

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `instructions` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `sections` |  | sequence of section (at most 10000 items) |
| `chatgpt` |  | name → promptDeclaration (at most 10000 properties) |

## component_mcpServer

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `mcpServer` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `transport` | yes | transport |

## component_hook

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `hook` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `event` | yes | event |
| `run` | yes | run |
| `matcher` |  | string |
| `timeoutSeconds` |  | integer ≥ 1 |

## component_subagent

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `subagent` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `description` | yes | string |
| `prompt` | yes | prompt |
| `model` |  | string |
| `tools` |  | sequence of string (at most 10000 items) |

## component_command

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `command` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `description` | yes | string |
| `prompt` | yes | prompt |
| `parameters` |  | sequence of parameter (at most 10000 items) |

## component_lspServer

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `lspServer` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `run` | yes | run |
| `languages` | yes | name → string (at most 10000 properties) |
| `initializationOptions` |  | name → NativeValue (at most 10000 properties) |

## component_permissions

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `permissions` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `rules` | yes | sequence of rule (at most 10000 items) |

## component_ignore

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `ignore` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `patterns` | yes | sequence of string (at most 10000 items) |
| `purpose` |  | `context` / `indexing` |

## component_plugin

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `plugin` |
| `agents` |  | sequence of agent (at most 10000 items) |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue (at most 10000 properties) (at most 10000 properties) |
| `name` | yes | string |
| `source` | yes | string |
| `path` | yes | string |
| `mode` |  | `native` / `components` |
| `select` |  | sequence of `skills` / `instructions` / `mcpServer` / `hook` / `subagent` / `command` / `lspServer` / `permissions` / `ignore` / `plugin` (at most 10000 items) |
| `exclude` |  | sequence of componentReference (at most 10000 items) |

## component

one of: component_skills, component_instructions, component_mcpServer, component_hook, component_subagent, component_command, component_lspServer, component_permissions, component_ignore, component_plugin

## use

| Field | Required | Shape |
| --- | --- | --- |
| `group` | yes | string |
| `source` |  | string |
| `condition` |  | condition |

## group

| Field | Required | Shape |
| --- | --- | --- |
| `components` |  | sequence of component (at most 10000 items) |
| `uses` |  | sequence of use (at most 10000 items) |
| `condition` |  | condition |
