# Source policy fixtures

The source-policy tests use disposable projects, homes, Git repositories and
HTTP listeners bound to loopback. Fixtures are independently authored against
Core's public API and the documented allow-list intersection, deny precedence
and identity casing behavior in the [APM policy reference][apm-policy].

## Policy inputs

`SourcePolicyOperations.policyURL` identifies the optional user and project
files (`~/.agents/source-policy.yaml` and `.agent/source-policy.yaml`). A trusted
CLI or App configuration can set `RuntimeEnvironment.organizationSourcePolicyURL`
to an explicitly managed local policy file. A project install evaluates all
configured layers. A user install evaluates the user and explicit organization
layers. A missing explicitly configured organization file fails preparation.

```yaml
version: 1
allow:
  - git: https://github.com/example/skill-producer.git
  - http: https://index.example.org
  - local: /absolute/physical/producer
  - inline
deny:
  - missing
```

Git rules name exact host and repository identities. HTTP rules match the
scheme, host and port. Defaults and DNS spelling are normalized. GitHub owner
and repository names are case-insensitive. Git HTTP and git-protocol origins
remain distinct from HTTPS and SSH origins. The bare `local` rule matches any
local source. `inline` describes a consumer-authored component. `missing`
describes external content with unavailable provenance and requires an explicit
allow entry in every configured layer. Omit `allow` for a deny-only layer.
`allow: []` denies every origin in that layer.

`SourcePolicyDocument.parse` and `bytes(for:)` support CLI and App file editing.
`SourcePolicyOperations.inspect` reports all applicable layers and the read
interests for changes to the policy files. `SourcePolicyOperations.audit`
reports machine-readable violations of committed sources and artifact origins
without acquiring sources. An absent lock produces `hasLock: false`.

## Integration fixtures

Registry and bundle implementations share `SourceOrigin` and
`EffectiveSourcePolicy.require` for lookup and selection. Capture
`SourcePolicySnapshot` in the consuming scope, include its entry dependencies in
preview, bind its fingerprint to any preview/apply handle, and register it as
`PreparedEvidence` in the publication transaction.

Record every acquisition origin in the installed provenance, including the
catalog or registry, fetched artifacts, and upstream and transitive origins.
For bundles, preserve independent evidence of the original source coordinates
of each selected item across export, import, update and replay. The transport
used to deliver the bundle is an additional origin. Evaluate `.missing` when
that original provenance cannot be established. A local staging directory or
inline representation carries no authority to reclassify external content.
The sibling registry and bundle workflows own that evidence and its persistence
in their declarations and lock records. Their integration should exercise the
same rejection and no-publication assertions for offline restore.

The existing lock can audit the provenance it recorded. Older Git and HTTP
acquisitions may lack the ultimate redirect or rewrite destination. New
policy-controlled Git reads reject rewrites and disable HTTP redirects. New
policy-controlled index reads permit redirects on the original HTTP origin and
require explicit URLs for cross-origin artifacts. Scope and recovery locks use
the existing transaction protocol.

[apm-policy]: https://microsoft.github.io/apm/reference/policy-schema/#allow-list-semantics
