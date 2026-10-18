# Architecture

This directory holds the current truth for `core`, a SwiftPM library package.
`AgentsCore` owns shared sources, declaration and lock storage, cache, and agent locations;
`AgentsSkills` owns skill discovery and lifecycle operations and depends on
`AgentsCore` and Yams. `AgentsInstructions` owns instruction lifecycle and text
transformations. It depends on `AgentsCore` for sources and state, and on
`swift-markdown` for CommonMark structure. Tests follow those module boundaries.

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
