# Importing APM files

Select one document for each import. Use the APM manifest profile to preview
a package declaration or the APM lock profile to inspect exact revisions. Each proposal
identifies accepted source declarations, selectable components, unresolved
inputs and diagnostics at their original locations. Review the proposal in
the destination scope before applying it.

| Input | Behavior |
| --- | --- |
| Package name, version and target information | The importer checks the manifest shape and translates recognized targets. Conflicting target declarations produce diagnostics. |
| APM dependencies | Supported Git references and local package paths become candidate sources. Local package contents are inspected within the selected input directory. |
| APM lock file | Its own proposal records exact commits, source coordinates and transitive entries from the lock. |
| Incomplete, ambiguous or unsupported input | The diagnostic identifies the affected location. Review unresolved entries before selecting components. |

The import profile reads APM dependency mappings under `dependencies.apm`.
Entries under `dependencies.mcp` require separate configuration via MCP
Registry selection or the Agents manifest. The installed configuration uses the
Agents YAML declaration and JSON lock.

See the upstream [APM manifest schema](https://microsoft.github.io/apm/reference/manifest-schema/)
and [package installation guide](https://microsoft.github.io/apm/consumer/install-packages/).
