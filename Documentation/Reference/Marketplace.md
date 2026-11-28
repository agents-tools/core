# Team marketplace

Teams distribute versioned bundles from local directories, Git snapshots or
static HTTPS indexes. CLI and App share named marketplaces through
`MarketplaceDirectory`.

Project registrations live in `.agent/marketplaces.yaml`. User registrations
live in `~/.agents/marketplaces.yaml`. Each name maps to a directory, a Git
repository with an optional ref and subpath, or an HTTPS index URL. A project entry takes precedence
over a user entry of the same name. Relative filesystem addresses are anchored
to the project root or the user's home, according to the scope that owns them.

```yaml
team:
  git: https://github.com/example/team-catalog.git
  ref: stable
  subpath: packages
local:
  directory: ./team-market
hosted-team:
  hosted: https://packages.example.org/team/marketplace.json
```

Registering a name saves its address. Browsing reads the catalog. Installation
records the selected origin in `agents.yaml`, so subsequent changes to the
registration leave existing package pins intact.

## Publish and browse

Import `AgentsCore` and `AgentsUpdates`. Call
`MarketplaceOperations.publishBundle` with the Agents archive bytes, an
existing catalog directory, and the selected `scope` and
`RuntimeEnvironment`. The publisher checks current source and organization
policy for both the archive and the destination, and revalidates the policy
before the final rename. See [Author project packaging](AuthorPackaging.md)
for how the publisher verifies public MCP inputs.

For another archive format, use `MarketplaceOperations.publish` with that
format's inspection function. It validates the archive and returns its
package ID and version. Formats without portable source evidence are
evaluated as unknown sources. IDs are lowercase ASCII names using letters,
digits, periods, underscores and hyphens. Versions use canonical SemVer.

```text
releases/
  review-kit/
    1.0.0/
      release.json
      package.bundle
```

`release.json` declares `formatVersion` (1), `coordinate` (`package` and
`version`), `archiveDigest` (SHA-256), `archiveByteCount` and optional
`summary`. Publication syncs the two files and exposes the directory with
an exclusive rename. An identical retry verifies the published archive.
A different record at the same coordinate conflicts. Browsing ignores
hidden staging directories. A process interrupted before the rename may
leave a hidden staging directory. The catalog owner can remove an abandoned
stage after confirming its publisher has stopped.

Create a `MarketplaceRegistration` with a display name and
`MarketplaceOrigin`. The origin can be a directory or a Git repository.
Git supports full HTTP(S) and SSH URLs, host/repository shorthand and
explicit filesystem paths. A Git origin can select a ref and a catalog
subdirectory within the tree. Filesystem locations are absolute or relative
to the consumer project directory. Directory writes appear immediately.
For distribution through Git, commit the release files using the team's
repository workflow.

`MarketplaceOperations.browse` returns one observation. Use `search` to
filter by package or summary and `select(package:version:)` to choose an
exact release or the highest available SemVer. `updates(for:)` compares
available versions with a committed pin from the same origin. Git
observations carry a full commit. Several packages from the same catalog
can be installed from different commits.

## Hosted HTTPS indexes

Use `MarketplaceOrigin(hostedIndex:)` or `MarketplaceOrigin(kind: .hosted,
location:)` with an absolute HTTPS index URL. The canonical URL, including its
path, identifies the catalog across registration names. Browse, search and
`verifyCatalog` are read-only. Use `acquire` to verify an individual release.

`MarketplaceOperations.exportHostedBundle(_:to:summary:)` takes the bytes of a
verified native bundle and an existing staging directory. It returns the local
`marketplace.json` URL. Publish the index and the referenced archive paths using
your static host. The index contains `formatVersion: 1` and a `releases` array.
Each release contains `coordinate`, `archiveDigest`, `archiveByteCount`, an
optional `summary` and `archivePath` relative to the index directory. An index can
contain up to 4,096 releases and occupy up to 8 MiB. Archives can occupy up to
128 MiB each, subject to the install lock's aggregate byte budget. Publish
referenced archives before replacing a live index. A staged export uses immutable
archives, an atomic index replacement and a hidden writer lock. The index and its
archives use the same layout across exports. Native hosted indexes and APM JSON
file imports have separate formats.

