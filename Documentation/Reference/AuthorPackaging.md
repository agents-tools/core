# Author project packaging

Use `AuthorPackageOperations` in `AgentsUpdates` to build an Agents bundle
from an author project, even when no client has installed its components. A
project's author specification is separate from its installation declaration.

## Inputs and review

`scaffold(_:at:environment:)` creates a new directory below an existing
parent. It writes `author-package.json`, an empty `.agent/agents.yaml`, and
one complete starter skill. It does not choose a license, initialize Git, or
install anything. It refuses an existing directory unless its tree exactly
matches the scaffold.

In `author-package.json`, `package` is a `BundlePackage`; the other fields
are explicit selections:

| Field | Selects |
| --- | --- |
| `instructions` | Named instruction sections under `.agent/instructions/`, without the `.md` suffix. A referenced local attachment must be a regular file within that instruction container. |
| `skills` | Project-relative author-owned directories containing `SKILL.md`. Each entire directory is included. |
| `mcpServers` | Unambiguous, unconditional first-party MCP names in the root `.agent/agents.yaml` components list. |
| `lockedMembers` | Unique `{ "kind": "...", "name": "..." }` members of the project's verified `agents.resolved`. Kinds are `instructions`, `skills`, and `mcpServer`. |

Use first-party paths only for content you own. Use locked members for vendored
content rather than choosing installed client files as author inputs. Embedded
objects and exact offline Git resources are verified against the lock.
Live edit resources, missing locks or objects, ambiguous members, and digest
mismatches fail. Packaging does not solve a different release, access a
dependency catalog, or read client deployments. `package.dependencies` can
separately declare portable marketplace requirements for later resolution by an
Agents consumer; that does not implicitly vendor any members.

`preview(environment:)` reads the specification. `preview(_:environment:)`
accepts the same specification as a Swift value. Both return an
`AuthorPackageArtifact` with the exact canonical archive, SHA-256 digest,
component and source evidence, included paths, and separate content, policy,
and credential-omission findings. The preview leaves source state and output
destinations untouched. Paths, link spellings, executable flags, objects, and
metadata enter the archive identity. Local checkout and catalog paths do not.

Only selected inputs and their included support are scanned. Credential
filenames such as `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa` and
`id_ed25519` are refused, not silently skipped. Tree links must be relative
and resolve within the included tree. Marked-up local references in instruction
sections and skill manifests must resolve within the packaged resource root.
Hard-linked author files are refused. Other hidden characters are reported with
locations; audit findings do not change the underlying bytes. These checks do
not certify arbitrary file contents as free of secrets.

MCP environment and secret references stay symbolic. Both author capture and
`BundleOperations.export` preserve a literal environment value or header only
when it matches a public fixed value, default, or choice from the selected
registry server version and transport. Selection records the invocation and
public input fingerprints so these values can be packaged offline. Callers
can supply a typed `MCPRegistryServer` in `registrySchemas:` to validate the
values against that exact schema. An unverified literal requires a new
registry selection, a matching schema, or a symbolic reference.

New author captures report omitted credential-like native fields and command
arguments. Credential-bearing endpoints and unbound absolute resource
coordinates are refused. A first-party MCP can declare a relative executable
and working directory within its selected source. Capturing a declaration
never starts a process.

## Save and publish

- `write(_:to:environment:)` saves a captured archive file.
- `publish(_:to:environment:)` publishes the captured archive to an existing
  local Agents marketplace, using its authored description as the summary.
- `readArchive(at:expectedDigest:environment:registrySchemas:)` reads a
  selected archive file once and admits those exact bytes for review and later
  output. The archive carries the fingerprints for selected public inputs.
- `rebuild(expectedDigest:environment:)` and
  `rebuild(_:expectedDigest:environment:)` require the reviewed digest when
  reconstructing from source in another process.

In an interactive flow, show the preview and retain the capture until the user
chooses to write or publish. Do not rebuild from source under that decision.
Supply the same trusted environment to every operation. The author publisher
and `MarketplaceOperations.publishBundle` read fresh source and organization
policies for the archive and destination before creating release files. Both
revalidate file-backed policy before the final rename. When schema validation is requested, the capture retains those schemas
for its later write or publication.

Named marketplace releases retain their package name, version and archive
digest. Hosted releases also retain the exact HTTPS index and recorded
download routes, so the recipient can apply policy to the original package
and paths. Checkout and installation paths are omitted. Author captures use
portable local catalog evidence, and installed exports can retain an observed
local catalog directory for recipient policy.

Output stages beside the destination. The operating system must support atomic
no-replace rename on that volume. The same archive or complete tree is
idempotent; conflicting paths are never overwritten. Immutability here describes
the publication guarantee, not OS write protection against another program.
An interrupted process can leave a private `.stage-…` sibling, not a partially
published artifact. Existing bundle APIs and archives without author metadata
remain supported; clients reading archives with the new optional author or
dependency-provenance fields need a reader that understands those fields.

## Native plugin export

`NativePluginOperations.preview(_:for:marketplace:environment:)` takes a
checked author package capture and returns a `NativePluginArtifact`.
`write(_:to:expectedDigest:environment:)` writes only that complete tree;
use the native digest if rebuilding the native tree for a later write.
The native preview lists all files, links, modes, and findings, and
`contents(at:)` provides a file's exact bytes for inspection.

Native outputs require a lowercase kebab-case package name, a canonical
SemVer version, a description and an author. All support complete skills in
`skills/` and compatible MCP declarations in `.mcp.json`:

| Client | Plugin manifest | Optional one-plugin marketplace |
| --- | --- | --- |
| Claude Code | `.claude-plugin/plugin.json` | `.claude-plugin/marketplace.json` |
| Codex compatibility layout | `.codex-plugin/plugin.json` | `.agents/plugins/marketplace.json` |

The optional marketplace wraps the plugin at `plugins/<package>/`, supplies its
listing metadata and points to that directory with a local relative reference.
For Codex, the caller supplies a listing category. Export cannot install or
register this marketplace.

Claude Code supports symbolic environment and sensitive `userConfig`
references, SSE, and bundled executables resolved via
`${CLAUDE_PLUGIN_ROOT}`. Codex supports streamable HTTP and stdio with a
named executable, HTTP header environment references, and same-name stdio
environment forwarding. The
current projections refuse authored MCP working directories, target-specific
native overrides, Agents catalog requirements, and instruction sections,
rather than emitting files the client will not load. Prepare a separate
explicit selection for the native target if needed. The client owns installation
and removal; Agents still owns its independent bundle deployment and lock.

Layout sources: [APM pack behavior](https://microsoft.github.io/apm/reference/cli/pack/),
[Claude Code plugin reference](https://code.claude.com/docs/en/plugins/manifest-reference),
and [Codex plugin packaging](https://developers.openai.com/plugins/build/plugins).
