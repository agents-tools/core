import AgentsCore
import AgentsDescription
import Foundation

extension DocumentEditor {
  func apply(_ edit: ManifestEdit) throws {
    switch edit {
    case .setDefaultAgents(let agents): try setField("", "defaultAgents", agents.constructionValue)
    case .setExports(let exports): try setField("", "exports", exports.constructionValue)
    case .setWatch(let watch): try setField("", "watch", watch.constructionValue)
    case .upsertSource(let source):
      try upsert(source.constructionValue, collection: "/sources", key: "name")
    case .removeSource(let alias): try removeNamed(alias, collection: "/sources", key: "name")
    case .upsertGroup(let group):
      try upsert(group.constructionValue, collection: "/groups", key: "name")
    case .removeGroup(let name): try removeNamed(name, collection: "/groups", key: "name")
    case .insertComponent(let component, let container, let position):
      try insert(
        component.constructionValue, into: containerPath(container) + "/components", at: position)
    case .replaceComponent(let handle, let component):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try replace(pointer, with: component.constructionValue)
    case .removeComponent(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try remove(pointer)
    case .moveComponent(let handle, let container, let position):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component")
      try move(pointer, into: containerPath(container) + "/components", at: position)
    case .setSkillSelection(let handle, let selection):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try setField(pointer, "select", selection.constructionValue)
    case .upsertSkillOverride(let handle, let override):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try upsert(override.constructionValue, collection: pointer + "/overrides", key: "name")
    case .removeSkillOverride(let handle, let name):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "skills")
      try removeNamed(name, collection: pointer + "/overrides", key: "name")
    case .insertSection(let section, let handle, let position):
      let pointer = try resolve(handle)
      guard current.values[pointer]?.value.fields["sections"] != nil else {
        throw fail("manifest.edit.readOnly", "target has no instruction sections")
      }
      try insert(section.constructionValue, into: pointer + "/sections", at: position)
    case .removeSection(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "SectionReference")
      try remove(pointer)
    case .moveSection(let handle, let position):
      let pointer = try resolve(handle)
      try requireType(pointer, "SectionReference")
      try move(pointer, into: parent(pointer), at: position)
    case .upsertPrompt(let handle, let prompt):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "instructions")
      try upsert(prompt.constructionValue, collection: pointer + "/chatGPT", key: "name")
    case .removePrompt(let handle, let name):
      let pointer = try resolve(handle)
      try requireType(pointer, "Component", member: "instructions")
      try removeNamed(name, collection: pointer + "/chatGPT", key: "name")
    case .insertGroupReference(let reference, let container, let position):
      try insert(
        reference.constructionValue, into: containerPath(container) + "/uses", at: position)
    case .removeGroupReference(let handle):
      let pointer = try resolve(handle)
      try requireType(pointer, "GroupReference")
      try remove(pointer)
    case .setDictionaryEntry(let handle, let key, let value):
      let pointer = try resolve(handle)
      try dictionary(pointer, key: key, value: value)
    case .removeDictionaryEntry(let handle, let key):
      try dictionary(resolve(handle), key: key, value: nil)
    case .replaceConstant(let handle, let value, let accepted):
      try constant(handle, value: value, accepted: accepted)
    }
  }

  func setField(
    _ pointer: String, _ field: String, _ value: ConstructionValue, spelling: String? = nil
  ) throws {
    let owner = try direct(pointer)
    let node = current.admission.nodes[owner.syntax]
    guard node.kind == .call, let old = owner.value.fields[field] else {
      throw fail("manifest.edit.readOnly", "target is not a direct construction")
    }
    _ = try valueCost(value)
    if Lowering.lower(old) == Lowering.lower(value) { return }
    if let child = owner.field(field), !child.defaulted {
      try replace(pointer + "/" + pointerEscape(field), with: value)
      return
    }
    guard case .named(let type) = owner.type.unwrapped else {
      throw fail("manifest.edit.readOnly", "target has no named construction type")
    }
    let signatures = Vocabulary.signatures.filter {
      $0.type == type && $0.member == owner.value.member
    }
    guard
      let signature = signatures.first(where: {
        $0.parameters.contains(where: { $0.name == field })
      }), let position = signature.parameters.firstIndex(where: { $0.name == field })
    else { throw fail("manifest.edit.readOnly", "unknown construction field") }
    let next = node.arguments.first { argument in
      let index = signature.parameters.firstIndex { $0.label == argument.label } ?? -1
      return index > position
    }
    let (style, indentation) = try style(at: node.range)
    let content =
      field + ": "
      + (spelling
        ?? CanonicalPrinter(style: style).render(value, indentation: indentation + style.indent))
    let multiline = hasNewline(node.range)
    if let next {
      let start =
        next.labelRange?.lowerBound ?? current.admission.nodes[next.value].range.lowerBound
      if multiline {
        let line = lineStart(start)
        if current.bytes[line..<start].allSatisfy({ $0 == UInt8(ascii: " ") }) {
          try patch(line..<line, indentation + style.indent + content + "," + style.newline)
        } else {
          try patch(start..<start, content + ", ")
        }
      } else {
        try patch(start..<start, content + ", ")
      }
    } else {
      let close = node.range.upperBound - 1
      if node.arguments.isEmpty {
        try patch(close..<close, content)
      } else if multiline {
        let last = node.arguments.last!
        let end = current.admission.nodes[last.value].range.upperBound
        if internalComments(end..<close) {
          throw fail("manifest.edit.readOnly", "ambiguous trailing argument comments")
        }
        try patch(end..<end, "," + style.newline + indentation + style.indent + content)
      } else {
        try patch(close..<close, ", " + content)
      }
    }
    try mutate(pointer + "/" + pointerEscape(field), value)
  }

  func upsert(_ value: ConstructionValue, collection: String, key: String) throws {
    guard let old = current.values[collection] else {
      throw fail("manifest.edit.readOnly", "collection has no source map")
    }
    let name = value.fields[key]?.text
    if let index = old.elementsForUse.firstIndex(where: { $0.value.fields[key]?.text == name }) {
      try replace(collection + "/\(index)", with: value)
    } else {
      try insert(value, into: collection, at: .last)
    }
  }

  func removeNamed(_ name: String, collection: String, key: String) throws {
    guard let old = current.values[collection] else {
      throw fail("manifest.edit.readOnly", "collection has no source map")
    }
    if let index = old.elementsForUse.firstIndex(where: { $0.value.fields[key]?.text == name }) {
      try remove(collection + "/\(index)")
    }
  }

  func position(_ position: InsertionPosition, collection: String, count: Int) throws -> Int {
    switch position {
    case .first: return 0
    case .last: return count
    case .before(let handle), .after(let handle):
      let pointer = try resolve(handle)
      guard parent(pointer) == collection, let index = Int(key(pointer)) else {
        throw fail("manifest.edit.impact", "insertion anchor belongs to another container")
      }
      if case .after = position { return index + 1 }
      return index
    }
  }

  func insert(
    _ value: ConstructionValue, into pointer: String, at position: InsertionPosition,
    carried: CarriedElement? = nil
  ) throws {
    guard let collection = current.values[pointer], case .array(let previous) = collection.value
    else { throw fail("manifest.edit.readOnly", "target is not an array") }
    let incoming = try valueCost(value)
    guard previous.count < ManifestLimits.Values.entries else {
      throw fail("manifest.limit", "edited array entries")
    }
    let combined = ValueCost.container(collection.elementsForUse.map(\.cost) + [incoming])
    let total = current.evaluation.total
    let projected = ValueCost(
      nodes: total.nodes - collection.cost.nodes + combined.nodes,
      strings: total.strings - collection.cost.strings + combined.strings,
      encoded: total.encoded - collection.cost.encoded + combined.encoded,
      depth: max(total.depth, incoming.depth + pointer.split(separator: "/").count + 1),
      origins: total.origins - collection.cost.origins + combined.origins)
    guard combined.fits, projected.fits else {
      throw fail("manifest.limit", "edited expanded document budget")
    }
    let index = try self.position(position, collection: pointer, count: previous.count)
    var expectedValues = previous
    expectedValues.insert(value, at: index)
    if collection.defaulted {
      if let carried {
        let owner = try direct(parent(pointer))
        let (style, indentation) = try style(at: current.admission.nodes[owner.syntax].range)
        let text =
          "[" + style.newline + indentation + style.indent + style.indent
          + carried.render(
            indentation: indentation + style.indent + style.indent, newline: style.newline)
          + style.newline + indentation + style.indent
          + "]"
        try setField(parent(pointer), key(pointer), .array(expectedValues), spelling: text)
      } else {
        try setField(parent(pointer), key(pointer), .array(expectedValues))
      }
      return
    }
    _ = try direct(pointer)
    let node = current.admission.nodes[collection.syntax]
    guard node.kind == .array else {
      throw fail("manifest.edit.readOnly", "target is an assembled array")
    }
    let (style, indentation) = try style(at: node.range)
    let multiline =
      hasNewline(node.range)
      || carried?.isMultiline == true
    let rendered =
      carried.map { $0.render(indentation: indentation + style.indent, newline: style.newline) }
      ?? CanonicalPrinter(style: style).render(
        value, indentation: multiline ? indentation + style.indent : indentation)
    if previous.isEmpty {
      let interior = (node.range.lowerBound + 1)..<(node.range.upperBound - 1)
      if !current.bytes[interior].allSatisfy({
        [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains($0)
      }) {
        throw fail(
          "manifest.edit.readOnly", "comment-only container insertion is ambiguous", range: interior
        )
      }
      try patch(
        interior,
        multiline
          ? style.newline + indentation + style.indent + rendered + (carried == nil ? "," : "")
            + style.newline + indentation : rendered)
    } else if index < previous.count {
      let child = collection.elementsForUse[index]
      let owned = try ownedRange(child, container: node, index: index)
      if multiline {
        guard owned.lowerBound == lineStart(owned.lowerBound) else {
          throw fail("manifest.edit.readOnly", "mixed inline and multiline collection layout")
        }
        try patch(
          owned.lowerBound..<owned.lowerBound,
          indentation + style.indent + rendered + (carried == nil ? "," : "") + style.newline)
      } else {
        try patch(owned.lowerBound..<owned.lowerBound, rendered + (carried == nil ? ", " : " "))
      }
    } else {
      let child = collection.elementsForUse.last!
      let range = current.admission.nodes[child.syntax].range
      let close = node.range.upperBound - 1
      let commas = current.admission.tokens.filter {
        $0.text == "," && $0.range.lowerBound >= range.upperBound && $0.range.upperBound <= close
      }
      let gap = range.upperBound..<close
      if internalComments(gap) {
        throw fail(
          "manifest.edit.readOnly", "trailing comments need an unambiguous insertion anchor",
          range: gap)
      }
      if multiline {
        let end = commas.first?.range.upperBound ?? range.upperBound
        try patch(
          end..<end,
          (commas.isEmpty ? "," : "") + style.newline + indentation + style.indent + rendered
            + (carried == nil && !commas.isEmpty ? "," : ""))
      } else {
        try patch(
          close..<close,
          (commas.isEmpty ? ", " : " ") + rendered + (carried == nil && !commas.isEmpty ? "," : ""))
      }
    }
    try mutate(pointer, .array(expectedValues))
  }

  func remove(_ pointer: String) throws {
    let value = try direct(pointer)
    let collectionPointer = parent(pointer)
    let collection = try direct(collectionPointer)
    let node = current.admission.nodes[collection.syntax]
    guard node.kind == .array, let index = Int(key(pointer)),
      case .array(var values) = collection.value
    else { throw fail("manifest.edit.readOnly", "removal requires a direct array element") }
    let range = try ownedRange(value, container: node, index: index)
    let hasComma = current.admission.tokens.contains {
      $0.text == ","
        && $0.range.lowerBound >= current.admission.nodes[value.syntax].range.upperBound
        && $0.range.upperBound <= range.upperBound
    }
    var patches = [SourcePatch(range: range, replacement: [])]
    if !hasComma && index > 0 {
      let previous = current.admission.nodes[node.children[index - 1]].range.upperBound
      if let comma = current.admission.tokens.last(where: {
        $0.text == "," && $0.range.lowerBound >= previous && $0.range.upperBound <= range.lowerBound
      }) {
        patches.append(SourcePatch(range: comma.range, replacement: []))
      } else {
        throw fail("manifest.edit.readOnly", "ambiguous separator ownership", range: range)
      }
    }
    values.remove(at: index)
    for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      try self.patch(patch.range, bytes: patch.replacement)
    }
    try mutate(collectionPointer, .array(values))
  }

  func move(_ pointer: String, into collection: String, at position: InsertionPosition)
    throws
  {
    let value = try direct(pointer)
    let from = parent(pointer)
    guard let old = current.values[from], let index = Int(key(pointer)),
      let target = current.values[collection], case .array = target.value
    else { throw fail("manifest.edit.readOnly", "move requires array containers") }
    let destination = try self.position(
      position, collection: collection, count: target.elementsForUse.count)
    if from == collection && (destination == index || destination == index + 1) { return }
    let node = current.admission.nodes[old.syntax]
    let owned = try ownedRange(value, container: node, index: index)
    let expression = current.admission.nodes[value.syntax].range
    let leading = current.source.spelling(owned.lowerBound..<expression.lowerBound)
    let comma = current.admission.tokens.first {
      $0.text == "," && $0.range.lowerBound >= expression.upperBound
        && $0.range.upperBound <= owned.upperBound
    }
    let beforeComma =
      comma.map { current.source.spelling(expression.upperBound..<$0.range.lowerBound) } ?? ""
    let afterComma = current.source.spelling(
      (comma?.range.upperBound ?? expression.upperBound)..<owned.upperBound)
    let carried = CarriedElement(
      text: leading + current.source.spelling(expression) + beforeComma + "," + afterComma,
      indentation: indentation(at: expression.lowerBound))
    try remove(pointer)
    current = try DeclarationDocument(
      bytes: table.bytes, identity: original.source.identity, validateDomain: false)
    // Stable container coordinates survive removals; same-container positions shift once.
    let refreshed =
      from == collection ? from : try currentPointerForContainer(collection, previous: target)
    let adjusted = from == collection && destination > index ? destination - 1 : destination
    let count = current.values[refreshed]?.elementsForUse.count ?? 0
    let insertion: InsertionPosition
    if adjusted == 0 {
      insertion = .first
    } else if adjusted == count {
      insertion = .last
    } else {
      // Use a current local anchor for the internal move only.
      try insertAtIndex(value.value, pointer: refreshed, index: adjusted, carried: carried)
      return
    }
    try insert(value.value, into: refreshed, at: insertion, carried: carried)
  }

  func insertAtIndex(
    _ value: ConstructionValue, pointer: String, index: Int, carried: CarriedElement
  ) throws {
    // A direct byte anchor avoids manufacturing a public snapshot handle.
    let collection = try direct(pointer)
    let node = current.admission.nodes[collection.syntax]
    let owned = try ownedRange(collection.elementsForUse[index], container: node, index: index)
    let (style, indentation) = try style(at: node.range)
    let multiline = hasNewline(node.range)
    try patch(
      owned.lowerBound..<owned.lowerBound,
      multiline
        ? indentation + style.indent
          + carried.render(indentation: indentation + style.indent, newline: style.newline)
          + style.newline
        : carried.render(indentation: "", newline: style.newline) + " ")
    var values = collection.value.array!
    values.insert(value, at: index)
    try mutate(pointer, .array(values))
  }

  func currentPointerForContainer(_ pointer: String, previous: EvaluatedValue) throws
    -> String
  {
    // Removing a root component cannot move a group definition, and group moves never nest groups.
    if let value = current.values[pointer], value.type == previous.type { return pointer }
    throw fail("manifest.edit.stale", "destination container changed during move")
  }

  func dictionary(_ pointer: String, key: String, value replacement: StaticValue?) throws {
    let value = try direct(pointer)
    if value.type == .named("ConfigurationValue"), value.value.member == "object" {
      try dictionary(pointer + "/value", key: key, value: replacement)
      return
    }
    let node = current.admission.nodes[value.syntax]
    guard node.kind == .dictionary, case .dictionary(let elementType) = value.type.unwrapped,
      case .object(var fields) = value.value
    else { throw fail("manifest.edit.readOnly", "target is not a direct dictionary") }
    if let replacement {
      let replacementValue = try contextualValue(replacement, as: elementType)
      if node.keys.contains(where: { $0.decoded == key }) {
        let childPointer = pointer + "/" + pointerEscape(key)
        try replace(childPointer, with: replacementValue)
        return
      }
      let close = node.range.upperBound - 1
      let (style, indentation) = try style(at: node.range)
      let text =
        quoted(key) + ": "
        + CanonicalPrinter(style: style).render(
          replacementValue, indentation: indentation + style.indent)
      let multiline = hasNewline(node.range)
      if node.children.isEmpty {
        let interior = (node.range.lowerBound + 1)..<close
        guard !internalComments(interior) else {
          throw fail("manifest.edit.readOnly", "comment-only dictionary insertion is ambiguous")
        }
        try patch(interior, text)
      } else {
        let end = current.admission.nodes[node.children.last!].range.upperBound
        guard !internalComments(end..<close) else {
          throw fail("manifest.edit.readOnly", "dictionary trailing comments are ambiguous")
        }
        let comma = current.admission.tokens.first {
          $0.text == "," && $0.range.lowerBound >= end && $0.range.upperBound <= close
        }
        if multiline {
          let at = comma?.range.upperBound ?? end
          try patch(
            at..<at,
            (comma == nil ? "," : "") + style.newline + indentation + style.indent + text
              + (comma == nil ? "" : ","))
        } else {
          try patch(close..<close, (comma == nil ? ", " : " ") + text + (comma == nil ? "" : ","))
        }
      }
      fields[key] = replacementValue
    } else {
      guard let index = node.keys.firstIndex(where: { $0.decoded == key }) else { return }
      let child = current.values[pointer + "/" + pointerEscape(key)]!
      let range = try ownedRange(child, container: node, index: index)
      let childEnd = current.admission.nodes[child.syntax].range.upperBound
      let hasComma = current.admission.tokens.contains {
        $0.text == "," && $0.range.lowerBound >= childEnd && $0.range.upperBound <= range.upperBound
      }
      var patches = [SourcePatch(range: range, replacement: [])]
      if !hasComma && index > 0 {
        let previous = current.admission.nodes[node.children[index - 1]].range.upperBound
        guard
          let comma = current.admission.tokens.last(where: {
            $0.text == "," && $0.range.lowerBound >= previous
              && $0.range.upperBound <= range.lowerBound
          })
        else { throw fail("manifest.edit.readOnly", "dictionary separator is ambiguous") }
        patches.append(SourcePatch(range: comma.range, replacement: []))
      }
      for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        try self.patch(patch.range, bytes: patch.replacement)
      }
      fields.removeValue(forKey: key)
      if fields.isEmpty {
        // The colon is necessary even if retained container whitespace/comments remain.
        let opener = node.range.lowerBound + 1
        try patch(opener..<opener, ":")
      }
    }
    try mutate(pointer, .object(fields))
  }

  func constant(_ handle: NodeID, value: StaticValue, accepted: [NodeID]) throws {
    let pointer = try resolve(handle)
    guard pointer.hasPrefix("/constants/"), let old = current.values[pointer] else {
      throw fail("manifest.edit.readOnly", "replaceConstant requires a definition handle")
    }
    let name = key(pointer)
    let uses = original.uses(ofConstant: name)
    guard Set(uses) == Set(accepted), accepted.allSatisfy({ $0.digest == original.digest }) else {
      throw fail("manifest.edit.impact", "accept the complete impacted reference set")
    }
    let replacementValue = try contextualValue(value, as: old.type)
    if Lowering.lower(old.value) == Lowering.lower(replacementValue) { return }
    let range = current.admission.nodes[old.syntax].range
    if internalComments(range) {
      throw fail(
        "manifest.edit.readOnly", "constant contains unmappable internal comments", range: range)
    }
    let altered = try Evaluator(
      source: current.source, admission: current.admission,
      replacements: [name: StaticValue.checked(replacementValue, type: old.type)]
    ).evaluate()
    func merge(_ old: ConstructionValue, _ new: ConstructionValue, _ expected: ConstructionValue)
      throws -> ConstructionValue
    {
      try charge(1)
      if old == new { return expected }
      switch (old, new, expected) {
      case (.array(let a), .array(let b), .array(let e))
      where a.count == b.count && a.count == e.count:
        return .array(try a.indices.map { try merge(a[$0], b[$0], e[$0]) })
      case (.node(let t, let m, let a), .node(let nt, let nm, let b), .node(_, _, let e))
      where t == nt && m == nm && a.keys == b.keys && a.keys == e.keys:
        var result = e
        for key in a.keys { result[key] = try merge(a[key]!, b[key]!, e[key]!) }
        return .node(type: t, member: m, fields: result)
      case (.object(let a), .object(let b), .object(let e))
      where a.keys == b.keys && a.keys == e.keys:
        var result = e
        for key in a.keys { result[key] = try merge(a[key]!, b[key]!, e[key]!) }
        return .object(result)
      default: return new
      }
    }
    expected = try merge(current.evaluation.root.value, altered.root.value, expected)
    impacted += uses
    try patch(range, replacementText(replacementValue, at: range))
    if let declaration = current.admission.declarations.first(where: { $0.name == name }),
      declaration.type == nil,
      needsContext(replacementValue, type: old.type)
    {
      let offset = declaration.nameRange.upperBound
      try patch(offset..<offset, ": " + (try typeSpelling(old.type)))
    }
  }

  func needsContext(_ value: ConstructionValue, type: ConstructionType) -> Bool {
    switch (value, type) {
    case (.text, .named("String")), (.integer, .named("Int")), (.boolean, .named("Bool")):
      return false
    case (.node(let type, _, _), _) where type == "Agents": return false
    case (.array(let values), .array(let element)):
      return values.first.map { needsContext($0, type: element) } ?? true
    case (.object(let fields), .dictionary(let element)):
      return fields.keys.sorted(by: utf8Less).first.map { needsContext(fields[$0]!, type: element) }
        ?? true
    default: return true
    }
  }

  func typeSpelling(_ type: ConstructionType) throws -> String {
    switch type {
    case .untyped: throw fail("manifest.edit.readOnly", "value has no construction type")
    case .named(let name): return name
    case .array(let element): return "[" + (try typeSpelling(element)) + "]"
    case .dictionary(let element): return "[String: " + (try typeSpelling(element)) + "]"
    case .optional(let element): return try typeSpelling(element)
    }
  }
}
