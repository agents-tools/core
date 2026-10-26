# Agents: Skills and Instructions from Declared Sources

## Status

Draft

## Problem

Agents load two kinds of guidance from disk. Skills are loaded on demand from
skill directories. Instructions are loaded into every session from files such
as `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, at user level and per project.

Skills can be installed from pinned sources, but instruction files are copied
by hand. The same sections end up in many repositories and user files, each
copy drifts on its own, and nothing records where a section came from or which
version it is. There is no way to tell which copy is current or to audit the
files systematically. ChatGPT cannot read local instruction files at all, so
its project and task instructions are pasted from yet another copy.

The skill implementation this package starts from has related gaps:

- Intent lives only in command history. A source added with `--all` does not
  follow later additions or removals.
- `install` re-resolves requirements instead of restoring the locked revision,
  and cannot restore well-known sources.
- One mutable checkout per source makes results depend on what ran before and
  lets inspection commands move it.
- Source identities collide across hosts and between local directories with
  the same name, and two sources can overwrite the same installed skill name.
- Watch is a review gate tied to the current directory, and it keeps a full
  checkout per reviewed commit.

## Goals

- Manage skills and instructions as two kinds of one model: shared sources,
  declaration, lock and lifecycle commands.
- Write each piece of guidance once, as an instructions file, and generate
  every target from them; make every target traceable to its sections and
  their locked versions, and make drift detectable.
- Scope a section to the files it governs, with the same effect in every agent
  that reads the generated files.
- Render instructions as named prompts for ChatGPT project instructions and
  scheduled tasks.
- Restore exactly what the lock records; re-resolve only on `add` and `update`.
- Report what changed upstream in subscribed sources.

## Non-goals

- Agent runtime configuration such as MCP servers, hooks, subagents and
  settings. These are evaluated separately after instructions ship.
- Collaboration. The tool is the only writer of generated targets; a change to
  a target from anywhere else is drift.
- Version control. The tool writes files; each project decides whether and when
  to commit them.
- Compatibility with earlier state files and source syntax.

## Products

| Product | Repository | Executable | Scope |
| --- | --- | --- | --- |
| Core library | `agents-tools/core` | — | Modules `AgentsCore` (sources, declaration, lock, cache, watch), `AgentsSkills`, `AgentsInstructions` |
| agents | `agents-tools/cli` | `agents` | Skills, instructions and watch |
| skill | `skill-cli/cli` | `skill` | Skills and watch only; depends on `AgentsCore` and `AgentsSkills` |

Both executables are thin command-line layers. All behavior lives in the core
modules, so the two products cannot diverge. The `skill` executable reads and
writes the same declaration, lock and watch state and leaves the
`instructions` parts untouched.

## Concepts

| Term | Meaning |
| --- | --- |
| Source | A Git repository, a local directory or a well-known index that provides skills, instructions or both |
| Skill | A directory with a `SKILL.md`, loaded by agents on demand |
| Instructions | One self-contained Markdown file in an instructions container, loaded by agents once it is written into a target |
| Section | The body of one instructions file as written into a target |
| Target | A file that agents read instructions from, generated in full from sections, or a named ChatGPT prompt |
| Declaration | What the user wants: sources, selected skills and sections, agents, subscriptions |
| Lock | What was resolved and written: pins, content hashes, installs and targets |
| Pin | The immutable state an item was resolved at: a Git revision, or a well-known artifact's URL and digest |

## Sources

A source can provide both kinds. Discovery needs no manifest. `--path <subdir>`
moves the search root for both kinds and is recorded with the source.

Skill discovery keeps the current implementation's rules: a `SKILL.md` at the
search root, skill directories directly under the root, the conventional
containers (`skills/` with `.curated`, `.experimental` and `.system`,
`.agents/skills/`, `.claude/skills/`, `.codex/skills/`, `.opencode/skills/`),
directories named by plugin and marketplace manifests, and a recursive search
when these find nothing or when `--full-depth` is given.

Instructions are `.md` files in the `instructions/` and `.agents/instructions/`
containers, including their subdirectories. An instructions file's name is its
path inside the container without `.md`, such as `epd/review` for
`instructions/epd/review.md`. Each path segment uses lowercase letters, digits
and hyphens, so names stay distinct on case-insensitive file systems. A name
present in both containers is an error. The containers hold regular files only;
a symbolic link is an error, not a way to publish a file kept elsewhere. Every
file in a container is an instructions file; other documents in the source
refer to them.

A project's own instructions live in its `.agent/instructions/` and are
selected by bare name. They are read from the working tree as it is, like a
skill in `edit` mode, so a changed instructions file and the target it
regenerates belong to one commit; the lock records their hashes.

An instructions file has a fixed format:

```markdown
---
description: Flag claims that the code and tests do not support.
paths: ["Sources/**/*.swift"]
---
## Code Review Rules

