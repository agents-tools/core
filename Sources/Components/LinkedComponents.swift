import AgentsCore
import AgentsInstructions
import AgentsSkills
import Foundation

/// Revision-independent, producer-qualified component identity. Roots remain separate namespaces.
package struct ComponentKey: Hashable, Sendable {
  package let source: String
  package let root: String
  package let group: String?
  package let kind: DeclaredComponentKind
  package let name: String
  package let containerRoot: String?
  let instructionInput: InstructionInput?

  struct InstructionInput: Hashable, Sendable {
    let source: String
    let root: String
  }

  package init(
    source: String, root: String, group: String?, kind: DeclaredComponentKind,
    name: String, containerRoot: String? = nil
  ) {
    self.init(
      source: source, root: root, group: group, kind: kind, name: name,
      containerRoot: containerRoot, instructionInput: nil)
  }

  init(
    source: String, root: String, group: String?, kind: DeclaredComponentKind, name: String,
    containerRoot: String?, instructionInput: InstructionInput?
  ) {
    self.source = source
    self.root = root
    self.group = group
    self.kind = kind
    self.name = name
    self.containerRoot = containerRoot
    self.instructionInput = instructionInput
  }

  func readingInstruction(from source: String, root: String) -> Self {
    .init(
      source: self.source, root: self.root, group: group, kind: kind, name: name,
      containerRoot: containerRoot, instructionInput: .init(source: source, root: root))
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.instructionInput == rhs.instructionInput
      && lhs.source.utf8.elementsEqual(rhs.source.utf8)
      && lhs.root.utf8.elementsEqual(rhs.root.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
      && lhs.group.map { Data($0.utf8) } == rhs.group.map { Data($0.utf8) }
      && lhs.containerRoot.map { Data($0.utf8) } == rhs.containerRoot.map { Data($0.utf8) }
  }
  package func hash(into hasher: inout Hasher) {
    hasher.combine(kind.rawValue)
    hasher.combine(instructionInput)
    for value in [Optional(source), root, group, name, containerRoot] {
      hasher.combine(value.map { Data($0.utf8) })
    }
  }
}

/// Exact, relative resource evidence. URLs used while reading never enter this value.
package struct LinkedResource: Equatable, Sendable {
  package let snapshot: SourceSnapshotID
  package let path: String
  package let hash: String
  package let executableFlags: [String: Bool]
  package let artifact: LockedArtifact?
  package let artifactLocation: LedgerLocation?
  package let antigravityInclude: Bool

  package init(
    snapshot: SourceSnapshotID, path: String, hash: String,
    executableFlags: [String: Bool], artifact: LockedArtifact? = nil,
    artifactLocation: LedgerLocation? = nil,
    antigravityInclude: Bool = false
  ) {
    self.snapshot = snapshot
    self.path = path
    self.hash = hash
    self.executableFlags = executableFlags
    self.artifact = artifact
    self.artifactLocation = artifactLocation
    self.antigravityInclude = antigravityInclude
  }
}

package enum LinkedPayload: Equatable, Sendable {
  case declaration(ComponentDeclaration)
  case skill(SnapshotSkill, mode: InstallMode, native: NativeConfiguration)
  case instruction(SnapshotInstruction, prompt: String?, native: NativeConfiguration)

  func sameContent(as other: Self) -> Bool {
    if case .declaration(let lhs) = self, case .declaration(let rhs) = other {
      guard let a = try? ResolvedLedgerCodec.bytes(LedgerPayload.component(lhs.comparisonPayload)),
        let b = try? ResolvedLedgerCodec.bytes(LedgerPayload.component(rhs.comparisonPayload))
      else { return false }
      return a == b
    }
    return self == other
  }
}

package struct LinkedPluginMember: Equatable, Sendable {
  package let parentOccurrence: Int
  package let selector: ComponentReferenceDeclaration

  package static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.parentOccurrence == rhs.parentOccurrence,
      let a = try? ResolvedLedgerCodec.bytes(LedgerPayload.reference(lhs.selector)),
      let b = try? ResolvedLedgerCodec.bytes(LedgerPayload.reference(rhs.selector))
    else { return false }
    return a == b
  }
}

