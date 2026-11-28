import Foundation
import StateTestSupport
import Testing

@testable import AgentsCore

@Suite struct AcquisitionCacheTests {
  @Test func inspectionIsReadOnlyAndRootSelectionUsesTheSuppliedHome() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    #expect(try cache.inspect().entries.isEmpty)
    #expect(try cache.preview(.clean).candidates.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: cache.root.path))
    #expect(throws: AcquisitionCacheError.invalidAge) { try cache.preview(.prune(days: -1)) }
    let env = RuntimeEnvironment(
      projectDirectory: root, homeDirectory: root.appendingPathComponent("home"),
      environment: ["AGENTS_CACHE_DIR": "custom"])
    #expect(
      AcquisitionCache(environment: env).root.path == root.appendingPathComponent("custom").path)
    var fallback = env
    fallback.environment = [:]
    #if os(macOS)
      let suffix = "home/Library/Caches/agents"
    #else
      let suffix = "home/.cache/agents"
    #endif
    #expect(
      AcquisitionCache(environment: fallback).root.path == root.appendingPathComponent(suffix).path)
  }

  @Test func unsafeRootAndSymlinkHazardsNeverTouchExternalData() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let sentinel = root.appendingPathComponent("sentinel")
    try Data("survive".utf8).write(to: sentinel)
    var env = fixtureCache(root).environment
    let protected = root.appendingPathComponent("protected/nested")
    env.protectedAcquisitionPaths = [protected]
    for invalid in [
      URL(fileURLWithPath: "/"), env.homeDirectory, root,
      env.projectDirectory.appendingPathComponent(".agent/cache"),
      root.appendingPathComponent("protected"), protected.appendingPathComponent("cache"),
    ] {
      env.acquisitionCacheRoot = invalid
      #expect(throws: AcquisitionCacheError.self) {
        try AcquisitionCache(environment: env).write(
          Data("value".utf8), store: .http, key: key("a"), object: "response")
      }
    }
    let unmarked = root.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
    try Data().write(to: unmarked.appendingPathComponent("foreign-file"))
    env.acquisitionCacheRoot = unmarked
    #expect(throws: AcquisitionCacheError.self) { try AcquisitionCache(environment: env).inspect() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: unmarked.path) == ["foreign-file"])

    let cache = fixtureCache(root)
    try cache.write(Data("value".utf8), store: .http, key: key("b"), object: "response")
    let unauthorized = cache.root.appendingPathComponent("http/" + key("c"))
    try FileManager.default.createSymbolicLink(at: unauthorized, withDestinationURL: sentinel)
    let result = try cache.apply(cache.preview(.clean))
    #expect(result.removed.count == 1)
    #expect(result.failures.map(\.path) == ["http/" + key("c")])
    #expect(try Data(contentsOf: sentinel) == Data("survive".utf8))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: unauthorized.path) == sentinel.path)
  }

  @Test func pruneSkipsAReusedGroupAndCleanCountsOnlyActualRemovals() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    let old = Date(timeIntervalSince1970: 1_000)
    let now = old.addingTimeInterval(40 * 86_400)
    for value in ["a", "b"] {
      try cache.write(Data(value.utf8), store: .git, key: key(value), object: value, now: old)
    }
    try cache.write(
      Data("response".utf8), store: .http, key: key("c"), object: "response", now: old)
    try cache.rememberDeployedBytes(Data("deployed".utf8))
    let preview = try cache.preview(.prune(), now: now)
    #expect(preview.candidates.count == 2)
    #expect(
      try cache.read(.git, key: key("a"), maximumBytes: 8, now: now) { $0.data } == Data("a".utf8))
    let pruned = try cache.apply(preview)
    #expect(pruned.isComplete)
    #expect(pruned.removed.map(\.object) == ["b"])
    #expect(pruned.skipped.map(\.object) == ["a"])
    #expect(pruned.reclaimedBytes == pruned.removed.first?.bytes)
    #expect(
      try cache.preview(.prune(days: 0), now: now.addingTimeInterval(1)).candidates.count == 1)
    let inventory = try cache.inspect()
    #expect(inventory.bytes(in: .git) > 1)
    #expect(inventory.bytes(in: .http) > 8)
    #expect(inventory.bytes(in: .deployed) > 8)
    let cleaned = try cache.apply(cache.preview(.clean))
    #expect(cleaned.reclaimedBytes == inventory.totalBytes)
    #expect(try cache.inspect().totalBytes == 0)
  }

  @Test func rootAndPayloadReplacementInvalidateReviewedEvidence() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    try cache.write(Data("one".utf8), store: .git, key: key("a"), object: "one")
    let reviewed = try cache.preview(.clean)
    let file = cache.root.appendingPathComponent("git/" + key("a") + "/bytes")
    try Data("two".utf8).write(to: file)
    let changed = try cache.apply(reviewed)
    #expect(changed.skipped.count == 1)
    #expect(changed.reclaimedBytes == 0)
    try FileManager.default.moveItem(at: cache.root, to: root.appendingPathComponent("old-cache"))
    try cache.write(Data("three".utf8), store: .git, key: key("b"), object: "three")
    #expect(throws: AcquisitionCacheError.rootChanged) { try cache.apply(reviewed) }
    #expect(try cache.inspect().entries.map(\.object) == ["three"])
  }

  @Test func deployedBytesAreRehashedAndColdMissesAreHarmless() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    let bytes = Data("expected".utf8)
    let digest = FileHash.sha256Hex(data: bytes)
    #expect(try cache.verifiedDeployedBytes(sha256: digest) == nil)
    try cache.rememberDeployedBytes(bytes)
    #expect(try cache.verifiedDeployedBytes(sha256: digest) == bytes)
    try Data("tampered".utf8).write(
      to: cache.root.appendingPathComponent("deployed/" + digest + "/bytes"))
    #expect(try cache.verifiedDeployedBytes(sha256: digest) == nil)
    try cache.rememberDeployedBytes(bytes)
    #expect(try cache.verifiedDeployedBytes(sha256: digest) == bytes)
  }

  @Test func unwriteableEntryReportsPartialFailureAndItsTrashCanBeRetried() throws {
    guard geteuid() != 0 else { return }
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    try cache.write(Data("first".utf8), store: .git, key: key("a"), object: "one")
    try cache.write(Data("second".utf8), store: .git, key: key("b"), object: "two")
    let trash = cache.root.appendingPathComponent(".trash")
    defer { makeDirectoriesWritable(root) }

    var blockedFirst = false
    let result = try cache.apply(
      cache.preview(.clean),
      afterDetach: {
        guard !blockedFirst else { return }
        blockedFirst = true
        let files = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        let entry = try #require(files.first { $0.hasSuffix(".entry") })
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o500], ofItemAtPath: trash.appendingPathComponent(entry).path)
      })
    #expect(!result.isComplete)
    #expect(result.removed.map(\.object) == ["two"])
    #expect(result.failures.map(\.path) == ["git/" + key("a")])
    let inventory = try cache.inspect()
    let pending = try #require(inventory.entries.first)
    #expect(pending.pendingDisposal)
    #expect(pending.bytes > 0)
    let detached = cache.root.appendingPathComponent(".trash/" + pending.id + ".entry")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: detached.path)
    let retry = try cache.apply(cache.preview(.clean))
    #expect(retry.isComplete)
    #expect(retry.reclaimedBytes == inventory.totalBytes)
  }

  @Test func independentReadersAndPublishersCoordinateWithCleanAndRecoverDetachedTrash() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let cache = fixtureCache(root)
    let first = try stateTestProcess(root: root, arguments: ["acquisition-publish"])
    let second = try stateTestProcess(root: root, arguments: ["acquisition-publish"])
    defer {
      terminateProcess(first)
      terminateProcess(second)
    }
    try finishProcesses([first, second], root: root)
    #expect(try cache.inspect().entries.count == 1)
    try cache.write(Data("other".utf8), store: .http, key: key("b"), object: "response")

    let reader = try stateTestProcess(root: root, arguments: ["acquisition-read", "leased"])
    defer { terminateProcess(reader) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: reader, root: root)
    try ProcessWait.stopped(reader, root: root, timeout: 10)
    let partial = try cache.apply(cache.preview(.clean))
    #expect(partial.removed.map(\.store) == [.http])
    #expect(partial.failures.map(\.reason) == [AcquisitionCacheError.busy.localizedDescription])
    #expect(kill(reader.processIdentifier, SIGCONT) == 0)
    try finishProcesses([reader], root: root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("ready"))

    let cleaner = try stateTestProcess(root: root, arguments: ["acquisition-clean", "detached"])
    defer { terminateProcess(cleaner) }
    try ProcessWait.marker(root.appendingPathComponent("ready"), child: cleaner, root: root)
    try ProcessWait.stopped(cleaner, root: root, timeout: 10)
    try ProcessWait.terminate(cleaner)
    let interrupted = try cache.inspect()
    #expect(interrupted.entries.count == 1)
    #expect(interrupted.entries.first?.pendingDisposal == true)
    let retry = try cache.apply(cache.preview(.prune(days: 0)))
    #expect(retry.reclaimedBytes == interrupted.totalBytes)
    #expect(retry.isComplete)
    #expect(try cache.inspect().entries.isEmpty)
  }

  private func fixtureCache(_ root: URL) -> AcquisitionCache {
    AcquisitionCache(
      environment: RuntimeEnvironment(
        projectDirectory: root.appendingPathComponent("project"),
        homeDirectory: root.appendingPathComponent("home"), environment: [:],
        acquisitionCacheRoot: root.appendingPathComponent("shared/cache")))
  }

  private func key(_ letter: String) -> String { String(repeating: letter, count: 64) }
}