### Claims

- Flag README, DocC, or release-note statements ...
```

- Front matter is required. `description`, also required, is one sentence on
  what the file makes the agent do; `list` shows it. `paths` is an optional list
  of project-relative glob patterns using `*`, `**` and `?`. Other keys are
  errors. Front matter is not written into targets.
- The body starts with one ATX heading at the level the author wants it to
  have in the target; every other heading is a deeper ATX heading. The tool
  never changes heading levels.
- The body does not end inside a code or HTML block.
- A link to a local file must resolve, from the target file, to a regular file
  inside the checkout being written. User targets belong to no checkout, so
  their sections link to no local file. URLs with a scheme other than `file:`
  and bare fragments are unrestricted; raw HTML links are invalid. Text that
  names a file, such as "run the checks in `CONTRIBUTING.md`", refers to the
  target's own files.

A source's instructions container is never itself a target location.

| Source kind | Pinned by | Notes |
| --- | --- | --- |
| Git repository | Commit revision | Remote URL or a local repository path |
| Local directory | Commit revision when it is a Git repository | Pinned content (`link` and `copy` installs, instructions) is read from the committed tree; uncommitted changes are ignored and reported. A directory that is not a Git repository can only be used in `edit` mode |
| Well-known index | Each artifact's URL and digest | Restore fetches the recorded URL and verifies the digest; it never consults the index |

Source IDs are normalized and provider-qualified, so the forms cannot collide:

| Kind | ID |
| --- | --- |
| Git | `host[:port]/path`, host lowercased, without scheme, user or `.git` (`github.com/owner/repo`) |
| Local | `local:` followed by the absolute path (`local:/Users/me/rules`) |
| Well-known | The index URL with its scheme (`https://example.com`) |

Two declared sources that normalize to the same ID are an error.

## Scopes and Files

| Scope | Declaration | Lock | Watch state | Targets |
| --- | --- | --- | --- | --- |
| Project | `.agent/agents.json` | `.agent/agents.resolved` | `.agent/agents.watch` | Project skills; `AGENTS.md` and `GEMINI.md` at the project root and in directories named by `paths`; Claude forwarding; ChatGPT prompts |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | User skills; each agent's user instructions file; ChatGPT prompts |

A project commits its declaration and lock, with its instructions files and
generated targets, as it would a package manifest and its lock: every checkout,
worktree and clone then holds the recipe and the result. The watch state, the
source cache and installed skill links are local and ignored. A project that
commits its state declares only portable sources, Git URLs or its own
instructions; a local source records an absolute path. User state is local and
always lives under `~/.agents`.

### Declaration

Commands edit the declaration; editing it by hand is possible.

