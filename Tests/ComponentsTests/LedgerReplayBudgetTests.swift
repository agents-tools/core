import AgentsCore
import AgentsInstructions
import Components
import Foundation
import Testing

@Suite("Ledger replay aggregate budget")
struct LedgerReplayBudgetTests {
  private func fixture(bytes: Int, repeats: Int, format: String = "agents/instructions@1") throws
    -> (LinkFixture, ResolvedLedger)
  {
    let fixture = try LinkFixture()
    let content = Data(repeating: 97, count: bytes)
    let hash = "sha256:" + FileHash.sha256Hex(data: content)
    var ledger = ResolvedLedger()
    ledger.sources["root"] = .init(kind: .local, revision: "live")
    ledger.contentObjects[hash] = content
    ledger.resources["file"] = .init(
      kind: .embedded, source: "root", path: "file", hash: hash,
      entries: [.init(path: ".", kind: .file, object: hash, executable: false, byteCount: bytes)])
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    ledger.lowerings = [
      .init(
        id: "test", format: format, inputs: [], resources: Array(repeating: "file", count: repeats),
        deployments: [],
        layout: .init(object: ["name": .init("output"), "sectionCount": .init(integer: repeats)]),
        platform: platform, artifacts: [])
    ]
    return (fixture, ledger)
  }

  @Test(arguments: ["agents/instructions@1", "agents/chatgpt@1"])
  func repeatedInputsRejectBeforeResourceAcquisition(_ format: String) throws {
    let (fixture, ledger) = try fixture(bytes: 1024 * 1024, repeats: 50_000, format: format)
    // Invalid content hashes would fail later; the aggregate bound must be the first failure.
    do {
      _ = try LedgerReplay.prepareLowerings(
        ledger, store: fixture.store, roots: [:], limits: .standard)
      Issue.record("oversized replay accepted")
    } catch {
      #expect(String(describing: error).contains("replay input byte budget"))
    }
  }

  @Test func validRepeatsAndRetainedOutputsShareBudget() throws {
    let (fixture, original) = try fixture(bytes: 3, repeats: 2, format: "test/budget@1")
    var limits = LedgerLimits.standard
    limits.resourceBytes = 12
    var calls = 0
    let renderer: LedgerRenderer = { lowering, _, _ in
      calls += 1
      return [.init(name: lowering.id, kind: .file, bytes: Data(repeating: 98, count: 6))]
    }
    let table = ["test/budget@1": renderer]
    _ = try LedgerReplay.prepareLowerings(
      original, store: fixture.store, roots: [:], limits: limits, renderers: table)
    #expect(calls == 1)
    var ledger = original
    var second = ledger.lowerings[0]
    second.id = "second"
    ledger.lowerings.append(second)
    limits.resourceBytes = 18
    #expect(throws: (any Error).self) {
      _ = try LedgerReplay.prepareLowerings(
        ledger, store: fixture.store, roots: [:], limits: limits, renderers: table)
    }
    #expect(calls == 3)
  }
  @Test(arguments: ["agents/instructions@1", "agents/chatgpt@1"])
  func compatibilityOutputsUseRemainingAggregateBudget(_ format: String) throws {
    let content = Data("---\ndescription: Example\n---\n# Example\n\nBody\n".utf8)
    let (fixture, original) = try fixture(bytes: content.count, repeats: 1, format: format)
    var ledger = original
    let hash = "sha256:" + FileHash.sha256Hex(data: content)
    ledger.contentObjects = [hash: content]
    ledger.resources["file"]?.hash = hash
    ledger.resources["file"]?.entries[0].object = hash
    let output =
      try format == "agents/instructions@1"
      ? InstructionCompatibility.renderSections([content], ids: ["file"])
      : InstructionCompatibility.renderPrompt([content], ids: ["file"], append: nil)
    var limits = LedgerLimits.standard
    limits.resourceBytes = content.count * 2 + output.count * 2 - 1
    _ = try LedgerReplay.prepareLowerings(ledger, store: fixture.store, roots: [:], limits: limits)
    var second = ledger.lowerings[0]
    second.id = "second"
    second.layout.object?["name"] = .init("second-output")
    ledger.lowerings.append(second)
    do {
      _ = try LedgerReplay.prepareLowerings(
        ledger, store: fixture.store, roots: [:], limits: limits)
      Issue.record("aggregate output budget accepted")
    } catch {
      #expect(String(describing: error).contains("rendered instruction byte budget"))
    }
  }

}
