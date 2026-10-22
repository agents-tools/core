# Update Reporting and Combined Application

Status: accepted.

Addresses core issues [14](https://github.com/agents-tools/core/issues/14),
[15](https://github.com/agents-tools/core/issues/15) and
[16](https://github.com/agents-tools/core/issues/16).

## Context

Consumers needed resolved versions, executable-mode changes and managed
membership to explain updates without inferring intent from file differences.
Sequential skill and instruction transactions could leave only one kind
updated when later preparation or application failed.

## Decisions and Rationale

- `AgentsUpdates` is a concrete composition product above the independent
  domain modules. Discovery remains domain-owned, shared resolution and
  transactions remain in `AgentsCore`, and consumers retain presentation.
  The skill-only consumer does not acquire a Markdown dependency.
- One existing `FileTransaction` covers both kinds and their merged state and
  pruning. Its journal already supports those destinations and recovery, so
  another commit protocol would duplicate the durability mechanism.
- The writer lock spans preparation, synchronous rendering and apply. A
  one-use, thread-bound handle protects the exact rendered plan and expires
  at closure exit. Long-lived/offline approvals require a separately designed
  persisted precondition contract.
- Missing resolved state changes reported membership without granting
  ownership of an existing skill target. The ownership guard protects user
  content independently of whether a link happens to match prospective intent.
- Executable flags are compared separately from persistent tree hashes.
  Changing those hashes would affect restoration and cache verification and
  require its own migration. A Boolean matches watch reporting without
  claiming to represent full POSIX permissions.
- Apply errors carry a confirmed outcome because a failure after the commit
  marker does not imply rollback. Outcome tracking is journal-specific so
  preparatory cache publication cannot be confused with target/state commit.
- Consumer CLI JSON integration keeps schema version 1 with additive metadata
  under the documented unknown-property rule. The core synthesized `Codable`
  representation is a separate, breaking surface; consumer adapters own the
  explicit JSON representation and compatibility with older reports.

Current contracts live in [Updates](../Architecture/Updates.md),
[State](../Architecture/State.md) and [Package](../Architecture/Package.md).
Combined install, cross-scope transactions, watch acknowledgments and unmanaged
adoption remain separately owned work.