```json
{
  "agents": ["codex", "claude-code"],
  "sources": {
    "rules": { "local": "~/Developer/rules", "branch": "main" },
    "swift-skills": { "git": "github.com/swift-library/skills", "from": "1.0.0" },
    "my-skills": { "local": "~/Developer/my-skills", "path": "skills" },
    "anthropic": { "git": "github.com/anthropics/skills" }
  },
  "skills": {
    "swift-skills": { "select": "all", "exclude": ["legacy-docx"] },
    "my-skills": {
      "select": ["pdf-forms", "release-notes"],
      "mode": "edit",
      "overrides": { "release-notes": { "agents": ["codex"] } }
    }
  },
  "instructions": {
    "agents": ["codex", "claude-code", "cursor", "opencode"],
    "sections": ["guide", "rules:canonical-artifacts", "code-review-rules"],
    "chatgpt": {
      "training": {
        "sections": ["rules:canonical-artifacts", "rules:training-logging"],
        "append": ".agent/chatgpt-training.md"
      },
      "weekly-export": { "sections": ["rules:weekly-nutrition-export"] }
    }
  },
  "watch": ["anthropic"]
}
```

- A source names its kind by key (`git`, `local`, `well-known`), plus an
  optional requirement and search `path`. Requirements are `branch`,
  `revision`, `exact` (one version), `from` (up to the next major version),
  `upToNextMinor`, or `from` with `to` (a half-open range). Without one, the
  latest version tag is used, or the default branch when there are no version
  tags.
- `agents` is the default agent list. Without it the default is `codex` and
  `claude-code`.
- `select` is `"all"` or a list of names. `"all"` follows the source's current
  membership on `update`; `exclude` names skills it skips. Removing one skill
  of an `"all"` selection adds it to `exclude`.
- `agents` and `mode` on a selection apply to its skills; `overrides` sets
  them for single skills. `mode` is `link` (default), `copy` or `edit`.
  `edit` links the live directory of a local source, takes no requirement and
  is never pinned.
- `instructions` holds one ordered section list per scope, written to the
  instruction file of every listed agent. Every change to the list or its pins
  is applied to all listed targets together; `--agent` on instruction
  commands sets the list of recipients.
- A section reference is `alias:name` for a declared source, or a bare name for
  the project's own instructions.
- `chatgpt` names prompts for ChatGPT project instructions and scheduled
  tasks. Each prompt has its own ordered section list and an optional
  custom-content file, relative to the scope root, that `render` appends.
- `watch` lists the aliases of subscribed sources. A source can be subscribed
  without selecting anything from it.

### Lock

```json
{
  "version": 1,
  "sources": {
    "github.com/swift-library/skills": {
      "kind": "git",
      "url": "https://github.com/swift-library/skills.git",
      "requirement": { "from": "1.0.0" }
    },
    "local:/Users/me/Developer/rules": {
      "kind": "local",
      "requirement": { "branch": "main" }
    },
    "local:/Users/me/Developer/my-skills": {
      "kind": "local",
      "path": "skills"
    },
    "https://example.com": {
      "kind": "well-known"
    }
  },
  "skills": {
    "swiftui-patterns": {
      "source": "github.com/swift-library/skills",
      "revision": "16548e957446d2b33a6792f180d6c3f815e76722",
      "version": "1.4.0",
      "path": "skills/swiftui-patterns",
      "hash": "sha256:…",
      "installs": { "codex": "link", "claude-code": "link" }
    },
    "pdf-forms": {
      "source": "local:/Users/me/Developer/my-skills",
      "path": "skills/pdf-forms",
      "installs": { "codex": "edit", "claude-code": "edit" }
    },
    "spreadsheet": {
      "source": "https://example.com",
      "artifact": {
        "type": "archive",
        "url": "https://example.com/.well-known/skills/spreadsheet.zip",
        "digest": "sha256:…"
      },
      "hash": "sha256:…",
      "installs": { "codex": "copy" }
    }
  },
  "instructions": {
    "sections": [
      {
        "name": "guide",
        "source": ".",
        "path": ".agent/instructions/guide.md",
        "hash": "sha256:…"
      },
      {
        "name": "canonical-artifacts",
        "source": "local:/Users/me/Developer/rules",
        "revision": "a03a475f0c1d2e3b4a5968778695a4b3c2d1e0f9",
        "path": "instructions/canonical-artifacts.md",
        "hash": "sha256:…"
      },
      {
        "name": "code-review-rules",
        "source": ".",
        "path": ".agent/instructions/code-review-rules.md",
        "hash": "sha256:…"
      }
    ],
    "chatgpt": {
      "weekly-export": {
        "sections": [
          {
            "name": "weekly-nutrition-export",
            "source": "local:/Users/me/Developer/rules",
            "revision": "a03a475f0c1d2e3b4a5968778695a4b3c2d1e0f9",
            "path": "instructions/weekly-nutrition-export.md",
            "hash": "sha256:…"
          }
        ]
      }
    },
    "targets": {
      "AGENTS.md": {
        "agents": ["codex", "claude-code", "cursor", "opencode"],
        "headingOffset": 0,
        "blockHash": "sha256:…",
        "created": false
      },
      "CLAUDE.md": {
        "agents": ["claude-code"],
        "import": "AGENTS.md",
        "blockHash": "sha256:…",
        "created": false
      }
    }
  }
}
```

