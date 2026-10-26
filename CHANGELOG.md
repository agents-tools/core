# Changelog

User-visible changes are recorded here in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
style. Versions follow the organization [versioning standard](https://github.com/agents-tools/.github/blob/master/VERSIONING.md);
publication follows the [release checklist](Documentation/Reference/Release.md).

## Unreleased

### Added

- Instructions files may sit in subdirectories of `instructions/` and
  `.agents/instructions/`; a file's name is its container-relative path, such
  as `epd/review`.
- A project's own instructions in `.agent/instructions/` are selected by bare
  name and read from the working tree. `InstructionAddOptions(source: ".")`
  adds them; `listOwn(environment:)` lists them.
- Front matter `paths` scopes a section: its patterns are named after its first
  heading, and in project scope the section is written to the `AGENTS.md` of
  the directory the patterns share.
- `InstructionOperations.export(projectRoots:environment:)` maps the locked
  targets of the user scope and given projects to their sections.
- Doctor reports hand-written files in target locations, own files changed
  since the lock, and links in generated targets that no longer resolve.

### Changed

- **Breaking:** an instructions file needs front matter with a `description`,
  and its body may start at any heading level. Add front matter to existing
  files; headings are written as authored.
- **Breaking:** targets are generated in full: a notice line followed by the
  sections. Custom content in targets, managed blocks, title detection, heading
  offsets and adoption of matching custom sections are gone. Move hand-written
  content into instructions files. Writing over a file that agents did not
  generate needs `replace`; `InstructionError.unownedTargets` names it.
- **Breaking:** `InstructionTargetChange.assembly` is replaced by `foreign`,
  and `InstructionDrift` is `clean`, `drifted` or `missing`. Diagnostic kinds
  `missingBlock`, `adoption` and `conflict` become `missingTarget`,
  `foreignTarget`, `ownChanged` and `invalidLink`.
- A local link in a section must resolve, from the target, to a file in the
  checkout being written; user targets accept no local links.
- A target that no longer receives sections is deleted only while it equals its
  locked rendering.

### Fixed

- Doctor's Codex size check counts only the project chain, as Codex does: the
  user file is loaded separately without a limit, separators are not counted,
  whitespace-only files add nothing, fallback names apply in every directory,
  and an existing `AGENTS.override.md`, even an empty one, hides `AGENTS.md`.

## 0.1.2 - 2026-10-25

### Added

- `AgentsUpdates` composes skill and instruction updates from one scope
  generation. `UpdateOperations.preview` returns a combined report;
  `withPreparedUpdate` holds the writer lock through preparation, rendering
  and a single recoverable apply. Its one-use handle expires at closure exit.
- Skill update results include `oldVersion`, `newVersion`, `lockMissing` and
  per-agent `SkillMembershipChange` rows, including unchanged and pinless
  live installations. Missing lock records do not grant ownership of existing
  targets.
- `UpdateApplyError` distinguishes confirmed unchanged, committed and
  recovery-required outcomes and preserves the underlying error.

### Changed

- **Breaking:** Require Swift 6.3 or newer and macOS 15 or newer. Upgrade the
  consumer toolchain and raise downstream macOS deployment targets to 15.
- **Breaking:** `SkillFileEntry.file(Data)` becomes
  `file(Data, executable: Bool)`. Upgrade constructors and pattern matches to
  supply or read the Boolean, which means any execute bit is set. Render it
  separately from content; it is not a complete permission mask.
- **Breaking:** synthesized `Codable` reports have a new file-case payload
  and required `UpdateResult.lockMissing` and `membership` fields. Update
  serialized report fixtures and custom codecs; old reports are not reusable
  apply plans. CLI JSON adapters remain owned by their consumer repositories.
- Standalone update callbacks retain their signatures and receipt semantics.
  Updates now reject changes to state, target identities, skill content/mode,
  instruction bytes and forwarding inputs made during the callback. Live
  source contents remain live, with identity and skill metadata revalidated.

### Fixed

- Report and apply executable-only changes, including local copy drift at an
  unchanged pin. Verify prepared, cached and staged modes separately from the
  unchanged persistent tree hashes and version 1 state formats.
- Resolve shared sources once during combined planning, merge domain-owned
  lock records, and include state-only changes in `CombinedUpdateReport.hasChanges`.
  Both kinds, changed state files and pruning commit or recover together.

## [0.1.1] - 2026-10-20

### Fixed

- Source arguments accept typed selectors again, such as
  `owner/repo@branch:main@path:skills@skill:pdf`, in skill add and listing,
  instruction add and watch add. `@ref:` is a revision.
- Sources whose locations end in the same component, such as
  `anthropics/skills` and `sketch-hq/skills`, can share a scope: the later one
  is declared under a prefixed alias such as `anthropics-skills`.

## [0.1.0] - 2026-10-19

The first release of the libraries behind `agents` and `skill`.

### Migration

- Consumers depend on `"0.1.0"..<"0.2.0"` instead of the `master` branch.

### Added

- Public `AgentsCore`, `AgentsSkills` and `AgentsInstructions` libraries for
  source resolution, skill management and instruction lifecycle operations.
- Declarative sources and per-item pins, verified source caches, exact restore
  and recoverable transactions for installations and state.
- Editable local skill installations, update previews and diagnostics.
- Managed instruction sections, Claude forwarding and named ChatGPT prompts.
- Independent source watch subscriptions with status, content diffs and seen
  baselines for Git and well-known sources.

### Changed

- Command parsing and executable distribution moved to the consuming CLI
  repositories; this package exposes reusable library APIs.

### Fixed

- Preserve exact prerelease pins while excluding prereleases from stable ranges.
- Reject unreadable resolved state before changing installed content.
- Keep inspection, watch status and diffs read-only; include physical recipient
  changes in update previews.
- Never replace a skill directory, file or resolvable link that the scope's lock
  does not manage; adding or installing over one fails and leaves it and the
  state unchanged.
- Diagnose shared installations correctly and allow removing managed records
  whose files are missing.
- Drain subprocess output concurrently and make Git operations non-interactive,
  with concise source-specific failures.

[0.1.1]: https://github.com/agents-tools/core/releases/tag/0.1.1
[0.1.0]: https://github.com/agents-tools/core/releases/tag/0.1.0
