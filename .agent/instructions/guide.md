---
description: Keep agents-tools/core's modules, dependency direction and public surface within their boundaries.
---
# core Agent Guide

## Task Route

- Run the build, test and strict formatting checks in `README.md#development`
  before handoff.
- For workflow changes, run `actionlint` on every workflow.
- Community files and templates are organization defaults in
  `agents-tools/.github`; this repository keeps `CODEOWNERS`, the Dependabot
  configuration and workflow callers under `.github/`.

## Module Boundaries

- Keep each target's responsibilities, dependencies and access levels as
  `Documentation/Architecture/Package.md` states, and update it with the
  dependency graph in `Package.swift`.
- Keep package-domain prefixes out of internal target names unless the package
  boundary stops making that context clear.
- Disable automatic maintenance and gc in fixture Git repositories.