- Every map is keyed by identity, so duplicates cannot exist. A skill name is
  unique within a scope: adding a skill whose name is already installed from
  another source fails until the existing one is removed.
- Each item carries its own pin. Updating one kind, or one skill, never
  invalidates the pin of another item from the same source.
- A well-known artifact records its type, URL and digest; a `files` artifact
  records the URL, path and digest of every file. `edit` installs are live
  links to the source directory and carry no pin or hash.
- Instruction targets are keyed by physical file: a path relative to the
  project root, or a `~`-relative path in user scope. Agents share an entry
  only when their files resolve to the same path. For a generated target,
  `blockHash` covers the whole rendered file, `headingOffset` is always 0 and
  `created` is false; ownership is proven by the file's generated notice, and
  which sections a target receives follows from their `paths`.
- A project's own instructions are recorded with source `.`, their path in the
  project and their hash; they have no revision, because they are read live.
- `install` uses the lock and nothing else: each install's agent and mode, and
  each pin. A pin that cannot be fetched, content whose digest does not match,
  or an own instructions file whose hash changed since the lock is an error,
  never a substitution.
- Output is sorted, except section order, and has no timestamps. Writes take a
  file lock and replace the file atomically.

### Watch State

```json
{
  "version": 1,
  "sources": {
    "github.com/anthropics/skills": { "seen": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" },
    "https://example.com": {
      "seen": {
        "spreadsheet": "sha256:…",
        "pdf-forms": "sha256:…"
      }
    }
  }
}
```

For a Git source, `seen` is a revision; the mirror keeps its history. For a
well-known index, `seen` maps each artifact name to its digest (for a `files`
artifact, the digest of its sorted file list with per-file digests). The cache
keeps the artifacts a watch state references, so `watch diff` can show their
content.

## Commands

Commands form a noun-verb tree. A kind group acts on that kind; a top-level
verb acts on every kind.

```text
agents
├── skills
│   ├── add <source> [names…]     no names: one skill is added, several are listed; --all selects all
│   ├── list [source]
│   ├── remove <names…>
│   ├── update [names…] [--apply]
│   └── init [name]
├── instructions
│   ├── add <source> [names…]     `.` selects the project's own; [--replace]
│   ├── list [source]
│   ├── remove <names…>
│   ├── update [--apply] [--replace]
│   ├── render chatgpt <prompt>
│   ├── export [--root <dir>…]
│   └── init <name>
├── watch
│   ├── add <source>
│   ├── status                    also `agents watch`
│   ├── diff <source> [name]
│   ├── seen <source> [--revision <rev>]
│   └── remove <source>
├── install
├── update [--apply]
└── doctor [--root <dir>…]
```

