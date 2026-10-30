# Swift Manifest

## Status

Accepted

## Context

A scope's declaration is standard JSON that the state store rewrites in full on
every save. People cannot annotate it, and every write normalizes it.

The declaration is about to describe every agent configuration component, not
only skills and instructions, and two front ends will edit it: the `agents`
CLI and a macOS GUI. People still read it in review and edit it by hand, so it
needs comments, and every tool write must keep them.

Swift has no maintained library that edits YAML without losing comments; a
YAML route needs a custom editor built on libyaml internals, plus rules for
YAML's implicit typing and indentation. A SwiftPM-style manifest that is
compiled and run executes repository code whenever a project is opened or
previewed, needs a toolchain and compile step on every read, and becomes
uneditable for tools once it contains logic.

## Decision

- The declaration is a Swift file, `Agents.swift`: `.agent/Agents.swift` for a
  project and `~/.agents/Agents.swift` for the user scope.
- Its vocabulary is a types-only module, `AgentsDescription`, modeled on
  `PackageDescription`. Sources, skills, instructions, MCP servers, hooks,
  subagents, commands and LSP servers are types, as are agents, scopes,
  platforms and conditions. A valid manifest type-checks against
  `AgentsDescription`.
- Core never compiles or runs a manifest. It parses the file with SwiftSyntax
  and evaluates a static subset: literals; initializers, static members and
  enum cases of `AgentsDescription` types; arrays and array concatenation;
  top-level `let` constants and references to them; `.when(agents:scopes:platforms:)`
  conditions; named groups, and references to groups that sources export.
  Functions, closures, loops, `var`, `if`, `#if`, `switch`, string
  interpolation and other imports are rejected with a line and column, and
  nothing is written.
- A leading version comment, in the manner of `swift-tools-version`, declares
  the language version. A tool refuses a manifest newer than it understands.
- Every write is a source edit. A write with no semantic change returns the
  original bytes; a change replaces only its target ranges, keeps comments by
  defined ownership rules, and is parsed and validated again before it is
  committed. A valid construct that an edit cannot address exactly, such as a
  constant assembled by concatenation, stays readable but is not edited by
  tools.
- `agents.resolved` remains the tool-owned JSON lock. Resolved pins live in the
  lock, not in the manifest.
- `agents manifest dump --json` prints the evaluated declaration for tools in
  other languages.
- The product reads and writes only `Agents.swift`. Existing repository and user
  scopes are converted once outside the product at release; the product does not
  read the earlier JSON declaration. A scope with a lock or watch state but no
  `Agents.swift` is an error.

## Consequences

- Core depends on swift-syntax, which lengthens clean builds.
- The static subset is a versioned contract. `AgentsDescription` and the static
  evaluator must not drift; examples are compiled against the types and
  compared with the evaluated model in tests.
- The state store gains a document layer that owns the original bytes, syntax
  tree, model and source locations, and that CLI and GUI edits share. Writes
  join the existing transaction and recovery model.
- Parsing untrusted manifests needs explicit limits on file size, nesting and
  evaluation work, and fuzzing before release.
- Editors offer completion only where `AgentsDescription` is available to them.
- Every repository that commits a JSON declaration, and every user scope, is
  converted once at release, outside the product.

## Alternatives Considered

- **Keep JSON.** No comments; explanations would need a structured field.
- **YAML.** Readable and familiar, but comment-preserving edits need a custom
  editor on non-public libyaml APIs, and implicit typing and indentation
  errors reach users.
- **JSONC or TOML.** Not chosen.
- **A compiled manifest, as in SwiftPM.** Full Swift, but opening or
  previewing a repository would run its code, every read would compile, and
  the GUI could not edit computed values.

## Related Documentation

- Accepted by the repository owner (showxu) on 2026-10-28.
- Current declaration, lock and state layout: [State](../Architecture/State.md)
- Language specification: [Agents Manifest Language](../Reference/Manifest.md)
- Component model the manifest describes: [Agent Components and Adapters](AgentComponents.md)
- Approval of executable components: [Executable Component Approval](ExecutableApproval.md)
- Product scope and front ends: [agents-tools/cli decisions](https://github.com/agents-tools/cli/tree/master/Documentation/Decisions)
