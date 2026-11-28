# Portable bundle fixtures for AgentsUpdates

The behavioral reference is the public APM pack and preview documentation
as published on 2026-11-25. The fixtures exercise a target-independent
selection, locked bytes with per-file integrity, and consumer-side preview
before applying. The Swift API and `agents.bundle` version 1 encoding are
defined here. [APM pack][pack] · [APM preview][preview]

## Public Swift API

Import `AgentsCore` and `AgentsUpdates`. Build the export selection from
`UpdateOperations.inspect(scope:environment:).components`. Use an
occurrence selection for an ambiguous component identity. Export retains
instruction order from the lock. A named ChatGPT prompt is outside the
instruction-section selection.

```swift
public struct BundlePackage {
  public init(name: String, version: String)
}

public struct BundleImportSelection {
  public init(componentID: String, targets: [AgentID])
}

public enum BundleOperations {
  public static func export(
    _ package: BundlePackage, selections: [ComponentSelection],
    scope: InstallScope, environment: RuntimeEnvironment
  ) throws -> Data

  public static func inspect(_ archive: Data) throws -> BundleInspection

  public static func previewImport(
    _ bundle: BundleInspection, selections: [BundleImportSelection],
    scope: InstallScope, environment: RuntimeEnvironment, replace: Bool = false
  ) throws -> BundleImportPreview

  public static func withPreparedImport<Result>(
    _ preview: BundleImportPreview, bindingProvider: (any RuntimeBindingProvider)? = nil,
    _ body: (PreparedUpdate) throws -> Result
  ) throws -> Result
}
```

`BundleInspection` exposes the package coordinates, format version, exact
archive digest, and component inventory. Each component provides its ID,
kind, name, source evidence, tree entries and, for MCP, symbolic
configuration. A marketplace can publish the exported bytes keyed by
package name and version and compare the consumer's `archiveDigest` with the
catalog digest. Verification covers the bytes and recorded claims. Publisher
authentication uses the consumer's trust policy.

Pass explicit component IDs and recipients to preview. The preview returns
the ordinary `CombinedUpdateReport` and an `ownershipConflict` when target
admission prevents publication. Conflicts that prevent native composition or
admission of the source tree surface as thrown errors. `replace: true`
authorizes ordinary instruction replacement. An unmanaged skill or native
key still uses the existing ownership checks. Select targets supported by
the component, scope and client adapter.

After confirmation, call `withPreparedImport` and invoke `apply()` on the
provided `PreparedUpdate`. This compares the re-prepared report with the
displayed fingerprint under the writer lock. The generated producer trees,
deployment files, declaration and lock publish through the same transaction.
Use a binding provider when a client requires runtime materialization. Export
and preview preserve symbolic bindings and avoid starting components.

## Archive v1

The archive is sorted-key UTF-8 JSON with unescaped slashes and a trailing
line feed. Its top-level keys are `format` (the string `agents.bundle`),
`version` (the integer `1`), `manifest`, `manifestDigest` and `contentObjects`.
Digest strings use lowercase hex prefixed by `sha256:`. `manifestDigest`
identifies the independently encoded canonical manifest. `contentObjects`
maps each file digest to its Base64 bytes. Files with identical bytes share
an object.

The manifest contains `package` (`name` and `version`) and the ordered
`components` array. A component contains `kind` (`instructions`, `skills` or
`mcpServer`), `name`, `sources` and `entries`. It also contains either
`discovery`, the instruction or skill discovery root, or `configuration`, the
tagged MCP transport and native values. Environment and secret fields retain
their symbolic name. Resource-backed MCP commands and working directories
refer to contained member paths. Ordinary executable names, arguments and
transport values retain their authored strings.

Source records contain the source `kind`, exact `revision` and, when
available, `version` and normalized transport `identity`. Local sources
omit absolute coordinates. An authored live input receives a content
revision. An export of an installed bundle carries forward its original
evidence. The update planner supplies these claims by linked snapshot in
`BundleSourceInputs.evidence`, alongside the destination preconditions.

Each tree has a directory entry named `.`. Other entries belong under
`payload`. Entries describe a file, directory or relative symlink. File
entries carry the object digest, byte count and executable flag. Links
carry their relative spelling. The archive admits only portable,
noncolliding paths with directory ancestors and resolves each link inside
the payload before materializing the tree. Files materialize with mode
`0644` or `0755` according to the executable flag. Locked instructions
carry the input files recorded for their selected section.

## Verification

Run the `PortableBundleTests` Swift Testing suite with an isolated home.
The producer and consumer use different temporary projects and homes.
Fixtures verify locked instructions, nested binary and executable skill
files, empty directories, relative symlinks, and runtime-only MCP bindings.
They also exercise a changed content object, a resealed traversal, an
unmanaged destination, and a stale confirmation.

[pack]: https://microsoft.github.io/apm/reference/cli/pack/
[preview]: https://microsoft.github.io/apm/reference/cli/preview/
