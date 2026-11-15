# YAML Manifest

A project declares intent in `.agent/agents.yaml`; user intent lives in
`~/.agents/agents.yaml`. Producers publish the same canonical filename under
`.agent/`, or `agents.yaml` when the producer root is itself `.agent`.
`agents.resolved` remains tool-owned JSON.

```yaml
version: 1
sources:
  team: {url: https://github.com/example/config, requirement: {from: "1.0.0"}}
components:
  - {kind: skills, source: team, select: [review], agents: [codex]}
  - kind: instructions
    sections: [{name: common}]
    chatgpt:
      review: {sections: [{name: common}], append: prompts/review.md}
groups:
  checks:
    components: [{kind: ignore, name: private, patterns: [private/**]}]
uses: [{group: checks}]
exports: [checks]
```

The distributed [JSON schema](../../Sources/AgentsManifest/Resources/agents.schema.json)
is the field-shape owner. [Generated field help](ManifestSchema.md) lists every
supported shape and its schema-owned collection bounds. The finite compiler
rejects unsupported validation keywords, values and combinations; its generated
rules enforce the accepted constraints. Parser and decoded-value safety budgets
apply independently of these field constraints.
Unknown fixed fields, decoded duplicate keys and invalid scalar
kinds are errors. Domain validation also checks unused groups and inactive
components. References remain symbolic until linking; declaration reads never
resolve sources, access resources or execute component programs.

Git requirements also apply to local Git repositories declared with `path`;
their local source identity and declaring environment remain unchanged.

## Values and Ordering

Sources, groups, components, uses, exports, prompt sections and named ChatGPT
prompts retain order and occurrences. Ordinary dictionaries and NativeValue
objects have unordered domain semantics while their untouched document spelling
is preserved. Omitted recipients/condition dimensions inherit or impose no
restriction; explicit empty lists select nothing. Omitted `select` means all;
`select: []` selects none. Watch omission and an empty list are equivalent, and
watch order is set-like. Ordinary optional fields do not accept null.

Scalar resolution follows YAML 1.2 Core. `yes`, `on` and dates are strings;
quoted and block scalars are strings. Integer fields require representable plain
integers. Native values also admit finite decimals, arrays, objects and null.
Every decimal is written as `!!float "<exact JSON-number text>"`; integer-shaped
payloads, negative zero, exponent spelling and trailing zeroes retain identity.
This tag is permitted only on NativeValue scalars. `<<` is an ordinary data key.

UTF-8, a leading BOM, LF/CRLF, block and flow collections and all ordinary scalar
styles are supported. Raw NEL, line separator and paragraph separator characters
are rejected before either parser; use double-quoted escapes `\u0085`,
`\u2028` and `\u2029` to retain those exact characters. Anchors, aliases,
directives, complex keys, multiple documents and other tags are rejected.

## Edits and Source Maps

`DeclarationDocument` exposes complete IR and semantic JSON Pointer locations:
`sources.team` maps to `/sources/0`, its key to `/sources/0/name`, and nested
group components to `/groups/0/components/...`. Handles belong to one digest.
`ManifestEdit` accepts Core domain values and prepares bytes without writing.

No-op changes return exact bytes. Changed fields and collection entries preserve
unrelated bytes. Adjacent leading comments and same-line trailing comments belong
to their item; moves carry them. Deletion retains comments unless explicitly
owned by a replaced value. Blank-separated headers belong to their container.
Special layouts that cannot be changed precisely fail before publication.

Complete declaration planning composes private parser/schema-checked drafts,
refreshes occurrence ranges and verifies full expected IR at every step. Final
domain and environment validation precede returning any candidate bytes.
Public documents and public prepared changes never expose unchecked drafts.

## Bounds and Dump

Input is bounded at 2,097,152 bytes; CSTs at 100,000 nodes/depth 128; decoded
values at 100,000 nodes/depth 64, 10,000 entries per container and 16,777,216
string bytes. Parser-stage progress callbacks enforce an additional measured
work bound before CST traversal. Scalar scanning remains input-byte bounded;
these are work limits, not a claim of a fixed allocation bound.

Source maps admit 100,000 locations, 1,000,000 origins and 16,777,216 encoded
bytes. Dump output is bounded at 33,554,432 bytes. Public edit batches admit 100
requests, with 200,000 comparison pairs and 1,000,000 editing steps. Private
composition retains finite total work and bounded internal batches.

`ManifestDump` uses schema version 2, `format: "yaml"`, manifest version 1,
source digest, complete typed IR and indexed locations. Decimal records retain
`{kind: "decimal", value: "<exact text>"}`; arbitrary native object keys cannot
collide with this dump-only envelope.
