import AgentsCore
import Testing

@testable import AgentsManifest

@Suite("Expanded manifest accounting")
struct ExpansionBudgetTests {
  @Test func referenceOriginsChargeTheirOwnDocumentIdentities() throws {
    let document = try DeclarationDocument(
      bytes: Array(
        """
        // agents-tools-version: 1.0
        import AgentsDescription
        let agents = Agents(components: [.command(name: "review", description: "Review", prompt: "p")])
        """.utf8), identity: DocumentIdentity("producer"))
    let record = try #require(document.declaration.components.first)
    let locations = document.sourceMap.entries.filter {
      $0.pointer == "/components/0" || $0.pointer.hasPrefix("/components/0/")
    }
    let origin = SourceSpan(
      document: DocumentIdentity(String(repeating: "consumer", count: 5_000)),
      start: 0, end: 1, line: 1, column: 1)
    var budget = ManifestExpansionBudget()
    try budget.consume(record, origins: [origin], locations: locations, spending: { _ in })
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      for _ in 0..<100 {
        try budget.consume(record, origins: [origin], locations: locations, spending: { _ in })
      }
    }
  }

  @Test func repeatedLocationsShareTheSourceMapEncodedBudget() throws {
    let document = try DeclarationDocument(
      bytes: Array(
        """
        // agents-tools-version: 1.0
        import AgentsDescription
        let agents = Agents(components: [.command(name: "review", description: "Review", prompt: "p")])
        """.utf8), identity: DocumentIdentity(String(repeating: "source", count: 5_000)))
    let record = try #require(document.declaration.components.first)
    let locations = document.sourceMap.entries.filter {
      $0.pointer == "/components/0" || $0.pointer.hasPrefix("/components/0/")
    }
    var budget = ManifestExpansionBudget()
    try budget.consume(record, origins: [], locations: locations, spending: { _ in })
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      for _ in 0..<100 {
        try budget.consume(record, origins: [], locations: locations, spending: { _ in })
      }
    }
  }

  @Test func repeatedRecordsAccumulateStringAndOutputCost() throws {
    let record = DeclarationRecord(
      kind: "command", fields: ["prompt": .string(String(repeating: "p", count: 100_000))])
    var budget = ManifestExpansionBudget()
    for _ in 0..<100 { try budget.consume(record, origins: [], locations: [], spending: { _ in }) }
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      for _ in 0..<100 {
        try budget.consume(record, origins: [], locations: [], spending: { _ in })
      }
    }
    let escaped = DeclarationRecord(
      kind: "command", fields: ["prompt": .string(String(repeating: "\0", count: 100_000))])
    var output = ManifestExpansionBudget()
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      for _ in 0..<100 {
        try output.consume(escaped, origins: [], locations: [], spending: { _ in })
      }
    }
  }

  @Test func collectionsAndInheritedOriginsUseManifestPolicy() throws {
    let entries = DeclarationRecord(
      kind: "configuration", fields: ["items": .array(Array(repeating: .null, count: 10_001))])
    var budget = ManifestExpansionBudget()
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      try budget.consume(entries, origins: [], locations: [], spending: { _ in })
    }
    let origins = DeclarationRecord(kind: "hook", fields: ["name": .string("h")])
    let span = SourceSpan(
      document: DocumentIdentity("producer"), start: 0, end: 1, line: 1, column: 1)
    let referenceOrigins = Array(repeating: span, count: 10_000)
    var repeated = ManifestExpansionBudget()
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      for _ in 0..<100 {
        try repeated.consume(origins, origins: referenceOrigins, locations: [], spending: { _ in })
      }
    }
  }

  @Test func traversalWorkIsSpentBeforeFailureAndCancellationPropagates() throws {
    let record = DeclarationRecord(
      kind: "configuration", fields: ["items": .array(Array(repeating: .null, count: 1_000))])
    var budget = ManifestExpansionBudget()
    var didSpend = false
    #expect(throws: CancellationError.self) {
      try budget.consume(record, origins: [], locations: []) { _ in
        didSpend = true
        throw CancellationError()
      }
    }
    #expect(didSpend)
    didSpend = false
    #expect(throws: ManifestExpansionBudget.Failure.self) {
      try budget.consume(
        DeclarationRecord(
          kind: "configuration", fields: ["items": .array(Array(repeating: .null, count: 10_001))]),
        origins: [], locations: [], spending: { _ in didSpend = true })
    }
    #expect(didSpend)
  }
}
