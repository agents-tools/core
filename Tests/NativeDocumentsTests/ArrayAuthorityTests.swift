import Foundation
import NativeDocuments
import Testing

@Suite("Native array semantic authority")
struct ArrayAuthorityTests {
  @Test func nativeDigestPinsKindsLexemesDecodedBytesAndObjectOrdering() throws {
    let base = try document(#"{"a":[1,"x",true,null]}"#, .json)
    let digest = try base.arrayDigest(keyRegion("a"))
    #expect(digest.format == "native-array@1")
    #expect(digest.digest == "ca94654645dcd00338f30082bb9324bc2af825a26709c3507da05b9215d932fb")
    let trivia = try document(
      #"{/* retained */"a":[1,"\u0078",true,null,]}"#, .jsonc(trailingCommas: true))
    #expect(try trivia.arrayDigest(keyRegion("a")) == digest)
    for changed in [#"[1.0,"x",true,null]"#, #"[1e0,"x",true,null]"#, #"[1,"x",null,true]"#] {
      #expect(try document("{\"a\":" + changed + "}", .json).arrayDigest(keyRegion("a")) != digest)
    }
    let ordered = try document(#"{"a":[{"z":1,"a":2}]}"#, .json)
    let reordered = try document(#"{"a":[{"a":2,"z":1}]}"#, .json)
    #expect(try ordered.arrayDigest(keyRegion("a")) == reordered.arrayDigest(keyRegion("a")))
    let composed = try document("{\"a\":[{\"é\":1}]}", .json)
    let decomposed = try document("{\"a\":[{\"e\u{301}\":1}]}", .json)
    #expect(try composed.arrayDigest(keyRegion("a")) != decomposed.arrayDigest(keyRegion("a")))
    let collision = try document("{\"a\":[{\"é\":1,\"e\u{301}\":2}]}", .json)
    #expect(try collision.read(keyRegion("a"))?.value == nil)
    #expect(try collision.arrayDigest(keyRegion("a")).digest.count == 64)
    let hex = try document("a=[0x10,1979-05-27,nan]\n")
    let decimal = try document("a=[16,1979-05-27,nan]\n")
    #expect(try hex.arrayDigest(keyRegion("a")) != decimal.arrayDigest(keyRegion("a")))
    let ids = try document("{\"a\":[{\"id\":\"é\",\"n\":1},{\"id\":\"e\u{301}\",\"n\":2}]}", .json)
    for (id, value) in [("é", 1), ("e\u{301}", 2)] {
      let region = NativeRegion([.key("a"), .occurrence(.init(idKey: "id", id: id)), .key("n")])
      #expect(try ids.read(region)?.value == .integer(value))
    }
    #expect(!String(describing: digest).contains(digest.digest))
    #expect(!String(reflecting: digest).contains(digest.digest))
  }

  @Test func persistedDigestValidatesWholePreimageBeforeDuplicateOrdinalSelection() throws {
    let source = #"{"a":["same","same","same","same","same"]}"#
    let original = try document(source, .json)
    let array = keyRegion("a")
    let digest = try original.arrayDigest(array)
    let regions = try original.validatedOccurrences(in: array, matching: digest, ordinals: [2, 4])
    #expect(regions.count == 2)
    #expect(try original.read(regions[0])?.value == .string("same"))
    for invalid in [
      NativeArrayDigest(format: "native-array@2", digest: digest.digest),
      NativeArrayDigest(format: digest.format, digest: String(repeating: "0", count: 64)),
      NativeArrayDigest(format: digest.format, digest: "PRIVATE_VALUE"),
    ] {
      do {
        _ = try original.validatedOccurrences(in: array, matching: invalid, ordinals: [2])
        Issue.record("unvalidated persisted evidence selected an occurrence")
      } catch let error as NativeDocumentError {
        #expect(!error.description.contains("PRIVATE_VALUE"))
        #expect(!error.description.contains(digest.digest))
      }
    }
    for index in [-1, 5] {
      #expect(throws: NativeDocumentError.self) {
        try original.validatedOccurrences(in: array, matching: digest, ordinals: [index])
      }
    }
    let changed = try document(#"{"a":["same","same","same","same","changed"]}"#, .json)
    #expect(throws: NativeDocumentError.self) {
      try changed.validatedOccurrences(in: array, matching: digest, ordinals: [2])
    }
    let all = try original.validatedOccurrences(in: array, matching: digest, ordinals: [0, 2, 4])
    let retained = try [all[1], all[2]].map { try #require(try original.read($0)) }
    let prepared = try original.prepare(
      [
        .remove(region: all[0], expected: owned(original, all[0])),
        .append(region: array, expected: owned(original, array), value: .string("same")),
      ], retaining: retained, trackingArrays: [array])
    let fresh = try NativeDocument(bytes: prepared.bytes, format: .json, budget: generousBudget())
    #expect(try fresh.arrayDigest(array) == digest)
    // Equal final values cannot preserve foreign ordinal authority after remove/append.
    #expect(!prepared.arrayTransitions[0].canRetainToken)
    let first = try #require(prepared.survivingRegions[0].observation)
    let second = try #require(prepared.survivingRegions[1].observation)
    guard case .occurrence(let a) = first.region.steps.last,
      case .occurrence(let b) = second.region.steps.last
    else {
      Issue.record("missing remaps")
      return
    }
    #expect(a.ordinal == 1 && b.ordinal == 3)
    let removed = try fresh.prepare(
      [.remove(region: first.region, expected: .owned(first))], retaining: [second])
    #expect(removed.survivingRegions[0].observation != nil)
    #expect(throws: NativeDocumentError.self) {
      try changed.prepare([], retaining: retained)
    }
  }

  @Test func siblingChangesPreservePrivateArrayContinuityAndDescendantChangesRotateIt() throws {
    let original = try document(
      #"{/* private sibling */"a":[{"secret":"PRIVATE"}],"b":["UNSELECTED"],"other":1}"#,
      .jsonc(trailingCommas: false)
    )
    let array = keyRegion("a")
    let digest = try original.arrayDigest(array)
    let selected = try original.validatedOccurrences(in: array, matching: digest, ordinals: [0])[0]
    let observation = try #require(try original.read(selected))
    let sibling = try original.prepare(
      [
        .put(
          region: keyRegion("other"), expected: owned(original, keyRegion("other")),
          value: .integer(2))
      ], retaining: [observation], trackingArrays: [array, keyRegion("b")])
    #expect(sibling.arrayTransitions[0].canRetainToken)
    #expect(sibling.arrayTransitions[0].digest == digest)
    #expect(sibling.arrayTransitions[1].index == 1)
    #expect(sibling.arrayTransitions[1].canRetainToken)
    #expect(text(sibling).contains("/* private sibling */"))
    let secret = NativeRegion(selected.steps + [.key("secret")])
    let updated = try original.prepare(
      [
        .put(region: secret, expected: owned(original, secret), value: .string("CHANGED"))
      ], retaining: [observation], trackingArrays: [array, keyRegion("b")])
    #expect(!updated.arrayTransitions[0].canRetainToken)
    #expect(updated.arrayTransitions[0].digest != digest)
    #expect(updated.arrayTransitions[1].canRetainToken)
    #expect(
      updated.survivingRegions[0].observation?.value == .object(["secret": .string("CHANGED")]))
    #expect(throws: NativeDocumentError.self) {
      try original.prepare([], trackingArrays: [array, array])
    }
  }

  @Test func ancestorReplacementAndArrayRemovalCannotContinueEqualAuthority() throws {
    let original = try document(#"{"parent":{"a":[1],"other":true}}"#, .json)
    let parent = keyRegion("parent")
    let array = keyRegion("parent", "a")
    let old = try #require(try original.read(array))
    let replacement = try original.prepare(
      [
        .put(
          region: parent, expected: owned(original, parent),
          value: .object(["a": .array([.integer(1)]), "other": .boolean(false)]))
      ], retaining: [old], trackingArrays: [array])
    #expect(try replacement.arrayTransitions[0].digest == original.arrayDigest(array))
    #expect(!replacement.arrayTransitions[0].canRetainToken)
    #expect(replacement.survivingRegions[0].observation == nil)
    let noOp = try original.prepare(
      [
        .put(
          region: parent, expected: owned(original, parent),
          value: .object(["a": .array([.integer(1)]), "other": .boolean(true)]))
      ], retaining: [old], trackingArrays: [array])
    #expect(noOp.bytes == original.bytes)
    #expect(noOp.arrayTransitions[0].canRetainToken)
    let removed = try original.prepare(
      [.remove(region: array, expected: .owned(old))], retaining: [old], trackingArrays: [array])
    #expect(removed.arrayTransitions[0].region == nil)
    #expect(removed.arrayTransitions[0].digest == nil)
    #expect(removed.survivingRegions[0].observation == nil)
    #expect(throws: NativeDocumentError.self) {
      try original.prepare([
        .remove(region: array, expected: .owned(old)),
        .put(region: array, expected: .owned(old), value: .array([.integer(1)])),
      ])
    }
  }

  @Test func movedPositionalAncestorsRotateButStableNativeIDsKeepTheirAddress() throws {
    for stable in [false, true] {
      let original = try document(#"{"items":[{"id":"first"},{"id":"second","a":[1]}]}"#, .json)
      let items = keyRegion("items")
      let occurrences = try #require(try original.read(items)).occurrences
      let first = NativeRegion(items.steps + [.occurrence(occurrences[0])])
      let second = NativeRegion(
        items.steps + [.occurrence(stable ? .init(idKey: "id", id: "second") : occurrences[1])])
      let array = NativeRegion(second.steps + [.key("a")])
      let prepared = try original.prepare(
        [.remove(region: first, expected: owned(original, first))], trackingArrays: [array])
      #expect(prepared.arrayTransitions[0].canRetainToken == stable)
      let fresh = try NativeDocument(bytes: prepared.bytes, format: .json, budget: generousBudget())
      #expect(
        try fresh.read(#require(prepared.arrayTransitions[0].region))?.value
          == .array([.integer(1)]))
    }
  }

  @Test func ancestorAppendPreservesStableIDNestedArrayWhileOuterArrayRotates() throws {
    let original = try document(#"{"items":[{"id":"first","hooks":[1]}]}"#, .json)
    let items = keyRegion("items")
    let hooks = NativeRegion([
      .key("items"), .occurrence(.init(idKey: "id", id: "first")), .key("hooks"),
    ])
    let old = try #require(try original.read(hooks))
    let digest = try original.arrayDigest(hooks)
    let appended = try original.prepare(
      [
        .append(
          region: items, expected: owned(original, items), value: .object(["id": .string("second")])
        )
      ], retaining: [old], trackingArrays: [hooks, items])
    #expect(appended.arrayTransitions[0].canRetainToken)
    #expect(appended.arrayTransitions[0].digest == digest)
    #expect(appended.arrayTransitions[0].region == hooks)
    #expect(!appended.arrayTransitions[1].canRetainToken)
    let fresh = try NativeDocument(bytes: appended.bytes, format: .json, budget: generousBudget())
    #expect(try fresh.read(hooks)?.value == .array([.integer(1)]))
    let surviving = try #require(appended.survivingRegions[0].observation)
    let edited = try fresh.prepare(
      [
        .append(region: hooks, expected: .owned(surviving), value: .integer(2))
      ], trackingArrays: [hooks])
    #expect(!edited.arrayTransitions[0].canRetainToken)
    #expect(edited.arrayTransitions[0].digest != digest)
  }

  @Test func conditionalPruningReportsArrayDisappearanceAndSurvivorRemoval() throws {
    let original = try document(#"{"a":[1],"keep":true}"#, .json)
    let array = keyRegion("a")
    let digest = try original.arrayDigest(array)
    let element = try original.validatedOccurrences(in: array, matching: digest, ordinals: [0])[0]
    let observed = try #require(try original.read(element))
    let prepared = try original.prepare(
      [
        .remove(region: element, expected: .owned(observed)),
        .pruneCreatedContainer(region: array, observed: #require(try original.read(array))),
      ], retaining: [observed], trackingArrays: [array])
    #expect(text(prepared) == #"{"keep":true}"#)
    #expect(prepared.arrayTransitions[0].region == nil)
    #expect(!prepared.arrayTransitions[0].canRetainToken)
    #expect(prepared.survivingRegions[0].observation == nil)
  }

  @Test func nativeAtomArraysRetainContinuityWithoutProjectingTheirValues() throws {
    let original = try document("a=[1979-05-27,nan] # native atoms\nother=1\n")
    let array = keyRegion("a")
    let digest = try original.arrayDigest(array)
    let region = try original.validatedOccurrences(in: array, matching: digest, ordinals: [0])[0]
    let observation = try #require(try original.read(region))
    #expect(observation.value == nil)
    let prepared = try original.prepare(
      [
        .put(
          region: keyRegion("other"), expected: owned(original, keyRegion("other")),
          value: .integer(2))
      ], retaining: [observation], trackingArrays: [array])
    #expect(prepared.arrayTransitions[0].canRetainToken)
    #expect(prepared.arrayTransitions[0].digest == digest)
    #expect(prepared.survivingRegions[0].observation?.nativeKind == "dateTime")
    #expect(text(prepared).contains("a=[1979-05-27,nan] # native atoms\n"))
  }

  @Test func repeatedDigestQueriesShareBudgetAndCancellationStillApplies() throws {
    var cancelled = false
    let budget = NativeDocumentBudget(
      limits: .init(
        storage: 2_000_000, work: 200_000, nodes: 10_000, depth: 64, uninterruptedBytes: 1_000_000),
      cancellation: { cancelled })
    let source = "{\"a\":[\"" + String(repeating: "x", count: 4096) + "\"]}"
    let original = try NativeDocument(bytes: Data(source.utf8), format: .json, budget: budget)
    let digest = try original.arrayDigest(keyRegion("a"))
    for _ in 0..<100 { #expect(try original.arrayDigest(keyRegion("a")) == digest) }
    cancelled = true
    do {
      _ = try original.arrayDigest(keyRegion("a"))
      Issue.record("cached digest bypassed cancellation")
    } catch NativeDocumentError.cancelled {}
  }
}
