# Release Checklist

`agents-tools/core` releases are Git tags consumed by `agents-tools/cli` and
`skill-cli/cli`. Release in this order: **core → both CLIs → both Homebrew
taps**. Each CLI owns its version and executable release; each tap distributes
its CLI release.

Follow the organization [versioning standard][versioning] and
[maintenance change flow][maintenance]. Release notes are maintained in
[CHANGELOG.md](../../CHANGELOG.md).

## Version and Notes

Release timing follows the organization [versioning standard][versioning],
which defers to the governing delivery workflow. Include the version change and
changelog entry in the requirement's final delivery candidate.

- [ ] Choose the next version from the changes in `Unreleased` using the
  organization [versioning standard][versioning].
- [ ] Use a tag named exactly `X.Y.Z`, with **no `v` prefix**. Published tags
  are never moved, replaced, or reused; corrections require a new version.
  Replace `X.Y.Z` below with the chosen version and confirm the tag is unused:

  ```bash
  version=X.Y.Z
  git tag --list "$version"
  ```

- [ ] Move the shipped `Unreleased` changes into a `## X.Y.Z` section in
  `CHANGELOG.md`, retaining `Unreleased` for subsequent work. Include public API
  additions, changes and removals, fixes, and migration steps for both CLI
  consumers. Merge the final delivery candidate before selecting the release
  commit and running preflight. Set `notes_file` to the prepared release notes file.
- [ ] Use the repository's local SSH signing configuration for commits and
  tags, with the configured key available.

## Preflight

- [ ] Start in a clean task-owned or detached worktree of `agents-tools/core`
  at the accepted `origin/master` commit. Confirm there are no staged,
  modified or untracked files, then resolve the current default-branch head:

  ```bash
  git status --short
  git fetch origin master --tags
  release_commit=$(git rev-parse HEAD)
  git rev-parse origin/master
  ```

  Confirm `release_commit` equals `origin/master`. Keep this checkout at that
  commit throughout preflight and publication.

- [ ] Confirm `policy / policy` and `validate / swift-package` succeeded on
  that exact release commit on `master`. A passing PR run does not establish
  the status of the squash-merged release commit.
- [ ] Run the local release checks below from a fresh build path with dependency
  and manifest caches disabled. Let this validation finish independently of
  superseding development CI runs; development CI is not release validation.
  All commands must exit zero, and strict formatting must produce no warnings.

  ```bash
  rm -rf .build/release-validation
  swift build -c release --scratch-path .build/release-validation \
    --disable-dependency-cache --manifest-cache none
  env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME \
    -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test \
    --scratch-path .build/release-validation \
    --disable-dependency-cache --manifest-cache none
  xcrun swift-format lint --strict --configuration .swift-format --recursive Package.swift Sources Tests
  git diff --check
  ```

  The test command clears agent configuration overrides while keeping `HOME`,
  `TMPDIR`, and `PATH` at their defaults.

- [ ] Recheck `git status --short` for a clean tree and `git rev-parse HEAD`
  against `release_commit`. If the release commit changes, repeat preflight.

## Publish Core

- [ ] Create a signed annotated tag on the checked release commit. `-s`
  creates the annotated signature using the configured SSH signing key:

  ```bash
  git tag -s "$version" "$release_commit" -m "Release $version" &&
    git verify-tag "$version" &&
    tag_commit=$(git rev-parse "$version^{commit}") &&
    test "$tag_commit" = "$release_commit"
  ```

  Confirm the signature is valid and the tag resolves to `release_commit`.

- [ ] Push that tag and verify its remote target before creating the GitHub
  release with the prepared notes:

  ```bash
  git push origin "refs/tags/$version" &&
    remote_tag=$(git ls-remote --exit-code origin "refs/tags/$version^{}") &&
    test "$remote_tag" = "$(printf '%s\t%s' "$release_commit" "refs/tags/$version^{}")" &&
    gh release create "$version" --verify-tag --title "$version" --notes-file "$notes_file"
  ```

  The remote `^{}` entry identifies the annotated tag's target commit. The
  `&&` chain requires a successful push, remote lookup, and exact match with
  `release_commit` before publication. Stop on any failure; published tags are
  never moved. `--verify-tag` checks tag existence, not commit identity. Confirm
  the release displays the expected version, commit, and notes before updating
  consumers.

## Release Consumers and Taps

- [ ] In **both** `agents-tools/cli` and `skill-cli/cli`, update the core
  dependency in `Package.swift` to the published core version. While core is
  `0.x`, use the minor-bounded range `"X.Y.Z"..<"X.(Y+1).0"`: substitute the
  released version and the next minor version, with patch zero. For example:

  ```swift
  .package(url: "https://github.com/agents-tools/core.git", "0.2.3"..<"0.3.0")
  ```

  This permits compatible patch updates while excluding breaking minor
  releases. When core reaches `1.0.0`, change the rule to `from:` for the
  published version, allowing updates up to the next major version:

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
- [ ] Verify **each** updated formula in a disposable Homebrew test environment
  where it is not already installed. Start in the edited tap checkout. Set
  `formula_name` to the formula's filename without `.rb` and `test_tap` to an
  unused temporary `owner/name` tap name. Disable API installs and automatic
  updates, tap the local checkout, and copy the candidate formula into that
  test tap so uncommitted edits are included:

  ```bash
  export HOMEBREW_NO_INSTALL_FROM_API=1
  export HOMEBREW_NO_AUTO_UPDATE=1
  tap_checkout=$PWD
  brew tap "$test_tap" "$tap_checkout" &&
    test_tap_checkout=$(brew --repository "$test_tap") &&
    cp "Formula/$formula_name.rb" "$test_tap_checkout/Formula/$formula_name.rb" &&
    cmp "Formula/$formula_name.rb" "$test_tap_checkout/Formula/$formula_name.rb" &&
    brew info --json=v2 "$test_tap/$formula_name"
  ```

  Stop if setup fails. Check the displayed stable source URL and SHA-256
  against the intended CLI release archive and its independently calculated
  digest before proceeding. Keep the test tap unchanged throughout validation.
- [ ] Fetch the candidate's source archive to validate its checksum, then
  build and test the formula from the populated test tap:

  ```bash
  brew fetch --force --build-from-source "$test_tap/$formula_name" &&
    brew install --build-from-source "$test_tap/$formula_name" &&
    brew test "$test_tap/$formula_name"
  ```

  All commands must pass for both formulae before publishing the tap updates.
  Discard the disposable test environment after validation.

- [ ] Remove `.build/release-validation` and retire the release worktree after
  recording the accepted commit, tag and validation results in the release.

[versioning]: https://github.com/agents-tools/.github/blob/master/VERSIONING.md
[maintenance]: https://github.com/agents-tools/.github/blob/master/MAINTENANCE.md#change-flow
