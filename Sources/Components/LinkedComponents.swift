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
}

/// Exact, relative resource evidence. URLs used while reading never enter this value.
package struct LinkedResource: Equatable, Sendable {
  package let snapshot: SourceSnapshotID
  package let path: String
  package let hash: String
  package let executableFlags: [String: Bool]
  package let artifact: LockedArtifact?

  package init(
    snapshot: SourceSnapshotID, path: String, hash: String,
    executableFlags: [String: Bool], artifact: LockedArtifact? = nil
  ) {
    self.snapshot = snapshot
    self.path = path
    self.hash = hash
    self.executableFlags = executableFlags
    self.artifact = artifact
  }
}

package enum LinkedPayload: Equatable, Sendable {
  case declaration(ComponentDeclaration)
  case skill(SnapshotSkill, mode: InstallMode, native: NativeConfiguration)
  case instruction(SnapshotInstruction, prompt: String?, native: NativeConfiguration)

  func sameContent(as other: Self) -> Bool {
    if case .declaration(let lhs) = self, case .declaration(let rhs) = other {
      return lhs.comparisonPayload == rhs.comparisonPayload
    }
    return self == other
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
}

package struct LinkedComponent: Equatable, Sendable {
  package let key: ComponentKey
  package let snapshot: SourceSnapshotID
  package let pin: SourceRevision?
  package let payload: LinkedPayload
  package var conditions: [DeclarationCondition]
  package var recipients: Set<AgentID>
  /// ChatGPT is a projection, not an AgentID. Scope/platform constraints still apply.
  package let chatGPT: Bool
  package let resources: [LinkedResource]
  package var origins: [ContributionOrigin]
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
}

package struct LinkedComponents: Equatable, Sendable {
  package let components: [LinkedComponent]
  package let references: [LinkedReference]
  package let constraints: [SourceConstraint]
  package let selections: [String: SourceRevision]
  package let sourceSnapshots: [SourceSnapshotEvidence]

  /// A semantic projection protects pins, payloads, resource evidence and effective targets.
  /// Reference counts and occurrence numbering do not by themselves change protected content.
  package func protectedChanges(
    from previous: Self, allowing kinds: Set<DeclaredComponentKind>
  ) -> [ComponentKey] {
    func protected(_ graph: Self) -> [ComponentKey: [LinkedComponent]] {
      Dictionary(grouping: graph.components.filter { !kinds.contains($0.key.kind) }, by: \.key)
    }
    let before = protected(previous)
    let after = protected(self)
    return Set(before.keys).union(after.keys).filter { key in
      let lhs = before[key] ?? []
      let rhs = after[key] ?? []
      guard lhs.count == rhs.count else { return true }
      return zip(lhs, rhs).contains { a, b in
        a.snapshot != b.snapshot || a.pin != b.pin || !a.payload.sameContent(as: b.payload)
          || a.conditions != b.conditions
          || a.recipients != b.recipients || a.chatGPT != b.chatGPT || a.resources != b.resources
          || Set(a.origins.flatMap(\.dependencies)) != Set(b.origins.flatMap(\.dependencies))
      }
    }.sorted { lhs, rhs in
      [lhs.source, lhs.root, lhs.group ?? "", lhs.kind.rawValue, lhs.name]
        .lexicographicallyPrecedes(
          [rhs.source, rhs.root, rhs.group ?? "", rhs.kind.rawValue, rhs.name])
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
