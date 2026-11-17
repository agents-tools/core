# Passive agent client inspection

`AgentsUpdates` exposes a synchronous, read-only client observation API. Supply
one captured `RuntimeEnvironment`; the default scope is `.user`.

```swift
import AgentsCore
import AgentsUpdates

let environment = RuntimeEnvironment()
let report = try AgentClientOperations.inspect(environment: environment)
for client in report.clients {
  for command in client.commands {
    print(client.agent.displayName, command.name, command.status.rawValue)
    print(command.version.rawVersion ?? "Unknown")
  }
}
```

`AgentClientInspection` and its immutable `Sendable` records describe the
observation interval, captured project/home context, PATH coverage, command and
application observations, logical configuration locations and frozen schema
evidence. Request `.project` with the selected project's explicit environment
to inspect its locations.

Command lookup searches only absolute entries in the supplied PATH, in order,
and stops at the first regular executable for each command. Empty and relative
entries appear in `excludedEntries`. `lookupIssues` preserves failed access
before a selection; a later selection then does not guarantee shell resolution.
Missing commands mean no executable was found within this coverage. Shell
aliases, functions and installations outside PATH are outside this observation.
Cursor's `editorLauncher` and `agentCLI` records are separate.

On macOS, application lookup uses registered bundle identifiers with an existing
discovery recipe and validates the bundle's metadata identity. Other platforms
report application lookup as unavailable. Currently the evidenced application
recipe is Cursor; other agents return an unavailable application observation.
Only Cursor's recognized editor launcher layout is associated with that bundle.
Other executable layouts return `unrecognizedLayout`; arbitrary neighboring
package metadata and directory labels do not supply versions.

Versions retain raw labels. Bundle version and build are separate fields, with
metadata URL/key provenance. Missing, unreadable, malformed, oversized or
non-regular metadata has a typed `unknownReason`. Metadata reads follow ordinary
installation symlinks, validate the opened descriptor and enforce a 1 MiB limit
throughout reading. Inspection never executes candidate files.

Configuration locations come from their existing skill, instruction and native
route owners. Presence checks inspect type only, without reading configuration
contents. Semantic records remain distinct when paths coincide, including
Claude local/user MCP regions. OpenCode JSON and JSONC alternatives are both
reported. Skill scan paths and installation destinations have different
purposes. Gemini/OpenCode skill and native overrides follow their respective
owners, so their paths can differ. Invalid native overrides affect their own
location observations; absent roots still yield logical paths.

Schema evidence preserves the registry's surface, component kind, scope and
standalone/plugin-member placement. `recorded` means the profile has frozen
schema evidence; `unsupportedUnderEvidence` reflects an explicit unsupported
contract, and `unverified` means the contract is not established. Revisions and
source references are evidence provenance. In particular, `installed:2.1.309`
is a historical evidence revision, not a currently detected client version.
Preview remains responsible for configuration admission.

Consumers should run inspection on their existing operation executor and retain
the latest result in their client settings state. Re-detection is explicit.
Returned paths are provenance, rather than workspace-monitor read footprints.
Unknown versions, missing clients and detection failures do not change editing
availability. The report is an interval of observations, rather than an atomic
filesystem snapshot. This operation neither recovers nor writes managed state.
