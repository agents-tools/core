import AgentsCore
import AgentsDescription

/// Turns a declaration change into source bytes. Existing documents receive the smallest edits
/// that express the semantic difference, without reordering; bytes outside the edited ranges,
/// including comments, are unchanged. Batches hold at most 100 requests and are replanned
/// against the bytes each batch produces. The final document must project to `next`.
package enum DeclarationEditPlan {
  /// Returns `nil` when `next` is semantically equal to `previous`. Without existing bytes, the
  /// canonical printer writes the complete document, and a semantically empty `next` writes none.
  /// `previous` must equal the projection of `bytes`; `manifest.edit.baseline` reports a caller
  /// whose preparation no longer describes the document.
  package static func bytes(
    replacing previous: Declaration, with next: Declaration, in bytes: [UInt8]?,
    identity: DocumentIdentity, environment: RuntimeEnvironment
  ) throws -> [UInt8]? {
    try self.bytes(
      replacing: previous, with: next, in: bytes, identity: identity, environment: environment,
      planning: { $0 })
  }

  // A module-internal seam alters planned batches to exercise the final comparison.
  static func bytes(
    replacing previous: Declaration, with next: Declaration, in bytes: [UInt8]?,
    identity: DocumentIdentity, environment: RuntimeEnvironment,
    planning adjust: ([DocumentOperation]) -> [DocumentOperation]
  ) throws -> [UInt8]? {
    func equivalent(_ lhs: Declaration, _ rhs: Declaration) -> Bool {
      ManifestProjection.equivalent(lhs, rhs, environment: environment)
    }
    guard let bytes else {
      guard equivalent(previous, Declaration()) else {
        throw failure(
          "manifest.edit.baseline", "the declaration has no document to edit",
          span: SourceSpan(document: identity, start: 0, end: 0, line: 1, column: 1))
      }
      if equivalent(next, Declaration()) { return nil }
      let output = try CanonicalPrinter().manifest(
        DeclarationConstruction.root(next).constructionValue)
      try verify(
        DeclarationDocument(bytes: output, identity: identity), next, environment: environment)
      return output
    }
    var document = try DeclarationDocument(bytes: bytes, identity: identity)
    var current = try ManifestProjection.declaration(of: document, environment: environment)
    guard equivalent(current, previous) else {
      throw failure(
        "manifest.edit.baseline", "the document changed after the declaration was read",
        span: document.source.span(0..<0))
    }
    if equivalent(previous, next) { return nil }
    var remaining = Int.max
    while true {
      var planner = Planner(
        document: document, current: current, next: next, environment: environment)
      let operations = adjust(try planner.plan())
      if operations.isEmpty { break }
      let change = try document.preparing(
        operations: Array(operations.prefix(ManifestLimits.Editing.requests)))
      guard change.bytes != document.bytes, operations.count < remaining else {
        throw failure(
          "manifest.edit.mismatch", "an edit batch made no progress",
          span: document.source.span(0..<0))
      }
      remaining = operations.count
      document = try DeclarationDocument(bytes: change.bytes, identity: identity)
      current = try ManifestProjection.declaration(of: document, environment: environment)
    }
    try verify(document, next, environment: environment)
    return document.bytes
  }

  private static func verify(
    _ document: DeclarationDocument, _ next: Declaration, environment: RuntimeEnvironment
  ) throws {
    let result = try ManifestProjection.declaration(of: document, environment: environment)
    guard ManifestProjection.equivalent(result, next, environment: environment) else {
      throw failure(
        "manifest.edit.mismatch", "the edited document differs from the intended declaration",
        span: document.source.span(0..<0))
    }
  }

  static func failure(_ code: String, _ message: String, span: SourceSpan) -> ManifestFailure {
    ManifestFailure(ManifestDiagnostic(code: code, message: message, span: span))
  }
}

/// Plans one batch over one snapshot. Sources are added before references to them and removed
/// after every reference. Each collection receives insertions before removals, so a retained
/// element stays the insertion anchor. Selections grow before overrides arrive and shrink after
/// overrides leave, so every prefix of a split plan keeps overrides inside the selection.
private struct Planner {
  let document: DeclarationDocument
  let current: Declaration
  let next: Declaration
  let environment: RuntimeEnvironment
  var operations: [DocumentOperation] = []

