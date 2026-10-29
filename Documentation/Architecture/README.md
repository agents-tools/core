# Architecture

This directory holds the current truth for `core`, a SwiftPM library package.
`AgentsDescription` supplies the types-only construction vocabulary, and
`AgentsManifest` compiles and edits supplied manifest snapshots without I/O.
`AgentsCore` owns syntax-independent declaration IR, spans, provenance, shared sources, declaration and lock storage, cache, watch subscriptions, and agent locations;
`AgentsSkills` owns skill discovery and lifecycle operations and depends on
`AgentsCore` and Yams. `AgentsInstructions` owns instruction lifecycle and text
transformations. It depends on `AgentsCore` for sources and state, and on
`swift-markdown` for CommonMark structure. `AgentsUpdates` composes both domains
above those modules. Tests follow those module boundaries.

## Belongs Here

- current package structure
- current target boundaries
- current documentation model
- current placement and ownership guidance

## Does Not Belong Here

- unresolved alternatives: `../Proposals/`
- decision records and cutovers: `../Decisions/` and `../Migrations/`
- retired material: `../Archive/`
- supporting reference material and examples: `../Reference/`

## Current Files

- `Package.md`: library products, module boundaries, and public workflows
- `State.md`: declaration, resolved state, source cache and installation invariants
- `Instructions.md`: instruction discovery, targets, lifecycle, prompts and diagnostics
- `Watch.md`: subscription operations, upstream comparisons and seen-state retention
- `Updates.md`: combined preparation, report semantics, handle lifetime and apply outcomes
