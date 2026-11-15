import Foundation
import Testing

@testable import TOMLSemantics

func generousBudget() -> SemanticBudget {
  SemanticBudget(
    limits: .init(
      storage: 20_000_000, work: 20_000_000, nodes: 100_000, depth: 128,
      uninterruptedBytes: 1_000_000))
}

@Test func exactKeysAndLazyValidation() throws {
  let a = "prefixabcdefgh-a\u{301}\u{327}-zyxwvuts"
  let b = "prefixabcdefgh-a\u{327}\u{301}-zyxwvuts"
  let doc = try SemanticDocument(
    source: "\"é\"=1\n\"e\u{301}\"=2\n\"\(a)\"=3\n\"\(b)\"=4", budget: generousBudget())
  guard case .object(let pairs) = doc.root else {
    Issue.record("root")
    return
  }
  #expect(pairs.count == 4)
  #expect(pairs[0].key.utf8.elementsEqual("é".utf8))
  #expect(pairs[1].key.utf8.elementsEqual("e\u{301}".utf8))
  #expect(throws: (any Error).self) {
    try SemanticDocument(source: "a=1\n\"\\u0061\"=2", budget: generousBudget())
  }
  for source in [
    "deep=[{bad=2023-02-30}]", #"deep=[{bad="\q"}]"#, "x=9223372036854775808", "x=1979-05",
    "x=12:13:",
  ] {
    #expect(throws: (any Error).self) {
      try SemanticDocument(source: source, budget: generousBudget())
    }
  }
  for source in ["x=12:13:14.1", "x=12:13", "x={\na=1,\n}", "x=[0xFE,1.0,true,1979-05-27,\"yes\"]"]
  {
    _ = try SemanticDocument(source: source, budget: generousBudget())
  }
}

@Test func semanticBudgetAndCancellation() throws {
  let tiny = SemanticBudget(
    limits: .init(storage: 2, work: 100, nodes: 10, depth: 3, uninterruptedBytes: 10))
  #expect(throws: SemanticBudget.Failure.self) { try SemanticDocument(source: "x=1", budget: tiny) }
  let cancelled = SemanticBudget(
    limits: .init(storage: 1000, work: 1000, nodes: 100, depth: 10, uninterruptedBytes: 1000),
    cancellation: { true })
  #expect(throws: SemanticBudget.Failure.self) {
    try SemanticDocument(source: "x=1", budget: cancelled)
  }
  var cancellationChecks = 0
  let scanning = SemanticBudget(
    limits: .init(
      storage: 100_000, work: 100_000, nodes: 10_000, depth: 10, uninterruptedBytes: 100_000),
    cancellation: {
      cancellationChecks += 1
      return cancellationChecks > 100
    })
  do {
    _ = try SemanticDocument(source: "#" + String(repeating: "x", count: 5000), budget: scanning)
    Issue.record("semantic comment scanning ignored cancellation")
  } catch SemanticBudget.Failure.cancelled {}
  let depth = SemanticBudget(
    limits: .init(
      storage: 100_000, work: 100_000, nodes: 1000, depth: 3, uninterruptedBytes: 100_000))
  #expect(throws: SemanticBudget.Failure.self) {
    try SemanticDocument(source: "x={\na={\nb={\nc={\nd=1\n}\n}\n}\n}", budget: depth)
  }
}
