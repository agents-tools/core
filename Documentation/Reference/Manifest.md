# Agents Manifest Language

`Agents.swift` declares a scope's agent configuration in a statically evaluated
subset of Swift. This reference specifies language version 1.0: the construction
vocabulary, source files and the version directive, the admission grammar and
typing, resource limits, document editing, the evaluated JSON dump, diagnostics
and conformance requirements. `AgentsDescription` supplies the vocabulary and
`AgentsManifest` implements the front end, editor and dump.

[State](../Architecture/State.md#declaration) specifies the subset the state
layer deploys and how declaration writes are published. The
[manifest proposal](../Proposals/AgentsManifest.md) holds the pending targeting,
source linking, component deployment, approval and lock design.

The core repository declares:

```swift
// agents-tools-version: 1.0
import AgentsDescription

let agents = Agents(
  sources: [
    .source(
      name: "agents-tools",
      url: "https://github.com/agents-tools/.github",
      branch: "master",
      subpath: ".agent"
    ),
  ],
  components: [
    .instructions(
      sections: [
        "guide",
        .section(name: "shared/swift-package-route", source: "agents-tools"),
        .section(name: "shared/swift-package-tests", source: "agents-tools"),
      ],
      agents: [.claudeCode, .codex]
    ),
  ]
)
```

## Construction Vocabulary

`AgentsDescription` is a compilable, types-only Swift module. Every manifest
accepted by the static evaluator must type-check against the matching module
with the real Swift compiler, including contextual factories, dictionaries and
literal conversions. Compiler type-checkability is a language 1.0 requirement;
editor integration, including making the module available to SourceKit-LSP, is
outside this specification.

The interface below lists the entire public construction surface. Types conform
to `Sendable` and `Equatable`; factory results are immutable data. Opaque structs
have no public memberwise initializer. Literal-protocol initializers are compiler
entry points, invoked through literals in the manifest grammar. The module uses
the standard library and performs no I/O, registration, resolution or evaluation.
Public names are distinct from top-level standard-library, Foundation and SwiftUI
types so front ends can import those modules together.

Factories and labels follow SwiftPM's authoring shape and the
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
Each component occupies one construction level. Its family-specific fields end
with the same `agents:`, `condition:`, `native:` tail. Payload storage is private.

A **watch subscription** observes changes in a named source independently of
installation. **Install mode** chooses a link to verified cached content (`.link`),
a verified installed copy (`.copy`), or a live local skill link (`.edit`). Edit
mode has no immutable pin or content hash and requires a local source without a
requirement.

### Root, sources and composition

```swift
public enum Agent: Sendable, Equatable {
  case claudeCode, codex, cursor, geminiCLI, openCode
}
public enum Scope: Sendable, Equatable { case project, user }
public enum Platform: Sendable, Equatable { case macOS, linux }
public enum InstallMode: Sendable, Equatable { case link, copy, edit }

public struct Condition: Sendable, Equatable {
  public static func when(
    agents: [Agent]? = nil, scopes: [Scope]? = nil,
    platforms: [Platform]? = nil
  ) -> Condition
}

public struct Agents: Sendable, Equatable {
  public init(
    defaultAgents: [Agent]? = nil, exports: [String] = [], sources: [Source] = [],
    components: [Component] = [], groups: [ComponentGroup] = [],
    uses: [GroupReference] = [], watch: [String] = []
  )
}

public struct Version: Sendable, Comparable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func == (lhs: Version, rhs: Version) -> Bool
  public static func < (lhs: Version, rhs: Version) -> Bool
}

extension Range where Bound == Version {
  public static func upToNextMajor(from version: Version) -> Range<Version>
  public static func upToNextMinor(from version: Version) -> Range<Version>
}

public struct Source: Sendable, Equatable {
  public static func source(
    name: String, url: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, from: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, exact: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, branch: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, revision: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, url: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, from: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, exact: Version, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, branch: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, revision: String, subpath: String? = nil
  ) -> Source
  public static func source(
    name: String, path: String, _ range: Range<Version>, subpath: String? = nil
  ) -> Source
  public static func source(name: String, index: String, subpath: String? = nil) -> Source
}

public struct ComponentGroup: Sendable, Equatable {
  public static func group(
    name: String, components: [Component] = [], uses: [GroupReference] = [],
    condition: Condition? = nil
  ) -> ComponentGroup
}
public struct GroupReference: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func group(name: String, condition: Condition? = nil) -> GroupReference
  public static func group(
    name: String, source: String, condition: Condition? = nil
  ) -> GroupReference
}
```

There is one `let agents = Agents(...)`, optionally annotated `: Agents`.
Other constants contain reusable values. Source names are lexical aliases, not
output paths. A **discovery root** is the source root with its optional safe
`subpath` applied; component and export discovery start there. Core owns source
identity normalization and requirement resolution.

`Version` uses core's semantic-version validation and precedence. A requirement
is a value: `from: x` and `.upToNextMajor(from: x)` denote
`x ..< (major + 1).0.0`; `.upToNextMinor(from: x)` denotes
`x ..< major.(minor + 1).0`. The upper bounds have no prerelease or build metadata,
even when the lower bound has either. The lower bound retains its prerelease and
metadata. All range forms use the resolver's `isInRange(from:to:)`: build metadata
does not affect precedence, and a prerelease tag additionally needs a bound with
a prerelease and the same major/minor/patch triple. Exact requirements retain
core's full normalized-version matching, including build metadata.

Lowering canonicalizes the `Range<Version>` value. An upper bound equal by SemVer
precedence to `(major + 1).0.0` becomes `SourceRequirement.upToNextMajor`; one
equal to `major.(minor + 1).0` becomes `upToNextMinor`; any other upper bound
becomes `SourceRequirement.range(from:to:)`. The two canonical upper bounds
never coincide. Version strings use core's
normalized description; range equality compares bounds by SemVer precedence,
while exact-version equality includes metadata. Invalid versions, non-increasing
ranges and successor overflow are located `manifest.domain` errors. Candidate
successor bounds are computed with checked arithmetic; a literal range does not
fail merely because a nonmatching candidate successor would overflow.

The canonical printer uses `from:` for a major range,
`.upToNextMinor(from:)` for a minor range and adjacent `"lower"..<"upper"` for
other half-open ranges. `exact:`, `branch:` and `revision:` retain their meanings.
Default latest-tag/default-branch selection remains core's rule. Requirements
apply to Git URL sources and Git-backed local paths only. `.source(name:index:)`
represents the well-known index kind and has no Git requirement.
`path:` locates a resource inside a named source or supplies a local source
location; `subpath:` narrows the source's own discovery root.

Source aliases are nonempty, colon-free strings, with `.` reserved for the
declaring package. Escapes preserve otherwise valid string
contents. Two aliases for one normalized source identity in a document are errors.
Group and newly introduced named component identifiers are relative slash-separated
names with no empty, `.` or `..` segment, colon, backslash or control character.
Skill and instruction names retain their domain validators. ChatGPT prompt names
use an arbitrary string-key namespace; they are not filesystem paths.
Names must be unique in their respective namespace.

Git URLs are complete transport URLs, as in SwiftPM. A hand-written shorthand is
admitted with `SourceDeclaration` normalization and a `manifest.domain` warning
whose fix-it is the complete URL: `intranet/team` means `https://intranet/team`,
preserving the host; it is not the CLI's owner/repository shorthand. The editor
and canonical printer emit complete URLs using `SourceDeclaration.gitURL`: add `https://`
to host/repository shorthand, preserve existing schemes and preserve complete
SCP-style URLs such as `user@host:path`. Preserving SCP transport syntax also
preserves its remote path interpretation. Identity normalization lowercases the
host, retains an explicit port, trims path slashes and removes a terminal `.git`;
printing preserves the repository suffix.

`exports: ["review"]` exports the group named `review`; export name and group name
are identical. A differently named wrapper group provides a renamed export.
`watch` is a unique array of declared source aliases, with no recipient or condition. Observed
baselines remain in `agents.watch`, not the manifest. Neither exports nor unused
groups cause deployment or subscriptions in a consumer.

### Literal values and supporting types

```swift
public struct SkillSelection: Sendable, Equatable, ExpressibleByArrayLiteral {
  public static var all: SkillSelection { get }
  public init(arrayLiteral elements: String...)
}
public struct SkillOverride: Sendable, Equatable {
  public static func skill(name: String, mode: InstallMode? = nil, agents: [Agent]? = nil) -> SkillOverride
}
public struct SectionReference: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func section(
    name: String, source: String? = nil, condition: Condition? = nil
  ) -> SectionReference
}
public struct ChatGPTPrompt: Sendable, Equatable {
  public static func prompt(
    name: String, sections: [SectionReference], append: String? = nil,
    condition: Condition? = nil
  ) -> ChatGPTPrompt
}
public struct Resource: Sendable, Equatable {
  public static func path(_ path: String, source: String? = nil) -> Resource
}
public struct PromptContent: Sendable, Equatable, ExpressibleByStringLiteral {
  public init(stringLiteral value: String)
  public static func file(_ path: String, source: String? = nil) -> PromptContent
}
public enum RuntimeValue: Sendable, Equatable, ExpressibleByStringLiteral {
  case literal(String)
  case environment(String)
  case secret(String)
  public init(stringLiteral value: String)
}
public struct ExecutableInvocation: Sendable, Equatable {
  public static func executable(
    _ executable: String, arguments: [String] = [],
    environment: [String: RuntimeValue] = [:], workingDirectory: Resource? = nil
  ) -> ExecutableInvocation
}
public indirect enum ConfigurationValue: Sendable, Equatable,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  case string(String)
  case integer(Int)
  case decimal(String)
  case boolean(Bool)
  case null
  case array([ConfigurationValue])
  case object([String: ConfigurationValue])
  public init(stringLiteral value: String)
  public init(integerLiteral value: Int)
  public init(booleanLiteral value: Bool)
  public init(nilLiteral: ())
  public init(arrayLiteral elements: ConfigurationValue...)
  public init(dictionaryLiteral elements: (String, ConfigurationValue)...)
}
public typealias NativeConfiguration = [String: [String: ConfigurationValue]]

public struct MCPTransport: Sendable, Equatable {
  public static func stdio(
    _ executable: String, arguments: [String] = [],
    environment: [String: RuntimeValue] = [:], workingDirectory: Resource? = nil
  ) -> MCPTransport
  public static func streamableHTTP(
    url: String, headers: [String: RuntimeValue] = [:]
  ) -> MCPTransport
  public static func sse(url: String, headers: [String: RuntimeValue] = [:]) -> MCPTransport
}
public enum HookEvent: Sendable, Equatable {
  case beforeTool, afterTool, sessionStart, sessionEnd
  case native(String)
}
public struct PromptParameter: Sendable, Equatable {
  public static func parameter(name: String, description: String, defaultValue: String? = nil) -> PromptParameter
}
public enum PermissionOperation: Sendable, Equatable {
  case read, write, execute
  case tool(String)
}
public struct PermissionRule: Sendable, Equatable {
  public static func allow(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
  public static func ask(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
  public static func deny(_ operation: PermissionOperation, _ pattern: String) -> PermissionRule
}
public enum IgnorePurpose: Sendable, Equatable { case context, indexing }
public enum PluginMode: Sendable, Equatable { case native, components }
public enum ComponentKind: Sendable, Equatable {
  case skills, instructions, mcpServer, hook, subagent, command
  case lspServer, permissions, ignore, plugin
}
public enum ComponentReference: Sendable, Equatable {
  case skill(name: String)
  case instruction(name: String)
  case mcpServer(name: String)
  case hook(name: String)
  case subagent(name: String)
  case command(name: String)
  case lspServer(name: String)
  case permissions(name: String)
  case ignore(name: String)
  case plugin(name: String)
}
```

Literal conversions are closed and contextual. `PromptContent`,
`SectionReference`, `GroupReference`, `Version` and `RuntimeValue` accept string literals; `SkillSelection`
accepts string array literals. `ConfigurationValue` accepts strings, signed
64-bit integer literals, booleans, `nil`, arrays and string-keyed dictionaries.
Decimals use `.decimal("1.25")`, with finite JSON-number text; floating-point
literals are outside the grammar. Native configuration is a dictionary keyed
by registry schema ID, with a string-keyed configuration object as each value.
Duplicate decoded keys, compared using Swift String equality including canonical
Unicode equivalence, are domain errors at every dictionary level, even if their
values are equal. There is no user-defined literal conformance or conversion
from an already-typed `String`, `[String]` or dictionary to a wrapper type.

A bare section string names the declaring package's own instruction section;
`.section(name: "engineering", source: "rules")` names a source section, and
source `"."` names an own section. A root user-scope declaration uses named
instruction sources. Ordered sections, Markdown rendering and **front matter**
(the structured metadata preceding a content file's body) retain their
instruction-domain semantics. ChatGPT is a named prompt rendering destination,
not an `Agent`. Prompt `append` paths are relative to the project root in project
scope and to the runtime home in user scope.

Omitted mode inherits the selection mode, then `.link`. Link and copy modes
preserve independent item pins. Omitted skill selection means all discovered
members; `[]` selects none. Exclusions win; overrides do not re-add excluded items.
An override outside an explicit selection is a `manifest.domain` error.
An all-member selection can retain overrides for members not yet discovered.

`path` locates a resource inside the declaring package or a named source
discovery root; `subpath` narrows the source's own root before discovery. Resource
paths are safe relative paths. Project package roots are project directories; a
user package root is its user-state directory. Absolute and home-relative
resource paths, traversal and escaping symlinks are errors. Source locations keep
their absolute and home-relative path support. Executables are fixed program
names or package-relative executable paths, with separate argument arrays.
Environment and secret bindings are symbolic: reading and dumping never resolve
their values.

### Component factories

```swift
public struct Component: Sendable, Equatable {
  public static func skills(
    source: String, select: SkillSelection = .all, exclude: [String] = [],
    mode: InstallMode? = nil, overrides: [SkillOverride] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func instructions(
    sections: [SectionReference] = [], chatGPT: [ChatGPTPrompt] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func mcpServer(
    name: String, transport: MCPTransport,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func hook(
    name: String, event: HookEvent, run: ExecutableInvocation,
    matcher: String? = nil, timeoutSeconds: Int? = nil,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func subagent(
    name: String, description: String, prompt: PromptContent,
    model: String? = nil, tools: [String]? = nil,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func command(
    name: String, description: String, prompt: PromptContent,
    parameters: [PromptParameter] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func lspServer(
    name: String, run: ExecutableInvocation, languages: [String: String],
    initializationOptions: [String: ConfigurationValue] = [:],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func permissions(
    name: String, rules: [PermissionRule],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func ignore(
    name: String, patterns: [String], purpose: IgnorePurpose = .context,
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
  public static func plugin(
    name: String, path: String, source: String,
    mode: PluginMode = .components, select: [ComponentKind]? = nil,
    exclude: [ComponentReference] = [],
    agents: [Agent]? = nil, condition: Condition? = nil,
    native: NativeConfiguration = [:]
  ) -> Component
}
```

### Domain rules

Domain validation runs offline over every evaluated value, including unused
constants, inactive values and unused groups. A failure is a located
`manifest.domain` error unless the table names another code.

| Value | Checks |
| --- | --- |
| Sources | Aliases are unique, nonempty, colon-free and not `.`. Git URLs and index URLs must yield a transport identity; a local path is nonempty and has no NUL. `branch:` and `revision:` values are nonempty, have no NUL and do not start with `-`. `subpath` is a safe relative path. Two aliases with one normalized identity are an error; a Git shorthand is a warning with the complete-URL fix-it. |
| Root fields | `defaultAgents` and each condition dimension have no duplicate members. Group names, `exports` and `watch` are unique. An export names a local group (`manifest.group.missing`); a watch entry names a declared alias. |
| Names | Group, named-component and typed component-reference names are relative names as defined above. Skill and instruction section names use their domain validators. Prompt names are unique within a component; prompt parameter names are nonempty and contain no `}`, `:` or NUL. |
| Skills | The source is a declared alias or `.`. Explicit selections and exclusions are valid, unique skill names; override names are unique and lie inside an explicit selection. Edit mode, on the selection or an override, requires a local source without a requirement. |
| Resources | Resource, prompt file, `append` and `subpath` paths are safe relative paths. An executable containing `/` or starting with `~` is also a resource path. |
| Transports | Streamable HTTP and SSE URLs are HTTP(S) URLs with a host and no credentials or fragment. |
| Hooks | `timeoutSeconds` is positive. A `.native` event has exactly one explicit recipient. |
| Commands | Every `${input:name}` token in a literal prompt names a declared parameter; `$${input:` escapes a token. |
| LSP servers | Each `languages` key is a dot-prefixed file extension without `/`; each language ID is nonempty. |
| Permissions | Read and write patterns are safe relative paths. |
| Plugins | The source is declared and `path` is a safe relative path. Native mode has exactly one explicit recipient and no selection or exclusions. Selections and exclusions have no duplicates. |
| Configuration values | `.decimal` text is a finite JSON number. Duplicate decoded keys at any dictionary level are `manifest.dictionary.duplicateKey`. |

Recipient capabilities, native schema registration, executable approval and
adapter rules are deployment checks; the
[manifest proposal](../Proposals/AgentsManifest.md#component-deployment) specifies
them.

## Source Files and Versions

Project source is `.agent/Agents.swift` relative to the explicit project root;
user source is `~/.agents/Agents.swift` relative to core's runtime home. Each
scope's lock is the adjacent `agents.resolved`. There is no ancestor search or
automatic user/project merge. An absent file is an absent declaration;
[State](../Architecture/State.md#absent-declaration) defines how that combines
with existing lock or watch state.

The first line is exactly `// agents-tools-version: 1.0`, at byte zero after an
optional UTF-8 BOM, terminated by LF, CRLF or EOF. General version syntax is
`// agents-tools-version: MAJOR.MINOR`, with the shown spaces, decimal components
without leading zeroes except `0`, and no patch, suffix or trailing whitespace.
A missing, malformed, duplicate or unsupported directive has its own diagnostic.
Directive recognition is lexical: a directive-shaped line comment outside a
string is a duplicate; text inside a string literal is ordinary content.
A 1.0 reader accepts exactly `1.0`. A future reader explicitly declares its support
set. Newer unsupported versions request an upgrade; older unsupported versions
request a supported converter. Language, package, adapter, lock and dump versions
are independent. Editing preserves the BOM and newline style; the canonical
printer emits UTF-8 without a BOM.

## Static Grammar

Exactly one unqualified `import AgentsDescription` precedes top-level initialized,
single-binding `let` declarations. Names use the identifier grammar below, are
unique and cannot shadow vocabulary types. Constants bind in textual order; references to later constants
or themselves fail. There are no modifiers, attributes, wrappers or semicolons.
Every declaration, including unused constants and inactive branches, is checked.
Group-name references are resolved separately and may refer forward.

| Accepted syntax | Rule |
| --- | --- |
| `SourceFileSyntax`, `ImportDeclSyntax`, `VariableDeclSyntax` | The file structure above, with one identifier-pattern binding and initializer per declaration. |
| `StringLiteralExprSyntax` | Single-line and multiline literals from the closed lexical grammar below, with Swift decoding and no interpolation. Contextual `GroupReference` literals denote local groups; this is a type conversion, not an extra grammar production. |
| Integer, Boolean and nil literals | Decimal signed-64 integers with underscore separators, Bool and contextual nil. One unary minus is accepted only immediately adjacent to a decimal integer literal, with no intervening trivia. Other bases, floating literals and other numeric operators fail admission. |
| `ArrayExprSyntax` | Homogeneous arrays or a contextual, whitelisted array-literal conversion. Trailing commas are allowed. Empty literals require contextual type. |
| `DictionaryExprSyntax` | String-literal keys, homogeneous contextual values, or a contextual configuration object. `[:]` is an empty dictionary. Keys are decoded before duplicate detection; key references/interpolation are rejected. |
| `DeclReferenceExprSyntax` | A preceding constant, a vocabulary type as a member/call base, or the permitted operator. |
| Sequence/folded infix expressions | Only left-associative array `+` with exact `[T]` operands, at most 32 terms per additive chain. No concatenation of selections or configuration values, dictionary merging or string concatenation. A single half-open version range is admitted only in the source requirement position defined below; other operators are rejected. |
| `TupleExprSyntax` | One unlabeled expression in parentheses, not tuple values. |
| `MemberAccessExprSyntax` | Listed static factories, static `.all`, and enum cases, qualified or contextual. No instance-property access, subscripts or optional chaining. |
| `FunctionCallExprSyntax` | `Agents(...)`, listed static factories and associated cases, with exact labels and order. Literal-protocol entry points are reached only through literals. No arbitrary functions or trailing closures. |
| Type annotations | `String`, `Int`, `Bool`, named vocabulary types/aliases, `[T]` and `[String: T]`. No explicit Optional annotations, user aliases, qualified/generic/existential/function/metatype syntax. |

Grammar admission precedes SwiftParser and the iterative tree check precedes all
recursive SwiftSyntax processing. The normative productions below and the syntax
node table describe the same constructs, subject to the byte, token, chain and
depth limits below. These limits apply even to unused or inactive
expressions. Parser recovery, missing tokens and unexpected syntax are errors.
Tokens inside accepted nodes are admitted only in the roles above. Constructors create data;
they never invoke Swift compiler code while evaluating a manifest.

### Type inference and literal conversions

An annotation or parameter type supplies context inward. Otherwise literals,
qualified calls and references synthesize types outward. Without context, a
string is `String`, an integer is `Int`, and a boolean is `Bool`. Arrays infer
from the first element; dictionaries infer from the first value and require all
other values to agree. Empty collections, nil and a leading shorthand member
cannot infer a type alone. Dictionary keys are always strings.

Optional parameter types remain part of the construction API: their context
admits `nil` or injection of a value of the wrapped type. Source annotations use
the non-Optional forms in the grammar; `T?` and `Optional<T>` fail grammar admission.
This does not change the module's public Optional signatures or compiler typing.

In contextual vocabulary types, only the literal conformances declared above
apply. Nested configuration literals propagate `ConfigurationValue` context to
every child. For an Optional parameter with wrapped type `T`, nil means absence;
non-nil values may receive `T` context and Optional injection. For non-Optional `ConfigurationValue`, nil means
configuration null. Signed integer literal conversion follows Swift's literal
semantics and must fit the declared literal type. `.decimal(...)` remains explicit.
No arbitrary user protocol dispatch or conversion of pre-existing typed values
is allowed. In particular, a `String` constant is not implicitly a `PromptContent`
or a `SectionReference`, `GroupReference` or `Version`, and a `[String]` constant is not a `SkillSelection`.

For array `+`, context propagates to both operands when present; otherwise infer
the left array and use its element type for the right array. An expression of
`SkillSelection` or `ConfigurationValue` type is not a Swift array. Constants
must be typed where declared, not inferred backward from later uses. A standalone
component is `let reviewer: Component = .subagent(...)` or a fully qualified
factory call. The evaluator's accepted language is a subset of real Swift typing,
not an alternative type system.

### Normative admission grammar

`AgentsManifest` owns a strict lexer and a deterministic recognizer for these
productions. No byte reaches SwiftParser until the complete input snapshot passes
recognition. SwiftParser supplies the lossless tree for editing and diagnostics;
it does not decide which source grammar is admitted. The recognizer does not
resolve constants or evaluate constructors. The subsequent type/domain checks
restrict identifiers and calls to the vocabulary and rules above.

The grammar uses `?` for optional, `*` for repetition and `|` for alternatives;
quoted punctuation denotes source tokens. Trivia may separate tokens except at
explicitly contiguous spellings. `newline` means at least one LF, CRLF or CR in
the separating trivia. The version directive is checked as specified above using
the same lexer's comment/string boundaries, before syntax is handed to SwiftParser.

```ebnf
document       = "import" "AgentsDescription" newline declaration
                 (newline declaration)* EOF ;
declaration    = "let" bareName (":" type)? "=" expression ;
type           = typeName | "[" type "]" | "[" "String" ":" type "]" ;
expression     = primary ("+" primary)* ;
primary        = string | integer | "-" integer | "true" | "false" | "nil"
               | namedValue | array | dictionary | "(" expression ")" ;
namedValue     = sourceCall | callee ("(" arguments? ")")? ;
callee         = bareName | bareName "." name | "." name ;
arguments      = argument ("," argument)* ;
argument       = (name ":")? expression ;
sourceCall     = (".source" | "Source.source") "(" "name" ":" expression ","
                 (("url" | "path") ":" expression
                    ("," requirement)? | "index" ":" expression)
                 ("," "subpath" ":" expression)? ")" ;
requirement    = ("from" | "exact" | "branch" | "revision") ":" expression
               | versionRange | rangeFactory ;
versionRange   = string "..<" string ;
rangeFactory   = (".upToNextMajor" | ".upToNextMinor")
                 "(" "from" ":" expression ")" ;
array          = "[" (expression ("," expression)* ","?)? "]" ;
dictionary     = "[" ":" "]"
               | "[" string ":" expression
                 ("," string ":" expression)* ","? "]" ;
```

`typeName` is exactly `String`, `Int`, `Bool`, or a public vocabulary type/alias
listed under Construction vocabulary. Type existence is checked during recognition. `sourceCall` takes
precedence over the general call production for `.source` and `Source.source`; those spellings cannot bypass it through `callee`. The
`.upToNextMajor` and `.upToNextMinor` callees are reserved to `rangeFactory`,
including its required argument list; other positions fail recognition.
`versionRange` is not a general expression: no grouping, constants, chaining or
other operands are admitted at its position. A range factory is contextual to
this same unlabeled requirement slot. Its argument receives `Version` context;
`from:` and `exact:` on the source also receive `Version` context. The subsequent
checker enforces version typing and domain validation. `callee` is a
syntactic spelling; subsequent vocabulary checking rejects unlisted functions,
instance members, literal-protocol entry points and invalid factory labels.
There is no postfix loop: a callee has at most one member operation and one call,
for a maximum grammatical chain of **2**. The independent postfix-operation
counter has a ceiling of **4** per primary; budget headroom admits no additional
production. No operation attaches to a call result, grouped
expression or subscript. The leading shorthand dot counts as one operation.
These are exactly the construction forms needed by the vocabulary. Parentheses
contain one expression; calls have no trailing comma; collections may have one.
The additive production has at most **32 terms**, with later type checking
requiring array operands. A version range has exactly two literal operands.
No assignment expression or prefix-keyword production exists. An identifier after a completed expression is a syntax error, not an
implicit prefix, argument or declaration.

The lexical grammar is closed:

- An identifier has ASCII head `[A-Za-z_]` and continuation `[A-Za-z_0-9]*`.
  Backticks, `$` names and non-ASCII identifiers are excluded; Unicode remains
  available in string values, including all domain names and paths. `name` excludes
  the reserved spellings listed below. `bareName` additionally excludes `await`,
  `copy`, `consume`, `each` and `unsafe`; those contextual spellings may occur as
  argument labels or member names, including `.copy`. They cannot introduce a
  prefix production or a bare binding/reference/callee in language 1.0.
- `integer` is `[0-9][0-9_]*`. The optional minus is a separate token immediately
  adjacent to its digits and only in the shown primary production. Its preceding
  source character must be ASCII whitespace (space, tab, CR or LF), `(`, `[`, `,`
  or `:`; an adjacent operator or comment terminator cannot precede the sign.
  Range checking follows during typing. There are no floating-point, exponent or
  radix literals;
  decimal configuration values use `.decimal("1.25")`.
- `string` is an ordinary double-quoted single-line literal or a triple-quoted
  multiline literal. Both allow exactly `\0`, `\\`, `\t`, `\n`, `\r`, `\"`, `\'`
  and `\u{H}` escapes, where `H` is one to eight ASCII hex digits naming a Unicode
  scalar (not a surrogate and at most `10FFFF`). Interpolation and escaped newline
  continuation are excluded. A single-line literal contains no unescaped CR/LF.
  A multiline opener is followed immediately by LF, CRLF or CR; its closing
  delimiter is preceded on its line only by spaces. A content line is either
  empty (zero characters before its newline) or starts with the closing delimiter's
  exact space indentation prefix, which Swift decoding removes. Additional leading
  spaces remain content. Whitespace-only lines are nonempty and must carry the
  full prefix. A tab anywhere in a content line's leading whitespace or in the
  closing delimiter's indentation is a syntax error; tabs after the first
  non-whitespace content character remain literal content. These rules apply
  identically to LF, CRLF and CR lines. Unescaped single/double quote runs are
  multiline content; the first
  unescaped triple quote closes it. Unescaped control scalars below U+0020 other
  than tab and multiline CR/LF are rejected. Raw strings do not exist: `#` outside
  string/comment content always fails recognition.
- Trivia is ASCII space, tab, LF, CRLF or CR, an optional BOM at byte zero, `//`
  comments through the next CR/LF or EOF, and `/* ... */` comments with at most
  **20** nested levels. The lexer validates UTF-8 throughout the snapshot. Strings
  and comments are opaque to expression counters. No other whitespace or comment
  form is admitted.
- Source punctuation is `( ) [ ] , : . = + ..<` and the adjacent numeric sign `-`,
  only in the roles in the productions. Callee member spellings contain no trivia
  around their dot; the call opener immediately follows its callee. Both `=` and
  binary `+` require at least one ASCII whitespace character (space, tab, CR or LF)
  immediately on each side. Comments do not substitute for whitespace: every
  comment in an operator-to-operand gap must itself have whitespace immediately
  before and after it. Thus `value /* note */ = -1` is admitted, but `value=0`,
  `value= 0`, `value=-1`, `a+b` and `a/* note */ + b` fail recognition. A located
  `manifest.syntax` diagnostic names the canonical spelling, such as
  `let value = -1` or `left + right`. These adjacency rules make
  Swift operator/member tokenization unambiguous. The single `..<` token is
  admitted only by `versionRange`, with either no whitespace on both sides or
  at least one ASCII whitespace character immediately on both sides. Comments
  in either operand gap must themselves be surrounded by whitespace, as for `+`.
  The canonical operator spelling is `"1.2.0"..<"1.8.0"`; an asymmetric boundary
  reports that spelling in a located `manifest.syntax` diagnostic. A lone `<`
  or `>` is never admitted. Other operators, generic angle
  brackets, braces, attributes, directives, macros and regex literals fail at
  recognition. There is no fallback to SwiftParser recovery.

The exact reserved identifier spellings are:

```text
_ Any Self as associatedtype break case catch class continue default defer deinit
do else enum extension fallthrough false fileprivate for func guard if import in
init inout internal is let nil open operator precedencegroup private protocol public
repeat rethrows return self static struct subscript super switch throw throws true
try typealias var where while
```

The lexer consumes each byte a bounded number of times, without backtracking or
unbounded lookahead. The parser uses at most two tokens of lookahead to distinguish
argument labels and dictionary entries, bounded delimiter frames for nested
productions, and loops for siblings and additive terms. It never speculatively
parses a whole expression and rewinds. Its work, storage, literal validation and
located-diagnostic construction are linear in bounded input size. A failure ends
recognition with a located `manifest.syntax` or `manifest.limit`; SwiftParser is
not called. Accepted grammar structure and spans are retained for differential
validation, independently of the later semantic IR.

## Resource Limits

Admission reads at most 2,097,153 bytes, rejecting the extra byte before decoding,
lexing or parsing; it never allocates an unbounded file buffer. The exact admitted
snapshot is subsequently parsed. The recognizer permits at most 100,000 non-trivia
tokens; the minus and integer count separately, and `..<` counts as one token
plus its two string-literal operands. Range factories count as ordinary calls.
Version values charge their decoded bytes and nodes; range costs include both
endpoints before canonical lowering or serialization. It additionally reserves syntax
storage conservatively as **16 + 4 × (tokens + literal breaks + literal escapes)**,
capped at 100,000 nodes before SwiftParser is invoked. A literal break is each
CR or LF byte inside a string (CRLF counts twice); a literal escape is each
backslash byte inside a string, including escaped backslashes. These extra units
cover the parser's segmentation of multiline/escaped literals. The grammar-derived
reservation covers file and wrapper nodes as well as tokens; the independent
post-parse guard verifies actual counts.
A parser dependency change must revalidate the reservation against every grammar
production. The reservation is a language budget even when an individual input's
actual tree would be smaller; generated source passes the same admission.

Every open `[` or `(` increments a grammar counter before entering the enclosed
production, including type annotations. Square depth above **8** or combined
depth above **20** is `manifest.limit` at the first excess opener. Block-comment
depth above 20, a thirty-third additive term or an excess token/storage reservation
likewise fails before parsing. All other missing, misplaced or unsupported tokens
are `manifest.syntax` at the expected production's location (EOF for missing
input). Unbalanced openers remain counted until rejection; neither trivia nor
parenthesized subexpressions can bypass the counters. No production permits more
than two postfix operations or more than one numeric sign. These grammar bounds
apply equally to unused constants and inactive components.

Immediately after parsing, an **iterative, non-recursive** walk checks all syntax
nodes, including collections, tokens, missing nodes and unexpected nodes, in the
all-nodes view. The root has depth 1; depth above **128** or more than **100,000**
nodes is `manifest.limit`. Reserve stack/node budget before enqueueing children;
compute failure offsets from cached byte lengths during the walk. Do not call
recursive visitors, `hasError`, diagnostic generation, tree descriptions, source
mapping, equality or evaluation before this guard succeeds. The same rule applies
to transformed/folded trees: build/check them iteratively before recursive use.
The tree ceiling is independent of source delimiter depth and leaves room for
SwiftSyntax's wrapper nodes. Evaluation retains its separate frame/work limits.

No manifest input within the byte limit may crash or hang the hosting process,
including the GUI. Invalid and over-budget input must end in a bounded diagnostic
without writes or partial IR publication. This is a required implementation and
release invariant, not a conclusion inferred from `maximumNestingLevel` or a
finite set of passing examples. Parser construction, error inspection, tree
lifetime/teardown and every consumer of syntax are included in the invariant.

The square-bracket ceiling is **8**, independently of the general delimiter
ceiling of **20**. The complete manifest examples in this reference and in the
manifest proposal reach depth 3. Fixed family fields, excluding recursive
configuration values and arbitrary nested array constants, reach depth 5: root
groups, components, ChatGPT prompts, sections, then a section condition's
recipient array.
Eight leaves three levels of syntax-depth margin over that fixed structure.
`ConfigurationValue` is recursive, so its vocabulary has no intrinsic finite
nesting maximum; its expanded values remain limited to depth 64. Named constants
allow deeper configuration values to be assembled without deep source nesting,
subject to all expansion budgets. This separates authoring depth from value depth
and caps square-bracket ambiguity before parser recovery. The parser's own
nesting option remains defense in depth, not a parse-time bound.

The evaluator may store immutable values as a DAG, but all limits are measured
as if each reference were expanded by value. Each value carries a checked cost
summary: expanded node count, decoded string/key bytes, canonical encoded byte
count, maximum depth and source-origin count. For a container, costs are its own
cost plus the sum of each child's costs **for every occurrence**. Reusing a
constant twice adds its full cost twice, including all descendants. An alias
inherits the referenced cost; memoization does not discount expansion.

Compute costs bottom-up with checked, saturating arithmetic capped at the limit
plus one. Before concatenation, reference insertion, group expansion or any output
allocation, combine the summaries and reject an oversized result. No descendant
walk, copying, formatting, map expansion or equality comparison occurs first.
This rejects exponential reuse such as repeated `array([previous, previous])`
while that value is constructed, even when its underlying storage is small.
Every constant must fit individually; totals count every top-level definition
and every root occurrence, including inactive and unused values.

Encoded-size summaries include repeated dictionary keys, string escaping,
punctuation, indentation and trailing newline. Before writing a dump or generated
source, reserve its complete bounded size from those summaries. When formatting
context changes indentation, use a checked worst-case bound or recompute the
summary over the bounded structure before emitting bytes. Locations and provenance
are separately budgeted and included in the final dump's size reservation.

| Resource | Language 1.0 bound |
| --- | --- |
| Input | 2,097,152 UTF-8 bytes per manifest, enforced by bounded reading before grammar admission, decoding or parsing; invalid UTF-8 fails. |
| Admission | Linear lexer and grammar recognizer; 100,000 tokens; syntax reservation `16 + 4 × (tokens + literal breaks + literal escapes) ≤ 100,000`; square depth 8; combined square/parenthesis depth 20; comment depth 20; postfix-operation budget 4 (the grammar uses at most 2); one adjacent numeric sign; additive chain 32 terms. Failures reject before SwiftParser. |
| Parser/tree | `maximumNestingLevel: 20` in every build configuration. Iterative guard: depth 128 (root 1), 100,000 syntax nodes including tokens and excluding trivia, before any recursive processing. |
| Evaluator | 64 active expression/reference frames; 100,000 work steps per document. Every visited expression, lookup, produced node and concatenation element costs a step. |
| Expanded values | 100,000 nodes and 16,777,216 decoded string/key bytes across the document's values, charged by occurrence, with 10,000 entries per array/dictionary and maximum expanded value depth 64, including referenced descendants. |
| Domain validation | 100,000 traversal steps per document. |
| Local groups | 64 active local group references while checking for reference cycles. |
| Source maps | 100,000 location records, 1,000,000 total origin spans and 16,777,216 encoded bytes; repeated origins count repeatedly. Reserve before expanding a reference's map. |
| Output | 33,554,432 bytes for the entire dump including locations/diagnostics; generated manifest source still obeys the 2,097,152-byte input limit. |
| Comparison/edit batch | 200,000 expanded node-pair visits per full comparison; 1,000,000 aggregate steps and 100 requests per edit batch. Operand cost summaries are checked before comparison starts. |

A work budget is charged before executing a step; exhaustion is a diagnostic,
not an invitation to return a truncated model. Comparisons can use identity or
memoization only after verifying expanded operand bounds. Diagnostics and JSON
escaping are bounded operations. Source download and extraction limits belong to
core's loader. Cancellation is separate from language semantics. Fuzzing and adversarial reuse tests cover every bounded
consumer of values, not just the parser.

## Group References

Group references are symbolic in the front end: no group is expanded and no
source manifest is read. The front end checks the local graph only:

- group names are unique, including unused groups;
- every export and every unqualified `GroupReference` names a local group, or
  fails with `manifest.group.missing`;
- following unqualified references from every group, a reference back into the
  active chain fails with `manifest.group.cycle`, whose related spans list the
  chain; a diamond is not a cycle;
- an active chain longer than the local group budget is `manifest.limit`.

A qualified `.group(name:source:)` reference names a declared source alias; its
group is resolved only by source linking. Group references may refer forward to
groups declared later in the same document.

## Document Editing

`AgentsManifest.DeclarationDocument` owns the original bytes, syntax, declaration
IR, source map, diagnostics, editability and the original byte digest. Domain
edits use the same vocabulary names as authored values; lowering converts them to
core IR. Snapshot node handles are separate from persistent component identities.

```swift
public struct DeclarationDocument: Sendable {
  public init(bytes: [UInt8], identity: DocumentIdentity) throws
  public let declaration: DeclarationIR
  public let diagnostics: [ManifestDiagnostic]
  public let sourceMap: DeclarationSourceMap
  public let digest: String
  public var bytes: [UInt8] { get }
  public func node(at pointer: String) -> NodeID?
  public func constant(named name: String) -> NodeID?
  public func uses(ofConstant name: String) -> [NodeID]
  public func editability(of node: NodeID) -> Editability
  public func preparing(_ edits: [ManifestEdit]) throws -> DocumentChange
}
public enum Editability: Sendable, Equatable {
  case direct
  case sharedConstant(uses: [NodeID])
  case readOnly(reason: String)
}
public enum ManifestEdit: Sendable {
  case setDefaultAgents([Agent]?)
  case upsertSource(Source)
  case removeSource(alias: String)
  case insertComponent(Component, into: ContainerID, at: InsertionPosition)
  case replaceComponent(NodeID, with: Component)
  case removeComponent(NodeID)
  case moveComponent(NodeID, into: ContainerID, at: InsertionPosition)
  case setSkillSelection(NodeID, SkillSelection)
  case upsertSkillOverride(NodeID, SkillOverride)
  case removeSkillOverride(NodeID, name: String)
  case insertSection(SectionReference, into: NodeID, at: InsertionPosition)
  case removeSection(NodeID)
  case moveSection(NodeID, at: InsertionPosition)
  case upsertPrompt(NodeID, ChatGPTPrompt)
  case removePrompt(NodeID, name: String)
  case upsertGroup(ComponentGroup)
  case removeGroup(name: String)
  case insertGroupReference(GroupReference, into: ContainerID, at: InsertionPosition)
  case removeGroupReference(NodeID)
  case setExports([String])
  case setWatch([String])
  case setDictionaryEntry(NodeID, key: String, value: StaticValue)
  case removeDictionaryEntry(NodeID, key: String)
  case replaceConstant(NodeID, with: StaticValue, acceptingUses: [NodeID])
}
```

`NodeID` is an opaque handle bound to the document digest; `node(at:)` takes a
JSON Pointer into the lowered declaration, and `constant(named:)` and
`uses(ofConstant:)` take Swift identifiers. `ContainerID` addresses the root or a
group. `InsertionPosition` is `.first`, `.last`, `.before(NodeID)` or
`.after(NodeID)`. `StaticValue` is the bounded checked algebra of literals,
collections and vocabulary values, not raw Swift text. Dictionary value edits
must match the target's inferred value type. Whole-component replacement covers
recipients, conditions and all family-specific fields.

The document applies requests in order to construct the expected complete IR,
checks their complete impact and budgets, and produces disjoint byte patches.
`DocumentChange` contains the original digest, patches, resulting bytes and
digest, expected declaration, impacted references, diagnostics and semantic
delta. Only the document layer constructs it, and it publishes nothing. Scope
declarations are written only through the state layer's
[declaration writes](../Architecture/State.md#declaration-writes); front ends
never save source independently.

### Editability

`editability(of:)` reports exactly what the editor accepts:

| Construct | Editability |
| --- | --- |
| Element of a direct array literal | `direct`. Insert, remove and move identifiable elements, preserving order. Removing an element of a single-line array also removes its separating space. |
| Entry of a direct dictionary literal, including a literal configuration value | `direct`. Set or remove a decoded key's value or entry; unrelated entries keep their order and comments. |
| Signature argument of a direct root, group or component construction, present or omitted | `direct`. Replace the exact value range and retain outer trivia, insert a missing argument in signature order, or remove an unambiguous argument. |
| Member value, such as `.copy` or `.codex` | `direct`. Replaced in place. |
| Constant definition | `sharedConstant`, listing every direct and transitive use. Only `replaceConstant` changes it, accepting the complete impacted reference set. |
| Constant reference or assembled value | `readOnly`; replace the definition explicitly. |
| Concatenation | `readOnly`; it has no independent source range. |
| Normalized field, such as a source requirement or a component kind | `readOnly`; replace the containing construction. |
| Any value inside a read-only value | `readOnly`. |
| Stale handle | `readOnly`; preparing an edit with it fails with `manifest.edit.stale`. |

Ambiguous trivia or separators make an edit fail with `manifest.edit.readOnly`,
with a span and reason; there is no regeneration fallback. Removing referenced
sources or groups requires a complete batch that repairs the references. Stale
handles, overlaps, incomplete impact and mismatched results have separate
`manifest.edit.stale`, `.overlap`, `.impact` and `.mismatch` diagnostics.

### Comment ownership

Comments follow SwiftSyntax trivia ownership:

1. Standalone comments immediately above a node with no separating blank line
   belong to that node; a dictionary key and value form one entry node.
2. Comments beginning on a node's or its comma's line belong to that preceding
   node, including multiline block comments.
3. Comments inside an expression or between it and its comma belong to it.
4. Comments separated from the next node by a blank line belong to the container.
   The preamble and version directive belong to the file.
5. Delete/move operations carry owned comments. Value replacement preserves outer
   comments; whole-node replacement refuses if internal comments cannot be mapped
   to retained fields. Unowned comments remain in place.
6. Empty containers become `[]` or `[:]` only when their interiors are whitespace.
   Container comments survive; ambiguous mixed layouts or comment-only insertion
   sites are read-only. An argument list holding only comments is read-only.

### New text

New nodes use the shortest canonical type-correct spelling. `Agents(...)` is the
only ordinary initializer in manifest expressions; nested values use leading-dot
factories. Sources use `.source(name:url:)`, `.source(name:path:)` or
`.source(name:index:)`, and references use `source:`. Requirement values use the
canonical requirement spelling defined under Construction vocabulary. Literal
conformances provide strings for prompts, own sections, local group references
and versions, array literals for explicit skill selections, and JSON-style
configuration literals. Dictionary literals and direct factories construct the
remaining values. Existing unmodified expressions keep their spelling.

New text uses the container's consistent indentation, newline and comma style;
absent evidence, it uses two spaces, LF and trailing commas in multiline
collections. Argument order follows signatures; root insertion order is
`defaultAgents`, `exports`, `sources`, `components`, `groups`, `uses`, `watch`.
`upsertSource(Source)` preserves the complete requirement value. Fresh node
layout follows the canonical printer; existing surrounding style takes
precedence. Inserting the first argument into an empty argument list, such as
`Agents()`, uses the canonical call layout, so a collection or nested call
argument starts a multiline list. Conflicting local style is an editability
diagnostic, not permission to reformat the file.

The editor and canonical printer emit one ASCII space on each side of `=` and
`+`, with adjacent sign/digits for negative integers: `let value = -1`. A value
replacement re-checks both joins with the unchanged source, including neighboring
comments, against the lexical rules before it becomes a patch. For example,
replacing `0` in `[/* note */0]` emits ` -1` inside that value's replacement range,
producing `[/* note */ -1]` while preserving all bytes outside the range. The
editor never joins a sign to `=` or to a comment terminator. A source that already
fails recognition, such as `let value=0`, cannot receive a domain edit. If a safe
boundary cannot be represented in the authorized patch range, preparation fails
with an editability diagnostic. The complete candidate passes recognition again
before SwiftParser is invoked; a failed check publishes no patch or source bytes.

Range replacement re-checks both operator/operand boundaries and the containing
source requirement slot. A complete replacement uses the canonical requirement
spelling, including changing the argument label when its range category changes.
A leaf endpoint edit preserves surrounding trivia only if the result still meets
balanced spacing and comment rules; otherwise the necessary whitespace is part of
the explicit patch, or the edit fails with `manifest.edit.readOnly` when comment
ownership is ambiguous.

### Edit invariants

The invariants are byte-exact no-op return, byte preservation outside disjoint
patch ranges, and full reparse, type check, evaluation and domain validation of
the complete candidate before it is returned. The resulting complete IR must equal
the expected IR, including inactive groups and exports; only source positions and
trivia are excluded. All stages use the expanded-size budgets. BOM, final-newline
presence and unrelated bytes survive.

### Canonical printing

The canonical printer lays out new nodes and prints a complete document for a
new declaration file. Equal values print identical bytes. A document is the
version line, `import AgentsDescription`, one blank line, then
`let agents = Agents(...)`, with two-space indentation, LF, no BOM and one final
newline. Assignment and array concatenation use one ASCII space on each side of
`=` and `+`; negative literals use an adjacent sign and digits. Strings use
ordinary quotes; quotes, backslashes, LF, CR and tab are escaped, other control
scalars are lowercase Swift `\u{...}` escapes, and other Unicode scalars are
preserved without normalization.

Values use literal prompts, sections, selections and dictionaries and direct
factories. Default-valued arguments are omitted; explicit Optional values that
distinguish inheritance are retained. Signature order determines labels.
Dictionary keys sort by UTF-8 bytes; arrays keep their order. A collection of
scalar literals or payload-free enum members fits inline when the complete line,
including indentation and comma, is at most 80 UTF-8 bytes; otherwise it expands.
Collections containing collections or factory/initializer calls are multiline.
A call with only scalar arguments fits inline under the same limit; calls with
collections, ranges or nested calls are multiline. Multiline collections have
trailing commas; call arguments have none after the last argument. Empty
collections are `[]` or `[:]`. Printing never reformats an existing document.

## Evaluated JSON Dump

`ManifestDump(bytes:)` and `ManifestDump(document:)` evaluate only one local
declaration. The dump does not resolve external groups, fetch sources or
secrets, inspect native files or compile or run the manifest. Conditional
branches and group references remain symbolic. `encodedJSON()` returns one UTF-8
JSON object with sorted keys, two-space indentation and a trailing LF. Invalid
input throws `ManifestFailure` with its diagnostics, and no partial object
exists. `agents manifest dump --json` prints these bytes; its exit status and
diagnostic presentation belong to the CLI.

The root has `schemaVersion: 1`, `kind: "manifest"`, `languageVersion: "1.0"`,
`sourceDigest`, `declaration`, `locations` and `diagnostics`. The digest is
`sha256:` plus 64 lowercase hexadecimal digits over the original bytes.
`declaration` has `defaultAgents`, `exports`, `sources`, `components`, `groups`,
`uses` and `watch`. Default arrays are empty, Optional absence is null, and
explicit empty recipients remain distinct from inheritance.

A component encodes directly as `{ "kind": "mcpServer", "name": "workspace",
"transport": { ... }, "agents": ["claude-code"], "condition": null,
"native": {} }`. There is no payload wrapper. The remaining schema is determined
by the vocabulary as follows:

- Tagged families encode `{kind, ...fields}`. Component/transport kinds are
  their factory names. `ExecutableInvocation` is `kind: "executable"` with executable,
  arguments, environment and workingDirectory. `.group(name:)` references encode
  kind `local`; `.group(name:source:)` references encode kind `exported`, with
  name and condition. An exported reference always has a non-null source; a local
  reference has none (encoded as null). Conditions encode their
  three dimensions without a kind. Permission rules encode
  `{kind: "allow" | "ask" | "deny", operation, pattern}`; their two unlabeled
  factory arguments use the keys `operation` and `pattern`. LSP `languages`
  encodes an object mapping extension keys to language-ID strings.
- A source has `kind: "git" | "local" | "index"`, name, location (`url`, `path` or
  `index`, matching its factory field), subpath and requirement. A `path:` source
  with a requirement remains kind `local`. Requirement is null or an
  object with exactly one of `branch`, `revision`, `exact`, `from`, `upToNextMinor`,
  or `from` plus `to`, matching core's `SourceRequirement` encoding. Version values encode
  as normalized version strings. Every range value encodes its canonical
  requirement kind: `from`,
  `upToNextMinor`, or `from`/`to`, regardless of its construction spelling.
- Groups, skill overrides, ChatGPT prompts, prompt parameters and resources encode
  their factory fields without a factory-name tag; the resource's unlabeled
  subject uses key `path`. Arrays/dictionaries encode as JSON collections,
  with defaults supplied.
  Exports and watch are string arrays. An instruction section is always an object
  with name, source and condition, even when authored as a string.
- Skill selection encodes `"all"` or an array of names. Prompt content is
  `{kind: "literal", value: <string>}` or `{kind: "file", path, source}`.
  Runtime values similarly use literal/environment/secret and value. Literal
  spelling and explicit equivalent cases have identical evaluated output.
- Payload-free enum cases are strings, except mixed enums always use tagged
  objects. Associated values retain labels; a single unlabeled payload uses
  `value`. Typed component references use kind and name. Configuration values
  retain kind and value tags, including nested arrays/objects; null has only kind,
  and decimal values remain strings to prevent numeric rounding.
- Agent IDs are `claude-code`, `codex`, `cursor`, `gemini-cli`, `opencode`;
  platforms are `macos`, `linux`; other enum spellings are unchanged.

Components, group references, sections, hooks, permission rules, ignore patterns,
arguments and prompt parameters preserve order. Definitions of sources/groups,
exports, watch, named prompts and overrides sort by name; recipients, exclusions
and explicit skill selections sort by canonical identity. Dictionary keys sort
by decoded UTF-8 bytes. Typed plugin exclusions sort by kind then name.
Constants are substituted by value within the checked expansion budget.

A location has `pointer` (JSON Pointer into the normalized declaration), `span`,
`origins`, `defaulted` and `editability`. Spans have document `"manifest"`, start/end
byte offsets and starting line/column. A use's span identifies the use site;
origins include definitions. Missing fields anchor to their containing construction
with defaulted true. Editability is `editability(of:)` for that location: kind
`direct`; kind `sharedConstant` with the `uses` spans of every impacted reference;
or kind `readOnly` with its `reason`. Locations sort by pointer then start
offset; runtime node handles are not serialized.

Diagnostics have code, severity, message, span and related spans, sorted by
position then code. No timestamps, cache paths or resolved secrets are emitted.
Readers ignore unknown object keys but reject unsupported schema versions and
unknown semantic discriminants. Changed meanings or new discriminants require
a new schema version; optional metadata additions do not. Source digest/locations
may change with comments while declaration stays equal. Entire output and map
size are reserved before serialization under the expanded-size budgets.

## Diagnostics

Diagnostics include stable code, severity, message, primary span, related spans
and optional suggested edit. Spans use half-open UTF-8 byte offsets and 1-based
line/UTF-8-byte-column positions. At most 100 diagnostics plus one truncation
notice are produced. Any structural/type/domain error rejects the candidate;
no partial declaration is published.

| Diagnostic | Meaning |
| --- | --- |
| `manifest.version.missing`, `.invalid`, `.duplicate`, `.unsupported` | Version selection failed. |
| `manifest.syntax` | Recognizer: a lexical or production violation, including missing/extra imports, juxtaposed identifiers, unsupported prefixes, raw strings, interpolation and malformed literals. SwiftParser syntax/recovery diagnostics can occur only after recognizer acceptance and the tree guard; such a disagreement is also an implementation regression. |
| `manifest.call`, `manifest.type`, `manifest.operator` | After the tree guard: unlisted call/member, incorrect labels/order/type, missing context, integer overflow or non-array use of the admitted `+` operator. The `..<` operator is typed as `Range<Version>` only in its admitted requirement position. Other operators, including closed ranges (`...`), fail admission with a located `manifest.syntax` diagnostic; `ClosedRange<Version>` also has no matching compiler overload. |
| `manifest.reference` | Unknown, forward, self, duplicate or shadowing constant name. |
| `manifest.domain`, `manifest.dictionary.duplicateKey` | Invalid domain value or duplicate decoded dictionary key. A `manifest.domain` warning reports a Git shorthand with its fix-it. |
| `manifest.group.cycle`, `.missing` | Invalid local group graph, with the relevant reference chain. |
| `manifest.limit` | Recognizer: byte, token, syntax-storage reservation, comment, delimiter or chain limit. Iterative tree guard: node/depth limit. Later stages: evaluation, expansion, domain traversal, local group depth, output, generated source or edit budget. |
| `manifest.diagnostics.truncated` | The warning that replaces diagnostics beyond the limit. |
| `manifest.edit.readOnly`, `.stale`, `.overlap`, `.impact`, `.mismatch` | Document editing, as described under Document Editing. Declaration edit planning also reports `.mismatch` when a batch makes no progress or the final projection differs from the intended declaration. |
| `manifest.edit.baseline` | Declaration edit planning: the declaration an operation read differs from the projection of the bytes it prepared. |
| `manifest.unsupported` | The state layer's deployable-subset projection meets an active structure outside that subset; the span locates it. See [State](../Architecture/State.md#deployable-subset). |
| `manifest.dump.mismatch` | A source-map pointer is absent from the evaluated declaration while building a dump; this is an implementation regression. |

## Conformance and Validation

Every Swift code block in this reference and in the manifest proposal,
including interface and editor-API blocks, must pass `swiftc -parse`;
signature-only interface blocks use `swiftc -frontend -parse` with
`.swiftinterface` inputs so getter declarations are parsed in interface mode.
Positive fixtures compile against `AgentsDescription` and their
compiled values match static evaluation under plain value equality, including
equal range forms and string-literal group references. Compiler-required literal conformances and evaluator
registrations are checked against the same signature inventory. Negative fixtures
cover unsupported syntax, contextual typing, duplicate dictionary keys, budgets
and spans. No accepted static value may fail real Swift type checking.

Adversarial tests run every input in a subprocess with a parent watchdog and
assert normal completion without signals, crashes or unbounded memory growth.
Fixed regressions include balanced/unbalanced square nests, mixed square/call
nests, dictionaries, nested shorthand calls and parentheses, brace nests, generic
types `A<A<...B...>>`, ambiguous `a<a<...b`, and long member, numeric-prefix,
force-unwrap, call, subscript and `+` chains. Include the small generic-type form,
200,000-operation chains, and repeated `copy`, `await`, `consume`, `each` and
`unsafe` before an operand, all within the byte limit. Raw-string boundary cases
include `#"""#` followed by dangerous declarations and a comment containing
`"""#`; rejection occurs at the first hash, before SwiftParser sees that snapshot.
All forbidden forms must fail recognition. Bounded grammar forms must complete
parsing and the tree guard normally. Explicit synthetic deep/wide trees exercise
the iterative node/depth rejection independently of admission.

Literal/trivia cases cover ordinary escapes, multiline indentation and quote
runs, malformed Unicode escapes, raw delimiters, interpolation and nested comments.
Include absent/asymmetric whitespace and comments on both sides of `=` and `+`,
numeric signs at every permitted and forbidden boundary, and negative value
replacement with byte preservation through editor preparation. Multiline cases
distinguish empty, short whitespace-only and fully indented lines; cover mixed
indentation, leading tabs, closing-delimiter tabs and CRLF line endings. Operator
rejections assert both the diagnostic location and its canonical spelling.
Verify contextual words in permitted label/member positions as well as rejected
bare/prefix uses, juxtaposed identifiers, non-ASCII identifier rejection, and
Unicode string content. Check exact byte, delimiter, comment, additive, token,
syntax-reservation and actual-tree boundaries with located diagnostics. Rejections
assert zero SwiftParser calls. All complete examples pass recognition, the tree
guard, syntax checks and real compiler type checking.

CI runs **differential fuzzing**, not merely crash testing. Each run includes at
least 256 generated grammar constructions, 128 arbitrary token sequences, 128
injected disallowed-token cases and 256 mutations of generated sources, with
recorded deterministic seeds. Vary declaration/type structure, call labels,
array/dictionary nesting, literal boundaries, contextual words, comments,
truncation and near-limit input sizes. The recognizer itself must never crash or
exceed the per-case watchdog, whether it accepts or rejects an input.

For **every accepted input**, SwiftParser must produce an error-free tree whose
projection equals the recognizer's: declaration kind/name/span, type structure,
call labels and nesting, member/reference structure, arrays/dictionaries,
parentheses/additive expressions and exact literal spellings and UTF-8 spans.
Wrapper nodes and trivia are excluded from this projection. Compare independently
constructed projections; using SwiftParser to supply either recognizer decisions
or its expected structure would invalidate the test. Any parse error, unexpected
tree-budget failure or structural/literal disagreement is a test failure. Retain
and minimize counterexamples. Scheduled fuzzing extends the same bounded corpus.

Each input must finish admission, parsing, iterative checking, syntax-error
inspection and tree teardown, when reached, within **2 seconds wall-clock** in
the release test configuration on each required CI runner, separately from
compiler build time. The release configuration is the shipped front end, so it is
the performance gate. CI runs both the debug and release test configurations on
macOS and Linux. The debug configuration runs the same inputs with a 30-second
watchdog that detects hangs; unoptimized dependencies make its timings a hang
check, not the performance gate. The parent watchdog covers the entire child
lifetime; a timeout or signal fails the test, never counts as a successful
rejection. Record runner/toolchain identity, seeds, stage, token
and tree counts and timings. These are regression gates, not permission to relax
language limits on slower machines. Every SwiftParser dependency or host-toolchain
update reruns the fixed and fuzz suites at the candidate version and compares
with the recorded baseline. A crash, hang, deadline violation, incorrect stage or differential disagreement
blocks the update and release. All guards apply in every build configuration.

Tests also cover local group cycles and diamonds, byte-preserving edits, comment
ownership, canonical printing and deterministic dumps. Resource tests include
exponential constant reuse in unused declarations, dumping, source maps and
comparison. Range differential cases cover balanced/unbalanced spacing, comment
adjacency, misplacement, chained and closed ranges, nonliteral endpoints and
replacement boundaries; admitted cases must match SwiftParser's structure, and
semantically accepted cases must type-check against the types module. Fuzzing
runs with fixed budgets on macOS and Linux.

Canonical printing has byte-exact goldens: printing twice gives identical bytes,
and editing an empty `Agents()` step by step reaches the same bytes as printing
the complete value. Declaration edit planning has deterministic-seed property
tests: a printed random declaration projects back to its value, planning from one
random declaration to another projects to the second, and comments outside the
edited ranges survive.

## Related Documentation

- [State and Source Cache](../Architecture/State.md)
- [Package Architecture](../Architecture/Package.md)
- [Agents Manifest Contract](../Proposals/AgentsManifest.md)
- [Swift Manifest](../Decisions/SwiftManifest.md)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- [Swift Lexical Structure](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/lexicalstructure/)
