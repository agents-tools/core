# Native Documents

`NativeDocuments` is a package-only byte inspection and regional editing layer.
It receives `Data`, a fixed JSON/JSONC/TOML format, an operation budget and typed
region intents. Adapters own client dialects and ownership decisions. Filesystem
access, routes, secrets, locks, freshness, transactions and publication stay with
their existing owners.

## Inspection and evidence

`NativeDocument` preserves the supplied bytes. Regions consist of exact decoded
keys and array occurrence evidence. Key and string identity uses decoded UTF-8
sequences. Canonically equivalent Unicode strings remain distinct native values.
Objects retain ordered entries; projecting a region that Core dictionaries cannot
represent returns no Core value. TOML date/time and non-finite numbers likewise
remain native atoms, retaining their lexemes.

`read` returns an optional package-only observation with a Core value when
representable, native kind, raw numeric lexeme, explicit projection failure,
ephemeral byte ranges, exact structural fingerprint
and array occurrence evidence. Observations and prepared bytes can contain
materialized secrets; they are neither preview records nor serialized ledger
models. Diagnostics use fixed codes and byte ranges, without source excerpts.

A put requires an absent expectation or matching owned observation. Removal
requires matching owned evidence. Empty object-container removal requires explicit
caller-supplied creation evidence and fails if comments must remain. An existing
unmanaged region is never adopted by matching a desired value. Missing object
ancestors can be created; the preparation reports created container regions.

Stable array IDs are exact string fields and must be unique. Without an ID,
observations retain a structural fingerprint, ordinal and neighboring evidence.
Duplicate content is rejected when it cannot be uniquely identified; an ordinal
alone does not authorize a match. Individual occurrence edits preserve other
array entries and their order. An absent terminal occurrence with a stable ID can
append an exactly matching object. Owned array-of-table sets diff their entries
and append complete new occurrences; removing the final occurrence retains an
explicit empty array. New child tables bind only where their native scope can be
proved.

## Parsers and edits

JSON has one root and preserves raw numeric lexemes. JSONC comments and trailing
commas are independent fixed-dialect capabilities. The scanner validates string
escapes/surrogates and decoded duplicate keys. A leading UTF-8 BOM is preserved.

TOML uses the fixed grammar in `TreeSitterTOML` with the existing formal runtime
dependency for locations. `TOMLSemantics` contains the licensed parser/validator
subset from pinned TOMLDecoder, with exact key identity, lexical scalar
classification, complete lazy validation, actual EOF checks and cooperative
resource admission. Each target records upstream file hashes and patch details.
The semantic parser remains the validity owner when the older CST grammar
cannot locate legal TOML syntax; such documents can be inspected and return
`syntaxNotLocated` for edits. No error recovery tree is used for editing.

The TOML index resolves quoted/dotted keys, inline tables and array-of-table
headers in source order. Child table headers bind to the latest array table.
Scalar updates replace only the value span. Object updates diff members;
removal uses individual owned entries and headers across table blocks. Inline
punctuation is located independently of comments. Structural edits with ambiguous
trivia or scope are refused. New members use their containing table block or a
precise new table declaration, preserving subsequent table scope.

Every preparation checks overlap and ownership, builds the complete expected
native tree, constructs nonoverlapping patches, copies every unselected byte
segment unchanged and reparses the complete candidate. Only a candidate equal to
the expected tree is returned. No-op intent returns the original bytes, including
escape spelling, newline style, comments and key order. Multiple internal drafts
are private; failure returns no partially prepared result.

JSON integer/decimal declarations can encode the same numeric token. TOML
integer-looking decimal declarations append `e0` to retain native float kind.
Encoding and comparison preserve exact decimal text without a Double round trip.
Core projection removes TOML digit separators and a leading plus while retaining
the original numeric token separately in the observation.
Declarations and ledger identity remain with their owners, independently of
native byte no-ops.

## Budget and cancellation

`NativeDocumentBudget` is one serial operation-scoped mutable reference supplied
by the caller. Input admission, semantic construction, node/depth checks, decoded
storage, scans/key comparisons, reads, fingerprints, rendering, patches, drafts
and reparses consume that reference. No stage resets it. Limits are explicit
caller inputs rather than copies of YAML or ledger policy.

Before entering the C parser, the entire input must fit the caller's maximum
uninterrupted-byte envelope. This covers strings, keys, skipped comments and
whitespace alike. The fixed grammar also reserves a conservative logical node
envelope of four nodes per input byte plus the document root before CST entry;
traversal and progress callbacks consume additional work. The progress callback
checks the same cancellation source and budget between parser work intervals.
All parser/tree handles are synchronously released on every exit.

These are conservative logical admission units and cooperative cancellation,
not exact heap/RSS quotas or hard real-time deadlines. A caller requiring a
smaller uninterrupted interval must supply a smaller envelope. There is no
background timeout task or filesystem provider in this layer.
