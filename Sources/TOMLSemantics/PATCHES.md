# TOML semantic source subset

Source: TOMLDecoder 0.4.5, revision
`a2bbd2796fe3064e107de18cb56031052c4fa899`, MIT. `provenance.json`
records each copied file's original path and SHA256. `upstream.patch` records
the complete zero-context differences for those exact hashed files, including
repository formatting.
`SemanticBudget.swift` and `SemanticDocument.swift` are package-owned seams.

The subset contains the parser, token/model/constants, scalar/date validators,
key context and errors. General Decodable containers, public table/array
accessors, Dictionary/Any conversion, executables, tests, documentation,
benchmarks and build plugins are not included.

Local changes are limited to:

- Per-operation budget/cancellation propagation through construction, capacity
  reservation, recursive descent, token/trivia scans, key comparisons, lazy
  scalar decoding and ordered traversal. Original typed throws become ordinary
  throwing calls so budget and cancellation errors propagate without casts.
- Exact decoded UTF-8 key comparison, including sampled-hash collisions. Unused
  key-transform and String-key Dictionary/Any access paths are removed. Keyed
  model types do not synthesize String equality.
- Stable entry source positions for ordered typed traversal. Scalar syntax is
  classified before invoking its standard validator. Overflowing integers do
  not retry as floating point. Raw numeric lexemes and native atoms remain
  separate from Core projection; finite decimal projection removes only TOML
  separators and a leading plus, with no floating-point formatting.
- Actual EOF guards after fractional-time scanning and before the month/day
  delimiter. No source terminator, sentinel or synthetic newline is appended.
- Required string helper budget propagation and quoted-key validation through
  the same standard validators. Decoder-specific date initializers and unused
  Foundation date conversion extensions are omitted with the decoder product.
- Repository Swift formatting.

NativeDocuments owns the JSON syntax, source index, ownership expectations,
patches and full-candidate comparison. This target has no library product and
performs no I/O. Standard-validator failures are translated into safe document
codes by NativeDocuments; upstream error descriptions are never preview text.
