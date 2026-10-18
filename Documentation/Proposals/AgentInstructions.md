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
- Render instructions as a prompt for ChatGPT.
- Restore exactly what the lock records; re-resolve only on `update`.
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
| Core library | `agents-tools/core` | — | Modules `AgentsCore` (sources, declaration, lock, cache), `AgentsSkills`, `AgentsInstructions` |
| agents | `agents-tools/cli` | `agents` | Skills, instructions and watch |
| skill | `skill-cli/cli` | `skill` | Skills and watch only; depends on `AgentsCore` and `AgentsSkills` |

Both executables are thin command-line layers. All behavior lives in the core
modules, so the two products cannot diverge.

## Concepts

| Term | Meaning |
| --- | --- |
| Source | A local directory, Git repository or well-known URL that provides skills, instructions or both |
| Skill | A directory with a `SKILL.md`, loaded by agents on demand |
| Instructions | One Markdown file in a source, loaded by agents in every session |
| Target | A file that agents read instructions from, or the ChatGPT prompt |
| Managed block | The part of a target that the tool writes from sources |
| Custom content | Everything in a target outside the managed block; it belongs to the target's owner |
| Declaration | What the user wants: sources, selected skills and instructions, targets, subscriptions |
| Lock | What was resolved and written: revisions, digests, content hashes |

## Sources

A source can provide both kinds. Discovery is by convention and needs no
manifest.

- Skills: directories containing `SKILL.md` under `skills/` or `.agents/skills/`.
- Instructions: `.md` files directly under `instructions/` or
  `.agents/instructions/`. The file name without `.md` is the instructions name.
- `--path <subdir>` moves the search root for both kinds and is recorded in the
  declaration.

An instructions file starts with exactly one level-1 heading and uses level 2
or deeper for everything else:

```markdown
# Canonical Artifacts

Treat conversation, review feedback, and intermediate attempts as editing
context. ...
```

