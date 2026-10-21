# Repository Presentation

The README introduces the library through a public API example. Use the same
short description for the tagline, repository About field and social card:

> Swift libraries behind agents and skill: sources, locks, skills, instructions
> and watch.

## Header

The linked [framework logo](../../.github/assets/logo/logo.svg) is generated
from the `core` icon entry in the [organization DESIGN][design]. Static badges
use its `ink` token for the value background and `social-preview-muted` for
the label background.
CI uses the workflow's live status badge. Badge labels and links derive from
`.github/workflows/ci.yml`, `Package.swift` and `LICENSE`.

The static badges use Shields' query-form endpoint. The README checker's badge
URL checks cover its path-form endpoint, so also inspect the served SVG
`aria-label` and fill colors against the manifest, license and DESIGN when
changing this header. Keep the order CI, Swift, platforms, license.

## Quick Look

The README example links a live local skill for Codex in project scope. Start
with a fresh project containing this `skills/review/SKILL.md`:

```markdown
---
name: review
description: Review code for correctness and maintainability.
---

# Review

Check the proposed changes against their requirements.
```

Validate the exact README snippet in a scratch SwiftPM executable under the
checkout's ignored `.build/presentation/consumer/` directory. Its manifest uses
Swift tools 6.3, a macOS 13 minimum, and `.package(path: "../../..")` to depend on
this checkout. Add the `AgentsCore` and `AgentsSkills` products to the executable
target; the local dependency's package identity is the checkout directory's
name.

Copy the Swift block under `Quick look` verbatim into the executable source.
Build with `swift build --package-path .build/presentation/consumer`, then run
that executable with `.build/presentation/project/` as its working directory,
containing the skill fixture above. Unset `CODEX_HOME`, `CLAUDE_CONFIG_DIR`,
`XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` when running it.

The expected stdout is `review` followed by a newline. Verify that
`.agents/skills/review` in the scratch project links to `skills/review` and that
`.agent/agents.json` and `.agent/agents.resolved` record the selection. Remove
`.build/presentation/` after validation.

[design]: https://github.com/agents-tools/.github/blob/master/DESIGN.md

## Social preview

The committed [PNG](../../.github/assets/social-preview/social-preview.png) is
rendered from the DESIGN, fonts and catalog at the `agents-tools/.github`
presentation workflow pin in [CI](../../.github/workflows/ci.yml). The catalog's
light-page icon resolves to this checkout's framework logo SVG.

Follow the pinned toolchain's [local regeneration procedure][toolchain]. Use
`standard_dir` for the standard inputs at the CI pin and `toolchain_dir` for
that package, keeping temporary inputs under ignored `.build/`:

```sh
node "$toolchain_dir/src/cli.ts" social-preview render \
  --design "$standard_dir/DESIGN.md" --fonts "$standard_dir/.github/design/fonts" \
  --catalog "$standard_dir/profile/catalog.json" --repository core \
  --icon .github/assets/logo/logo.svg \
  --out .github/assets/social-preview/social-preview.png
node "$toolchain_dir/src/cli.ts" social-preview check \
  --design "$standard_dir/DESIGN.md" --fonts "$standard_dir/.github/design/fonts" \
  --catalog "$standard_dir/profile/catalog.json" --repository core \
  --icon .github/assets/logo/logo.svg --assets .github/assets/social-preview
```

CI's `presentation` caller takes no inputs. On drift, artifact `presentation`
contains `presentation.tar`; extract it with
`tar -xf presentation.tar -C .github/assets`, review and commit the PNG.

[toolchain]: https://github.com/showxu/skills/blob/9e5d7268232b78f5fbef21ccfb9e3a079f2ef7e3/skills/github-readme-design/references/renderers.md#local-regeneration
