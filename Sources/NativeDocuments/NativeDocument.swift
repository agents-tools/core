import AgentsCore
import Foundation
import TOMLSemantics

package typealias NativeDocumentBudget = SemanticBudget

package struct NativeDocument {
  package let bytes: Data
  package let format: NativeDocumentFormat
  let budget: NativeDocumentBudget
  let root: Node
  let source: [UInt8]
  let comments: [Range<Int>]
  let located: Bool

  package init(bytes: Data, format: NativeDocumentFormat, budget: NativeDocumentBudget) throws {
    self = try translated {
      try budget.allocate(bytes.count, stage: "input bytes")
      // Admission and cooperative work precede copies, decoder and parser construction.
      for _ in bytes { try budget.step() }
      try budget.allocate(bytes.count, stage: "UTF8 validation")
      guard String(data: bytes, encoding: .utf8) != nil else {
        throw NativeDocumentError.invalidDocument(code: "utf8", range: nil)
      }
      let source = Array(bytes)
      let root: Node
      let comments: [Range<Int>]
      let located: Bool
      if format == .toml {
        var parser = TOMLIndex(bytes: source, budget: budget)
        root = try parser.parse()
        comments = parser.comments
        located = parser.located
      } else {
        var parser = JSONParser(bytes: source, format: format, budget: budget)
        root = try parser.parse()
        comments = parser.comments
        located = true
      }
      return Self(
        bytes: bytes, format: format, budget: budget, root: root, source: source,
        comments: comments, located: located)
    }
  }

  private init(
    bytes: Data, format: NativeDocumentFormat, budget: NativeDocumentBudget, root: Node,
    source: [UInt8], comments: [Range<Int>], located: Bool
  ) {
    self.bytes = bytes
    self.format = format
    self.budget = budget
    self.root = root
    self.source = source
    self.comments = comments
    self.located = located
  }

  package func read(_ region: NativeRegion) throws -> NativeObservation? {
    try translated {
      guard let node = try resolve(region, on: root) else { return nil }
      return try observation(node, region: region)
    }
  }

  package func prepare(_ edits: [NativeRegionEdit]) throws -> PreparedNativeChange {
    try translated {
      try budget.check()
      var addresses: [[AddressStep]] = []
      for edit in edits {
        guard !edit.region.steps.isEmpty else {
          throw NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, edit.region, [])
        }
        let address = try address(edit.region)
        for (index, previous) in addresses.enumerated() {
          try budget.step(address.reduce(0) { $0 + $1.work } + previous.reduce(0) { $0 + $1.work })
          let conditionalAncestor =
            (edit.isConditionalPrune && previous.count > address.count
              && previous.starts(with: address))
            || (edits[index].isConditionalPrune && address.count > previous.count
              && address.starts(with: previous))
          let orderedAppend =
            (edit.isAppend && previous.starts(with: address)
              && (previous.count > address.count || edits[index].isAppend))
            || (edits[index].isAppend && address.count > previous.count
              && address.starts(with: previous))
          if !conditionalAncestor && !orderedAppend
            && (address.starts(with: previous) || previous.starts(with: address))
          {
            throw NativeDocumentError.unsupportedEdit(.overlappingEdits, edit.region, [])
          }
        }
        let existing = try resolve(edit.region, on: root)
        if edit.isAppend, let existing, existing.kind != .array {
          throw NativeDocumentError.ownershipMismatch(edit.region)
        }
        if case .createdContainer = edit.expected {
          if edit.isConditionalPrune {
            guard let existing, existing.kind == .object || existing.kind == .array else {
              throw NativeDocumentError.ownershipMismatch(edit.region)
            }
          } else {
            guard case .remove = edit, let existing, existing.kind == .object,
              existing.members.isEmpty
            else { throw NativeDocumentError.ownershipMismatch(edit.region) }
          }
        }
        switch edit.expected {
        case .absent:
          guard existing == nil else { throw NativeDocumentError.ownershipMismatch(edit.region) }
        case .owned(let observation), .createdContainer(let observation):
          try budget.step(observation.fingerprint.count)
          guard let existing, try sameRegion(observation.region, edit.region),
            try existing.fingerprint(budget) == observation.fingerprint
          else { throw NativeDocumentError.ownershipMismatch(edit.region) }
        }
        addresses.append(address)
      }
      if !edits.isEmpty && !located {
        throw NativeDocumentError.unsupportedEdit(.syntaxNotLocated, edits[0].region, [])
      }
      var current = self
      var changed: [NativeRegion] = []
      var created: [NativeRegion] = []
      var observed: [Int] = []
      var appended: [(editIndex: Int, ordinal: Int)] = []
      var removed: [([AddressStep], Int)] = []
      try budget.allocate(edits.count, stage: "native edit order")
      var prunes: [Int] = []
      var appends: [Int] = []
      var order: [Int] = []
      for index in edits.indices {
        try budget.step()
        if edits[index].isConditionalPrune {
          prunes.append(index)
        } else if edits[index].isAppend {
          appends.append(index)
        } else {
          order.append(index)
        }
      }
      try prunes.sort {
        try budget.step()
        return addresses[$0].count == addresses[$1].count
          ? $0 < $1 : addresses[$0].count > addresses[$1].count
      }
      try budget.allocate(prunes.count, stage: "conditional prune order")
      order.append(contentsOf: appends)
      order.append(contentsOf: prunes)
      for editIndex in order {
        let edit = edits[editIndex]
        try budget.step()
        let effective = try current.region(edit.region, at: addresses[editIndex], removed: removed)
        let old = try current.resolve(effective, on: current.root)
        if edit.isConditionalPrune {
          guard let old else {
            // Dotted TOML parents can disappear with their last owned entry.
            changed.append(edit.region)
            continue
          }
          guard
            (old.kind == .object && old.members.isEmpty)
              || (old.kind == .array && old.elements.isEmpty)
          else { continue }
          if try current.hasComments(old) { continue }
        }
        let desired: Node?
        var appendedValue: Node?
        switch edit {
        case .put(_, _, let value), .append(_, _, let value):
          let text = try NativeRenderer(format: format, budget: budget, region: edit.region).render(
            value)
          if format == .toml {
            let parsed = try NativeDocument(
              bytes: Data(("value = " + text).utf8), format: .toml, budget: budget)
            appendedValue = parsed.root.members.first?.node
          } else {
            let parsed = try NativeDocument(bytes: Data(text.utf8), format: .json, budget: budget)
            appendedValue = parsed.root
          }
          if edit.isAppend {
            guard let element = appendedValue else {
              throw NativeDocumentError.ownershipMismatch(edit.region)
            }
            if old == nil { try budget.node(depth: effective.steps.count) }
            let array = try old?.copy(budget) ?? Node(.array)
            try budget.allocate(1, stage: "appended occurrence")
            array.elements.append(element)
            desired = array
          } else {
            desired = appendedValue
            appendedValue = nil
          }
        case .remove, .pruneCreatedContainer:
          desired = nil
        }
        if let old, let desired, try old.equal(to: desired, budget: budget) {
          observed.append(editIndex)
          continue
        }
        guard old != nil || desired != nil else {
          throw NativeDocumentError.ownershipMismatch(edit.region)
        }
        if let old, desired == nil, old.kind == .object && old.members.isEmpty {
          guard case .createdContainer = edit.expected else {
            throw NativeDocumentError.ownershipMismatch(edit.region)
          }
          guard try !current.hasComments(old) else {
            throw NativeDocumentError.unsupportedEdit(.ambiguousTrivia, edit.region, old.headers)
          }
        }
        if edit.isAppend && old == nil {
          try budget.allocate(effective.steps.count + 1, stage: "created array evidence")
          created.append(effective)
        }
        try current.createdObjects(old: old, new: desired, path: effective.steps, into: &created)
        let expected = try current.root.copy(budget)
        try current.change(
          expected, steps: effective.steps[...], desired: desired, region: effective,
          created: &created)
        var editor = PatchBuilder(document: current, region: effective)
        let checked: NativeDocument
        do {
          if let appendedValue, old != nil {
            try editor.appendOccurrence(appendedValue, path: effective.steps)
          } else if let old, let desired {
            try editor.diff(old, desired: desired, path: effective.steps)
          } else if let old {
            try editor.remove(old, path: effective.steps)
          } else if let desired {
            try editor.insert(path: effective.steps, value: desired, root: current.root)
          }
          let candidate = try editor.apply()
          checked = try NativeDocument(bytes: candidate, format: format, budget: budget)
        } catch NativeDocumentError.invalidDocument {
          if edit.isConditionalPrune { continue }
          throw NativeDocumentError.unsupportedEdit(
            .wouldRewriteUnownedStructure, edit.region, editor.patches.map(\.range))
        } catch NativeDocumentError.unsupportedEdit(let reason, _, _)
          where edit.isConditionalPrune
          && [.ambiguousTrivia, .syntaxNotLocated, .wouldRewriteUnownedStructure].contains(reason)
        {
          continue
        }
        var nextRemoved = removed
        if desired == nil, case .element(let ordinal) = addresses[editIndex].last {
          try budget.allocate(removed.count + 1, stage: "removed occurrence addresses")
          try budget.allocate(addresses[editIndex].count, stage: "removed occurrence path")
          nextRemoved.append((Array(addresses[editIndex].dropLast()), ordinal))
        }
        try current.removeVanishedContainers(
          expected, checked: checked, edits: edits, prunes: prunes, addresses: addresses,
          removed: nextRemoved)
        guard try checked.root.equal(to: expected, budget: budget) else {
          if edit.isConditionalPrune { continue }
          throw NativeDocumentError.unsupportedEdit(
            .wouldRewriteUnownedStructure, edit.region, editor.patches.map(\.range))
        }
        if edit.isAppend {
          var ordinal = old?.elements.count ?? 0
          for (path, _) in removed {
            try budget.step(path.reduce(0) { $0 + $1.work })
            if path == addresses[editIndex] { ordinal += 1 }
          }
          try budget.allocate(1, stage: "insertion identity")
          appended.append((editIndex, ordinal))
        } else if desired != nil {
          observed.append(editIndex)
        }
        removed = nextRemoved
        current = checked
        changed.append(edit.region)
      }
      var observations: [NativeObservation] = []
      for index in observed {
        let region = try current.region(edits[index].region, at: addresses[index], removed: removed)
        if let node = try current.resolve(region, on: current.root) {
          observations.append(try current.observation(node, region: region))
        }
      }
      var appendedOccurrences: [NativeAppendedOccurrence] = []
      for insertion in appended {
        let index = insertion.editIndex
        let parent = try current.region(edits[index].region, at: addresses[index], removed: removed)
        guard let array = try current.resolve(parent, on: current.root) else {
          throw NativeDocumentError.ownershipMismatch(parent)
        }
        var ordinal = insertion.ordinal
        for (path, _) in removed {
          try budget.step(path.reduce(0) { $0 + $1.work })
          if path == addresses[index] { ordinal -= 1 }
        }
        guard ordinal >= 0 && ordinal < array.elements.count else {
          throw NativeDocumentError.ownershipMismatch(parent)
        }
        let evidence = try current.insertionEvidence(in: array, ordinal: ordinal)
        let region = NativeRegion(parent.steps + [.occurrence(evidence)])
        try budget.allocate(region.steps.count + 1, stage: "insertion observation")
        appendedOccurrences.append(
          NativeAppendedOccurrence(
            editIndex: index,
            observation: try current.observation(array.elements[ordinal], region: region)))
      }
      return PreparedNativeChange(
        bytes: current.bytes, changedRegions: changed, observations: observations,
        createdContainers: created, appendedOccurrences: appendedOccurrences)
    }
  }

  /// A dotted TOML object has no independent syntax to retain after its last entry goes away.
  /// Only explicitly authorized conditional containers may disappear from the expected tree.
  private func removeVanishedContainers(
    _ expected: Node, checked: NativeDocument, edits: [NativeRegionEdit], prunes: [Int],
    addresses: [[AddressStep]], removed: [([AddressStep], Int)]
  ) throws {
    guard format == .toml else { return }
    for index in prunes {
      try budget.step()
      var deleted = false
      for (parent, ordinal) in removed {
        try budget.step(
          parent.reduce(0) { $0 + $1.work } + addresses[index].reduce(0) { $0 + $1.work })
        if addresses[index].count > parent.count,
          addresses[index].prefix(parent.count).elementsEqual(parent),
          addresses[index][parent.count] == .element(ordinal)
        {
          deleted = true
          break
        }
      }
      if deleted { continue }
      let original = edits[index].region
      let region: NativeRegion
      do {
        region = try self.region(original, at: addresses[index], removed: removed, on: expected)
      } catch NativeDocumentError.ownershipMismatch {
        // An earlier conditional prune may already have removed an enclosing occurrence.
        continue
      }
      guard let node = try resolve(region, on: expected), node.kind == .object,
        node.members.isEmpty, node.range == nil, node.headers.isEmpty, node.entry == nil
      else { continue }
      let actual = try checked.region(original, at: addresses[index], removed: removed)
      guard try checked.resolve(actual, on: checked.root) == nil else { continue }
      var created: [NativeRegion] = []
      try change(
        expected, steps: region.steps[...], desired: nil, region: region, created: &created)
    }
  }

  private func sameRegion(_ a: NativeRegion, _ b: NativeRegion) throws -> Bool {
    guard a.steps.count == b.steps.count else { return false }
    for (a, b) in zip(a.steps, b.steps) {
      switch (a, b) {
      case (.key(let a), .key(let b)): if try !budget.equal(a, b) { return false }
      case (.occurrence(let a), .occurrence(let b)):
        let aSize =
          (a.idKey?.utf8.count ?? 0) + (a.id?.utf8.count ?? 0) + (a.snapshot?.count ?? 0)
          + (a.arraySnapshot?.count ?? 0)
          + (a.previous?.count ?? 0) + (a.next?.count ?? 0)
        let bSize =
          (b.idKey?.utf8.count ?? 0) + (b.id?.utf8.count ?? 0) + (b.snapshot?.count ?? 0)
          + (b.arraySnapshot?.count ?? 0)
          + (b.previous?.count ?? 0) + (b.next?.count ?? 0)
        try budget.step(aSize + bSize + 1)
        if a != b { return false }
      default: return false
      }
    }
    return true
  }

  private enum AddressStep: Equatable {
    case key(Data)
    case element(Int)
    case append(Data, Data)
    var work: Int {
      switch self {
      case .key(let bytes): bytes.count
      case .element: 1
      case .append(let key, let id): key.count + id.count + 1
      }
    }
  }

  private func address(_ region: NativeRegion) throws -> [AddressStep] {
    try budget.enter(region.steps.count)
    var node: Node? = root
    var result: [AddressStep] = []
    for step in region.steps {
      try budget.step()
      switch step {
      case .key(let key):
        try budget.allocate(key.utf8.count + 1, stage: "region address")
        result.append(.key(Data(key.utf8)))
        if let current = node, let i = try current.member(key, budget: budget) {
          node = current.members[i].node
        } else {
          node = nil
        }
      case .occurrence(let evidence):
        guard let current = node else { throw NativeDocumentError.ownershipMismatch(region) }
        do {
          let i = try occurrence(evidence, in: current, region: region)
          result.append(.element(i))
          node = current.elements[i]
        } catch NativeDocumentError.ownershipMismatch {
          guard current.kind == .array, let key = evidence.idKey, let id = evidence.id,
            result.count == region.steps.count - 1
          else { throw NativeDocumentError.ownershipMismatch(region) }
          try budget.allocate(key.utf8.count + id.utf8.count + 1, stage: "new occurrence address")
          result.append(.append(Data(key.utf8), Data(id.utf8)))
          node = nil
        }
      }
    }
    return result
  }

  /// Addresses refer to the original snapshot. Only removals can shift other owned occurrences.
  private func region(
    _ original: NativeRegion, at address: [AddressStep], removed: [([AddressStep], Int)],
    on startingRoot: Node? = nil
  ) throws -> NativeRegion {
    var node: Node? = startingRoot ?? root
    var steps: [NativePathStep] = []
    for (index, step) in original.steps.enumerated() {
      try budget.step()
      switch step {
      case .key(let key):
        steps.append(step)
        if let current = node, let i = try current.member(key, budget: budget) {
          node = current.members[i].node
        } else {
          node = nil
        }
      case .occurrence(let evidence):
        if case .append = address[index] {
          steps.append(step)
          node = nil
          continue
        }
        guard let current = node, case .element(let ordinal) = address[index] else {
          throw NativeDocumentError.ownershipMismatch(original)
        }
        let prefix = Array(address.prefix(index))
        var shift = 0
        for (parent, deleted) in removed {
          try budget.step(prefix.reduce(0) { $0 + $1.work } + parent.reduce(0) { $0 + $1.work })
          if parent == prefix && deleted < ordinal { shift += 1 }
        }
        let i = ordinal - shift
        guard i >= 0 && i < current.elements.count else {
          throw NativeDocumentError.ownershipMismatch(original)
        }
        let element = current.elements[i]
        let next: NativeOccurrenceEvidence
        if evidence.arraySnapshot != nil {
          next = try insertionEvidence(in: current, ordinal: i)
        } else if let key = evidence.idKey, let m = try element.member(key, budget: budget),
          element.members[m].node.kind == .string
        {
          next = .init(idKey: key, id: element.members[m].node.text)
        } else {
          next = .init(
            snapshot: try element.fingerprint(budget), ordinal: i,
            previous: i > 0 ? try current.elements[i - 1].fingerprint(budget) : nil,
            next: i + 1 < current.elements.count
              ? try current.elements[i + 1].fingerprint(budget) : nil)
        }
        // Newly ambiguous evidence cannot become a later ownership capability.
        guard try occurrence(next, in: current, region: original) == i else {
          throw NativeDocumentError.unsupportedEdit(.ambiguousOccurrence, original, [])
        }
        steps.append(.occurrence(next))
        node = element
      }
    }
    return NativeRegion(steps)
  }

  func hasComments(_ node: Node) throws -> Bool {
    for comment in comments {
      try budget.step()
      if let range = node.range, range.overlaps(comment) { return true }
      for header in node.headers {
        try budget.step()
        if comment.lowerBound >= header.lowerBound
          && comment.lowerBound < (node.insertion ?? header.upperBound)
        {
          return true
        }
      }
    }
    return false
  }

  private func insertionEvidence(in array: Node, ordinal: Int) throws -> NativeOccurrenceEvidence {
    .init(
      snapshot: try array.elements[ordinal].fingerprint(budget), ordinal: ordinal,
      previous: ordinal > 0 ? try array.elements[ordinal - 1].fingerprint(budget) : nil,
      next: ordinal + 1 < array.elements.count
        ? try array.elements[ordinal + 1].fingerprint(budget) : nil,
      arraySnapshot: try array.fingerprint(budget))
  }

  func occurrence(_ evidence: NativeOccurrenceEvidence, in node: Node, region: NativeRegion) throws
    -> Int
  {
    guard node.kind == .array else { throw NativeDocumentError.ownershipMismatch(region) }
    if let arraySnapshot = evidence.arraySnapshot {
      try budget.step(arraySnapshot.count + (evidence.snapshot?.count ?? 0))
      guard let ordinal = evidence.ordinal, let snapshot = evidence.snapshot,
        ordinal >= 0 && ordinal < node.elements.count,
        try node.fingerprint(budget) == arraySnapshot,
        try node.elements[ordinal].fingerprint(budget) == snapshot
      else { throw NativeDocumentError.ownershipMismatch(region) }
      return ordinal
    }
    var matches: [Int] = []
    for (i, element) in node.elements.enumerated() {
      try budget.step()
      if let key = evidence.idKey, let id = evidence.id,
        let m = try element.member(key, budget: budget), element.members[m].node.kind == .string
      {
        if try budget.equal(element.members[m].node.text, id) { matches.append(i) }
      } else if let snapshot = evidence.snapshot {
        try budget.step(snapshot.count)
        if try element.fingerprint(budget) == snapshot { matches.append(i) }
      }
    }
    if evidence.idKey == nil && matches.count > 1 {
      var contextual: [Int] = []
      func same(_ a: Data?, _ b: Data?) throws -> Bool {
        switch (a, b) {
        case (.some(let a), .some(let b)):
          try budget.step(a.count + b.count)
          return a == b
        case (.none, .none): return true
        default: return false
        }
      }
      for i in matches {
        let previous = i > 0 ? try node.elements[i - 1].fingerprint(budget) : nil
        let next = i + 1 < node.elements.count ? try node.elements[i + 1].fingerprint(budget) : nil
        if try same(previous, evidence.previous) && same(next, evidence.next) {
          contextual.append(i)
        }
      }
      matches = contextual
    }
    guard !matches.isEmpty else { throw NativeDocumentError.ownershipMismatch(region) }
    guard matches.count == 1, let match = matches.first else {
      throw NativeDocumentError.unsupportedEdit(.ambiguousOccurrence, region, [])
    }
    return match
  }

  func resolve(_ region: NativeRegion, on root: Node) throws -> Node? {
    var node = root
    for step in region.steps {
      try budget.step()
      switch step {
      case .key(let key):
        guard node.kind == .object, let i = try node.member(key, budget: budget) else { return nil }
        node = node.members[i].node
      case .occurrence(let evidence):
        do {
          node = node.elements[try occurrence(evidence, in: node, region: region)]
        } catch NativeDocumentError.ownershipMismatch { return nil }
      }
    }
    return node
  }

  private func entryRanges(_ node: Node) throws -> [Range<Int>] {
    try budget.step()
    if let entry = node.entry {
      try budget.allocate(1, stage: "observation ranges")
      return [entry]
    }
    try budget.allocate(node.headers.count, stage: "observation ranges")
    var ranges = node.headers
    for member in node.members {
      let children = try entryRanges(member.node)
      try budget.allocate(children.count, stage: "observation ranges")
      ranges += children
    }
    for element in node.elements {
      let children = try entryRanges(element)
      try budget.allocate(children.count, stage: "observation ranges")
      ranges += children
    }
    return ranges
  }

  private func observation(_ node: Node, region: NativeRegion) throws -> NativeObservation {
    var occurrences: [NativeOccurrenceEvidence] = []
    if node.kind == .array {
      var prints: [Data] = []
      for e in node.elements { prints.append(try e.fingerprint(budget)) }
      for i in prints.indices {
        occurrences.append(
          .init(
            snapshot: prints[i], ordinal: i, previous: i > 0 ? prints[i - 1] : nil,
            next: i + 1 < prints.count ? prints[i + 1] : nil))
      }
    }
    return NativeObservation(
      region: region, value: try node.project(budget),
      nativeKind: node.atomType ?? node.kind.rawValue,
      numericLexeme: node.kind == .integer || node.kind == .decimal ? node.raw : nil,
      projectionFailure: try node.projectionFailure(budget),
      valueRange: node.range, entryRanges: try entryRanges(node),
      occurrences: occurrences, fingerprint: try node.fingerprint(budget))
  }

  private func createdObjects(
    old: Node?, new: Node?, path: [NativePathStep], into result: inout [NativeRegion]
  ) throws {
    guard let new, new.kind == .object else { return }
    try budget.step()
    if old?.kind != .object {
      try budget.allocate(path.count + 1, stage: "created container evidence")
      result.append(NativeRegion(path))
    }
    for member in new.members {
      let previous = try old?.member(member.key, budget: budget).map { old!.members[$0].node }
      try budget.allocate(path.count + 1, stage: "created container path")
      try createdObjects(
        old: previous, new: member.node, path: path + [.key(member.key)], into: &result)
    }
  }

  private func change(
    _ node: Node, steps: ArraySlice<NativePathStep>, desired: Node?, region: NativeRegion,
    created: inout [NativeRegion], offset: Int = 0
  ) throws {
    try budget.enter(offset)
    guard let step = steps.first else { throw NativeDocumentError.ownershipMismatch(region) }
    let tail = steps.dropFirst()
    switch step {
    case .key(let key):
      guard node.kind == .object else { throw NativeDocumentError.ownershipMismatch(region) }
      let m = try node.member(key, budget: budget)
      if tail.isEmpty {
        if let m {
          if let desired { node.members[m].node = desired } else { node.members.remove(at: m) }
        } else if let desired {
          node.members.append(Member(key: key, node: desired))
        }
      } else {
        let child: Node
        if let m {
          child = node.members[m].node
        } else {
          guard desired != nil else { throw NativeDocumentError.ownershipMismatch(region) }
          try budget.node(depth: offset)
          child = Node(.object)
          node.members.append(Member(key: key, node: child))
          created.append(NativeRegion(Array(region.steps.prefix(offset + 1))))
        }
        try change(
          child, steps: tail, desired: desired, region: region, created: &created,
          offset: offset + 1)
      }
    case .occurrence(let evidence):
      let i: Int
      do { i = try occurrence(evidence, in: node, region: region) } catch NativeDocumentError
        .ownershipMismatch
      {
        guard node.kind == .array, tail.isEmpty, let desired, desired.kind == .object,
          let key = evidence.idKey, let id = evidence.id,
          let field = try desired.member(key, budget: budget),
          desired.members[field].node.kind == .string,
          try budget.equal(desired.members[field].node.text, id)
        else { throw NativeDocumentError.ownershipMismatch(region) }
        try budget.allocate(1, stage: "new occurrence")
        node.elements.append(desired)
        return
      }
      if tail.isEmpty {
        if let desired { node.elements[i] = desired } else { node.elements.remove(at: i) }
      } else {
        try change(
          node.elements[i], steps: tail, desired: desired, region: region, created: &created,
          offset: offset + 1)
      }
    }
  }
}