For private hosting, supply `HostedMarketplaceAccess` to `browse`,
`verifyCatalog`, release `acquire`, `resolve` or `previewResolution`. The
credential provider receives the canonical index URL only for an exact matching
user registration. A CLI can look up a host-selected environment variable, and
an app can provide a session-only token. The provider returns the bearer token
itself. Source and organization policies apply before every request. Index
redirects stay in the admitted HTTPS directory. Archive redirects to another
origin require explicit `trustedDownloadOrigins` and permanently discard the
credential for that request chain.

Install hosted releases with `MarketplaceRoot`, `previewResolution` and
`withPreparedResolution` or `performResolution`. Bundle dependencies may use
relative package coordinates or an independently user-registered hosted index
URL. The hosted preview captures the exact archive bytes and request provenance.
Apply revalidates policy and destination state and uses the captured marketplace
closure. The graph lock records the index digest, archive digest and redirect
provenance, plus the archive bytes in `contentObjects`. Frozen restore verifies
the locked archives and replays selected components in an independent project
without hosted access or credentials.

## Acquire, preview and apply

`MarketplaceOperations.acquire` takes a release observation or a committed
pin. It verifies the exact byte count and digest and returns a
`VerifiedMarketplacePackage` with the archive. An old Git observation
reads its selected commit after the discovery ref advances. Pass the consuming
scope and environment to browse and acquire. The effective source policy checks
the catalog origin before opening it.

Pass the archive to its format owner for inspection and match its declared
package ID and version with the release coordinate. The archive importer
builds a full-scope update request and reports the source aliases of its
imported producer groups. Bind that request with
`package.bindingImport(_:as:sourceAliases:)`. Those aliases are owned by
the dependency. They must have exported group uses in the candidate and
provide replayable locked resources. Keep borrowed archive extraction
under the importer's staging scope.

Preview and reprepare with `UpdateOperations`, using the displayed
fingerprint to apply. `CombinedUpdateReport.marketplaceChanges` includes
the previous and proposed pins. Updating a dependency keeps its catalog
and package ID and replaces its owned contributions with the selected
release. `MarketplaceOperations.removalRequest(for:)` previews and
removes the dependency's declarations and deployments in the same
transaction. Other dependencies retain their pins.

The project declaration records stable intent alongside the generated
producer sources and group uses.

```yaml
version: 1
packages:
  review:
    package: review-kit
    version: "1.0.0"
    catalog:
      kind: git
      location: "https://github.com/example/team-catalog.git"
      ref: main
```

Commit both `.agent/agents.yaml` and `.agent/agents.resolved`. The ledger
pins the catalog origin, selected archive digest, Git commit when applicable,
and imported component and resource closure. Portable bundles retain original
producer and resource origins. A re-export also carries the catalog origin of a
marketplace-installed component. Applicable policies check those origins at
import, update, restore and audit. The bundle store is a materialization of
these inputs. A local producer with no portable coordinates requires an
explicit `missing` allowance in each configured layer. Restore checks the
declared selection and recorded contributions before rendering. It replays the
committed closure from ledger bytes without consulting the catalog or
authoring tree. Use `MarketplaceOperations.installed` to read admitted
pins. `ScopeInspection` exposes pins and any intent mismatch for read-only
audit. Its CycloneDX and SPDX inventories include admitted release versions,
archive digests and references to the imported components.

The workflow reference is APM v0.11.0's catalog registration, discovery
and locked package selection. Core uses the release-directory format and
Swift APIs described here.
[Release v0.11.0](https://github.com/microsoft/apm/releases/tag/v0.11.0) ·
[Marketplace reference](https://microsoft.github.io/apm/reference/cli/marketplace/) ·
[Consumer behavior](https://microsoft.github.io/apm/consumer/installing-from-marketplaces/)
