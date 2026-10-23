# core Agent Guide

Read `README.md` first for repository purpose, library API, and development
entry points.

## First-Principles Work

- Name the behavior, root cause, invariant, owner, data flow, and validation
  before changing reusable files.
- Change the owning layer, not the nearest convenient file.
- Keep changes traceable to the request, source evidence, or owning invariant.
- Validate with package-local checks when behavior changes.

## Task Route

- For documentation placement, read `Documentation/README.md` before editing.
- For current package structure, read `Documentation/Architecture/README.md`
  and the relevant architecture files.
- For unresolved design work, use `Documentation/Proposals/*`.
- For durable rationale, use `Documentation/Decisions/*`.
- For migration notes, use `Documentation/Migrations/*`.
- For retired material, use `Documentation/Archive/*`.
- For supporting details and examples, use `Documentation/Reference/*`.
- Community files and templates are organization defaults in
  `agents-tools/.github`; this repository keeps `CODEOWNERS`, Dependabot
  configuration and workflow callers under `.github/`.
- Follow the organization [maintenance change flow](https://github.com/agents-tools/.github/blob/master/MAINTENANCE.md#change-flow).

## Authority

- `AGENTS.md` is the agent guide for repository work.
- `README` files index scope and placement.
- `Documentation/Architecture/*` states current truth.
- `Documentation/Proposals/*` is design-in-progress.
- `Documentation/Decisions/*`, `Documentation/Migrations/*`, and
  `Documentation/Archive/*` are history.
- `.github/*` is GitHub-facing workflow metadata.

## Boundary Guardrails

- Do not promote machine-local paths, one-run state, fixture-only values, or
  temporary execution state into reusable docs, scripts, templates, or
  automation.
- If a value changes by input or environment, pass it in, configure it, derive
  it, or link to the owning artifact.
- Keep command parsing and terminal behavior in consuming repositories.
- Keep shared source, registry, lock, and watch behavior in `AgentsCore`; skill
  discovery and lifecycle behavior belongs in `AgentsSkills`.
- `AgentsCore` must not depend on `AgentsSkills`. Yams belongs to `AgentsSkills`.

## Tests

- Run the build, test and strict formatting checks in
  [README.md](README.md#development) before handoff. The required CI contexts
  are `policy / policy` and `validate / result`; keep their caller job
  IDs and shared workflow pins consistent with the
  [shared workflow reference](https://github.com/agents-tools/github-workflows#configuration).
  Shared CI compiles and tests only with the latest stable Xcode selected in
  `.github/swift-package.json`.
  Render and check the social preview locally with the github-readme-design
  toolchain against `agents-tools/.github`'s DESIGN, fonts and catalog; see
  `Documentation/Reference/Presentation.md`. Commit the resulting assets.
  For workflow edits, also run `actionlint` on every workflow.
- Pass an explicit initial branch when creating Git fixtures.
- Disable automatic maintenance and gc in fixture Git repositories.
- Each test that creates a temporary directory removes it.
- Run tests with agent configuration variables unset:

  ```bash
  env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME swift test
  ```

## Operating Notes

- Keep package-domain prefixes out of internal target names unless the package
  boundary stops making that context clear.
- Keep shared primitives and source resolution in `Sources/AgentsCore`.
- Keep skill discovery, installation, and orchestration in `Sources/AgentsSkills`.
- Expose consumer operations and their models publicly; keep implementation
  details internal or package-visible when shared between the two targets.
- Run `swift test` before handing off behavior changes.
