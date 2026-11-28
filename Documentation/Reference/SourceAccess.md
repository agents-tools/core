# Package source access

Source routing uses the operator's [user settings](UserSourceAccess.md).
A Swift host may supply a typed `RuntimeEnvironment.sourceAccess` override.
Project declarations select a source and a ref.

## Credential status

Pass the workspace's declaration, install selector, runtime environment, and
current `EffectiveSourcePolicy` to `SourceCredentialOperations.inspect`.
Consumers can read the local user and project policy through
`SourcePolicyOperations.inspect`. Source aliases and selectors resolve the
same way as installation. For example, `team@tag:release/v1` means the
literal tag `release/v1`.

A report gives the provider, effective host and port, transport, credential
category, availability, and optional validation status. Inspection makes
no requests and never invokes a credential resolver. Host-only inspection
considers host-wide bindings. SSH credentials are managed by SSH.
An explicitly delegated Git host reports `delegated/unverified`.

Use `SourceAuthority` to identify an exact host and port, with 443 as the
default. Core classifies GitHub and GitLab on their standard authorities.
Register enterprise authorities in `SourceAccessConfiguration.providers`.
A `SourceCredentialBinding` authorizes either a direct HTTPS repository or
a mirror. A path-scoped direct binding names the repository. A path-scoped
mirror binding names the configured base path followed by the logical
repository namespace, such as `/proxy/org/repo`. A matching repository
binding takes precedence over a host-wide binding. Duplicate matching
bindings fail the operation.

`SourceCredentialOperations.validate` sends the selected credential only
to its configured provider identity endpoint after policy admits that
endpoint. The supported identity requests are GitHub's
`https://api.github.com/user`, GitHub Enterprise's `/api/v3/user`, and
GitLab's `/api/v4/user`. HTTP 200 is accepted and HTTP 401 is refused.
A mirror route, an unauthorized validation endpoint, or an inconclusive
response gives `indeterminate`. Reports contain status and omit provider
response bodies and Git subprocess diagnostics.

`SourceCredentialOperations.export` explicitly writes one selected,
exportable value to a writable pipe. A shell can capture the pipe through
command substitution. Opaque bindings and non-pipe output are refused.
The caller controls what the pipe recipient does with the value.

## Egress and archive selection

`SourceAccessConfiguration.Egress.proxyOnly` requires an admitted archive
profile for a network repository. The logical repository and effective
HTTPS destination each need admission under the current source policies.
For MCP Registry requests, set `MCP_REGISTRY_URL` to the team's HTTPS registry.
In proxy-only mode, registry searches and locked installations require the
configured host, port and base path. Well-known indexes and hosted marketplaces
require direct HTTP egress. Organization policy continues to use its separately
configured discovery location, policy file, or HTTPS endpoint. Offline
restore uses eligible previously verified governance evidence.

A mirror profile defines one source authority, HTTPS base path, and archive
flavor. The client makes one GET and refuses redirects.

| Profile | Request relative to the configured base |
| --- | --- |
| GitHub archive reverse proxy | `owner/repo/archive/refs/tags/release/v1.zip`, the corresponding `refs/heads/` path, or `owner/repo/archive/<full-commit>.zip` |
| GitLab repository API | `api/v4/projects/group%2Fsub%2Frepo/repository/archive.zip?sha=<encoded-ref>` |

GitLab accepts full commit IDs. A profile whose endpoint supports qualified
refs can opt in to a `refs/tags/` or `refs/heads/` query value.
The client supports typed tags, branches, and full commits. A selection
that needs discovery fails on archive-only routes. A locked version
selection can replay its recorded ref when the version still meets the
current requirements. History operations, including Git watch, require
Git objects. Artifactory VCS profiles are unsupported.

The request shapes describe the Swift client's contract. Local fixture
results do not establish interoperability with any live enterprise host
or other package manager.

## Restore and private publication

A resolved source's optional `archive` object records `effectiveURL`,
`flavor`, a `ref` with `kind` and `name`, `treeDigest`,
`observedArchiveDigest`, and, for strict profiles, `requiredArchiveDigest`.
The source's revision is the normalized tree digest. A resource with
`kind: archive` names verified tree paths and digests. Frozen replay
admits the recorded route before using a retained ZIP or reacquiring it.

Recompression can satisfy a tree-authoritative lock. A strict pin also
requires its recorded ZIP digest. An update preview can report changed ZIP
bytes with the same tree through `archiveRepresentationChanges`.

Verified archive recovery is kept under the runtime home in an owner-only
store. Scope reservations protect committed and in-flight generations.
Archive bytes become durable before a lock or deployment names them.
A copied lock supplies request coordinates and digests. Offline restore
requires eligible local recovery bytes. Public packages and shared
acquisition caches omit private archive payloads.

Private copies and rendered files use owner-only permissions. Directory
and link targets require controlled filesystem ancestry. Core checks
ownership, permissions, and ACLs during preview and publication. Native
configuration that would place archive content in the lock is refused.
