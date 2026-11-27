# User source access settings

Swift hosts, including the CLI and App, use the operator's
`~/.agents/source-access.yaml` for source routing. The file applies to user
and project operations. Project declarations and locks select sources and
revisions. Trust settings come from the operator profile or an explicit
configuration supplied by a trusted Swift host.

The file is optional. With no file, the runtime uses ordinary direct egress.
`version: 1` and `egress` are required in a configured file. The egress
values are `directAllowed` and `proxyOnly`. The latter admits network
repositories through configured archive mirrors and denies direct indexes,
registries and hosted marketplaces. The logical source and destination
also remain subject to the applicable source policies.

## GitHub archive mirror

```yaml
version: 1
egress: proxyOnly
mirrors:
  - source:
      host: github.com
    base: https://archives.example.test/github
    flavor: github
credentials:
  - route: mirror
    host: archives.example.test
    path: /github/team/package
    environmentVariable: TEAM_ARCHIVE_TOKEN
```

For `team/package@tag:release/v1`, this selects
`https://archives.example.test/github/team/package/archive/refs/tags/release/v1.zip`.
The exact credential scope is the mirror base path plus the logical
repository path. Omit `path` only to authorize that binding for the whole
authority on the selected route.

## Enterprise direct HTTPS

```yaml
version: 1
egress: directAllowed
providers:
  - host: code.example.test
    port: 8443
    provider: gitlab
credentials:
  - route: direct
    host: code.example.test
    port: 8443
    path: /division/tools/package
    environmentVariable: PACKAGE_GIT_TOKEN
    validationEndpoint: https://code.example.test:8443/api/v4/user
```

The host and port identify the exact authority. Omitted ports mean 443.
`provider` is `github` or `gitlab`. Their public services are recognized
on standard ports. A direct binding matches the HTTPS repository path with
the optional transport suffix `.git` removed. A repository binding takes
precedence over an authority-wide binding. The selected program must receive
the named variable in its process environment. An absent or invalid value
reports an unavailable credential. The settings store only the variable name.

The optional `validationEndpoint` enables explicit provider validation for
a direct binding. The URL must be the admitted provider identity endpoint.
The optional `exportable: true` allows the explicit pipe-backed export
operation. Both are off by default.

A mirror's `source` contains `host` and optional `port`. Its `base` is
HTTPS with a fixed path. Supported flavors are `github` and `gitlab`.
For a GitLab API mirror, set `supportsQualifiedGitLabRefs: true` only when
its endpoint supports qualified tag and branch refs. A mirror can set
`requiresExactArchiveBytes: true` to require matching ZIP bytes on replay.
Both flags default to false.

## Diagnostics and editing

Use an owner-controlled home and `.agents` directory. The profile must be
a regular file owned by the current user, with one link and without external
write or control access. The editor saves new content with mode `0600`.
Unsafe locations and malformed profiles fail closed. A malformed profile
in a safe location can be opened and repaired in the editor.

```swift
import AgentsCore
import Foundation

var runtime = RuntimeEnvironment()
let editor = try SourceAccessSettingsEditor(environment: runtime)
let proposal = try editor.preview(Data("version: 1\negress: proxyOnly\n".utf8))
try editor.save(proposal)
runtime.reloadSourceAccessSettings()
```

Pass the same runtime to subsequent operations. To reset, open a fresh
editor and save `editor.preview(nil)`. A saved preview becomes stale when
its captured profile changes, even when another editor writes the change.
A runtime that already captured a profile fails its source access checks if
the file changes. Rebuild the runtime or call `reloadSourceAccessSettings()`
and start a fresh operation after the operator chooses to reload.
`RuntimeEnvironment(sourceAccess: configuration)` uses an explicitly
supplied typed configuration for embedding and isolated tests.
