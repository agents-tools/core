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
- Make every managed instruction section traceable to a source and a locked
  version, keep owner-written content editable, and make drift detectable.
- Render instructions as named prompts for ChatGPT project instructions and
  scheduled tasks.
- Restore exactly what the lock records; re-resolve only on `add` and `update`.
- Report what changed upstream in subscribed sources.

## Non-goals

- Agent runtime configuration such as MCP servers, hooks, subagents and
  settings. These are evaluated separately after instructions ship.
- Collaboration. The tool is the only writer of managed sections; a change to a
  managed section from anywhere else is drift.
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
| Instructions | One Markdown file in a source, loaded by agents in every session |
| Section | The content of one instructions file as written into a target |
| Target | A file that agents read instructions from, or a named ChatGPT prompt |
| Managed block | The part of a target file that the tool writes from sources |
| Custom content | Everything in a target outside the managed block; it belongs to the target's owner |
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

Instructions are `.md` files directly under `instructions/` or
`.agents/instructions/`. The file name without `.md` is the instructions name.
An instructions file starts with exactly one level-1 ATX heading and uses
level 2 or deeper for everything else:

```markdown
# Canonical Artifacts

Treat conversation, review feedback, and intermediate attempts as editing
context. ...
```

A source's instructions directory is never itself a target location.

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
| Project | `.agent/agents.json` | `.agent/agents.resolved` | `.agent/agents.watch` | Project skills; `AGENTS.md`, `GEMINI.md` and Claude forwarding at the project root; ChatGPT prompts |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | User skills; each agent's user instructions file; ChatGPT prompts |