package struct LinkedPluginExpansion: Equatable, Sendable {
  package let snapshot: SourceSnapshotID
  package let root: String
  package let containerRoot: String
  package let document: String
  package let input: LedgerInputProvenance
  package var children: [Int]

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.snapshot.source.utf8.elementsEqual(rhs.snapshot.source.utf8)
      && lhs.snapshot.revision.utf8.elementsEqual(rhs.snapshot.revision.utf8)
      && lhs.root.utf8.elementsEqual(rhs.root.utf8)
      && lhs.containerRoot.utf8.elementsEqual(rhs.containerRoot.utf8)
      && lhs.document.utf8.elementsEqual(rhs.document.utf8)
      && lhs.input == rhs.input && lhs.children == rhs.children
  }
}

package struct ContributionOrigin: Equatable, Sendable {
  package let occurrence: Int
  package let provenance: SourceProvenance
  package let declaration: SourceSpan?
  package let sourceOrigins: [SourceSpan]
  package let reference: Int?
  package let condition: DeclarationCondition
  package let recipients: Set<AgentID>
  /// Source variables traversed to reach this contribution, including resource dependencies.
  package let dependencies: [SourceSnapshotID]
  package let consumerEditable: Bool
  package var pluginMember: LinkedPluginMember? = nil
  package var pluginExpansion: LinkedPluginExpansion? = nil
}

package struct LinkedComponent: Equatable, Sendable {
  package let key: ComponentKey
  package let declaringSnapshot: SourceSnapshotID
  package let snapshot: SourceSnapshotID
  package let pin: SourceRevision?
  package let payload: LinkedPayload
  package var conditions: [DeclarationCondition]
  package var recipients: Set<AgentID>
  /// ChatGPT is a projection, not an AgentID. Scope/platform constraints still apply.
  package let chatGPT: Bool
  package var resources: [LinkedResource]
  package var origins: [ContributionOrigin]
  /// Consumer-owned export input. It is not read or retained for installation replay.
  package var localAppend: LedgerLocation? = nil
  package var copyRecipients: Set<InstructionRecipient> = []
}

package struct SourceConstraint: Equatable, Sendable {
  package let source: String
  package let root: String
  package let requirement: SourceRequirement?
  package let referenceChain: [SourceSpan]
}

package struct LinkedReference: Equatable, Sendable {
  package let occurrence: Int
  package let parent: Int?
  package let group: String
  package let snapshot: SourceSnapshotID
  package let root: String
  package let constraint: SourceConstraint?
  package let referenceChain: [SourceSpan]
  package let manifestHash: String
}

package struct LinkedSourceUse: Equatable, Sendable {
  package let source: String
  package let root: String
  package let requirement: SourceRequirement?
  package let organizationRequirements: [SourceRequirement]?

  init(
    source: String, root: String, requirement: SourceRequirement?,
    organizationRequirements: [SourceRequirement]? = nil
  ) {
    self.source = source
    self.root = root
    self.requirement = requirement
    self.organizationRequirements = organizationRequirements
  }
}