`--agent <agent>`, `--scope project|user` and `--path <subdir>` mean the same
in every command except `install`. `--agent` defaults to the declaration's
`agents`. `skills add` also takes `--mode link|copy|edit`, and `skills add` and
`skills list <source>` take `--full-depth`. `instructions add` and
`instructions update --apply` take `--replace` to take over an existing target
file that agents did not generate.
For skills, omitting `--agent` makes `remove` act on all recipients and `list` show all recipients; declaration defaults apply only when adding or when a selection has no recipients.

| Command | Behavior |
| --- | --- |
| `add` | Update the declaration, resolve, write, update the lock. Any stop leaves the declaration, lock and files unchanged |
| `update` | Re-resolve the declaration and show what would change against the files on disk. `--apply` writes the resolved content and the new lock together, showing the difference before it replaces drifted content. Without names it reconciles `"all"` selections with the source's membership; with names it touches only those skills, and a named skill missing upstream is an error. `--apply` lists the ChatGPT prompts whose content changed, since ChatGPT has to be updated by pasting the new render |
| `install` | Restore skills and instruction targets exactly as the lock records them, without resolving. It takes no `--agent` or `--mode` |
| `list` | Installed skills, or managed sections and targets; with a source, what it provides |
| `remove` | Remove from the declaration, files and lock |
| `init` | Create a skill directory or an instructions file in the current directory |
| `render` | Print a ChatGPT prompt: its locked sections followed by its custom-content file, without markers. A prompt without locked sections is an error |
| `export` | Print the instruction mapping assembled from the user lock and the locks of the projects given with `--root`: for each target, its scope, recipients and sections with their sources and pins. It describes the locked state, not what is on disk, and reports a missing or unreadable scope instead of omitting it |
| `watch add` | Subscribe and record the source's current revision as seen |
| `watch status` | Report each subscribed source since its seen revision, per skill and instructions: new, changed, removed |
| `watch diff` | Show the changes behind `status`, for one source or one item |
| `watch seen` | Advance the seen revision to the source's current revision, or to `--revision` |
| `watch remove` | Drop the subscription and its state; installed items stay |
| `doctor` | Compare lock and disk and report problems (see below). `--root` audits several projects read-only, given explicit directories |

`update` without `--apply`, `list`, `doctor`, `render`, `export`,
`watch status` and `watch diff` change no declaration, lock, watch state,
target or checked-out revision. They may fetch new objects into a source
mirror.

`doctor` reports missing installs, drifted skill copies, missing or drifted
targets, existing files in target locations that agents did not generate, own
instructions changed since the lock, invalid instructions files and links,
sources with newer matching versions, local sources with uncommitted changes in
selected paths, sections installed at both scopes, Claude Code forwarding
problems, and a Codex `AGENTS.override.md` that hides a managed `AGENTS.md`.

It also reports a project whose Codex instructions exceed
`project_doc_max_bytes` (Codex configuration, default 32 KiB). The budget
covers only the project chain: from the project root, found by
`project_root_markers`, down to the working directory, the first regular file
in each directory among `AGENTS.override.md`, `AGENTS.md` and the configured
fallback names, even an empty one. It counts file bytes, not the separators
Codex inserts, and skips whitespace-only files. The user file
`$CODEX_HOME/AGENTS.md` is loaded separately and has no size limit.

The `skill` executable exposes the skills and watch subset with the same
behavior: `skill add|list|remove|update|init|install|doctor|watch …`.

## Agents and Instruction Files

| Agent | User scope | Project scope |
| --- | --- | --- |
| `codex` | `$CODEX_HOME/AGENTS.md`, default `~/.codex/AGENTS.md` | `AGENTS.md` |
| `claude-code` | `$CLAUDE_CONFIG_DIR/CLAUDE.md`, default `~/.claude/CLAUDE.md` | `AGENTS.md`, with forwarding below |
| `cursor` | Not file-based | `AGENTS.md` |
| `opencode` | `$XDG_CONFIG_HOME/opencode/AGENTS.md`, default `~/.config/opencode/AGENTS.md` | `AGENTS.md` |
| `gemini-cli` | `~/.gemini/GEMINI.md` | `GEMINI.md` |
| `chatgpt` | Named rendered prompts, no file | Named rendered prompts, no file |

