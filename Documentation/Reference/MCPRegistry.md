# Install an MCP server from a registry

The `AgentsUpdates` registry API reads the public MCP Registry or a configured
v0.1 subregistry. A consumer can browse pages, inspect a specific version, choose
one of its remote or package configurations, and preview a managed server in a
project or user scope.

## Find a version

```swift
import AgentsCore
import AgentsUpdates
import Foundation

let registry = MCPRegistry.official
let page = try await registry.search("weather", limit: 20)
if let cursor = page.nextCursor {
  let next = try await registry.search("weather", limit: 20, cursor: cursor)
  // Display next.servers.
}
```

Omit the search text to list servers. The default version filter is `"latest"`.
Pass an exact version or pass `nil` to browse all versions. Reuse the cursor with
the same registry and query. To retrieve a known version directly, call
`server(named:version:credentials:scope:environment:)` with the full registry name. An omitted
version resolves the registry's latest alias and returns its exact version.

For a private registry, initialize `MCPRegistry(endpoint:)` with the base URL
before `/v0.1`, including any deployment path prefix. Pass authorization or an
API key as `credentials` headers on each request. Requests with credentials
require HTTPS, with HTTP available on the loopback IP addresses. The client
rejects redirects and uses no stored cookies, credentials, or cache. The
credential headers are used only for the registry request. Pass the consuming
`scope` and `environment` to discovery so the project, user and configured
organization policies can check the registry origin before the request.

## Select a choice and preview its targets

Each version returns its remote and package choices. Display the endpoint or
package coordinates, transport, binding requirements and any
`unavailableReason`. Supply `.environment(name)` for symbolic inputs and
`.choice(value)` for inputs restricted to listed values. A non-secret default
is used when the input has no listed choices and the caller leaves it unset.
HTTP header references supply the entire header value. The variable for bearer authorization
contains the `Bearer ` prefix as well as the token. Clients obtain these values
at run time.

```swift
func previewRegistryChoice(
  _ choice: MCPRegistryChoice,
  named name: String,
  agents: [AgentID],
  bindings: [String: MCPRegistryBinding],
  packageCommand: String? = nil,
  scope: InstallScope,
  environment: RuntimeEnvironment
) throws -> (UpdateRequest, CombinedUpdateReport) {
  let destination = try UpdateOperations.inspect(scope: scope, environment: environment)
  let discovery = try choice.select(
    named: name, agents: agents, in: destination, bindings: bindings,
    packageCommand: packageCommand)
  let request = discovery.updateRequest()
  let report = try UpdateOperations.preview(request, scope: scope, environment: environment)
  return (request, report)
}
```

Use `compatibleAgents(in:bindings:packageCommand:)` to populate the recipient
picker for the configured choice. It uses the native adapters' transport and
symbolic reference rules. The preview then checks the actual destination,
including existing configuration and ownership.

After confirmation, use `UpdateOperations.withPreparedUpdate` with the same
scope and environment and call
`apply(ifUnchangedFrom: report.displayedFingerprint)`. The transaction writes
the MCP declaration, lock, and selected client configuration. It uses the
captured endpoint or package coordinate even if the registry changes in the
meantime. The declaration and lock preserve the registry base URL, full
server name, exact server version, and selected endpoint or artifact origin.
For stdio, they also record the exact package or image coordinate.
`ComponentInspection.mcpRegistry` and portable bundles expose this evidence.
The invocation digest binds the record to the selected launcher, arguments,
transport and binding configuration. Reselect the exact registry version to
change those values. Older declarations and locks can still be read and
restored when their launcher and package coordinate agree. Reselect legacy
records when organization policy requires verified registry selection or a
package export needs to verify which literal bindings came from that selection.

Install, update and restore check the registry and selected origin under the
applicable policies. When egress is proxy-only, restore and the source and
organization CI audits require each locked registry to match the configured
HTTPS authority, port and base path. Searching, selecting, previewing and
applying do not start a server or run a package launcher.

## Supported choices

- Remote Streamable HTTP and legacy SSE use fixed HTTP(S) endpoints. A template
  can use fixed, non-secret registry variables. A runtime-bound header requires
  HTTPS or a loopback IP endpoint.
- Stdio packages support npm via `npx`, PyPI via `uvx`, and OCI via `docker`.
  npm and PyPI require an exact package version. When `requiresPackageCommand`
  is true, supply the Python distribution's console command as `packageCommand`.
  OCI accepts a fixed tag or a SHA-256 image digest. Fixed package arguments and
  process environment bindings are supported. Client-side runtime availability
  and package access are the caller's responsibility.
- Choices requiring unresolved endpoint variables, dynamic command-line values,
  custom launcher arguments, external package-file checksum verification, or
  another package type carry an availability reason. Secret inputs are available
  as symbolic header or environment bindings on clients that preserve those
  references.

The HTTP and metadata contracts are the [MCP Registry v0.1 OpenAPI
specification](https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/openapi.yaml)
and the [2025-12-11 server schema](https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json).
The consumer workflow follows the public [APM MCP discovery
reference](https://microsoft.github.io/apm/reference/cli/mcp/) and [MCP installation
guide](https://microsoft.github.io/apm/consumer/install-mcp-servers/).