All three files are local state and are not committed. The project's state
lives inside the project, so moving a repository moves its state. User state is
always under `~/.agents`.

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
    "sections": ["rules:canonical-artifacts", "rules:first-principles-work"],
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
        "name": "canonical-artifacts",
        "source": "local:/Users/me/Developer/rules",
        "revision": "a03a475f0c1d2e3b4a5968778695a4b3c2d1e0f9",
        "path": "instructions/canonical-artifacts.md",
        "hash": "sha256:…"
      },
      {
        "name": "first-principles-work",
        "source": "local:/Users/me/Developer/rules",
        "revision": "a03a475f0c1d2e3b4a5968778695a4b3c2d1e0f9",
        "path": "instructions/first-principles-work.md",
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
        "headingOffset": 1,
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
  only when their files resolve to the same path. `created` records that the
  tool created the file.
- `install` uses the lock and nothing else: each install's agent and mode,
  each pin and each target's heading offset. A pin that cannot be fetched, or
  content whose digest does not match, is an error, never a substitution.
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
│   ├── add <source> [names…]     [--replace]
│   ├── list [source]
│   ├── remove <names…>
│   ├── update [--apply]
│   ├── render chatgpt <prompt>
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
`skills list <source>` take `--full-depth`.

| Command | Behavior |
| --- | --- |
| `add` | Update the declaration, resolve, write, update the lock. Any stop leaves the declaration, lock and files unchanged |
| `update` | Re-resolve the declaration and show what would change against the files on disk. `--apply` writes the resolved content and the new lock together, showing the difference before it replaces drifted or conflicting content. Without names it reconciles `"all"` selections with the source's membership; with names it touches only those skills, and a named skill missing upstream is an error. `--apply` lists the ChatGPT prompts whose content changed, since ChatGPT has to be updated by pasting the new render |
| `install` | Restore skills and managed blocks exactly as the lock records them, without resolving. It takes no `--agent` or `--mode` |
| `list` | Installed skills, or managed sections and targets; with a source, what it provides |
| `remove` | Remove from the declaration, files and lock |
| `init` | Create a skill directory or an instructions file in the current directory |
| `render` | Print a ChatGPT prompt: its locked sections followed by its custom-content file, without markers. A prompt without locked sections is an error |
| `watch add` | Subscribe and record the source's current revision as seen |
| `watch status` | Report each subscribed source since its seen revision, per skill and instructions: new, changed, removed |
| `watch diff` | Show the changes behind `status`, for one source or one item |
| `watch seen` | Advance the seen revision to the source's current revision, or to `--revision` |
| `watch remove` | Drop the subscription and its state; installed items stay |
| `doctor` | Compare lock and disk and report problems (see below). `--root` audits several projects read-only, given explicit directories |

`update` without `--apply`, `list`, `doctor`, `render`, `watch status` and
`watch diff` change no declaration, lock, watch state, target or checked-out
revision. They may fetch new objects into a source mirror.

`doctor` reports missing installs, drifted skill copies, drifted managed
blocks, sources with newer matching versions, local sources with uncommitted
changes in selected paths, sections installed at both scopes, Claude Code
forwarding problems, a Codex `AGENTS.override.md` that hides a managed
`AGENTS.md`, and Codex instructions that exceed `project_doc_max_bytes` (Codex
configuration, default 32 KiB) for the combined files Codex loads.

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
  `CLAUDE.local.md`, the tool writes a managed block containing an import of
  the project's `AGENTS.md` into the first of them that exists, with the path
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

A file target consists of custom content and at most one managed block:

```markdown
# Example Agent Guide

<!-- BEGIN managed by agents: do not edit this block. Edit its sources and run `agents update`. -->
## Canonical Artifacts

...

## First-Principles Work

...
<!-- END managed by agents -->

## Task Route

...
```

Markdown structure follows CommonMark: headings and marker lines are
recognized only outside fenced and indented code blocks. Source files must use
ATX headings and must not end inside a code block; targets may also contain
Setext headings. The assembled file is parsed before it is written and must
contain exactly the expected block; otherwise nothing is written.

1. A section is a heading and everything up to the next heading of the same or
   higher level, the next marker line or the end of the file. Sections in the block
   appear in declared order and are identified by heading.
2. The block is one contiguous region from the BEGIN line to the END line.
   Their text is fixed and carries no versions. More than one block, or
   unpaired or nested markers, is an error and nothing is written.
3. The target's title is the first level-1 heading in custom content before the
   block that does not match the level-1 heading of a selected section. With a
   title, every heading in the block is shifted one level down;
   a shift beyond level 6 is an error. The offset is computed on the first
   write and on `update` when the title appears or disappears; `install` uses
   the locked offset.
4. An existing section in custom content matches a declared section when its
   level and heading text equal those of the shifted source section, after
   trimming and collapsing whitespace. Several matches for one declared
   section, or two selected sections with the same heading from any sources,
   are an error.
5. On the first write the block goes where the earliest matching section is,
   otherwise before the first heading after the title, otherwise at the end
   of a file with a title, otherwise at the start.
6. A matching section with identical content is adopted: it moves into the
   block. A matching section with different content stops `add` with the
   difference unless `--replace` is given and is replaced by `update --apply`
   after the difference is shown. `update` and `doctor` only report adoptions
   and conflicts; `install` stops on a conflict.
7. The tool owns the marker lines, the block content and one blank line
   between the block and adjacent custom content. Custom content keeps its
   bytes. Section content is the source file with LF line endings, trailing
   blank lines removed and headings shifted; sections are separated by one
   blank line. When the block ends the file, the file ends with one newline.
   Removing the block leaves the custom content ending with one newline.
8. A section's `hash` covers the source file bytes. `blockHash` covers the
   rendered block from the BEGIN line through the END line with LF endings.
   Any difference from `blockHash` is drift: `doctor` reports it, `install`
   restores the locked content, and `update --apply` writes the newly resolved
   content after showing the difference.
9. Writing the same lock into the same custom content produces identical
   bytes.
10. Removing the last section removes the block, its markers and its
    separating blank line. A file whose lock entry records `created` and that
    has no custom content left is deleted; any other file is kept.
11. A section installed at both user and project scope produces a `doctor`
    warning.

`agents instructions render chatgpt <prompt>` prints the prompt's locked
sections in order with their source headings, followed by its custom-content
file. The output is pasted into ChatGPT, for example with `pbcopy`; the tool
does not write to ChatGPT.

A lost lock is not restored exactly, because headings do not identify a pin.
`update` re-resolves the declaration and reports how the result compares with
the existing block; `update --apply` adopts identical content, replaces
differing content after showing the difference, and writes the new lock. A file
without a lock entry is never deleted.

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
