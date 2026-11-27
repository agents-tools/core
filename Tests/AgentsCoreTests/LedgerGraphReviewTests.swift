import Foundation
import Testing

@testable import AgentsCore

@Suite("Ledger graph integrity")
struct LedgerGraphReviewTests {
  private let hash = "sha256:" + String(repeating: "0", count: 64)

  private func resource(_ entries: [LedgerEntry], support: [LedgerEntry] = []) -> LedgerResource {
    .init(
      kind: .embedded, source: "root", path: "vendor", hash: hash,
      entries: entries, support: support)
  }

  @Test func linksResolveBeforeParentTraversal() throws {
    let root = LedgerEntry(path: ".", kind: .directory, executable: false)
    let alias = LedgerEntry(path: "a", kind: .symlink, link: ".", executable: false)
    let escape = LedgerEntry(path: "b", kind: .symlink, link: "a/../outside", executable: false)
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(resource([root, alias, escape]))
    }
    let valid = LedgerEntry(path: "b", kind: .symlink, link: "a/a", executable: false)
    #expect(try LedgerResources.validatedEntries(resource([root, alias, valid])).count == 3)
    let missing = LedgerEntry(path: "b", kind: .symlink, link: "absent", executable: false)
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(resource([root, missing]))
    }
    let cycle = LedgerEntry(path: "b", kind: .symlink, link: "b", executable: false)
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(resource([root, cycle]))
    }
  }

  @Test func supportingAndRootLinksUseOwnedRoot() throws {
    let selected = LedgerEntry(path: ".", kind: .symlink, link: "shared/file", executable: false)
    let directory = LedgerEntry(path: "shared", kind: .directory, executable: false)
    let file = LedgerEntry(path: "shared/file", kind: .file, executable: false, byteCount: 0)
    #expect(
      try LedgerResources.validatedEntries(resource([selected], support: [directory, file])).count
        == 4)
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(resource([selected], support: [directory]))
    }
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(resource([selected]))
    }
    let escaping = LedgerEntry(path: "shared/a", kind: .symlink, link: ".", executable: false)
    let outside = LedgerEntry(
      path: "shared/b", kind: .symlink, link: "a/../../outside", executable: false)
    #expect(throws: (any Error).self) {
      _ = try LedgerResources.validatedEntries(
        resource([selected], support: [directory, file, escaping, outside]))
    }
  }

  @Test func capturesIntermediateSupportingLinksAndMaterializesContainedChains() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let selected = source.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("shared"), withIntermediateDirectories: true)
    try Data("content".utf8).write(to: source.appendingPathComponent("shared/file"))
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("alias").path, withDestinationPath: "shared")
    try FileManager.default.createSymbolicLink(
      atPath: selected.appendingPathComponent("a").path, withDestinationPath: ".")
    try FileManager.default.createSymbolicLink(
      atPath: selected.appendingPathComponent("link").path, withDestinationPath: "a/a/../alias/file"
    )
    let captured = try LedgerResources.capture(
      selected, embed: true, limits: .standard, sourceRoot: source)
    let record = LedgerResource(
      kind: .embedded, source: "root", path: "vendor", hash: captured.hash,
      entries: captured.entries, support: captured.support)
    #expect(record.support.contains { $0.path == "alias" && $0.kind == .symlink })
    let destination = root.appendingPathComponent("materialized")
    try LedgerResources.materialize(record, objects: captured.objects, at: destination)
    #expect(
      try Data(contentsOf: destination.appendingPathComponent("vendor/link"))
        == Data("content".utf8))
    let gitCapture = try LedgerResources.capture(
      selected, embed: false, limits: .standard, sourceRoot: source)
    #expect(gitCapture.support.map(\.path) == captured.support.map(\.path))
    #expect(gitCapture.objects.isEmpty)
    var escaped = record
    escaped.entries.append(
      .init(path: "bad", kind: .symlink, link: "a/../../outside", executable: false))
    let rejected = root.appendingPathComponent("rejected")
    #expect(throws: (any Error).self) {
      try LedgerResources.materialize(escaped, objects: captured.objects, at: rejected)
    }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
  }

  @Test func largeFlatGroupsAreAdmittedAndValidated() throws {
    var ledger = ResolvedLedger()
    ledger.sources["root"] = .init(kind: .local, revision: "live")
    ledger.groups = (0..<100_000).map {
      .init(id: $0, source: "root", root: ".", name: "group", manifestHash: hash, children: [])
    }
    let started = Date()
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    #expect(try ResolvedLedgerCodec.decode(encoded, limits: .standard) == ledger)
    print(
      "LEDGER_GROUP_CONTROL groups=\(ledger.groups.count) encodedBytes=\(encoded.count) seconds=\(Date().timeIntervalSince(started))"
    )
    ledger.groups[0].children = [1]
    #expect(throws: (any Error).self) { try ledger.validate() }
    ledger.groups[1].parent = 0
    try ledger.validate()
  }
}
