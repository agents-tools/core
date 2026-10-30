# Agent Components and Adapters

## Status

Accepted

## Context

Core manages skills and instructions, with each agent's locations encoded in
the agent registry. The next stage manages every agent configuration
component: MCP servers, hooks, subagents, commands and prompts, LSP servers,
permissions, ignore rules and plugins. Each supported agent stores these in
its own places and formats, often several components in one settings file.

Other tools distribute the same components in their own containers: Claude
Code, Codex and Cursor plugins and marketplaces, Gemini CLI extensions, APM
packages, rulesync sources and npx skills locks. Some agents also share
physical locations; Codex, Cursor, Gemini CLI and OpenCode read the same
`.agents/skills` directory.

## Decision

- **One component model.** Core models components independently of any agent.
  The manifest declares components; adapters deploy them.
- **Capability registry.** Core records, for each agent, component and scope,
  whether the agent supports it, its native location and format, and the keys
  agents owns in a shared file. CLI validation and GUI controls derive from
  the registry. Each supported combination is verified against the agent's
  current stable client.
- **Key-level ownership.** In shared configuration files agents changes and
  removes only the keys it wrote and preserves every other key.
- **Deployment ledger.** The lock records each physical target with its owner
  and content hash, and cleanup removes only what the lock proves agents owns.
- **Agent targeting.** Every component can be limited to agents and platforms.
  A producer declares targeting in front matter or a package manifest; a
  consumer narrows it in the manifest with `agents` or `.when(...)` and never
  widens it. A component reaches the declared agents that the registry says
  support it. When a shared location exposes a component to agents beyond its
  targeting, agents reports the conflict and the user chooses to share or to
  deploy to the agent's own location.
- **Absorb, decompose, recompose.** Input adapters read Claude marketplaces and
  plugins, Codex and Cursor plugins, Gemini CLI extensions, APM packages,
  rulesync sources, npx skills locks and hand-written native files. They split
  each container into components and record its provenance. A marketplace is a
  source that can be browsed and searched; installing from it is declared in
  the manifest and pinned in the lock.
- **Import.** The same adapters back `agents import`, which previews the
  manifest changes and target ownership it would take, and writes only with
  `--apply`. Import is one-way and never automatic. Adopting an existing
  native file goes through import, as the whole file or as a marked section.
- **Native deployment.** Components deploy to each agent's native locations.
  Where an agent accepts a component only through its plugin system, as Claude
  Code does for LSP servers, agents generates a native plugin that carries it.
  A vendor plugin can also be installed unchanged for its own agent. A
  component an agent cannot represent is reported, not dropped or
  approximated.
- **Distribution.** A source is a Git repository, local directory or index.
  A repository publishes reusable groups by declaring them in its
  `Agents.swift`; agents runs no hosted marketplace or registry.

## Consequences

- The agent registry grows into the capability registry and gains per-agent
  adapters for every component; adding an agent or component means adding
  registry entries, adapters and client probes.
- The lock grows from pins and hashes into a deployment ledger, a lock format
  change with its own lock conversion.
- Input adapters are versioned against the upstream formats they read and need
  fixtures from those formats.
- Shared settings files require structured, format-preserving edits for JSON,
  TOML and Markdown targets.
- Targeting is deployment intent, not isolation; shared locations remain
  visible to every agent that reads them.

## Alternatives Considered

- **Per-agent code paths without a registry.** Every new component would add
  special cases across CLI and GUI.
- **Copying plugins between agents unchanged.** Plugin formats and runtimes
  differ; components move between agents, containers do not.
- **Reading and writing other tools' manifests as agents' own.** Two managers
  would own the same outputs.
- **A hosted marketplace.** Git repositories already identify, version and
  distribute sources.

## Related Documentation

- Accepted by the repository owner (showxu) on 2026-10-28.
- Current agent locations and state: [Package](../Architecture/Package.md),
  [State](../Architecture/State.md)
- Manifest that declares components: [Swift Manifest](SwiftManifest.md)
- Approval before executable components deploy: [Executable Component Approval](ExecutableApproval.md)