Claude Code reads a project's `AGENTS.md` only when no `CLAUDE.md`,
`.claude/CLAUDE.md` or `CLAUDE.local.md` exists in the working directory or
above it. When `claude-code` is a target in project scope:

- a project `CLAUDE.md` that is a symbolic link to `AGENTS.md` already
  forwards, and nothing is written;
- otherwise, when the project has `CLAUDE.md`, `.claude/CLAUDE.md` or
  `CLAUDE.local.md`, the tool writes a managed block, the lines between
  `<!-- BEGIN managed by agents: do not edit this block. Edit its sources and
  run \`agents update\`. -->` and `<!-- END managed by agents -->`, containing
  an import of the project's root `AGENTS.md` into the first of them that
  exists, with the path
  relative to that file (`@AGENTS.md`, or `@../AGENTS.md` in
  `.claude/CLAUDE.md`). An existing import of the project's `AGENTS.md`, resolved
  relative to the containing file, counts as forwarding only as the tool's
  managed import block or as a standalone, unquoted and unformatted import line
  outside code and HTML, with optional surrounding whitespace; inline prose,
  formatted tokens, and quoted tokens do not count;
- a `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` in a directory above
  the project root is outside the project; `doctor` warns about it and nothing
  is written. User-level and managed-policy files do not count.

## Writing Targets

Every target is generated in full. The tool owns the whole file; nothing in it
is written by hand, and changes are made in the instructions files:

```markdown
<!-- Generated by agents from instruction files. Edit those files and run `agents update`. -->

# Example Agent Guide

Read `README.md` first.

## Code Review Rules

### Claims

- Flag README, DocC, or release-note statements ...
```

1. A target is the notice line, a blank line, and its sections in declared
   order separated by one blank line, ending with one newline. A section is an
   instructions file's body with front matter removed, LF line endings and no
   leading or trailing blank lines.
2. A section with `paths` gets one line after its first heading, "Applies when
   working on files matching `Sources/**/*.swift`.", listing its patterns in
   order. In project scope it is written into the `AGENTS.md`, and `GEMINI.md`
   for Gemini CLI, of the longest directory that the literal prefixes of all its
   patterns share; a pattern that starts with a wildcard keeps the section at
   the project root. User targets have no directories, so the line alone scopes
   the section. A directory receives a target only when a section is written to
   it.
3. Two sections in one target whose first headings have the same level and
   whitespace-collapsed text are an error.
4. The assembled target is parsed before it is written. Each section's first
   heading must remain a document-level heading, and its links must satisfy
   the rules under Sources; otherwise nothing is written.
5. A file is owned when the lock records it as a target or its first line is
   the notice. Writing over an existing file that is not owned requires
   `--replace`, after its difference is shown; otherwise `add` and
   `update --apply` stop and name the file.
6. A section's `hash` covers the instructions file's bytes. `blockHash` covers
   the rendered target with LF endings. Any difference between a target and its
   locked rendering is drift: `doctor` reports it, `install` restores the
   locked rendering, and `update --apply` writes the newly resolved content
   after showing the difference.
7. Writing the same lock produces identical bytes.
8. A target that no longer receives sections is deleted when its bytes equal
   the locked rendering; a drifted one is kept and reported. A file without a
   lock entry is never deleted.
9. A section installed at both user and project scope produces a `doctor`
   warning.

`agents instructions render chatgpt <prompt>` prints the prompt's locked
sections in order, rendered as in targets but without the notice, followed by
its custom-content file. The output is pasted into ChatGPT, for example with
`pbcopy`; the tool does not write to ChatGPT.

A lost lock is not restored exactly. `update` re-resolves the declaration and
compares the result with the files on disk; `update --apply` keeps an
identical file, replaces a differing generated file after showing the
difference, takes over a file agents did not generate only with `--replace`,
and writes the new lock.

## Watch