package struct LinkedComponents: Equatable, Sendable {
  package let components: [LinkedComponent]
  package let references: [LinkedReference]
  package let constraints: [SourceConstraint]
  package let selections: [String: SourceRevision]
  package let sourceSnapshots: [SourceSnapshotEvidence]
  package var sourceUses: [LinkedSourceUse] = []
  package var declaringSnapshots: [SourceSnapshotEvidence] = []

  /// A semantic projection protects pins, payloads, resource evidence and effective targets.
  /// Instructions retain order within each recipient or named prompt. Reference counts and
  /// occurrence numbering do not by themselves change protected content.
  package func protectedChanges(
    from previous: Self, allowing kinds: Set<DeclaredComponentKind>
  ) -> [ComponentKey] {
    func protected(_ graph: Self) -> [ComponentKey: [LinkedComponent]] {
      Dictionary(
        grouping: graph.components.filter {
          $0.key.kind != .instructions && !kinds.contains($0.key.kind)
        }, by: \.key)
    }
    var changes = Set<ComponentKey>()
    func relations(_ graph: Self) -> [Int: Data] {
      guard
        graph.components.contains(where: {
          $0.origins.contains { $0.pluginMember != nil || $0.pluginExpansion != nil }
        })
      else { return [:] }
      let occurrences = Dictionary(
        uniqueKeysWithValues: graph.components.flatMap { component in
          component.origins.map { ($0.occurrence, component) }
        })
      func identity(_ key: ComponentKey) -> LedgerValue {
        var fields: [String: LedgerValue] = [
          "source": .init(key.source), "root": .init(key.root),
          "kind": .init(key.kind.rawValue), "name": .init(key.name),
        ]
        fields["group"] = key.group.map { .init($0) }
        fields["containerRoot"] = key.containerRoot.map { .init($0) }
        return .init(object: fields)
      }
      var result: [Int: Data] = [:]
      for component in graph.components {
        for origin in component.origins {
          var fields: [String: LedgerValue] = [:]
          if let member = origin.pluginMember, let parent = occurrences[member.parentOccurrence] {
            fields["parent"] = identity(parent.key)
            fields["selector"] = LedgerPayload.reference(member.selector)
          }
          if let expansion = origin.pluginExpansion {
            fields["source"] = .init(expansion.snapshot.source)
            fields["revision"] = .init(expansion.snapshot.revision)
            fields["root"] = .init(expansion.root)
            fields["containerRoot"] = .init(expansion.containerRoot)
            fields["children"] = .init(
              array: expansion.children.compactMap { occurrences[$0] }.map { identity($0.key) })
          }
          if !fields.isEmpty {
            result[origin.occurrence] = try? ResolvedLedgerCodec.bytes(LedgerValue(object: fields))
          }
        }
      }
      return result
    }
    let beforeRelations = relations(previous)
    let afterRelations = relations(self)
    func compare(_ lhs: [LinkedComponent], _ rhs: [LinkedComponent]) {
      for (a, b) in zip(lhs, rhs) {
        // Coalescing retains distinct complete clauses; collection order carries no restriction.
        let sameConditions =
          [.hook, .permissions].contains(a.key.kind)
          ? a.conditions.count == b.conditions.count
            && a.conditions.allSatisfy { b.conditions.contains($0) }
          : a.conditions == b.conditions
        let aRelations = a.origins.compactMap { beforeRelations[$0.occurrence] }.sorted {
          $0.lexicographicallyPrecedes($1)
        }
        let bRelations = b.origins.compactMap { afterRelations[$0.occurrence] }.sorted {
          $0.lexicographicallyPrecedes($1)
        }
        if a.key != b.key || a.snapshot != b.snapshot || a.pin != b.pin
          || !a.payload.sameContent(as: b.payload)
          || !sameConditions
          || a.localAppend != b.localAppend
          || a.recipients != b.recipients || a.chatGPT != b.chatGPT || a.resources != b.resources
          || Set(a.origins.flatMap(\.dependencies)) != Set(b.origins.flatMap(\.dependencies))
          || aRelations != bRelations
        {
          changes.insert(a.key)
          changes.insert(b.key)
        }
      }
      for component in lhs.dropFirst(rhs.count) { changes.insert(component.key) }
      for component in rhs.dropFirst(lhs.count) { changes.insert(component.key) }
    }
    let before = protected(previous)
    let after = protected(self)
    for key in Set(before.keys).union(after.keys) {
      compare(before[key] ?? [], after[key] ?? [])
    }
    if !kinds.contains(.instructions) {
      enum Destination: Hashable {
        case recipient(InstructionRecipient)
        case prompt(String)
        case inactive(ComponentKey)
      }
      func instructions(_ graph: Self) -> [Destination: [LinkedComponent]] {
        var streams: [Destination: [LinkedComponent]] = [:]
        for component in graph.components {
          guard case .instruction(_, let prompt, _) = component.payload else { continue }
          for agent in component.recipients {
            streams[.recipient(.local(agent)), default: []].append(component)
          }
          for recipient in component.copyRecipients {
            streams[.recipient(recipient), default: []].append(component)
          }
          if component.chatGPT, let prompt {
            streams[.prompt(prompt), default: []].append(component)
          } else if component.recipients.isEmpty, component.copyRecipients.isEmpty {
            // Inactive declarations still protect their content, without imposing output order
            // between unrelated keys.
            streams[.inactive(component.key), default: []].append(component)
          }
        }
        return streams
      }
      let before = instructions(previous)
      let after = instructions(self)
      for destination in Set(before.keys).union(after.keys) {
        compare(before[destination] ?? [], after[destination] ?? [])
      }
    }
    return changes.sorted { lhs, rhs in
      [lhs.source, lhs.root, lhs.containerRoot ?? "", lhs.group ?? "", lhs.kind.rawValue, lhs.name]
        .lexicographicallyPrecedes(
          [
            rhs.source, rhs.root, rhs.containerRoot ?? "", rhs.group ?? "", rhs.kind.rawValue,
            rhs.name,
          ])
    }
  }

  package func requireEditable(_ key: ComponentKey) throws {
    let matches = components.filter { $0.key == key }
    guard !matches.isEmpty else { throw LinkError.missing("component: \(key.name)", []) }
    for component in matches {
      if let origin = component.origins.first(where: { !$0.consumerEditable }) {
        throw LinkError.notEditableHere(key, origin.provenance)
      }
    }
  }

  /// Keeps other domains' exact choices when removing constraints or updating direct items.
  package func protectedPins(allowing kinds: Set<DeclaredComponentKind>) -> [String: SourceRevision]
  {
    let protected = Set(
      components.filter { !kinds.contains($0.key.kind) }
        .flatMap { $0.origins.flatMap(\.dependencies).map(\.source) })
    return selections.filter { protected.contains($0.key) }
  }
}

