# Contributing

This repository is a SwiftPM package. Keep changes small, tested, and aligned
with the documented package boundaries.

## Development Loop

```bash
swift build
swift test
swift build -c release
```

## Change Guidelines

- Put shared source, registry, lock, and watch behavior in the `AgentsCore`
  target under `Sources/AgentsCore`, with tests in `Tests/AgentsCoreTests`.
- Put skill discovery, installation, and lifecycle behavior in the `AgentsSkills`
  target under `Sources/AgentsSkills`, with tests in `Tests/AgentsSkillsTests`.
- Keep dependencies directed from `AgentsSkills` to `AgentsCore`; Yams belongs
  to `AgentsSkills`.
- Update `Documentation/Architecture/*` when the current structure changes.
- Add a decision record under `Documentation/Decisions/*` when a change locks
  in a meaningful direction.

## Pull Requests

Before opening a pull request, include:

- a short description of the behavior change
- validation commands and results
- documentation updates when library behavior or package structure changes