Watch is a subscription to upstream sources.

```text
$ agents watch
github.com/anthropics/skills  3 commits since a1b2c3d (now 9f8e7d6)
  + new      pdf-forms
  ~ changed  frontend-design   4 files
  - removed  legacy-docx
local:/Users/me/Developer/rules  up to date
```

A Git subscription follows the source's declared branch, or its default
branch. A well-known subscription follows the index.
Installing and updating use `add` and `update`. Scheduling periodic checks is
left to the caller.

## Source Cache

Each source has one mirror in the scope's cache. Resolution reads requirements
against the mirror. Materialization extracts an exact pin into a directory
named by source and pin, shared by every consumer of that pin and pruned when
no lock references it. Well-known artifacts are stored by digest. Mirrors of
subscribed sources are kept while the subscription exists. No command moves a
working tree that another operation depends on.

## Removed Behavior

- The review workflow of watch: review cursors, status, outcome, open-item and
  granularity fields, packet export, and installing from a watch baseline.
- The `--watch`, `--watch-only`, `--from-watch` and `--replace-requirement`
  flags; watch is a command family.
- Decoding of earlier lock and ledger formats, and the `owner/repo#ref@skill`
  shorthand.
- Built-in source aliases.
- `user` replaces `global` in all state and code.
- Relocating user state with `XDG_STATE_HOME`; user state is always under
  `~/.agents`.
- Installing from a local directory that is not a Git repository in `link` or
  `copy` mode; such a directory is used in `edit` mode only.
- Installing uncommitted working-tree content of a local Git repository in
  `link` or `copy` mode; those modes read the committed tree.

## Open Questions

- Runtime configuration (MCP servers, hooks, subagents, settings) as further
  kinds.
- Skill inventory, reference graph and directional-reference checks for skill
  collections.

## Design References

- Agents keep persistent instructions as one Markdown file per rule in a
  conventional directory: GitHub Copilot's
  [`.github/instructions/`](https://docs.github.com/en/copilot/concepts/prompting-and-context/custom-instructions),
  Cursor's [`.cursor/rules/`](https://cursor.com/docs/context/rules) and
  Claude Code's [`.claude/rules/`](https://code.claude.com/docs/en/memory).
  Instructions containers follow the same layout, with front matter as in
  Cursor's `.mdc` rules and `paths` as in Claude Code's path-scoped rules.
- [Ruler](https://github.com/intellectronica/ruler) and
  [rulesync](https://github.com/dyoshikawa/rulesync) concatenate a rules
  directory into each agent's instruction file and replace the whole file. The
  tool generates whole files the same way and also: commits the generated files
  so that readers that cannot generate them see them; records a lock with
  hashes, reports drift and writes through a recoverable transaction instead of
  leaving backups; pins shared sources and reports upstream changes; checks
  that links resolve where the section lands; validates a fixed file format;
  checks Codex's project size budget; audits several projects and exports their
  mapping; and renders ChatGPT prompts.
- GitHub Codex code review reads only committed `AGENTS.md` files, the root file
  and nested files that cover a changed file, and follows their
  `## Code Review Rules`
  ([Codex GitHub integration](https://learn.chatgpt.com/docs/third-party/github)).
  Generated targets are therefore committed.
- A nested `AGENTS.md` scopes its directory. Claude Code loads one when it
  reads a file there ([memory](https://code.claude.com/docs/en/memory)); Codex
  loads the chain from the project root to its working directory and instructs
  the model to obey every `AGENTS.md` that covers a file it changes
  ([`agents_md.rs`](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/core/src/agents_md.rs)).
  `paths` uses this chain, and its explicit line also scopes user targets,
  which have no directories.
- Codex limits only the project chain to `project_doc_max_bytes` and loads the
  user file separately, which `doctor` follows.
- Cursor rules mention files of the same project for the agent to read when
  needed and keep what must always be in context in the rule body. A section
  is written into other projects and user files, so a local link must resolve
  where it lands.
