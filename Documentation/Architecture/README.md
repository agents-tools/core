# Architecture

This directory holds the current truth for `core`, a SwiftPM library package.
`AgentsCore` owns shared source, registry, lock, and watch behavior;
`AgentsSkills` owns skill discovery and lifecycle operations and depends on
`AgentsCore` and Yams. `AgentsInstructions` owns pure instruction text
transformations and depends on `AgentsCore` for hashing and `swift-markdown`
for CommonMark structure. Tests follow those module boundaries.

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

- `Package.md`: library products, module boundaries, and runtime state
