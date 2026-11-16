import AgentsCore
import AgentsManifest
import Foundation
import Testing

@testable import Components

@Suite("Indexed component resources", .serialized)
struct ArtifactLinkingTests {
  @Test func nestedArtifactFilesAreScopedAndContained() throws {
    let fixture = try LinkFixture()
    var borrowed: URL?
    try SourceResolutionSession.withTemporaryRead(store: fixture.store) { session in
      let view = try session.fileSnapshot(
        source: "https://example.invalid", revision: "fixture",
        files: [
          "SKILL.md": Data("skill".utf8), "references/context.md": Data("context".utf8),
          "scripts/run": Data("script".utf8),
        ], executableFlags: ["scripts/run": true])
      borrowed = view.root
      #expect(try Data(contentsOf: view.resource("references/context.md")) == Data("context".utf8))
      #expect(try FileHash.executableFlags(view.root)["scripts/run"] == true)
      #expect(throws: CoreError.self) {
        try session.fileSnapshot(
          source: "https://example.invalid", revision: "unsafe",
          files: ["../escape": Data()])
      }
    }
    #expect(!FileManager.default.fileExists(atPath: try #require(borrowed).path))
  }

  @Test(arguments: [InstallMode.copy, .link])
  func selectedIndexDownloadsAndRetainedClosuresAreIndependent(_ mode: InstallMode) throws {
    let fixture = try LinkFixture()
    let web = fixture.root.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let server = try IndexHTTPServer(root: web)
    defer { server.stop() }
    let oldAlpha = try archive("alpha", body: "old alpha", fixture: fixture, web: web)
    let oldBeta = try archive("beta", body: "old beta", fixture: fixture, web: web)
    try index([("alpha", oldAlpha), ("beta", oldBeta)], fixture: fixture, web: web)
    let document = try fixture.document(
      """
      version: 1
      sources: {web: {index: '\(server.url)'}}
      components: [{kind: skills, source: web, select: [alpha, beta], mode: \(mode.rawValue)}]
      """)
    func freeze(pins: [ComponentKey: SourceRevision] = [:], previous: ResolvedLedger? = nil) throws
      -> ResolvedLedger
    {
      try ComponentLinker.withLinkedComponents(
        document: document, store: fixture.store, platform: .macOS,
        directPins: pins, retaining: previous
      ) { graph, session in
        try LedgerFreeze.freeze(
          graph, session: session,
          locations: .init(sources: [
            "local:" + fixture.project.path: .init(kind: .registered, root: "project", path: ".")
          ]), limits: .standard)
      }
    }
    let original = try freeze()
    let previous = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(original, limits: .standard), limits: .standard)
    let beta = try #require(previous.components.values.first { $0.name == "beta" })
    #expect(previous.sources[beta.source]?.revision == oldBeta)
    let betaResourceID = try #require(beta.resources.first)
    let betaResource = try #require(previous.resources[betaResourceID])
    #expect(betaResource.entries.contains { $0.path == "references/context.md" })
    #expect(betaResource.entries.contains { $0.path == "scripts/run" && $0.executable })
    let key = ComponentKey(
      source: "local:" + fixture.project.path, root: ".", group: nil,
      kind: .skills, name: "beta")
    let newAlpha = try archive("alpha", body: "new alpha", fixture: fixture, web: web)
    // The protected member disappears from the index and its exact download is unavailable.
    try FileManager.default.removeItem(at: web.appendingPathComponent("beta.tar.gz"))
    try index([("alpha", newAlpha)], fixture: fixture, web: web)
    let next = try freeze(pins: [key: .init(revision: oldBeta)], previous: previous)
    let retained = try #require(next.components.values.first { $0.name == "beta" })
    #expect(retained == beta)
    let retainedResourceID = try #require(retained.resources.first)
    #expect(next.resources[retainedResourceID] == betaResource)
    let alpha = try #require(next.components.values.first { $0.name == "alpha" })
    #expect(next.sources[alpha.source]?.revision == newAlpha)
    let nested = try #require(
      betaResource.entries.first { $0.path == "references/context.md" }?.object)
    #expect(next.contentObjects[nested] == Data("old beta context".utf8))
    #expect(throws: LinkError.self) { try freeze(pins: [key: .init(revision: oldBeta)]) }
    // A different advertised artifact must not be fetched for the protected member.
    try index(
      [("alpha", newAlpha), ("beta", "sha256:" + String(repeating: "a", count: 64))],
      fixture: fixture, web: web)
    let advertised = try freeze(pins: [key: .init(revision: oldBeta)], previous: previous)
    #expect(advertised.components.values.first { $0.name == "beta" } == beta)
    var replay = next
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    replay.lowerings = replay.components.sorted { $0.key < $1.key }.map { id, component in
      .init(
        id: component.name, format: "agents/skill@1", inputs: [id],
        resources: component.resources, deployments: [],
        layout: .init(object: ["name": .init(component.name)]), platform: platform, artifacts: [])
    }
    replay = try LedgerReplay.prepareLowerings(
      replay, store: fixture.store,
      roots: ["project": fixture.project], limits: .standard)
    replay = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(replay, limits: .standard), limits: .standard)
    server.stop()
    try FileManager.default.removeItem(at: web)
    try LedgerReplay.withReplay(
      replay, store: fixture.store, roots: ["project": fixture.project], limits: .standard
    ) { artifacts in
      let betaTree = try #require(artifacts.first { $0.name == "beta" }?.tree)
      #expect(
        try Data(contentsOf: betaTree.appendingPathComponent("references/context.md"))
          == Data("old beta context".utf8))
      #expect(try FileHash.executableFlags(betaTree)["scripts/run"] == true)
    }
    // A wholly retained named selection works without an index or server.
    let offline = try fixture.document(
      """
      version: 1
      sources: {web: {index: '\(server.url)'}}
      components: [{kind: skills, source: web, select: [beta], mode: copy}]
      """)
    try ComponentLinker.withLinkedComponents(
      document: offline, store: fixture.store, platform: .macOS,
      directPins: [key: .init(revision: oldBeta)], retaining: previous
    ) { graph, session in
      #expect(graph.components.count == 1)
      let resource = try #require(graph.components.first?.resources.first)
      #expect(
        try FileHash.folderHash(session.resource(snapshot: resource.snapshot, path: resource.path))
          == String(betaResource.hash.dropFirst(7)))
    }
    let rebound = try fixture.document(
      """
      version: 1
      sources: {web: {index: '\(server.url)/other'}}
      components: [{kind: skills, source: web, select: [beta], mode: copy}]
      """)
    #expect(throws: LinkError.self) {
      try ComponentLinker.withLinkedComponents(
        document: rebound, store: fixture.store, platform: .macOS,
        directPins: [key: .init(revision: oldBeta)], retaining: previous
      ) { _, _ in }
    }
    var corrupt = previous
    corrupt.resources[betaResourceID]?.hash = "sha256:" + String(repeating: "0", count: 64)
    #expect(throws: LinkError.self) {
      try ComponentLinker.withLinkedComponents(
        document: offline, store: fixture.store, platform: .macOS,
        directPins: [key: .init(revision: oldBeta)], retaining: corrupt
      ) { _, _ in }
    }
  }

  @Test(arguments: [InstallScope.project, .user])
  func retainedAllMembersBelongToTheirRecordedIndexes(_ scope: InstallScope) throws {
    let fixture = try LinkFixture()
    let store = StateStore(scope: scope, environment: fixture.environment)
    let packageRoot = scope == .project ? fixture.project : store.directory
    let webA = fixture.root.appendingPathComponent("web-a")
    let webB = fixture.root.appendingPathComponent("web-b")
    for web in [webA, webB] {
      try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    }
    let serverA = try IndexHTTPServer(root: webA)
    defer { serverA.stop() }
    let serverB = try IndexHTTPServer(root: webB)
    defer { serverB.stop() }
    let alphaDigest = try archive("alpha", body: "alpha original", fixture: fixture, web: webA)
    let betaDigest = try archive("beta", body: "beta original", fixture: fixture, web: webB)
    try index([("alpha", alphaDigest)], fixture: fixture, web: webA)
    try index([("beta", betaDigest)], fixture: fixture, web: webB)
    let document = try fixture.document(
      """
      version: 1
      sources: {a: {index: '\(serverA.url)'}, b: {index: '\(serverB.url)'}}
      components: [{kind: skills, source: a}, {kind: skills, source: b}]
      """)
    func freeze(pins: [ComponentKey: SourceRevision] = [:], previous: ResolvedLedger? = nil) throws
      -> ResolvedLedger
    {
      try ComponentLinker.withLinkedComponents(
        document: document, store: store, platform: .macOS,
        directPins: pins, retaining: previous
      ) { graph, session in
        try LedgerFreeze.freeze(
          graph, session: session,
          locations: .init(sources: [
            "local:" + packageRoot.path: .init(
              kind: .registered, root: scope == .project ? "project" : "state", path: ".")
          ]), limits: .standard)
      }
    }
    let previous = try ResolvedLedgerCodec.decode(
      ResolvedLedgerCodec.encode(freeze(), limits: .standard), limits: .standard)
    func key(_ name: String) -> ComponentKey {
      .init(
        source: "local:" + packageRoot.path, root: ".", group: nil, kind: .skills, name: name)
    }
    let pins: [ComponentKey: SourceRevision] = [
      key("alpha"): .init(revision: alphaDigest), key("beta"): .init(revision: betaDigest),
    ]
    // Membership comes from each pin's recorded index, even after its download disappears.
    try FileManager.default.removeItem(at: webA.appendingPathComponent("alpha.tar.gz"))
    try FileManager.default.removeItem(at: webB.appendingPathComponent("beta.tar.gz"))
    try index([], fixture: fixture, web: webA)
    try index([], fixture: fixture, web: webB)
    let retained = try freeze(pins: pins, previous: previous)
    #expect(retained.components == previous.components)
    #expect(retained.resources == previous.resources)
    #expect(retained.contentObjects == previous.contentObjects)
    let freshAlpha = try archive("alpha", body: "alpha fresh", fixture: fixture, web: webA)
    try index([("alpha", freshAlpha)], fixture: fixture, web: webA)
    let mixed = try freeze(pins: [key("beta"): .init(revision: betaDigest)], previous: previous)
    let beta = try #require(previous.components.values.first { $0.name == "beta" })
    #expect(mixed.components.values.first { $0.name == "beta" } == beta)
    for id in beta.resources { #expect(mixed.resources[id] == previous.resources[id]) }
    let alpha = try #require(mixed.components.values.first { $0.name == "alpha" })
    #expect(mixed.sources[alpha.source]?.revision == freshAlpha)
    var missingPin = pins
    missingPin[key("alpha")] = .init(revision: "sha256:" + String(repeating: "0", count: 64))
    #expect(throws: LinkError.self) { try freeze(pins: missingPin, previous: previous) }
    var corrupt = previous
    let betaResource = try #require(beta.resources.first)
    corrupt.resources[betaResource]?.hash = "sha256:" + String(repeating: "0", count: 64)
    #expect(throws: LinkError.self) { try freeze(pins: pins, previous: corrupt) }
  }

  private func archive(_ name: String, body: String, fixture: LinkFixture, web: URL) throws
    -> String
  {
    let root = fixture.root.appendingPathComponent(name)
    try fixture.write(
      "---\nname: \(name)\ndescription: Fixture\n---\n\(body)\n", to: "SKILL.md", base: root)
    try fixture.write(body + " context", to: "references/context.md", base: root)
    try fixture.write("fixture script", to: "scripts/run", base: root)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("scripts/run").path)
    let archive = web.appendingPathComponent(name + ".tar.gz")
    if FileManager.default.fileExists(atPath: archive.path) {
      try FileManager.default.removeItem(at: archive)
    }
    try ProcessRunner.run(
      "/usr/bin/env", arguments: ["tar", "-czf", archive.path, "."], workingDirectory: root)
    return "sha256:" + (try FileHash.sha256Hex(file: archive))
  }

  private func index(_ members: [(String, String)], fixture: LinkFixture, web: URL) throws {
    let entries = members.map { name, digest in
      [
        "name": name, "description": "Fixture", "type": "archive", "url": "/\(name).tar.gz",
        "digest": digest,
      ]
    }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json", "skills": entries,
    ])
    try fixture.write(
      String(decoding: bytes, as: UTF8.self), to: ".well-known/agent-skills/index.json", base: web)
  }
}

