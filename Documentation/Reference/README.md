# Reference

This directory holds supporting reference material for `core`.

## Guides

- [Agent client inspection](AgentClients.md): passive observations and schema evidence through the public API.
- [MCP registry](MCPRegistry.md) covers browsing, selecting, and deploying registry servers through the public API.
- [APM file import](APMImport.md) describes the supported manifest and lock inputs.
- [Agents manifest language](Manifest.md): YAML field shapes, scalar semantics, limits, source edits, dump and diagnostics.
- [Team marketplace](Marketplace.md) covers local publication, Git catalogs and locked package selection.
- [Author project packaging](AuthorPackaging.md) covers read-only review, exact
  archive publication, and native plugin layouts.
- [Repository presentation](Presentation.md): the README Quick look fixture and
  standalone consumer validation.
- [Release checklist](Release.md): preflight, signed version tags, GitHub
  releases, and downstream CLI and Homebrew updates.

## Placement

- Use this directory for details that support implementation and operation.
- Keep current package structure in `../Architecture/`.
- Keep design alternatives in `../Proposals/`.
