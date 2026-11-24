import Foundation
import Testing

@testable import AgentsCore

@Suite("Requirement semantics")
struct RequirementSemanticsTests {
  @Test(arguments: [
    (
      SourceRequirement.range(from: "v1.2.0+lower", to: "2.0.0+upper"),
      SourceRequirement.upToNextMajor(from: "1.2.0")
    ),
    (.range(from: "1.2.0-beta+lower", to: "1.3.0+upper"), .upToNextMinor(from: "v1.2.0-beta")),
    (.exact(" V1.2.3+build "), .exact("1.2.3+build")),
    (.branch("main"), .branch("main")), (.revision("abc"), .revision("abc")),
  ])
  func selectionsCompareSemanticValues(_ legacy: SourceRequirement, _ modern: SourceRequirement)
    throws
  {
    #expect(legacy.declarationEquivalent(to: modern))
    let decoded = try JSONDecoder().decode(
      SourceRequirement.self, from: JSONEncoder().encode(legacy))
    #expect(decoded == legacy)
    #expect(try decoded.canonicalized().declarationEquivalent(to: modern))
  }

  @Test func absenceExactMetadataPrereleasesAndDifferentRangesStayDistinct() {
    for (left, right) in [
      (SourceRequirement.exact("1.2.3+one"), SourceRequirement.exact("1.2.3+two")),
      (.upToNextMajor(from: "1.2.0-beta"), .upToNextMajor(from: "1.2.0")),
      (.upToNextMajor(from: "1.2.0"), .upToNextMinor(from: "1.2.0")),
      (.branch("main"), .revision("main")),
    ] { #expect(!left.declarationEquivalent(to: right)) }
    #expect(LockedSource(kind: .local) != LockedSource(kind: .local, requirement: .branch("main")))
  }

  @Test func argumentSelectorsAcceptEqualBoundsAndRejectDifferentIntent() throws {
    let environment = RuntimeEnvironment(environment: [:])
    let declaration = Declaration(sources: ["s": SourceDeclaration(kind: .local, location: "local")]
    )
    let selected = try SourceArgument("s@from:1.2.0").selection(
      in: declaration, requirement: .range(from: "v1.2.0+meta", to: "2.0.0"), path: nil,
      environment: environment)
    #expect(selected.requirement == .upToNextMajor(from: "1.2.0"))
    #expect(selected.requirement?.declarationEquivalent(to: .upToNextMajor(from: "1.2.0")) == true)
    #expect(throws: CoreError.self) {
      try SourceArgument("s@minor:1.2.0").selection(
        in: declaration, requirement: .range(from: "1.2.0", to: "2.0.0"), path: nil,
        environment: environment)
    }
  }

