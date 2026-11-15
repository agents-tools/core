import AgentsCore

struct DraftBatch {
  let document: DeclarationDocument
  let changedPointers: [String]
}

struct DocumentEditor {
  let document: DeclarationDocument

  func prepare(_ edits: [ManifestEdit]) throws -> DocumentChange {
    guard edits.count <= ManifestLimits.Editing.requests else {
      throw failure("manifest.limit", "edit request limit")
    }
    var current = document
    var pointers: [String] = []
    var work = 0
    var comparisons = 0
    var handles = Dictionary(uniqueKeysWithValues: document.locations.keys.map { ($0, $0) })
    for edit in edits {
      let requested = try operations(edit, in: current, handles: handles)
      var operations: [IREdit] = []
      for request in requested {
        if case .set(let pointer, let replacement?) = request,
          let old = IRTree.value(IRTree.root(current.declaration), at: pointer)
        {
          var diff = IRDiff(comparisons: comparisons)
          try diff.compare(old, replacement, at: pointer)
          comparisons = diff.comparisons
          operations += diff.edits
        } else {
          operations.append(request)
        }
      }
      var offset = 0
      while offset < operations.count {
        let end = min(operations.count, offset + ManifestLimits.Editing.requests)
        let batch = try Self.draft(Array(operations[offset..<end]), in: current, work: &work)
        current = batch.document
        pointers += batch.changedPointers
        offset = end
      }
      for operation in operations { handles = Self.remap(handles, after: operation) }
    }
    let final = try DeclarationDocument(bytes: current.bytes, identity: document.source.identity)
    guard final.declaration == current.declaration else {
      throw failure("manifest.edit.mismatch", "final declaration differs from intended IR")
    }
    return Self.change(from: document, to: final, pointers: pointers)
  }

  /// Drafts cannot be published. Every operation refreshes the CST/source map and checks full
  /// expected IR; only domain reference validation is deferred across private composition.
  static func draft(_ edits: [IREdit], in document: DeclarationDocument) throws -> DraftBatch {
    guard edits.count <= ManifestLimits.Editing.requests else {
      throw document.source.failure("manifest.limit", "edit request limit", 0)
    }
    var work = 0
    return try draft(edits, in: document, work: &work)
  }

  private static func draft(_ edits: [IREdit], in document: DeclarationDocument, work: inout Int)
    throws -> DraftBatch
  {
    var current = document
    var changed: [String] = []
    for edit in edits {
      let old = IRTree.root(current.declaration)
      let expected = edit.applying(to: old)
      work +=
        IRTree.count(old) + IRTree.count(expected) + current.metrics.syntaxNodes
        + current.comments.count
      try validateIRBudget(expected, source: document.source)
      guard work <= ManifestLimits.Editing.steps else {
        throw document.source.failure("manifest.limit", "edit batch work steps", 0)
      }
      if expected == old { continue }
      let patches = try YAMLPatches(document: current).patches(for: edit, expected: expected)
      var bytes = current.bytes
      let sorted = patches.sorted { $0.range.lowerBound > $1.range.lowerBound }
      var boundary = bytes.count
      for patch in sorted {
        guard patch.range.lowerBound >= 0, patch.range.upperBound <= boundary else {
          throw document.source.failure("manifest.edit.mismatch", "overlapping edit patches", 0)
        }
        bytes.replaceSubrange(patch.range, with: patch.replacement)
        boundary = patch.range.lowerBound
      }
      let next = try DeclarationDocument(
        bytes: bytes, identity: document.source.identity, validateDomain: false)
      guard IRTree.root(next.declaration) == expected else {
        throw document.source.failure(
          "manifest.edit.mismatch", "edit differs from full expected declaration", 0)
      }
      guard next.bytes != current.bytes else {
        throw document.source.failure("manifest.edit.mismatch", "an edit batch made no progress", 0)
      }
      current = next
      switch edit {
      case .set(let pointer, _), .insert(let pointer, _, _), .remove(let pointer, _),
        .move(let pointer, _, _):
        changed.append(pointer)
      case .relocate(let origin, _, let destination, _): changed += [origin, destination]
      }
    }
    return DraftBatch(document: current, changedPointers: changed)
  }

