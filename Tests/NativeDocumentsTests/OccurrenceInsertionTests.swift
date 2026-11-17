import AgentsCore
import Foundation
import NativeDocuments
import Testing

@Suite("Ordered native occurrence insertion")
struct OccurrenceInsertionTests {
  @Test func equalUnmanagedHooksRemainDistinctAndOwnersRemoveIndependently() throws {
    let source =
      #"{"hooks":{"SessionStart":[{"command":"check"},{"command":"check"}]},"other":true}"#
    let array = keyRegion("hooks", "SessionStart")
    let hook = NativeValue.object(["command": .string("check")])
    let original = try document(source, .json)
    let added = try original.prepare([
      .append(region: array, expected: owned(original, array), value: hook),
      .append(region: array, expected: owned(original, array), value: hook),
    ])
    #expect(
      text(added)
        == source.replacingOccurrences(
          of: "]}", with: ", {\"command\": \"check\"}, {\"command\": \"check\"}]}"))
    #expect(added.appendedOccurrences.map(\.editIndex) == [0, 1])
    let first = added.appendedOccurrences[0].observation
    let second = added.appendedOccurrences[1].observation
    #expect(first.region != second.region)
    let live = try NativeDocument(bytes: added.bytes, format: .json, budget: generousBudget())
    #expect(try live.read(first.region)?.value == hook)
    #expect(try live.read(second.region)?.value == hook)
    let removed = try live.prepare([
      .remove(region: first.region, expected: .owned(first)),
      .put(region: second.region, expected: .owned(second), value: hook),
    ])
    #expect(removed.observations.count == 1)
    let retained = try #require(removed.observations.first)
    let fresh = try NativeDocument(bytes: removed.bytes, format: .json, budget: generousBudget())
    // A stale duplicate must not move ownership to the last equal unmanaged occurrence.
    #expect(try fresh.read(second.region) == nil)
    let restored = try fresh.prepare([
      .remove(region: retained.region, expected: .owned(retained))
    ])
    #expect(text(restored) == source.replacingOccurrences(of: "]}", with: "  ]}"))
  }

  @Test func appendPreservesJSONCCommentsAndCreatesOnlyMissingContainers() throws {
    let source =
      "{\n  \"hooks\": {\"BeforeAgent\": [\n    {\"command\":\"unmanaged\"} // retained\n  ]},\n  // sibling\n  \"other\": 7\n}"
    let original = try document(source, .jsonc(trailingCommas: true))
    let array = keyRegion("hooks", "BeforeAgent")
    let changed = try original.prepare([
      .append(
        region: array, expected: owned(original, array), value: .object(["command": .string("new")])
      )
    ])
    #expect(
      text(changed)
        == source.replacingOccurrences(
          of: "{\"command\":\"unmanaged\"} // retained\n",
          with: "{\"command\":\"unmanaged\"}, // retained\n    {\"command\": \"new\"}\n"))
    let empty = try document("{\"other\":7}", .json)
    let created = try empty.prepare([
      .append(region: array, expected: .absent, value: .object(["command": .string("new")]))
    ])
    let new = try NativeDocument(bytes: created.bytes, format: .json, budget: generousBudget())
    #expect(try new.read(array)?.occurrences.count == 1)
    #expect(try new.read(keyRegion("other"))?.value == .integer(7))
    #expect(created.createdContainers.contains(keyRegion("hooks")))
    #expect(created.createdContainers.contains(array))
    let inserted = try #require(created.appendedOccurrences.first).observation
    let removed = try new.prepare([
      .pruneCreatedContainer(
        region: keyRegion("hooks"), observed: #require(try new.read(keyRegion("hooks")))),
      .pruneCreatedContainer(region: array, observed: #require(try new.read(array))),
      .remove(region: inserted.region, expected: .owned(inserted)),
    ])
    #expect(text(removed) == "{\"other\":7}")
  }

  @Test func createdContainersUnderSnapshotParentsResolveAndPrune() throws {
    for removeEarlier in [false, true] {
      let source =
        removeEarlier
        ? #"{"items":[{"remove":true},{"keep":true}]}"# : #"{"items":[{"keep":true}]}"#
      let original = try document(source, .json)
      let items = keyRegion("items")
      let occurrences = try #require(try original.read(items)).occurrences
      let parent = NativeRegion(items.steps + [.occurrence(occurrences[removeEarlier ? 1 : 0])])
      let array = NativeRegion(parent.steps + [.key("nested"), .key("hooks")])
      var edits: [NativeRegionEdit] = [
        .append(region: array, expected: .absent, value: .integer(1)),
        .append(region: array, expected: .absent, value: .integer(2)),
      ]
      if removeEarlier {
        let first = NativeRegion(items.steps + [.occurrence(occurrences[0])])
        edits.append(.remove(region: first, expected: try owned(original, first)))
      }
      let changed = try original.prepare(edits)
      let live = try NativeDocument(bytes: changed.bytes, format: .json, budget: generousBudget())
      #expect(changed.createdContainers.count == 2)
      var removals: [NativeRegionEdit] = []
      for region in changed.createdContainers {
        let observed = try #require(try live.read(region))
        removals.append(.pruneCreatedContainer(region: region, observed: observed))
      }
      for insertion in changed.appendedOccurrences {
        removals.append(
          .remove(region: insertion.observation.region, expected: .owned(insertion.observation)))
      }
      let restored = try live.prepare(removals)
      let restoredDocument = try NativeDocument(
        bytes: restored.bytes, format: .json, budget: generousBudget())
      #expect(
        try restoredDocument.read(items)?.value == .array([.object(["keep": .boolean(true)])]))
      #expect(!text(restored).contains("nested"))
    }
  }

  @Test func tomlOccurrencesAppendWithoutNativeIDsAndPreserveUnrelatedBytes() throws {
    for source in [
      "hooks = [{ command = 'keep' }] # retained\nother = 7\n",
      "# retained\nother = 7\n[[hooks]]\ncommand = 'keep'\n",
    ] {
      let original = try document(source)
      let array = keyRegion("hooks")
      let changed = try original.prepare([
        .append(
          region: array, expected: owned(original, array),
          value: .object(["command": .string("new")]))
      ])
      #expect(text(changed).contains("command = 'keep'"))
      #expect(text(changed).contains("# retained\n"))
      #expect(text(changed).contains("other = 7\n"))
      #expect(!text(changed).contains("id"))
      let live = try NativeDocument(bytes: changed.bytes, format: .toml, budget: generousBudget())
      let inserted = try #require(changed.appendedOccurrences.first).observation
      let removed = try live.prepare([.remove(region: inserted.region, expected: .owned(inserted))])
      #expect(text(removed) == (source.hasPrefix("#") ? source + "\n\n" : source))
    }
  }

  @Test func sameSnapshotRemovalAppendAndRefreshPreserveOrder() throws {
    let original = try document(#"{"items":["unmanaged","old","retained"]}"#, .json)
    let array = keyRegion("items")
    let entries = try #require(try original.read(array)).occurrences
    let old = NativeRegion(array.steps + [.occurrence(entries[1])])
    let retained = NativeRegion(array.steps + [.occurrence(entries[2])])
    let changed = try original.prepare([
      .append(region: array, expected: owned(original, array), value: .string("new")),
      .remove(region: old, expected: owned(original, old)),
      .put(region: retained, expected: owned(original, retained), value: .string("retained")),
      .append(region: array, expected: owned(original, array), value: .string("last")),
    ])
    let live = try NativeDocument(bytes: changed.bytes, format: .json, budget: generousBudget())
    #expect(
      try live.read(array)?.value
        == .array([.string("unmanaged"), .string("retained"), .string("new"), .string("last")]))
    #expect(changed.appendedOccurrences.map(\.editIndex) == [0, 3])
    #expect(
      try live.read(changed.appendedOccurrences[0].observation.region)?.value == .string("new"))
    #expect(
      try live.read(changed.appendedOccurrences[1].observation.region)?.value == .string("last"))
  }

  @Test func appendRetainsIdentityThroughConditionalOccurrencePruning() throws {
    let original = try document(#"{"items":[{"payload":{"owned":1}},{"unmanaged":true}]}"#, .json)
    let array = keyRegion("items")
    let first = try #require(try original.read(array)).occurrences[0]
    let selected = NativeRegion(array.steps + [.occurrence(first)])
    let payload = NativeRegion(selected.steps + [.key("payload")])
    let child = NativeRegion(payload.steps + [.key("owned")])
    let changed = try original.prepare([
      .append(
        region: array, expected: owned(original, array), value: .object(["new": .boolean(true)])),
      .pruneCreatedContainer(region: selected, observed: #require(try original.read(selected))),
      .pruneCreatedContainer(region: payload, observed: #require(try original.read(payload))),
      .remove(region: child, expected: owned(original, child)),
    ])
    let live = try NativeDocument(bytes: changed.bytes, format: .json, budget: generousBudget())
    let inserted = try #require(changed.appendedOccurrences.first).observation
    #expect(
      try live.read(array)?.value
        == .array([
          .object(["unmanaged": .boolean(true)]), .object(["new": .boolean(true)]),
        ]))
    #expect(try live.read(inserted.region)?.value == .object(["new": .boolean(true)]))
  }

  @Test func explicitAppendComposesWithExistingNativeIDInsertion() throws {
    let original = try document(#"{"items":[{"id":"existing"}]}"#, .json)
    let array = keyRegion("items")
    let nativeID = NativeRegion(array.steps + [.occurrence(.init(idKey: "id", id: "named"))])
    let changed = try original.prepare([
      .append(region: array, expected: owned(original, array), value: .string("last")),
      .put(region: nativeID, expected: .absent, value: .object(["id": .string("named")])),
    ])
    let live = try NativeDocument(bytes: changed.bytes, format: .json, budget: generousBudget())
    let inserted = try #require(changed.appendedOccurrences.first).observation
    #expect(
      try live.read(array)?.value
        == .array([
          .object(["id": .string("existing")]), .object(["id": .string("named")]), .string("last"),
        ]))
    #expect(try live.read(inserted.region)?.value == .string("last"))
  }

  @Test func insertionEvidenceReconstructsWithoutOffsetsAndRejectsCorruption() throws {
    let original = try document(#"{"items":["same","same"]}"#, .json)
    let array = keyRegion("items")
    let changed = try original.prepare([
      .append(region: array, expected: owned(original, array), value: .string("same"))
    ])
    let observation = try #require(changed.appendedOccurrences.first).observation
    guard case .occurrence(let saved) = observation.region.steps.last else {
      Issue.record("missing insertion evidence")
      return
    }
    let snapshot = try #require(saved.snapshot)
    let ordinal = try #require(saved.ordinal)
    let arraySnapshot = try #require(saved.arraySnapshot)
    let retained = NativeOccurrenceEvidence(
      snapshot: snapshot, ordinal: ordinal,
      previous: saved.previous, next: saved.next, arraySnapshot: arraySnapshot)
    let selected = NativeRegion(array.steps + [.occurrence(retained)])
    let live = try NativeDocument(bytes: changed.bytes, format: .json, budget: generousBudget())
    #expect(try live.read(selected)?.value == .string("same"))
    let corrupt = NativeOccurrenceEvidence(
      snapshot: snapshot, ordinal: ordinal,
      previous: saved.previous, next: saved.next, arraySnapshot: Data("corrupt".utf8))
    #expect(try live.read(NativeRegion(array.steps + [.occurrence(corrupt)])) == nil)
  }

  @Test func appendSharesTheOperationBudgetAcrossDraftsAndEvidence() throws {
    func bounded() -> NativeDocumentBudget {
      NativeDocumentBudget(
        limits: .init(
          storage: 1_000_000, work: 100_000, nodes: 10_000, depth: 30,
          uninterruptedBytes: 10_000))
    }
    let source = #"{"items":[]}"#
    let array = keyRegion("items")
    let value = NativeValue.string(String(repeating: "x", count: 2048))
    let single = try document(source, .json, budget: bounded())
    #expect(
      try single.prepare([
        .append(region: array, expected: owned(single, array), value: value)
      ]).appendedOccurrences.count == 1)
    let batch = try document(source, .json, budget: bounded())
    let edits = try (0..<16).map { _ in
      NativeRegionEdit.append(region: array, expected: try owned(batch, array), value: value)
    }
    do {
      _ = try batch.prepare(edits)
      Issue.record("unbounded cumulative append work")
    } catch NativeDocumentError.budgetExceeded {}
    #expect(batch.bytes == Data(source.utf8))
  }

  @Test func staleAppendPreimageOrdinaryOverlapAndAmbiguousEvidenceRefuse() throws {
    let array = keyRegion("items")
    let original = try document(#"{"items":[1,1]}"#, .json)
    let changed = try document(#"{"items":[1,1,1]}"#, .json)
    #expect(throws: NativeDocumentError.self) {
      try changed.prepare([
        .append(region: array, expected: owned(original, array), value: .integer(2))
      ])
    }
    #expect(throws: NativeDocumentError.self) {
      try original.prepare([
        .put(region: array, expected: owned(original, array), value: .array([])),
        .append(region: array, expected: owned(original, array), value: .integer(2)),
      ])
    }
    let ambiguous = try document(#"{"items":[1,1,1,1,1]}"#, .json)
    let evidence = try #require(try ambiguous.read(array)).occurrences[2]
    #expect(throws: NativeDocumentError.self) {
      try ambiguous.read(NativeRegion(array.steps + [.occurrence(evidence)]))
    }
    let insertion = try original.prepare([
      .append(region: array, expected: owned(original, array), value: .integer(1))
    ])
    let owner = try #require(insertion.appendedOccurrences.first).observation
    let externallyChanged = try document(#"{"items":[1,1,1,1]}"#, .json)
    #expect(throws: NativeDocumentError.self) {
      try externallyChanged.prepare([.remove(region: owner.region, expected: .owned(owner))])
    }
  }
}
