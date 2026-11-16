// Exact sample data from the pinned producer releases. No fixture command is executed.
enum ImportPinnedFixtures {
  // https://github.com/microsoft/apm/blob/787a97cc52fbbcc344374e1567b2a1e5b8adf441/apm.yml
  static let apmManifest = #"""
    name: apm
    version: 0.10.0
    description: APM (Agent Package Manager) -- ship and govern AI agent context
    includes: auto
    author: Microsoft
    license: Apache-2.0

    # Pinned so every contributor's `apm install` deploys the same tree this
    # repo commits (.github/ plus .agents/skills/ via skills convergence),
    # instead of auto-detecting whichever harness their machine signals.
    # Contributors on another harness opt in with `apm install --target <name>`.
    targets:
      - copilot

    # Local-path manifest deps on the extracted skill packages.
    # Each was INLINE in .apm/skills/ until the v2 extraction.
    # Extraction unlocks consumer reuse of each primitive standalone
    # (consumers can install just a panel for single-PR review / single-
    # issue triage, or an orchestrator entrypoint which transitively
    # pulls its engine + panels).
    #
    # User-facing schedulers are declared here. Workers arrive
    # transitively:
    #  - autopilot-issue-triage-scheduler -> autopilot-issue-triage-worker
    #  - autopilot-issue-delivery-scheduler -> autopilot-issue-delivery-worker
    #  - autopilot-pr-triage-scheduler -> autopilot-pr-triage-worker
    #  - autopilot-pr-review-scheduler -> autopilot-pr-review-worker
    #  - autopilot-pr-merge-worker is summoned by name (never by
    #    the PR review scheduler)
    dependencies:
      apm:
        - ./packages/autopilot/autopilot-issue-triage-scheduler
        - ./packages/autopilot/autopilot-issue-delivery-scheduler
        - ./packages/autopilot/autopilot-pr-triage-scheduler
        - ./packages/autopilot/autopilot-pr-review-scheduler
        - ./packages/autopilot/autopilot-pr-merge-worker
      mcp: []

    scripts: {}
    """# + "\n"
  // https://github.com/dyoshikawa/rulesync/blob/fbe4fe58334cab4e84b87f20d730d6450a35e0f7/rulesync.jsonc
  static let rulesyncConfig = #"""
    {
      "$schema": "https://github.com/dyoshikawa/rulesync/releases/latest/download/config-schema.json",

      // Per-target features using the new object form on `targets`.
      // See docs/guide/configuration.md for details.
      "targets": {
        "copilot": {
          "rules": {
            "ruleDiscoveryMode": "explicit",
            "includeLocalRoot": false
          },
          "commands": true,
          "mcp": false,
          "subagents": true,
          "skills": true,
          "hooks": true
        },
        "claudecode": {
          "rules": true,
          "commands": true,
          "mcp": true,
          "subagents": true,
          "skills": true,
          "hooks": true
        },
        "opencode": {
          "rules": true,
          "commands": true,
          "mcp": true,
          "subagents": true,
          "skills": true,
          "hooks": true
        },
        "codexcli": {
          "rules": true,
          "commands": false,
          "mcp": false,
          "subagents": true,
          "skills": true,
          "hooks": false,
          "permissions": true
        },
        "takt": {
          "rules": true,
          "commands": true,
          "subagents": true,
          "skills": true
        }
      },

      // Output root directory or directories for generation.
      "outputRoots": ["."],

      // Delete existing files before generating
      "delete": true,
      "verbose": true,
      "silent": false,

      "simulateCommands": true,
      "simulateSubagents": true,
      "simulateSkills": true,

      // When true (default), `rulesync gitignore` only emits entries for the
      // tools listed in `targets`.
      "gitignoreTargetsOnly": false
    }
    """# + "\n"
}
