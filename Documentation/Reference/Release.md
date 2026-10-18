# Release Checklist

`agents-tools/core` releases are Git tags consumed by `agents-tools/cli` and
`skill-cli/cli`. Release in this order: **core → both CLIs → both Homebrew
taps**. Each CLI owns its version and executable release; each tap distributes
its CLI release.

## Preflight

- [ ] Start in an up-to-date `master` checkout of `agents-tools/core`. Confirm
  the branch is `master` and the tree has no staged, modified, or untracked
  files before updating it:

  ```bash
  git branch --show-current
  git status --short
  git fetch origin --tags
  git pull --ff-only origin master
  release_commit=$(git rev-parse HEAD)
  git rev-parse origin/master
  ```

  Confirm `release_commit` equals `origin/master`. Keep this checkout at that
  commit throughout preflight and publication.

- [ ] Confirm the CI workflow is green on that exact release commit on
  `master`, including Format, Test, Diff Check, and Release Build. A passing
  PR run does not establish the status of the squash-merged release commit.
- [ ] Run the local release checks. All commands must exit zero, and formatting
  must produce no warnings. CI uses strict lint so any finding fails the job.

  ```bash
  swift build -c release
  env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
  xcrun swift-format lint --strict --configuration .swift-format --recursive Package.swift Sources Tests
  git diff --check
  ```

  The test command clears agent configuration overrides while keeping `HOME`,
  `TMPDIR`, and `PATH` at their defaults.

- [ ] Recheck `git status --short` for a clean tree and `git rev-parse HEAD`
  against `release_commit`. If the release commit changes, repeat preflight.

## Version and Notes

- [ ] Choose the next version using SemVer and the changes since the last
  release. Bump patch for backward-compatible fixes and minor for
  backward-compatible functionality. Breaking changes bump major starting at
  `1.0.0`; during `0.x`, they bump minor. Reset lower components when bumping a
  higher component.
- [ ] Use a tag named exactly `X.Y.Z`, with **no `v` prefix**. Published tags
  are never moved, replaced, or reused; corrections require a new version.
  Replace `X.Y.Z` below with the chosen version and confirm the tag is unused:

  ```bash
  version=X.Y.Z
  git tag --list "$version"
  ```

- [ ] Prepare release notes covering public API additions, changes and
  removals, fixes, and any migration steps for the two CLI consumers. Set
  `notes_file` to the path of the prepared notes file.
- [ ] Use the repository's local SSH signing configuration for commits and
  tags, with the configured key available. Release-related PR titles use
  Conventional Commits: PRs are squash-merged with the PR title as the commit
  subject.

## Publish Core

- [ ] Create a signed annotated tag on the checked release commit. `-s`
  creates the annotated signature using the configured SSH signing key:

  ```bash
  git tag -s "$version" "$release_commit" -m "Release $version"
  git rev-parse "$version^{commit}"
  ```

  Confirm the tag resolves to `release_commit`.

- [ ] Push that tag, then create the GitHub release with the prepared notes:

  ```bash
  git push origin "refs/tags/$version"
  gh release create "$version" --verify-tag --title "$version" --notes-file "$notes_file"
  ```

  `--verify-tag` requires the published tag to exist. Confirm the release
  displays the expected version, commit, and notes before updating consumers.

## Release Consumers and Taps

- [ ] In **both** `agents-tools/cli` and `skill-cli/cli`, update the core
  dependency in `Package.swift` to the published core version:

  ```swift
  .package(url: "https://github.com/agents-tools/core.git", from: "X.Y.Z")
  ```

  Resolve dependencies and update each repository's tracked resolution file
  when applicable. Run that CLI's checks and address any required API migration.
- [ ] Release both CLIs using their own release procedures and versions, with
  signed commits and tags. Confirm both CLI releases are published before
  proceeding to the taps.
- [ ] Update the formula in each CLI's Homebrew tap: set `url` to that CLI's
  released source archive and `sha256` to the SHA-256 of the exact downloaded
  archive bytes. Use each CLI's release version for its formula.
- [ ] Verify **each** updated formula in a clean test environment where it is
  not already installed. Set `formula` to the tap's fully qualified formula
  name and run:

  ```bash
  brew install --build-from-source "$formula"
  brew test "$formula"
  ```

  Both commands must pass for both formulae before publishing the tap updates.
