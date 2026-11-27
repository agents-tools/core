# Content audit

Use `ContentAuditOperations` from `AgentsUpdates` to inspect local prompts.
A scope scan discovers recognized files even before `agents.resolved` exists.
Pass `agents:` to limit discovery to selected readers. An explicit file scan
accepts a recognized native document or a Markdown or plain text prompt
(`.md`, `.mdc`, `.txt`, `.prompt`) inside the selected project or home.

```swift
import AgentsCore
import AgentsUpdates
import Foundation

let project = URL(fileURLWithPath: "/path/to/project", isDirectory: true)
let environment = RuntimeEnvironment(projectDirectory: project)
let audit = ContentAuditOperations.scan(environment: environment)
let status = audit.ciExitCode
let sarif = try audit.export(.sarif)

let prompt = project.appendingPathComponent("AGENTS.md")
let fileAudit = ContentAuditOperations.scan(file: prompt, environment: environment)
func stripReviewedPrompt(
  _ file: URL, environment: RuntimeEnvironment,
  approve: (ContentAuditStripPreview) throws -> Bool
) throws {
  let preview = try ContentAuditOperations.previewStrip(file: file, environment: environment)
  if try approve(preview) { try ContentAuditOperations.applyStrip(preview) }
}
```

| Agent | Prompt surfaces |
| --- | --- |
| Codex | `AGENTS.md` and overrides, `SKILL.md` entries, `developer_instructions` in agent TOML |
| Claude Code | Context files, Markdown rules, commands and agents, `SKILL.md` entries, `prompt` on nested prompt and agent hooks |
| Cursor | Context files, Markdown commands and agents, MDC rules, `SKILL.md` entries, `prompt` on flat prompt hooks |
| Gemini CLI | Context files, Markdown agents, `SKILL.md` entries, `prompt` in command TOML |
| OpenCode | Context files, Markdown commands and agents, `SKILL.md` entries, command `template` and agent `system` fields in native JSON or JSONC |
| Antigravity | Project rules and skill entry points, and user rules and skills in the native config directory |

Project discovery also covers local `.agent/instructions`. Use `scope: .user` with
the intended home in `RuntimeEnvironment` for user profiles. Discovery stays
inside that scope, skips nested repositories and protected paths, and admits
linked skills through a matching in-scope ledger entry. Structured documents
contribute only recognized decoded prompt fields. A recognized document without
prompt fields appears as skipped. Source coordinates use one-based UTF-16
columns. Native findings carry a field pointer, decoded coordinates, and
physical coordinates when the literal spelling can be mapped.

The gate fails for critical Unicode, incomplete coverage and detected
recorded-content drift. Warnings and informational findings pass the gate.
`scanExitCode` distinguishes warning-only reports from clean or informational
reports. Scope scans compare present, admitted prompts to recorded file hashes
where available. Shared settings attribute managed fields using ledger region
evidence. Combine this report with existing lifecycle inspection for
deployment presence, source policy and full deployment drift. Explicit file
scans use ledger ownership and omit the recorded hash comparison. The report
exports JSON, SARIF 2.1.0 and Markdown with scope-relative locations. [APM audit reference](https://microsoft.github.io/apm/reference/cli/audit/) · [Baseline content-integrity check](https://microsoft.github.io/apm/reference/baseline-checks/#content-integrity)

Strip is a separate one-file operation for explicitly selected regular text
prompts. The preview identifies deletions by exact UTF-8 byte ranges and
preserves the BOM, line endings and informational characters. Apply revalidates
the file identity and reviewed bytes before publishing the replacement. Native
settings and linked files require manual edits. Rerun the audit after applying
a strip. A managed file edited in place may then need changes to its source
and a refreshed deployment.
