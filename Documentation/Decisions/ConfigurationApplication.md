# Configuration Application

## Status

Accepted by the repository owner (showxu) on 2026-11-06.
Supersedes [Executable Component Approval](ExecutableApproval.md).

## Context

`agents` manages declarations, installed resources and native configuration.
The agent that consumes a configuration owns its runtime: starting servers,
authenticating, trusting a workspace and deciding whether to call a tool.
Configuration changes and runtime operations have different owners.

## Decision

- **One application action.** The GUI shows the concrete configuration changes
  and targets, then applies them when the user confirms. An explicit modifying
  CLI command expresses the same intent. External automation invokes those
  commands within its supplied scope. The GUI checks, notifies and applies on
  request.
- **Preview freshness.** Core validates that the candidate and relevant target
  state still match the presented changes. If they changed, the front end
  refreshes the preview before applying.
- **Configuration lifecycle.** Installation and updates write configuration,
  resources and registration files. Parsing, inspection and configuration
  application do not start the declared component programs. The manifest is
  statically evaluated.
- **Optional MCP connection test.** A separate explicit action tests the chosen
  configuration through protocol initialization and tool discovery. A stdio
  test starts its displayed command; a remote test connects through the
  declared transport. The test has bounded time and output, supports
  cancellation and cleans up the connections and processes it owns. It does
  not invoke business tools. Testing is independent of configuration apply.
- **Client-owned runtime decisions.** Server trust, tool-call authorization and
  authentication remain with the consuming client. An adapter does not modify
  those records merely to make a configured component appear active. Explicit
  permission configuration remains a managed component with its own declared
  intent.

## Consequences

The declaration records intent and the ledger records committed configuration
and ownership. CLI and GUI use the same prepare/apply transaction. Connection
tests return observations about the selected configuration in the current
environment; their result does not establish that a native client has loaded
or enabled the component.

## Related Documentation

- [Agent Components and Adapters](AgentComponents.md)
- [Swift Manifest](SwiftManifest.md)
- [Agents Manifest Contract](../Proposals/AgentsManifest.md)