  mutating func plan() throws -> [DocumentOperation] {
    var skillComponents: [String: Int] = [:]
    var instructionsComponent: Int?
    for (index, component) in document.declaration.components.enumerated() {
      if component.kind == "skills", let alias = component["source"]?.string {
        skillComponents[alias] = index
      } else if component.kind == "instructions" {
        instructionsComponent = index
      }
    }
    for alias in next.sources.keys.sorted(by: utf8Less) {
      let source = next.sources[alias]!
      if let existing = current.sources[alias],
        ManifestProjection.equivalent(existing, source, environment: environment)
      {
        continue
      }
      operations.append(
        .edit(.upsertSource(try DeclarationConstruction.source(alias: alias, source))))
    }
    try recipients(owner: "", field: "defaultAgents", current.agents, next.agents)

    let currentSkills = current.skills ?? [:]
    let nextSkills = next.skills ?? [:]
    let retainedInstructions =
      next.instructions == nil
      ? nil : try instructionsComponent.map { try handle("/components/\($0)") }
    for alias in nextSkills.keys.sorted(by: utf8Less) {
      if let existing = currentSkills[alias] {
        try skills(at: "/components/\(skillComponents[alias]!)", existing, nextSkills[alias]!)
      } else {
        operations.append(
          .edit(
            .insertComponent(
              DeclarationConstruction.skills(alias: alias, nextSkills[alias]!), into: .root,
              at: retainedInstructions.map { .before($0) } ?? .last)))
      }
    }
    switch (instructionsComponent, next.instructions) {
    case (let index?, let instructions?):
      try self.instructions(at: "/components/\(index)", current.instructions!, instructions)
    case (nil, let instructions?):
      operations.append(
        .edit(
          .insertComponent(
            DeclarationConstruction.instructions(instructions), into: .root, at: .last)))
    case (let index?, nil):
      operations.append(.edit(.removeComponent(try handle("/components/\(index)"))))
    case (nil, nil): break
    }
    for alias in currentSkills.keys.sorted(by: utf8Less) where nextSkills[alias] == nil {
      operations.append(
        .edit(.removeComponent(try handle("/components/\(skillComponents[alias]!)"))))
    }

    let watch = (next.watch ?? []).sorted(by: utf8Less)
    if Set(current.watch ?? []) != Set(watch) {
      if explicit("/watch") {
        let changes = try elements(at: "/watch", watch, value: { .text($0) })
        operations += changes.insertions + changes.removals
      } else {
        operations.append(.edit(.setWatch(watch)))
      }
    }
    for alias in current.sources.keys.sorted(by: utf8Less) where next.sources[alias] == nil {
      operations.append(.edit(.removeSource(alias: alias)))
    }
    return operations
  }

  mutating func skills(
    at pointer: String, _ current: SkillDeclaration, _ next: SkillDeclaration
  ) throws {
    let owner = try handle(pointer)
    var reductions: [DocumentOperation] = []
    switch (current.select, next.select) {
    case (.all, .all): break
    case (.names(let old), .names(let new)) where Set(old) == Set(new): break
    case (.names, .names(let names)):
      let changes = try elements(
        at: pointer + "/select", names.sorted(by: utf8Less), value: { .text($0) })
      operations += changes.insertions
      reductions = changes.removals
    case (.names, .all):
      operations.append(.edit(.setSkillSelection(owner, .all)))
    case (.all, .names):
      reductions = [
        .edit(.setSkillSelection(owner, DeclarationConstruction.selection(next.select)))
      ]
    }
    let currentOverrides = current.overrides ?? [:]
    let nextOverrides = next.overrides ?? [:]
    for name in nextOverrides.keys.sorted(by: utf8Less) {
      let override = nextOverrides[name]!
      if let existing = currentOverrides[name], ManifestProjection.equivalent(existing, override) {
        continue
      }
      operations.append(
        .edit(
          .upsertSkillOverride(owner, DeclarationConstruction.override(name: name, override))))
    }
    for name in currentOverrides.keys.sorted(by: utf8Less) where nextOverrides[name] == nil {
      operations.append(.edit(.removeSkillOverride(owner, name: name)))
    }
    operations += reductions
    let exclude = (next.exclude ?? []).sorted(by: utf8Less)
    if Set(current.exclude ?? []) != Set(exclude) {
      if explicit(pointer + "/exclude") {
        let changes = try elements(at: pointer + "/exclude", exclude, value: { .text($0) })
        operations += changes.insertions + changes.removals
      } else {
        operations.append(
          .setArgument(owner, field: "exclude", value: exclude.constructionValue))
      }
    }
    if current.mode != next.mode {
      operations.append(
        .setArgument(
          owner, field: "mode", value: next.mode.map(DeclarationConstruction.mode).constructionValue
        ))
    }
    try recipients(owner: pointer, field: "agents", current.agents, next.agents)
  }