private final class IndexHTTPServer {
  private let process = Process()
  private let output = Pipe()
  let url: String

  init(root: URL) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
      "-e",
      #"""
      use IO::Socket::INET;
      use POSIX qw(SIG_SETMASK sigprocmask);
      # The fixture's deadline and termination signals must be deliverable.
      sigprocmask(SIG_SETMASK, POSIX::SigSet->new()) or die "sigprocmask: $!";
      alarm 120;
      my $root = shift;
      my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, Proto => 'tcp') or die $!;
      $| = 1; print $server->sockport, "\n";
      while (my $client = $server->accept()) {
        my $request = <$client>;
        my ($path) = $request =~ m{^GET (/[^ ]*) HTTP/};
        while (my $line = <$client>) { last if $line eq "\r\n"; }
        my $bytes = ''; my $status = '404 Not Found';
        if (defined($path) && $path !~ /\.\./ && open(my $file, '<', "$root$path")) {
          binmode $file; local $/; $bytes = <$file>; close $file; $status = '200 OK';
        }
        print $client "HTTP/1.1 $status\r\nContent-Length: ", length($bytes), "\r\nConnection: close\r\n\r\n", $bytes;
        close $client;
      }
      """#, root.path,
    ]
    process.standardOutput = output
    try process.run()
    output.fileHandleForWriting.closeFile()
    var bytes = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
      if byte == Data([10]) { break }
      bytes.append(byte)
    }
    guard let port = Int(String(decoding: bytes, as: UTF8.self)) else {
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
      throw CoreError.invalidState("fixture listener unavailable")
    }
    url = "http://127.0.0.1:\(port)"
  }

  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? output.fileHandleForReading.close()
  }
}