  static func change(
    from original: DeclarationDocument, to final: DeclarationDocument, pointers: [String]
  ) -> DocumentChange {
    let a = original.bytes
    let b = final.bytes
    var first = 0
    while first < min(a.count, b.count) && a[first] == b[first] { first += 1 }
    var tail = 0
    while tail < min(a.count, b.count) - first && a[a.count - tail - 1] == b[b.count - tail - 1] {
      tail += 1
    }
    let patches =
      a == b
      ? []
      : [
        SourcePatch(
          range: first..<(a.count - tail), replacement: Array(b[first..<(b.count - tail)]))
      ]
    return DocumentChange(
      originalDigest: original.digest, patches: patches, bytes: b, digest: final.digest,
      expectedDeclaration: final.declaration, diagnostics: final.diagnostics,
      delta: SemanticDelta(changedPointers: Array(Set(pointers)).sorted(by: utf8Less)))
  }

  private func operations(
    _ edit: ManifestEdit, in current: DeclarationDocument, handles: [String: String]
  ) throws -> [IREdit] {
    let root = IRTree.root(current.declaration)
    func pointer(_ id: NodeID) throws -> String {
      guard id.digest == document.digest, document.node(at: id.pointer) == id,
        let mapped = handles[id.pointer], IRTree.value(root, at: mapped) != nil
      else { throw failure("manifest.edit.stale", "stale snapshot handle") }
      return mapped
    }
    func container(_ id: ContainerID, _ field: String) throws -> String {
      switch id {
      case .root: return "/" + field
      case .group(let id):
        let path = try pointer(id)
        guard IRTree.value(root, at: path)?.record?.kind == "group" else {
          throw failure("manifest.edit.readOnly", "expected a group occurrence")
        }
        return path + "/" + field
      }
    }
    func index(_ position: InsertionPosition, in path: String) throws -> Int {
      guard let values = IRTree.value(root, at: path)?.elements else {
        throw failure("manifest.edit.readOnly", "expected an ordered collection")
      }
      switch position {
      case .first: return 0
      case .last: return values.count
      case .before(let id), .after(let id):
        let target = try pointer(id)
        guard target.hasPrefix(path + "/"), let i = Int(target.dropFirst(path.count + 1)),
          i < values.count
        else { throw failure("manifest.edit.stale", "position is outside collection") }
        if case .after = position { return i + 1 }
        return i
      }
    }
    func upsert(_ path: String, _ value: DeclarationRecord) throws -> [IREdit] {
      guard let values = IRTree.value(root, at: path)?.elements else {
        throw failure("manifest.edit.readOnly", "expected a named collection")
      }
      if let index = values.firstIndex(where: { $0.record?["name"] == value["name"] }) {
        return [.set(path + "/\(index)", .record(value))]
      }
      return [.insert(path, values.count, .record(value))]
    }
    func removeNamed(_ path: String, _ name: String) throws -> [IREdit] {
      guard let values = IRTree.value(root, at: path)?.elements else {
        throw failure("manifest.edit.readOnly", "expected a named collection")
      }
      return values.firstIndex(where: { $0.record?["name"]?.string == name }).map {
        [.remove(path, $0)]
      } ?? []
    }
    func remove(_ id: NodeID) throws -> [IREdit] {
      let path = try pointer(id)
      let slash = path.lastIndex(of: "/")!
      guard let index = Int(path[path.index(after: slash)...]) else {
        throw failure("manifest.edit.readOnly", "expected an occurrence")
      }
      let parent = String(path[..<slash])
      guard IRTree.value(root, at: parent)?.elements?.indices.contains(index) == true else {
        throw failure("manifest.edit.readOnly", "expected an ordered occurrence")
      }
      return [.remove(parent, index)]
    }
    func move(_ id: NodeID, into path: String, at position: InsertionPosition) throws -> [IREdit] {
      let old = try pointer(id)
      let slash = old.lastIndex(of: "/")!
      let parent = String(old[..<slash])
      guard let from = Int(old[old.index(after: slash)...]),
        IRTree.value(root, at: parent)?.elements?.indices.contains(from) == true
      else { throw failure("manifest.edit.readOnly", "expected an ordered occurrence") }
      let target = try index(position, in: path)
      if parent == path { return [.move(path, from, target > from ? target - 1 : target)] }
      return [.relocate(parent, from, path, target)]
    }
    switch edit {
    case .setDefaultAgents(let agents):
      return [.set("/defaultAgents", YAMLConstruction.agents(agents))]
    case .upsertSource(let source): return try upsert("/sources", YAMLConstruction.source(source))
    case .removeSource(let alias): return try removeNamed("/sources", alias)
    case .insertComponent(let value, let owner, let position):
      let path = try container(owner, "components")
      return try [
        .insert(path, index(position, in: path), .record(YAMLConstruction.component(value)))
      ]
    case .replaceComponent(let id, let value):
      return try [.set(pointer(id), .record(YAMLConstruction.component(value)))]
    case .removeComponent(let id), .removeSection(let id), .removeGroupReference(let id):
      return try remove(id)
    case .moveComponent(let id, let owner, let position):
      return try move(id, into: container(owner, "components"), at: position)
    case .setSkillSelection(let id, let value):
      let owner = try pointer(id)
      guard IRTree.value(root, at: owner)?.record?.kind == "skills" else {
        throw failure("manifest.edit.readOnly", "expected a skills occurrence")
      }
      let path = owner + "/select"
      switch value {
      case .all: return [.set(path, .string("all"))]
      case .names(let names): return [.set(path, YAMLConstruction.strings(names))]
      }
    case .upsertSkillOverride(let id, let value):
      return try upsert(pointer(id) + "/overrides", YAMLConstruction.override(value))
    case .removeSkillOverride(let id, let name):
      return try removeNamed(pointer(id) + "/overrides", name)
    case .insertSection(let value, let id, let position):
      let path = try pointer(id) + "/sections"
      return try [
        .insert(path, index(position, in: path), .record(YAMLConstruction.section(value)))
      ]
    case .moveSection(let id, let position):
      let path = try pointer(id)
      let slash = path.lastIndex(of: "/")!
      return try move(id, into: String(path[..<slash]), at: position)
    case .upsertPrompt(let id, let value):
      return try upsert(pointer(id) + "/chatGPT", YAMLConstruction.promptDeclaration(value))
    case .removePrompt(let id, let name): return try removeNamed(pointer(id) + "/chatGPT", name)
    case .upsertGroup(let value): return try upsert("/groups", YAMLConstruction.group(value))
    case .removeGroup(let name): return try removeNamed("/groups", name)
    case .insertGroupReference(let value, let owner, let position):
      let path = try container(owner, "uses")
      return try [.insert(path, index(position, in: path), .record(YAMLConstruction.use(value)))]
    case .setExports(let values): return [.set("/exports", YAMLConstruction.strings(values))]
    case .setWatch(let values):
      if Set(values) == Set(current.declaration.watch) { return [] }
      return [.set("/watch", YAMLConstruction.strings(values))]
    case .setDictionaryEntry(let id, let key, let value):
      let path = try pointer(id)
      guard case .dictionary = IRTree.value(root, at: path) else {
        throw failure("manifest.edit.readOnly", "expected a dictionary")
      }
      return [.set(path + "/" + pointerEscape(key), YAMLConstruction.nativeValue(value))]
    case .removeDictionaryEntry(let id, let key):
      let path = try pointer(id)
      guard case .dictionary = IRTree.value(root, at: path) else {
        throw failure("manifest.edit.readOnly", "expected a dictionary")
      }
      return [.set(path + "/" + pointerEscape(key), nil)]
    }
  }
  private static func remap(_ handles: [String: String], after edit: IREdit) -> [String: String] {
    var result: [String: String] = [:]
    if case .relocate(let origin, let from, let destination, let to) = edit {
      let prefix = origin + "/" + String(from)
      let carried = handles.filter { $0.value == prefix || $0.value.hasPrefix(prefix + "/") }
      let shifted = remap(
        remap(handles, after: .remove(origin, from)), after: .insert(destination, to, .null))
      return shifted.merging(
        carried.mapValues { destination + "/" + String(to) + $0.dropFirst(prefix.count) }
      ) { _, value in value }
    }
    for (original, path) in handles {
      switch edit {
      case .set(let pointer, _):
        if !path.hasPrefix(pointer + "/") { result[original] = path }
      case .insert(let pointer, let index, _), .remove(let pointer, let index),
        .move(let pointer, let index, _):
        guard path.hasPrefix(pointer + "/") else {
          result[original] = path
          continue
        }
        let suffix = path.dropFirst(pointer.count + 1)
        let segments = suffix.split(separator: "/", maxSplits: 1)
        guard let current = Int(segments[0]) else {
          result[original] = path
          continue
        }
        let next: Int
        switch edit {
        case .insert: next = current >= index ? current + 1 : current
        case .remove:
          if current == index { continue }
          next = current > index ? current - 1 : current
        case .move(_, _, let to):
          if current == index {
            next = to
          } else if index < to && current > index && current <= to {
            next = current - 1
          } else if index > to && current >= to && current < index {
            next = current + 1
          } else {
            next = current
          }
        default: next = current
        }
        result[original] =
          pointer + "/" + String(next) + (segments.count == 2 ? "/" + segments[1] : "")
      case .relocate: break
      }
    }
    return result
  }
  private func failure(_ code: String, _ message: String) -> ManifestFailure {
    document.source.failure(code, message, 0)
  }
}
