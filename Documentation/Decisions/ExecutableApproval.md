# Executable Component Approval

## Status

Accepted

## Context

Hooks, MCP servers, LSP servers and plugins run commands on the machine where
they are deployed. A project's manifest is committed and changed by every
contributor, and sources change upstream, so a component can appear in a
scope's declaration without the person who runs `agents update` having
written or reviewed it.

## Decision

- Approval is per machine and bound to content identity: the component's
  declaration, the command it runs and the content it ships.
- A component that runs code is not deployed to a machine until it is approved
  there. Adding it through the CLI or GUI on that machine approves it.
  Components that arrive through a project manifest, an imported container or
  a source are pending until approved.
- A change to an approved component's content identity makes it pending again.
- Approvals are stored in the machine's user state, never in a committed lock.
- Update previews list pending components and what they would run. Applying
  deploys approved components and leaves pending ones undeployed and reported.
- Non-interactive runs approve only components named with their content
  identity.
- Reading, previewing and inspecting never run manifest code; the manifest is
  parsed, not executed.

## Consequences

- The deployment ledger distinguishes approved, pending and refused
  components.
- CLI and GUI share one approval flow; the GUI can show an on-device
  explanation of a pending command before the user decides.
- Teams that want shared trust approve on each machine or name approved
  content identities in automation.

## Alternatives Considered

- **Trust everything declared in the manifest.** A contributor's change to a
  committed manifest would run on everyone's machine without review.
- **Trust per source.** One approval would cover every later change from that
  source.
- **No approval.** Comparable tools already gate executable content.

## Related Documentation

- Accepted by the repository owner (showxu) on 2026-10-28.
- Components and deployment ledger: [Agent Components and Adapters](AgentComponents.md)
- Parse-only manifest: [Swift Manifest](SwiftManifest.md)