  mutating func instructions(
    at pointer: String, _ current: InstructionsDeclaration, _ next: InstructionsDeclaration
  ) throws {
    let owner = try handle(pointer)
    try recipients(owner: pointer, field: "agents", current.agents, next.agents)
    if current.sections != next.sections {
      let kept = try commonSubsequence(current.sections, next.sections)
      let keptCurrent = Set(kept.map(\.0))
      let keptNext = Set(kept.map(\.1))
      for index in next.sections.indices where !keptNext.contains(index) {
        // Inserting before the next retained section keeps several insertions in order.
        let anchor = try kept.first { $0.1 > index }.map {
          InsertionPosition.before(try handle(pointer + "/sections/\($0.0)"))
        }
        operations.append(
          .edit(
            .insertSection(
              DeclarationConstruction.section(next.sections[index]), into: owner,
              at: anchor ?? .last)))
      }
      for index in current.sections.indices where !keptCurrent.contains(index) {
        operations.append(.edit(.removeSection(try handle(pointer + "/sections/\(index)"))))
      }
    }
    let currentPrompts = current.chatgpt ?? [:]
    let nextPrompts = next.chatgpt ?? [:]
    for name in nextPrompts.keys.sorted(by: utf8Less)
    where currentPrompts[name] != nextPrompts[name] {
      operations.append(
        .edit(.upsertPrompt(owner, DeclarationConstruction.prompt(name: name, nextPrompts[name]!))))
    }
    for name in currentPrompts.keys.sorted(by: utf8Less) where nextPrompts[name] == nil {
      operations.append(.edit(.removePrompt(owner, name: name)))
    }
  }

  /// Present arrays change element by element; inheritance and its replacement change the
  /// whole argument.
  mutating func recipients(
    owner: String, field: String, _ current: [AgentID]?, _ next: [AgentID]?
  ) throws {
    guard !ManifestProjection.sameRecipients(current, next) else { return }
    let pointer = owner + "/" + field
    let agents = DeclarationConstruction.recipients(next)
    if current != nil, let agents, explicit(pointer) {
      let changes = try elements(
        at: pointer, agents.map { Lowering.lower($0.constructionValue).string! },
        value: { DeclarationConstruction.agent(AgentID(rawValue: $0)!).constructionValue })
      operations += changes.insertions + changes.removals
    } else if owner.isEmpty {
      operations.append(.edit(.setDefaultAgents(agents)))
    } else {
      operations.append(
        .setArgument(try handle(owner), field: field, value: agents.constructionValue))
    }
  }

  /// Element edits that turn the array at `pointer` into canonically ordered `desired`.
  /// Insertions keep canonical order when the retained elements already have it.
  func elements(
    at pointer: String, _ desired: [String], value: (String) -> ConstructionValue
  ) throws -> (insertions: [DocumentOperation], removals: [DocumentOperation]) {
    let wanted = Set(desired)
    let existing =
      document.values[pointer].map { Lowering.lower($0.value).elements ?? [] }?
      .compactMap(\.string) ?? []
    let kept = existing.enumerated().filter { wanted.contains($0.element) }
    let present = Set(kept.map(\.element))
    let ordered = zip(kept, kept.dropFirst()).allSatisfy { utf8Less($0.element, $1.element) }
    let container = try handle(pointer)
    var insertions: [DocumentOperation] = []
    for element in desired where !present.contains(element) {
      let anchor = ordered ? kept.first { utf8Less(element, $0.element) } : nil
      insertions.append(
        .insertElement(
          value(element), into: container,
          at: try anchor.map { .before(try handle(pointer + "/\($0.offset)")) } ?? .last))
    }
    let removals = try existing.indices.filter { !wanted.contains(existing[$0]) }.map {
      DocumentOperation.removeElement(try handle(pointer + "/\($0)"))
    }
    return (insertions, removals)
  }

  func explicit(_ pointer: String) -> Bool {
    document.values[pointer].map { !$0.defaulted } ?? false
  }

  func handle(_ pointer: String) throws -> NodeID {
    guard let node = document.node(at: pointer) else {
      throw DeclarationEditPlan.failure(
        "manifest.edit.mismatch", "planned edit has no source location",
        span: document.source.span(0..<0))
    }
    return node
  }

  /// Index pairs of a longest common subsequence; duplicates are matched in order.
  func commonSubsequence(_ lhs: [String], _ rhs: [String]) throws -> [(Int, Int)] {
    let (pairs, overflow) = (lhs.count + 1).multipliedReportingOverflow(by: rhs.count + 1)
    guard !overflow, pairs <= ManifestLimits.Editing.comparisonPairs else {
      throw DeclarationEditPlan.failure(
        "manifest.limit", "section comparison pairs", span: document.source.span(0..<0))
    }
    let width = rhs.count + 1
    var lengths = [Int](repeating: 0, count: (lhs.count + 1) * width)
    for i in stride(from: lhs.count - 1, through: 0, by: -1) {
      for j in stride(from: rhs.count - 1, through: 0, by: -1) {
        lengths[i * width + j] =
          lhs[i] == rhs[j]
          ? lengths[(i + 1) * width + j + 1] + 1
          : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
      }
    }
    var kept: [(Int, Int)] = []
    var (i, j) = (0, 0)
    while i < lhs.count && j < rhs.count {
      if lhs[i] == rhs[j] {
        kept.append((i, j))
        i += 1
        j += 1
      } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    return kept
  }
}
