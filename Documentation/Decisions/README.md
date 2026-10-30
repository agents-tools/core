# Decisions

This directory holds durable decision records for `skill-cli`.

## Records

- `UpdateReporting.md`: metadata, membership, composition and transaction rationale
- `CLIIdentity.md`: executable, package, distribution, and Swift-prefixed
  command identity
- `SPMInspiredRegistry.md`: SPM-inspired first-party skill registry schema
- `SwiftStyleFlagSurface.md`: Swift-style canonical flag spelling for
  install/list/remove/update
- `SwiftManifest.md`: `Agents.swift` as a statically evaluated Swift
  declaration with lossless edits
- `AgentComponents.md`: component model, capability registry, input adapters
  and native deployment
- `ExecutableApproval.md`: per-machine approval of components that run code

## Placement

- Use this directory for accepted decisions and the rationale behind them.
- Keep current structure in `../Architecture/`.
- Keep migration mechanics in `../Migrations/`.