The content is written verbatim apart from heading levels (see
[Writing targets](#writing-targets)). A source's instructions directory is
never itself a target location.

Source IDs are normalized: Git sources use host and path
(`github.com/owner/repo`), local sources use their absolute path
(`local:/path/to/dir`), and well-known sources use their URL host and path.
Different repositories never share an ID.

## Scopes and Files

| Scope | Declaration | Lock | Targets |
| --- | --- | --- | --- |
| Project | `.agent/agents.json` | `.agent/agents.resolved` | Project skills; `AGENTS.md` (and `GEMINI.md` for Gemini CLI) at the project root |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | User skills; each agent's user instructions file; the ChatGPT prompt |

Both files are local state and are not committed. The project's state lives
inside the project, so moving a repository moves its state. Watch state follows
the same scope rules.

### Declaration

Commands edit the declaration; editing it by hand is possible.

```json
{
  "agents": ["codex", "claude-code"],
  "sources": {
    "rules": { "path": "~/Developer/rules", "branch": "main" },
    "swift-skills": { "url": "github.com/swift-library/skills", "from": "1.0.0" }
  },
  "skills": {
    "swift-skills": { "select": "all" }
  },
  "instructions": {
    "AGENTS.md": {
      "agents": ["codex", "claude-code", "cursor", "opencode"],
      "sections": ["rules:canonical-artifacts", "rules:first-principles-work"]
    }
  },
  "watch": ["github.com/anthropics/skills"]
}
```

- `agents` is the default target list. Without it the default is `codex` and
  `claude-code`.
- `select` is `"all"` or a list of names. `"all"` follows the source's current
  membership on `update`.
- Instruction targets list sections in order as `source:name`.
- The `chatgpt` target may name a local custom-content file appended by
  `render`.

### Lock

```json
{
  "version": 1,
  "sources": {
    "github.com/swift-library/skills": {
      "kind": "git",
      "url": "https://github.com/swift-library/skills.git",
      "requirement": { "from": "1.0.0" },
      "revision": "16548e957446d2b33a6792f180d6c3f815e76722",
      "version": "1.4.0"
    },
    "local:/Users/me/Developer/rules": {
      "kind": "local",
      "requirement": { "branch": "main" },
      "revision": "a03a475f0c1d2e3b4a5968778695a4b3c2d1e0f9"
    }
  },
  "skills": {
    "swiftui-patterns": {
      "source": "github.com/swift-library/skills",
      "path": "skills/swiftui-patterns",
      "hash": "sha256:…",
      "installs": { "codex": { "mode": "link" }, "claude-code": { "mode": "link" } }
    }
  },
  "instructions": {
    "AGENTS.md": {
      "agents": ["codex", "claude-code", "cursor", "opencode"],
      "headingOffset": 1,
      "blockHash": "sha256:…",
      "sections": [
        {
          "name": "canonical-artifacts",
          "source": "local:/Users/me/Developer/rules",
          "path": "instructions/canonical-artifacts.md",
          "hash": "sha256:…"
        }
      ]
    }
  }
}
```

- Every map is keyed by identity, so duplicates cannot exist. A skill name is
  unique within a scope: adding a skill whose name is already installed from
  another source fails until the existing one is removed.
- `revision` (Git and local Git sources) and `digest` (well-known sources) are
  the locked state. `install` uses them and nothing else.
- Install paths and target paths are derived from scope, agent and file name;
  the lock does not store them.
- Output is sorted and has no timestamps. Writes take a file lock and replace
  the file atomically.

## Commands

Commands form a noun-verb tree. A kind group acts on that kind; a top-level
verb acts on every kind.

```text
agents
├── skills
│   ├── add <source> [names…]     no names: one item is added, several are listed; --all adds every skill
│   ├── list [source]
│   ├── remove <names…>
│   ├── update [--apply]
│   └── init <name>
├── instructions
│   ├── add <source> [names…]
│   ├── list [source]
│   ├── remove <names…>
│   ├── update [--apply]
│   ├── render <agent>            render chatgpt
│   └── init <name>
├── watch
│   ├── add <source>
│   ├── status                    also `agents watch`
│   ├── diff <source> [name]
│   ├── seen <source>
│   └── remove <source>
├── install
├── update [--apply]
└── doctor [--root <dir>…]
```

`--agent <agent>`, `--scope project|user` and `--path <subdir>` mean the same
in every command. `--agent` defaults to the declaration's `agents`.

| Command | Behavior |
| --- | --- |
| `add` | Update the declaration, resolve, write, update the lock |
| `update` | Show what re-resolving the declaration would change. `--apply` writes files and the lock, and shows a diff before replacing a drifted managed block |
| `install` | Restore skills and managed blocks from the lock without resolving. A missing revision or digest is an error, never a substitution |
| `list` | Installed skills, or managed instructions per target; with a source, what it provides |
| `remove` | Remove from the declaration, files and lock |
| `doctor` | Compare lock and disk: missing installs, drifted skill copies, drifted managed blocks, outdated sources, duplicate sections across scopes, a project `CLAUDE.md` that hides `AGENTS.md`, files over an agent's size limit. `--root` audits several projects read-only, given explicit directories |
| `render` | Print the assembled prompt for `chatgpt` |

`update` without `--apply`, `list`, `doctor`, `render` and `watch status` and
`watch diff` change no files, lock, watch state or checked-out revision. They
may fetch new objects into a source mirror.

The `skill` executable exposes the skills and watch subset with the same
behavior: `skill add|list|remove|update|init|install|doctor|watch …`.

## Agents and Instruction Files

| Agent | User scope | Project scope |
| --- | --- | --- |
| `codex` | `$CODEX_HOME/AGENTS.md` | `AGENTS.md` |
| `claude-code` | `$CLAUDE_CONFIG_DIR/CLAUDE.md` or `~/.claude/CLAUDE.md` | `AGENTS.md` |
| `cursor` | Not file-based | `AGENTS.md` |
| `opencode` | `$XDG_CONFIG_HOME/opencode/AGENTS.md` or `~/.config/opencode/AGENTS.md` | `AGENTS.md` |
| `gemini-cli` | `~/.gemini/GEMINI.md` | `GEMINI.md` |
| `chatgpt` | Rendered prompt, no file | Rendered prompt, no file |

Claude Code reads a project's `AGENTS.md` when no `CLAUDE.md`,
`.claude/CLAUDE.md` or `CLAUDE.local.md` exists in the working directory or
above it. When a project has a `CLAUDE.md`, the tool writes a managed block
containing `@AGENTS.md` into it instead of copying content, so Claude Code reads
the same file.

Agents that read the same file share one target. Declaring different sections
for agents that share a file is an error.

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

1. Sections appear in declared order.
2. The managed block is one contiguous region. On first write it goes where the
   first matching existing section was, otherwise below the file's level-1
   title, otherwise at the start. Custom content keeps its bytes and order.
3. The BEGIN and END comments delimit the block. Their text is fixed and carries
   no versions. Sections inside the block are identified by heading.
4. An existing section outside a block whose heading matches a declared section
   is adopted silently when its content is identical. Otherwise `update` shows
   the difference and replaces it only with `--apply`.
5. Two sources providing the same heading for one target is an error.
6. A section installed at both user and project scope produces a `doctor`
   warning.
7. Source headings are level 1. When the target has a level-1 title, every
   heading in the block is shifted one level down. A shift beyond level 6 is an
   error.
8. Sections are separated by one blank line; the file ends with one newline.
9. Removing the last section removes the block and its comments. A file the
   tool created and that has no custom content left is deleted.
10. `doctor` warns when a file exceeds the reading agent's limit, such as
    Codex's default 32 KiB.
11. Any change inside the block that does not match `blockHash` is drift.
    `doctor` reports it and `update` restores the source version after showing
    the difference.
12. Unpaired or nested markers are an error; nothing is written.

`agents instructions render chatgpt` prints the selected sections in order
followed by the target's custom-content file, without markers.

A lost lock is recoverable: the block's comments and section headings, matched
against the declared sources, rebuild the `instructions` entry.

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

`watch status` reports each subscribed source since its last seen revision,
per skill and instructions: new, changed, removed. `watch seen` advances the
seen revision. Installing and updating use `add` and `update`. Scheduling
periodic checks is left to the caller.

## Source Cache

Each source has one mirror in the scope's cache. Resolution reads requirements
against the mirror. Materialization extracts the exact locked revision into a
directory named by source and revision, shared by every consumer of that
revision and pruned when no lock references it. No command moves a working tree
that another operation depends on.

## Removed Behavior

- The review workflow of watch: review cursors, status, outcome, open-item and
  granularity fields, packet export, and installing from a watch baseline.
- The `--watch`, `--watch-only`, `--from-watch` and `--replace-requirement`
  flags; watch is a command family.
- Decoding of earlier lock and ledger formats, and the `owner/repo#ref@skill`
  shorthand.
- Built-in source aliases.
- `user` replaces `global` in all state and code.

## Open Questions

- Runtime configuration (MCP servers, hooks, subagents, settings) as further
  kinds.
- Skill inventory, reference graph and directional-reference checks for skill
  collections.
