import AgentsCore
import Foundation
import NativeDocuments
import Testing

@Test(arguments: ["json", "jsonc", "toml-table", "toml-dotted", "toml-inline"])
func childRemovalPrunesCreatedAncestorsInOnePrepare(_ syntax: String) throws {
  let source: String
  let format: NativeDocumentFormat
  switch syntax {
  case "json":
    source = #"{"keep":true,"outer":{"inner":{"owned":1}}}"#
    format = .json
  case "jsonc":
    source = #"{/* root note */"keep":true,"outer":{"inner":{"owned":1}}}"#
    format = .jsonc(trailingCommas: false)
  case "toml-table":
    source = "keep=true\n[outer.inner]\nowned=1\n"
    format = .toml
  case "toml-dotted":
    source = "keep=true\nouter.inner.owned=1\n"
    format = .toml
  default:
    source = "keep=true\nouter={inner={owned=1}}\n"
    format = .toml
  }
  let doc = try document(source, format)
  let outer = keyRegion("outer")
  let inner = keyRegion("outer", "inner")
  let child = keyRegion("outer", "inner", "owned")
  let pruneOuter = NativeRegionEdit.pruneCreatedContainer(
    region: outer, observed: try #require(try doc.read(outer)))
  let pruneInner = NativeRegionEdit.pruneCreatedContainer(
    region: inner, observed: try #require(try doc.read(inner)))
  let removal = NativeRegionEdit.remove(region: child, expected: try owned(doc, child))
  let result = try doc.prepare([pruneOuter, removal, pruneInner])
  #expect(try doc.prepare([removal, pruneInner, pruneOuter]).bytes == result.bytes)
  let checked = try NativeDocument(bytes: result.bytes, format: format, budget: generousBudget())
  #expect(try checked.read(outer) == nil)
  #expect(try checked.read(keyRegion("keep"))?.value == .boolean(true))
  #expect(result.changedRegions.contains(outer))
  #expect(result.changedRegions.contains(inner))
  if syntax == "json" { #expect(text(result) == #"{"keep":true}"#) }
  if syntax == "jsonc" { #expect(text(result) == #"{/* root note */"keep":true}"#) }
  if format == .toml { #expect(text(result).hasPrefix("keep=true\n")) }
}

@Test(arguments: ["jsonc", "jsonc-between", "toml"])
func conditionalPruningRetainsCommentsAndUnmanagedSiblings(_ syntax: String) throws {
  let source: String
  switch syntax {
  case "jsonc":
    source = #"{"outer":{"owned":1 /* keep note */},"other":{"owned":2,"unmanaged":3},"empty":{}}"#
  case "jsonc-between":
    source = #"{"outer":/* keep note */{"owned":1},"other":{"owned":2,"unmanaged":3},"empty":{}}"#
  default:
    source = "[outer] # keep note\nowned=1\n[other]\nowned=2\nunmanaged=3\n[empty]\n"
  }
  let format: NativeDocumentFormat =
    syntax.hasPrefix("jsonc") ? .jsonc(trailingCommas: true) : .toml
  let doc = try document(source, format)
  var edits: [NativeRegionEdit] = []
  for name in ["outer", "other"] {
    let parent = keyRegion(name)
    let child = keyRegion(name, "owned")
    edits.append(
      .pruneCreatedContainer(region: parent, observed: try #require(try doc.read(parent))))
    edits.append(.remove(region: child, expected: try owned(doc, child)))
  }
  let result = try doc.prepare(edits)
  let checked = try NativeDocument(bytes: result.bytes, format: format, budget: generousBudget())
  #expect(try checked.read(keyRegion("outer"))?.value == .object([:]))
  #expect(try checked.read(keyRegion("other"))?.value == .object(["unmanaged": .integer(3)]))
  #expect(try checked.read(keyRegion("empty"))?.value == .object([:]))
  #expect(text(result).contains("keep note"))
  #expect(!result.changedRegions.contains(keyRegion("outer")))
  #expect(!result.changedRegions.contains(keyRegion("other")))
  if syntax == "toml" {
    #expect(text(result).contains("[outer] # keep note\n"))
    #expect(text(result).hasSuffix("unmanaged=3\n[empty]\n"))
  } else {
    #expect(text(result).contains("/* keep note */"))
    #expect(text(result).hasSuffix(#""unmanaged":3},"empty":{}}"#))
  }
}

@Test func creationResultsSupplyOnlyTheContainersActuallyCreated() throws {
  let original = try document(#"{"existing":{},"keep":true}"#, .json)
  let child = keyRegion("outer", "inner", "owned")
  let installation = try original.prepare([
    .put(region: child, expected: .absent, value: .integer(1))
  ])
  #expect(!installation.createdContainers.contains(keyRegion("existing")))
  let fresh = try NativeDocument(
    bytes: installation.bytes, format: .json, budget: generousBudget())
  var edits: [NativeRegionEdit] = [.remove(region: child, expected: try owned(fresh, child))]
  for region in installation.createdContainers {
    edits.append(
      .pruneCreatedContainer(region: region, observed: try #require(try fresh.read(region))))
  }
  let removal = try fresh.prepare(edits)
  #expect(removal.bytes == original.bytes)
}

@Test func pruningUsesFreshRegionEvidenceWithoutAdoptingEmptyContainers() throws {
  let original = try document(#"{"created":{"owned":1},"equal":{"owned":1},"unowned":{}}"#, .json)
  let parent = keyRegion("created")
  let child = keyRegion("created", "owned")
  let observation = try #require(try original.read(parent))
  let changed = try document(#"{"created":{"owned":2},"equal":{"owned":1},"unowned":{}}"#, .json)
  do {
    _ = try changed.prepare([
      .remove(region: child, expected: owned(changed, child)),
      .pruneCreatedContainer(region: parent, observed: observation),
    ])
    Issue.record("stale creation observation authorized a draft")
  } catch NativeDocumentError.ownershipMismatch {}
  do {
    _ = try original.prepare([
      .pruneCreatedContainer(region: keyRegion("equal"), observed: observation)
    ])
    Issue.record("equal payload supplied another region's authority")
  } catch NativeDocumentError.ownershipMismatch {}
  let removal = try original.prepare([.remove(region: child, expected: owned(original, child))])
  let checked = try NativeDocument(bytes: removal.bytes, format: .json, budget: generousBudget())
  #expect(try checked.read(parent)?.value == .object([:]))
  #expect(try checked.read(keyRegion("unowned"))?.value == .object([:]))
  #expect(throws: NativeDocumentError.self) {
    try original.prepare([
      .pruneCreatedContainer(
        region: NativeRegion(keys: []),
        observed: #require(try original.read(NativeRegion(keys: []))))
    ])
  }
  let commented = try document(
    #"{"created":{/* new note */"owned":1},"equal":{"owned":1},"unowned":{}}"#,
    .jsonc(trailingCommas: false))
  let retained = try commented.prepare([
    .remove(region: child, expected: owned(commented, child)),
    .pruneCreatedContainer(region: parent, observed: observation),
  ])
  #expect(text(retained).contains(#""created":{/* new note */}"#))
}

@Test func conditionalAncestorsDoNotWeakenOrdinaryOverlapChecks() throws {
  let doc = try document(#"{"outer":{"child":{"owned":1}}}"#, .json)
  let parent = keyRegion("outer")
  let child = keyRegion("outer", "child")
  let parentObservation = try #require(try doc.read(parent))
  let childObservation = try #require(try doc.read(child))
  let conflicting: [[NativeRegionEdit]] = [
    [
      .remove(region: parent, expected: .owned(parentObservation)),
      .remove(region: child, expected: .owned(childObservation)),
    ],
    [
      .remove(region: parent, expected: .owned(parentObservation)),
      .pruneCreatedContainer(region: child, observed: childObservation),
    ],
    [
      .pruneCreatedContainer(region: parent, observed: parentObservation),
      .pruneCreatedContainer(region: parent, observed: parentObservation),
    ],
  ]
  for edits in conflicting {
    do {
      _ = try doc.prepare(edits)
      Issue.record("overlapping mandatory/duplicate authority was accepted")
    } catch NativeDocumentError.unsupportedEdit(.overlappingEdits, _, _) {}
  }
  do {
    _ = try doc.prepare([.remove(region: parent, expected: .createdContainer(parentObservation))])
    Issue.record("mandatory creation-only removal accepted a populated preimage")
  } catch NativeDocumentError.ownershipMismatch {}
}

@Test(arguments: ["json", "toml"])
func conditionalPruningRemapsOccurrencesAfterOwnedRemovals(_ syntax: String) throws {
  let source =
    syntax == "json"
    ? #"{"items":[{"id":"first","owned":0},{"payload":{"owned":1}},{"keep":true}],"outside":7}"#
    : "[[items]]\nid='first'\nowned=0\n[[items]]\n[items.payload]\nowned=1\n[[items]]\nkeep=true\n[outside]\nx=7\n"
  let format: NativeDocumentFormat = syntax == "json" ? .json : .toml
  let doc = try document(source, format)
  let array = keyRegion("items")
  let occurrences = try #require(try doc.read(array)).occurrences
  let first = NativeRegion([.key("items"), .occurrence(.init(idKey: "id", id: "first"))])
  let selected = NativeRegion([.key("items"), .occurrence(occurrences[1])])
  let payload = NativeRegion(selected.steps + [.key("payload")])
  let child = NativeRegion(payload.steps + [.key("owned")])
  let kept = NativeRegion([.key("items"), .occurrence(occurrences[2]), .key("keep")])
  let result = try doc.prepare([
    .pruneCreatedContainer(region: array, observed: #require(try doc.read(array))),
    .pruneCreatedContainer(region: selected, observed: #require(try doc.read(selected))),
    .remove(region: first, expected: owned(doc, first)),
    .remove(region: child, expected: owned(doc, child)),
    .put(region: kept, expected: owned(doc, kept), value: .boolean(false)),
    .pruneCreatedContainer(region: payload, observed: #require(try doc.read(payload))),
  ])
  let checked = try NativeDocument(bytes: result.bytes, format: format, budget: generousBudget())
  #expect(try checked.read(array)?.value == .array([.object(["keep": .boolean(false)])]))
  #expect(!result.changedRegions.contains(array))
  let observation = try #require(result.observations.first)
  #expect(try checked.read(observation.region)?.value == .boolean(false))
  if syntax == "json" {
    #expect(text(result) == #"{"items":[{"keep":false}],"outside":7}"#)
  } else {
    #expect(text(result).hasSuffix("keep=false\n[outside]\nx=7\n"))
  }
}

@Test func implicitTOMLParentsRequireTheirOwnCreationAuthority() throws {
  let doc = try document("outer.inner.owned=1\nkeep=true\n")
  let inner = keyRegion("outer", "inner")
  let child = keyRegion("outer", "inner", "owned")
  do {
    _ = try doc.prepare([
      .remove(region: child, expected: owned(doc, child)),
      .pruneCreatedContainer(region: inner, observed: #require(try doc.read(inner))),
    ])
    Issue.record("an unrecorded implicit ancestor disappeared")
  } catch NativeDocumentError.unsupportedEdit(.wouldRewriteUnownedStructure, _, _) {}
}

@Test(arguments: ["json", "toml"])
func lastOwnedOccurrenceAndCreatedArrayCanBeRemovedTogether(_ syntax: String) throws {
  let format: NativeDocumentFormat = syntax == "json" ? .json : .toml
  let doc = try document(
    syntax == "json" ? #"{"items":[{"owned":1}]}"# : "[[items]]\nowned=1\n", format)
  let array = keyRegion("items")
  let occurrence = NativeRegion([
    .key("items"), .occurrence(try #require(try doc.read(array)).occurrences[0]),
  ])
  let result = try doc.prepare([
    .remove(region: occurrence, expected: owned(doc, occurrence)),
    .pruneCreatedContainer(region: array, observed: #require(try doc.read(array))),
  ])
  let checked = try NativeDocument(bytes: result.bytes, format: format, budget: generousBudget())
  #expect(try checked.read(NativeRegion(keys: []))?.value == .object([:]))
}

@Test(arguments: ["json", "toml"])
func conditionalPruningDoesNotResolveNewAmbiguityByPosition(_ syntax: String) throws {
  let format: NativeDocumentFormat = syntax == "json" ? .json : .toml
  let doc = try document(
    syntax == "json"
      ? #"{"items":[{},{},{"owned":1},{},{}]}"# : "items=[{},{},{owned=1},{},{}]\n", format)
  let evidence = try #require(try doc.read(keyRegion("items"))).occurrences[2]
  let selected = NativeRegion([.key("items"), .occurrence(evidence)])
  let child = NativeRegion(selected.steps + [.key("owned")])
  do {
    _ = try doc.prepare([
      .remove(region: child, expected: owned(doc, child)),
      .pruneCreatedContainer(region: selected, observed: #require(try doc.read(selected))),
    ])
    Issue.record("an ambiguous empty occurrence was selected by its old position")
  } catch NativeDocumentError.unsupportedEdit(.ambiguousOccurrence, _, _) {}
}