  @Test func descriptorComparisonUsesIdentityRootAndSemanticRequirementWithoutRewritingReads()
    throws
  {
    let bytes = Data(
      #"{"kind":"git","url":"https://EXAMPLE.org:2222/team.git/","path":"skills","requirement":{"from":"v1.2.0","to":"2.0.0+meta"}}"#
        .utf8)
    let old = try JSONDecoder().decode(LockedSource.self, from: bytes)
    let new = LockedSource(
      kind: .git, url: "ssh://user@example.org:2222/team",
      requirement: .upToNextMajor(from: "1.2.0"), path: "skills")
    #expect(old == new)
    var equivalentRoot = new
    equivalentRoot.path = "./skills/"
    #expect(old == equivalentRoot)
    #expect(LockedSource(kind: .local) == LockedSource(kind: .local, path: "."))
    #expect(old.requirement == .range(from: "v1.2.0", to: "2.0.0+meta"))
    var changed = new
    changed.path = "instructions"
    #expect(old != changed)
    changed = new
    changed.url = "https://example.org:2223/team"
    #expect(old != changed)
    #expect(
      LockedSource(kind: .local, requirement: .range(from: "v1.2.0", to: "1.3.0")).requirement
        == .upToNextMinor(from: "1.2.0"))
  }

  @Test func fullLedgerComparisonPreservesEquivalentRequirementBytes() throws {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = LedgerSource(
      kind: .git, transport: "https://intranet/team.git",
      revision: String(repeating: "a", count: 40))
    ledger.sourceUses = [
      .init(source: "source", root: ".", requirement: .range(from: "v1.2.0", to: "2.0.0+meta"))
    ]
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    var next = ledger
    next.sourceUses[0].requirement = .upToNextMajor(from: "1.2.0")
    #expect(try ResolvedLedgerCodec.replacement(next, existing: bytes, limits: .standard) == nil)
    next.sourceUses[0].requirement = .upToNextMinor(from: "1.2.0")
    let changed = try #require(
      try ResolvedLedgerCodec.replacement(next, existing: bytes, limits: .standard))
    #expect(try ResolvedLedgerCodec.decode(changed, limits: .standard) == next)
  }

  @Test func resolutionSessionsReuseEqualRequirementsAndCacheKeysKeepExactPins() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: repo.appendingPathComponent("content"))
    try initGitRepo(repo)
    func git(_ args: [String]) throws {
      _ = try ProcessRunner.run("/usr/bin/env", arguments: ["git", "-C", repo.path] + args)
    }
    try git(["tag", "1.2.0"])
    let store = StateStore(
      scope: .project,
      environment: RuntimeEnvironment(projectDirectory: root, homeDirectory: root, environment: [:])
    )
    let session = try SourceResolutionSession(store: store)
    var source = SourceDeclaration(
      kind: .local, location: repo.path, requirement: .range(from: "v1.2.0+lower", to: "2.0.0+meta")
    )
    let first = try session.withSnapshot(source) { ($0, $1) }
    try Data("new".utf8).write(to: repo.appendingPathComponent("content"))
    try git(["commit", "-am", "new"])
    try git(["tag", "1.3.0"])
    source.requirement = .upToNextMajor(from: "1.2.0")
    let second = try session.withSnapshot(source) { ($0, $1) }
    #expect(first.0 == second.0 && first.1 == second.1)
    #expect(
      try String(contentsOf: second.1.appendingPathComponent("content"), encoding: .utf8) == "old")
    let cache = SourceCache(store: store)
    let newer = try cache.resolve(source)
    #expect(newer != first.0)
    let id = try source.identity(environment: store.environment)
    let oldDescriptor = try JSONDecoder().decode(
      LockedSource.self,
      from: Data(#"{"kind":"local","requirement":{"from":"v1.2.0","to":"2.0.0"}}"#.utf8))
    let newDescriptor = LockedSource(kind: .local, requirement: source.requirement)
    let before = try cache.materialize(
      sourceID: id, source: oldDescriptor, revision: first.0.revision)
    let after = try cache.materialize(
      sourceID: id, source: newDescriptor, revision: first.0.revision)
    #expect(before == after)
    #expect(
      try String(contentsOf: after.appendingPathComponent("content"), encoding: .utf8) == "old")
  }
}

