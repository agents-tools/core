# Changelog

User-visible changes are recorded here in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
style. Versions follow the organization [versioning standard](https://github.com/agents-tools/.github/blob/master/VERSIONING.md);
publication follows the [release checklist](Documentation/Reference/Release.md).

## Unreleased

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
