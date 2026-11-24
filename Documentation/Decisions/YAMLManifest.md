# YAML Manifest

## Status

Accepted.

## Decision

The canonical authoring document is `agents.yaml`, using YAML version 1 field
shapes owned by AgentsManifest. Core domain and lifecycle semantics remain
independent of syntax. The lock remains JSON. No component program runs while
reading, inspecting or editing a declaration.

A pinned Tree-sitter runtime and unmodified YAML grammar provide concrete ranges;
public Yams ordered-node composition decodes scalars after bounded admission.
Finite schema-generated constraints validate shapes. Explicit NativeValue-only
float tags retain decimal kind and exact text. Raw Unicode line separators that
parsers interpret differently are rejected before parsing; escaped values remain
exact strings.

Edits preserve unrelated bytes and owned comments. Complete intent, source
references and ordering are checked before returning candidate bytes. The
existing transaction, source identity, security and client-owned trust boundaries
continue unchanged. See the [current reference](../Reference/Manifest.md).