extension RequirementSemanticsTests {
  @Test(arguments: [
    (
      SourceRequirement.range(from: "v1.2.0+lower", to: "2.0.0+upper"),
      SourceRequirement.upToNextMajor(from: "1.2.0")
    ),
    (.range(from: "1.2.0-beta+lower", to: "1.3.0+upper"), .upToNextMinor(from: "v1.2.0-beta")),
    (.exact(" V1.2.3+build "), .exact("1.2.3+build")),
  ])
  func sourceAndGroupRequirementsPreserveOriginalLayout(
    _ original: SourceRequirement, _ equivalent: SourceRequirement
  ) throws {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = .init(
      kind: .git, transport: "https://intranet/team.git",
      revision: String(repeating: "a", count: 40))
    ledger.sourceUses = [.init(source: "source", root: ".", requirement: original)]
    ledger.groups = [
      .init(
        id: 0, source: "source", root: ".", name: "export", requirement: original,
        manifestHash: "sha256:" + String(repeating: "a", count: 64), children: [])
    ]
    let encoded = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    let originalBytes = try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: encoded),
      options: [.prettyPrinted, .sortedKeys])
    var next = ledger
    next.sourceUses[0].requirement = equivalent
    next.groups[0].requirement = equivalent
    #expect(
      try ResolvedLedgerCodec.replacement(next, existing: originalBytes, limits: .standard) == nil)
    #expect(
      try ResolvedLedgerCodec.decode(originalBytes, limits: .standard).groups[0].requirement
        == original)
    next.groups[0].requirement = .branch("different")
    #expect(
      try ResolvedLedgerCodec.replacement(next, existing: originalBytes, limits: .standard) != nil)
  }

  @Test func equivalentRequirementsDoNotMaskByteExactNativeOrRefChanges() throws {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = .init(
      kind: .git, transport: "https://intranet/team.git",
      revision: String(repeating: "a", count: 40))
    ledger.sourceUses = [
      .init(source: "source", root: ".", requirement: .range(from: "v1.2.0", to: "2.0.0+meta"))
    ]
    ledger.lowerings = [
      .init(
        id: "native", format: "test/value@1", inputs: [], resources: [], deployments: [],
        layout: .init("é"), platform: "macos", artifacts: [])
    ]
    let original = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    var next = ledger
    next.sourceUses[0].requirement = .upToNextMajor(from: "1.2.0")
    next.lowerings[0].layout = .init("e\u{301}")
    #expect(try ResolvedLedgerCodec.replacement(next, existing: original, limits: .standard) != nil)
    for (before, after) in [
      (LedgerValue("1.0", kind: .decimal), LedgerValue("1.00", kind: .decimal)),
      (LedgerValue(), LedgerValue(object: [:])),
      (
        LedgerValue(object: [
          "requirement": .init(object: ["from": .init("v1.2.0"), "to": .init("2.0.0+meta")])
        ]),
        LedgerValue(object: ["requirement": .init(object: ["from": .init("1.2.0")])])
      ),
    ] {
      ledger.lowerings[0].layout = before
      let valueBytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
      next = ledger
      next.sourceUses[0].requirement = .upToNextMajor(from: "1.2.0")
      next.lowerings[0].layout = after
      #expect(
        try ResolvedLedgerCodec.replacement(next, existing: valueBytes, limits: .standard) != nil)
    }
    ledger.sourceUses[0].requirement = .exact("1.2.3+one")
    let exactBytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    next = ledger
    next.sourceUses[0].requirement = .exact("1.2.3+two")
    #expect(
      try ResolvedLedgerCodec.replacement(next, existing: exactBytes, limits: .standard) != nil)
    for requirement in [SourceRequirement.branch("é"), .revision("é")] {
      ledger.sourceUses[0].requirement = requirement
      let refBytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
      next = ledger
      if case .branch = requirement {
        next.sourceUses[0].requirement = .branch("e\u{301}")
      } else {
        next.sourceUses[0].requirement = .revision("e\u{301}")
      }
      #expect(
        try ResolvedLedgerCodec.replacement(next, existing: refBytes, limits: .standard) != nil)
    }
  }
}

extension RequirementSemanticsTests {
  @Test func equivalentRequirementsStillRespectCandidateWireBudget() throws {
    var ledger = ResolvedLedger()
    ledger.sources["source"] = .init(
      kind: .git, transport: "https://intranet/team.git",
      revision: String(repeating: "a", count: 40))
    ledger.sourceUses = [
      .init(source: "source", root: ".", requirement: .upToNextMajor(from: "1.2.0"))
    ]
    let bytes = try ResolvedLedgerCodec.encode(ledger, limits: .standard)
    var next = ledger
    next.sourceUses[0].requirement = .range(
      from: "1.2.0", to: "2.0.0+" + String(repeating: "metadata", count: 20))
    var limits = LedgerLimits.standard
    limits.encodedBytes = bytes.count
    #expect(throws: (any Error).self) {
      try ResolvedLedgerCodec.replacement(next, existing: bytes, limits: limits)
    }
  }
}
