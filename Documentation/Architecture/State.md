# State and Source Cache

## Scope Locations

| Scope | Declaration | Lock | Watch path | Cache |
| --- | --- | --- | --- | --- |
| Project | `.agent/agents.json` | `.agent/agents.resolved` | `.agent/agents.watch` | `.agent/cache/` |
| User | `~/.agents/agents.json` | `~/.agents/agents.resolved` | `~/.agents/agents.watch` | `~/.agents/cache/` |

User paths are relative to `RuntimeEnvironment.homeDirectory`. State files belong
to their scope and are local state. Watch subscriptions have a declaration field
and reserved file path; subscription operations are implemented separately.

## Declaration

`agents.json` records user intent. `agents` defaults to `codex` and
`claude-code`. Source aliases name exactly one `git`, `local` or `well-known`
location, an optional requirement, and an optional search `path`.

```json
{
  "agents": ["codex", "claude-code"],
  "sources": {
    "team": { "git": "github.com/example/skills", "from": "1.0.0" },
    "drafts": { "local": "~/Developer/skills" }
  },
  "skills": {
    "team": { "select": "all", "exclude": ["retired"] },
    "drafts": {
      "select": ["release-notes"],
      "mode": "edit",
      "overrides": { "release-notes": { "agents": ["codex"] } }
    }
  }
}
```

A skill selection is `"all"` or a name array, with optional exclusions,
recipients, mode and per-skill overrides. `all` follows discovery membership on
an unnamed update. Removing a member adds an exclusion. Explicitly named
updates resolve only those members and fail if a requested member is missing.
Skill filesystem identities are unique within a scope across sources.

Requirements encode as `branch`, `revision`, `exact`, `from`, `upToNextMinor`,
or `from` plus `to`. Ranges include their lower bound and exclude their upper
bound. A prerelease requires a prerelease bound with the same major, minor and
patch. With no requirement, resolution chooses the latest semantic-version tag,
then the source's default branch when no version tag exists.

Source IDs are Git `host[:port]/path` with a lowercase host and without user,
scheme or `.git`; `local:` plus an absolute path; or a well-known URL retaining
its scheme. Declaring two aliases for one normalized ID is an error.

`instructions` holds recipients, ordered `source:name` section references, and
named `chatgpt` prompts with ordered sections and optional relative `append`
paths. `watch` is an alias array. Skill operations preserve both fields.

## Lock

`agents.resolved` version 1 has identity-keyed `sources` and `skills`, and an
`instructions` object containing `sections`, `chatgpt` and `targets`.

A locked source records its kind, Git URL where applicable, requirement and
search path. A skill records its source ID, its own revision and optional
version, relative directory path, content hash and `installs` mapping agent IDs
to `link`, `copy` or `edit`. Every non-edit item carries an immutable pin.
Updating one skill leaves other item pins unchanged.

Well-known items record an artifact's `type`, `url` and SHA-256 `digest`.
`files` artifacts additionally record every file's URL, path and digest. Their
aggregate digest covers the sorted, deterministically encoded file records.
Restoration reads these recorded URLs or verified digest cache entries and
never reads an index. Missing pins or mismatched content stop restoration.

Instruction section records carry name, source, revision or artifact, path and
hash. Prompts hold ordered locked sections and optional append paths. Physical
targets record agents, heading offset or import, block hash, and whether the
file was created by the tool. Skill writes retain these records unchanged.

Maps are key sorted. Unordered selections and agent lists are sorted; section
arrays and each prompt's section order are preserved. Files have a trailing
newline and no timestamps. Invalid state, duplicate JSON keys at any depth and
fields that would be discarded by decoding cause an error. Tree hashes use
length-prefixed records for paths, entry types and bytes, including empty
directories and symbolic link destinations.

Readers and writers serialize through `.agents.lock`. A durable
`transaction.json` in the scope state directory records every target, state
file and pruning replacement, its backup and staging paths, and created
parent directories before mutation. Backups and staged data are synced before
applying changes. macOS `renameatx_np(RENAME_SWAP)` atomically exchanges existing
directories, files and links with their replacements; installations are never
moved away before a replacement is present.

Each state operation first checks for an abandoned journal under the scope
lock. Before the journal's durable commit point, recovery restores all backups;
after it, recovery finishes cleanup. Backups remain available until rollback
or commit is durable, so recovery itself can be interrupted and repeated.
Recovery throws `CoreError.transactionRecovered` after completing, reporting
the scope and asking the caller to retry against the recovered generation.
This also applies to inventory, previews and doctor. Corrupt journals stop the
operation without guessing a recovery plan.

## Materialization and Installation

Each scope's cache contains:

```text
cache/
  mirrors/<source-key>.git/
  materialized/<source-key>/<full-revision>/
  artifacts/<sha256-hex>
  artifact-content/<sha256-hex>/
  locks/
```

A source key combines a readable prefix and the SHA-256 of its normalized ID.
A source has one bare mirror; requirement resolution reads its refs and tags.
Exact trees are extracted with Git archive and contain no repository metadata.
Consumers of the same source and revision share a materialized directory.

`link` points an agent's skill entry at verified cached content. `copy` installs
that content as a directory and rejects links escaping the installed subtree.
Links to content within the same project or user state root are relative, so
moving that root preserves them; external live edit links are absolute.
`edit` points directly at a live local skill
without pin or hash and requires a source without a requirement. Local
non-Git directories support edit mode. Git-backed link and copy operations read
committed trees, including when the source has uncommitted changes.

An update preview, source inspection or diagnostic can fetch into a mirror.
Inspection snapshots are disposable and do not move an installed tree or write
state or targets. Applying prepares all selected content, computes differences,
stages replacements, and commits target changes and state under the scope lock.
Pruning participates in that transaction. Pins referenced by skills, instruction
sections or prompt sections remain cached, as do trees containing live edit
sources. Pruning opens directory ancestry without following symlinks and uses
directory-relative enumeration, rename and deletion. It rejects symlinked cache
containers and never recursively follows a link during cleanup.
Mirrors remain available for source
history and future resolution.

Doctor reports missing installs, changed content and broken links, newer
matching Git resolutions, and uncommitted changes in selected local source
paths. `install` restores all recorded recipients and modes without changing
lock bytes. The consuming CLI controls presentation and user interaction.
