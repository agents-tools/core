import AgentsCore
import Foundation

/// Selection and protection are projections of the recorded graph, never of mutable producers.
package struct LedgerImpact {
  package let pins: [String: SourceRevision]
  package let directPins: [ComponentKey: SourceRevision]

  package init(
    ledger: ResolvedLedger, roots: [String: URL], kinds: Set<DeclaredComponentKind>,
    names: Set<String>, updating: Bool
  ) throws {
    func selected(_ c: LedgerComponent) -> Bool {
      kinds.contains(DeclaredComponentKind(rawValue: c.kind)!)
        && (names.isEmpty
          || names.contains(c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name))
    }
    var affected = Set<String>()
    if updating {
      for occurrence in ledger.occurrences {
        if let c = ledger.components[occurrence.component], selected(c) {
          affected.formUnion(occurrence.dependencies)
          affected.insert(c.source)
        }
      }
    }
    var pins: [String: SourceRevision] = [:]
    for group in ledger.groups where !affected.contains(group.source) {
      let source = ledger.sources[group.source]!
      if SourceCache.isObjectID(source.revision) {
        pins[try ledger.sourceIdentity(group.source, roots: roots)] = SourceRevision(
          revision: source.revision, version: source.version)
      }
    }
    var direct: [ComponentKey: SourceRevision] = [:]
    for c in ledger.components.values where !updating || !selected(c) {
      guard c.group == nil, let revision = c.revision else { continue }
      direct[
        ComponentKey(
          source: try ledger.sourceIdentity(c.declaringSource, roots: roots), root: c.root,
          group: nil, kind: DeclaredComponentKind(rawValue: c.kind)!,
          name: c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name
        )] = SourceRevision(revision: revision, version: c.version)
    }
    self.pins = pins
    directPins = direct
  }

  package static func requireProtected(
    previous: ResolvedLedger, next: ResolvedLedger, kinds: Set<DeclaredComponentKind>,
    names: Set<String> = [], roots: [String: URL]
  ) throws {
    struct Projection: Encodable {
      let component: LedgerComponent
      let sources: [[LedgerSource]]
      let resources: [LedgerResource]
    }
    func streams(_ ledger: ResolvedLedger) throws -> [String: [String]] {
      var result: [String: [String]] = [:]
      for occurrence in ledger.occurrences {
        guard var c = ledger.components[occurrence.component],
          !kinds.contains(DeclaredComponentKind(rawValue: c.kind)!)
            || (!names.isEmpty
              && !names.contains(c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name))
        else { continue }
        func sourceChain(_ id: String) throws -> [LedgerSource] {
          var result: [LedgerSource] = []
          var next: String? = id
          while let current = next, var source = ledger.sources[current] {
            next = source.container
            source.container = nil
            source.version = nil
            if source.kind == .local, !SourceCache.isObjectID(source.revision) {
              source.revision = "local"
            }
            if let transport = source.transport {
              source.transport = try SourceDeclaration(kind: source.kind, location: transport)
                .identity(environment: RuntimeEnvironment(environment: [:]))
            }
            if let location = source.location {
              source.location = .init(
                kind: .absolute, path: try location.resolve(roots: roots).path)
            }
            result.append(source)
          }
          return result
        }
        let sources =
          try [sourceChain(c.source), sourceChain(c.declaringSource)]
          + c.resources.map { try sourceChain(ledger.resources[$0]!.source) }
        let resources = c.resources.enumerated().map { index, id in
          var resource = ledger.resources[id]!
          resource.source = "resource:" + String(index)
          if resource.kind == .liveEdit { resource.hash = "live" }
          return resource
        }
        if var payload = c.payload.object {
          if let agents = payload["agents"]?.array {
            payload["agents"] = .init(array: agents.sorted { ($0.text ?? "") < ($1.text ?? "") })
          }
          if var condition = payload["condition"]?.object {
            for key in ["agents", "scopes", "platforms"] {
              if let values = condition[key]?.array {
                condition[key] = .init(array: values.sorted { ($0.text ?? "") < ($1.text ?? "") })
              }
            }
            payload["condition"] = .init(object: condition)
          }
          if c.kind == "skills", payload["mode"]?.text == "edit" { payload["description"] = nil }
          c.payload = .init(object: payload)
        }
        for index in c.conditions.indices {
          c.conditions[index].agents?.sort { $0.rawValue < $1.rawValue }
          c.conditions[index].scopes?.sort { $0.rawValue < $1.rawValue }
          c.conditions[index].platforms?.sort()
        }
        if ["hook", "permissions"].contains(c.kind) {
          try c.conditions.sort {
            try ResolvedLedgerCodec.digest($0) < ResolvedLedgerCodec.digest($1)
          }
          c.conditions = c.conditions.reduce(into: []) { result, condition in
            if !result.contains(condition) { result.append(condition) }
          }
        }
        if c.kind == "skills" { c.name = PathSafety.sanitizeName(c.name) }
        c.source = "input"
        c.declaringSource = "producer"
        c.resources = resources.map(\.hash)
        let digest = try ResolvedLedgerCodec.digest(
          Projection(component: c, sources: sources, resources: resources))
        let destinations: [String]
        if c.kind == DeclaredComponentKind.instructions.rawValue {
          destinations =
            c.recipients.map(\.rawValue)
            + (c.chatGPT ? ["prompt:" + (c.payload.object?["prompt"]?.text ?? "")] : [])
        } else if ["hook", "permissions", "ignore", "plugin"].contains(c.kind) {
          destinations = c.recipients.map { c.kind + ":" + $0.rawValue }
        } else {
          destinations = [c.kind + ":" + c.root + ":" + (c.group ?? "") + ":" + c.name]
        }
        for destination in destinations.isEmpty
          ? ["inactive:" + c.kind + ":" + c.name] : destinations
        {
          // Coalesced origins do not change effective content; instruction occurrences retain order.
          if c.kind == DeclaredComponentKind.instructions.rawValue
            || !result[destination, default: []].contains(digest)
          {
            result[destination, default: []].append(digest)
          }
        }
      }
      return result
    }
    let before = try streams(previous)
    let after = try streams(next)
    let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    guard changed.isEmpty else {
      throw CoreError.invalidState(
        "requiresCombinedUpdate: selected changes affect protected components: "
          + changed.joined(separator: ", "))
    }
  }

  package static func requireEditable(
    _ ledger: ResolvedLedger, kinds: Set<DeclaredComponentKind>, names: Set<String>,
    roots: [String: URL]
  ) throws {
    for occurrence in ledger.occurrences where !occurrence.consumerEditable {
      let c = ledger.components[occurrence.component]!
      if kinds.contains(DeclaredComponentKind(rawValue: c.kind)!),
        names.contains(c.kind == "skills" ? PathSafety.sanitizeName(c.name) : c.name)
      {
        let producer = try ledger.sourceIdentity(occurrence.declaringSource, roots: roots)
        let groups = Dictionary(uniqueKeysWithValues: ledger.groups.map { ($0.id, $0) })
        var chain: [String] = []
        var parent = occurrence.reference
        while let reference = parent, let group = groups[reference] {
          chain.append(
            try ledger.sourceIdentity(group.source, roots: roots) + ":" + group.root + "#"
              + group.name)
          parent = group.parent
        }
        throw CoreError.invalidState(
          "notEditableHere: \(c.name) is owned by producer \(producer), via \(chain.reversed().joined(separator: " -> ")) (\(occurrence.manifestPath))"
        )
      }
    }
  }
}
