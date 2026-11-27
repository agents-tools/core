# Organization install policy

Applications select policies through `RuntimeEnvironment.userOrganizationPolicy`
and `projectOrganizationPolicy`. The user selection also governs project
installs. A project selection adds a separate authority for project installs.
The consumer manifest and imported packages have no policy selector. The
existing user, project and explicitly configured organization source
allowlists remain hard gates.

The host can set `AGENTS_USER_ORGANIZATION_POLICY` and
`AGENTS_PROJECT_ORGANIZATION_POLICY` to an absolute file path, an HTTPS
document URL, or `github:OWNER/REPO` for organization discovery. Each
configured selection is required. An invalid location appears as a blocking
finding for that scope. An explicit Swift selection takes precedence for
its scope.

```swift
import AgentsCore
import AgentsUpdates
import Foundation

var environment = RuntimeEnvironment()
environment.userOrganizationPolicy = OrganizationPolicySelection(
  .local(URL(fileURLWithPath: "/etc/agents/agents-policy.yaml")))
let status = try OrganizationPolicyOperations.status(environment: environment)
let audit = try OrganizationPolicyOperations.audit(
  environment: environment, requireOrganizationPolicy: true)
```

Use `OrganizationPolicyReport.isBlocked` for status and
`OrganizationPolicyAudit.isBlocked` for CI. The audit also exposes hard
source violations and detects a marketplace declaration that differs from its
locked graph. It uses recorded lock data and passive workspace checks. Policy retrieval
is its only network operation. The CI presence option requires a loaded policy.

Successful install previews expose `CombinedUpdateReport.organizationPolicy`.
A policy refusal throws `OrganizationPolicyFailure` with the same report
shape. Each finding has its rule, subject, authority, effective outcome and
document digest. Dependency findings can include the path and the matched
rule. Preview clients should verify the displayed fingerprint at apply.
Policy evidence participates in the fingerprint and local bytes are
revalidated before publication.

## Policy documents

This example is a native Core policy document.

```yaml
name: team-baseline
version: "2026.1"
extends: common-policy.yaml
enforcement: block
dependencies:
  allow: ["github.com/example/**"]
  deny: ["**/retired"]
  require:
    - identity: "github.com/example/catalog#review-tools"
      from: "2.1.0"
  require_resolution: block
  require_pinned_constraint: true
  max_depth: 6
mcp:
  require: ["inline/team-docs"]
  transport: {allow: [streamable-http]}
executables:
  deny: ["github.com/example/catalog#review-tools"]
unmanaged_files:
  action: warn
  directories: [.agents/skills]
security:
  integrity: {require_hashes: true}
  audit: {fail_on_drift: true}
```

- `off` reports loaded policy. `warn` reports violations with advisory
  severity. `block` refuses violations before publication. Required policy
  availability is independent of the rule mode.
- Inheritance allows up to five documents. Policy findings retain the
  document that supplied the rule. Each allow list must match, explicit
  `[]` admits no identities, and `null` adds no restriction. Denies and
  requirements add across documents. Depth limits tighten. A child cannot
  lower the enforcement mode or weaken required version conflict handling.
- Package rules accept Git repository coordinates such as
  `github.com/example/repo` with an optional discovery subpath. Marketplace
  coordinates append `#package` to the catalog coordinate. Local catalog
  coordinates use `local:/absolute/path#package`. Standalone bundles have a
  deny identity of `_local/package`. Bundle acquisitions also check recorded
  producer origins. `sources` applies to source origins and `marketplace.allow`
  applies to catalog origins. Globs use `*` for a segment and `**` for zero or
  more segments. Hostless Git patterns match any host. Hostless exact Git
  requirements identify `github.com`. GitHub owner and repository names
  compare case-insensitively. Subpaths, package names and MCP names retain
  case.
- Package requirements verify both authored intent and selected deployment.
  `project-wins` honors a project constraint when present. `policy-wins`
  selects using the policy bounds for that package and records the override.
  `block` requires a version satisfying both. Override records require matching
  active policy for frozen replay. Audit never injects requirements.
- A marketplace root has depth one. A shared node uses the longest path
  among the selected roots. External component-group links count producer
  transitions. Pinned-constraint checks use the authored Git selector,
  including recognized release tags and full commit IDs.
- MCP rules use `inline/name`, qualified producer coordinates with
  `#server`, or the selected registry and server coordinate. The
  `mcp.require` extension uses exact identities. `mcp.self_defined` accepts
  `allow`, `warn`, or `deny`. Setting `trust_transitive: false` requires
  an explicit allow match. Transport restrictions check symbolic effective
  transport. Executable ceilings cover deployed hooks, LSP, self-defined MCP,
  executable resource entries and detected executable plugin contents.
  Opaque executable evidence is reported when a matching ceiling cannot be
  verified. `executables.require` verifies deployment evidence. Recommendations
  are reported as advisory metadata and grant no trust.
- `manifest.required_fields` checks admitted top-level keys.
  `require_explicit_includes` requires named skill selection where Core has
  an authored skill selector. `content_types.allow` uses Core component kind
  names. `scripts: deny` checks the presence of a top-level scripts field.
  Drift uses the lock and passive target evidence. A native layout that needs
  replay reports unverified drift when passive evidence is insufficient.
  Unmanaged checks cover registered skill and Antigravity rule directories
  by default. A policy can supply relative workspace directories and exclude
  path globs from the resulting findings.

## Availability and cache

A selection uses `.local(URL)`, `.https(URL)` or
`.organization(gitRemote: String)`. Supply the already identified GitHub
remote for organization discovery. Core tries `.github-private`, `.github`,
`.apm`, then `_apm` for `agents-policy.yaml`. Discovery uses public GitHub
raw HTTPS endpoints. A caller can select another provider through its
explicit HTTPS policy URL.

A local document can select a relative local parent or an explicit HTTPS
parent. Remote parents use the
same origin as the first HTTPS document, including the effective port. GitHub raw
documents also accept `owner/repository` parent shorthand. An organization
discovery selection can refer to its discovery chain using `extends: org`.
Remote URLs exclude credentials, queries and fragments. Redirects stay on
the same HTTPS origin. Authentication or origin violations and incomplete
inheritance fail closed.

The caller decides whether a selection is required. Remote documents use the
chain's minimum freshness TTL, capped at one day. Verified bytes can be used
up to seven days after a transient offline failure. The loader reports stale
evidence, including its age. Once a known chain sets `fetch_failure: block`,
its cached metadata preserves that outage behavior after the bytes expire.
An admitted install can refresh the disposable cache in the supplied home.
Status, CI, previews and refusals leave it unchanged.

Native Core policy uses the APM governance reference for scope, outcomes,
inheritance and trust semantics. Complete `apm-policy.yml` import, authenticated
provider discovery, external scanners and experimental registry requirements
are separate integrations. [APM policy reference](https://microsoft.github.io/apm/reference/policy-schema/)