package enum LinkError: Error, Sendable, CustomStringConvertible {
  case missing(String, [SourceSpan])
  case cycle([String], [SourceSpan])
  case incompatible([SourceConstraint])
  case budget(String)
  case conflict(ComponentKey, [ContributionOrigin])
  case invalid(String, [SourceSpan])
  case notEditableHere(ComponentKey, SourceProvenance)

  package var description: String {
    switch self {
    case .missing(let value, let chain): return "Missing \(value)\(Self.locations(chain))"
    case .cycle(let groups, let chain):
      return "Group cycle: \(groups.joined(separator: " → "))\(Self.locations(chain))"
    case .incompatible(let constraints):
      return "Incompatible source requirements: "
        + constraints.map {
          $0.source + " " + String(describing: $0.requirement) + Self.locations($0.referenceChain)
        }.joined(separator: "; ")
    case .budget(let name): return "Component linking exceeded \(name) budget"
    case .conflict(let key, let origins):
      return "Conflicting \(key.kind.rawValue) '\(key.name)'"
        + Self.locations(origins.flatMap { $0.provenance.referenceChain })
    case .invalid(let reason, let chain): return reason + Self.locations(chain)
    case .notEditableHere(let key, let provenance):
      return
        "notEditableHere: '\(key.name)' is owned by \(provenance.sourceIdentity)/\(provenance.relativePath)"
        + Self.locations(provenance.referenceChain)
    }
  }

  private static func locations(_ spans: [SourceSpan]) -> String {
    spans.map { " at \($0.document.rawValue):\($0.line):\($0.column)" }.joined()
  }
}
