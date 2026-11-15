# Manifest Field Shapes

Generated from `Sources/AgentsManifest/Resources/agents.schema.json`.

## Declaration

| Field | Required | Shape |
| --- | --- | --- |
| `version` | yes | `1` |
| `defaultAgents` |  | sequence of agent |
| `sources` |  | name → source |
| `components` |  | sequence of component |
| `groups` |  | name → group |
| `uses` |  | sequence of use |
| `exports` |  | sequence of string |
| `watch` |  | sequence of string |

## agent

`codex` / `claude-code` / `cursor` / `gemini-cli` / `opencode`

## condition

| Field | Required | Shape |
| --- | --- | --- |
| `agents` |  | sequence of agent |
| `scopes` |  | sequence of `project` / `user` |
| `platforms` |  | sequence of `macos` / `linux` |

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
| `arguments` |  | sequence of string |
| `environment` |  | name → binding |
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
| `sections` |  | sequence of section |
| `append` |  | string |
| `condition` |  | condition |

## override

| Field | Required | Shape |
| --- | --- | --- |
| `agents` |  | sequence of agent |
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
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `source` | yes | string |
| `select` |  | one of: `all`, sequence of string |
| `exclude` |  | sequence of string |
| `mode` |  | `link` / `copy` / `edit` |
| `overrides` |  | name → override |

## component_instructions

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `instructions` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `sections` |  | sequence of section |
| `chatgpt` |  | name → promptDeclaration |

## component_mcpServer

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `mcpServer` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `transport` | yes | transport |

## component_hook

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `hook` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `event` | yes | event |
| `run` | yes | run |
| `matcher` |  | string |
| `timeoutSeconds` |  | integer |

## component_subagent

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `subagent` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `description` | yes | string |
| `prompt` | yes | prompt |
| `model` |  | string |
| `tools` |  | sequence of string |

## component_command

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `command` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `description` | yes | string |
| `prompt` | yes | prompt |
| `parameters` |  | sequence of parameter |

## component_lspServer

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `lspServer` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `run` | yes | run |
| `languages` | yes | name → string |
| `initializationOptions` |  | name → NativeValue |

## component_permissions

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `permissions` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `rules` | yes | sequence of rule |

## component_ignore

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `ignore` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `patterns` | yes | sequence of string |
| `purpose` |  | `context` / `indexing` |

## component_plugin

| Field | Required | Shape |
| --- | --- | --- |
| `kind` | yes | `plugin` |
| `agents` |  | sequence of agent |
| `condition` |  | condition |
| `native` |  | name → name → NativeValue |
| `name` | yes | string |
| `source` | yes | string |
| `path` | yes | string |
| `mode` |  | `native` / `components` |
| `select` |  | sequence of `skills` / `instructions` / `mcpServer` / `hook` / `subagent` / `command` / `lspServer` / `permissions` / `ignore` / `plugin` |
| `exclude` |  | sequence of componentReference |

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
| `components` |  | sequence of component |
| `uses` |  | sequence of use |
| `condition` |  | condition |
