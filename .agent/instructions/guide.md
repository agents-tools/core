---
description: Keep agents-tools/core's modules, dependency direction and public surface within their boundaries.
---
# core Agent Guide

## Task Route

- Run the build, test and strict formatting checks in `README.md#development`
  before handoff.
- Community files and templates are organization defaults in
  `agents-tools/.github`; this repository keeps `CODEOWNERS`, the Dependabot
  configuration and workflow callers under `.github/`.

## Module Boundaries

- Keep shared primitives, source resolution, registry, lock and watch behavior
  in `Sources/AgentsCore`, and skill discovery, installation and lifecycle in
  `Sources/AgentsSkills`. `AgentsCore` must not depend on `AgentsSkills`; Yams
  belongs to `AgentsSkills`.
- Keep command parsing and terminal behavior in the consuming repositories.
- Expose consumer operations and their models publicly; keep implementation
  details internal, or package-visible when shared between targets.
- Keep package-domain prefixes out of internal target names unless the package
  boundary stops making that context clear.
- Disable automatic maintenance and gc in fixture Git repositories.
