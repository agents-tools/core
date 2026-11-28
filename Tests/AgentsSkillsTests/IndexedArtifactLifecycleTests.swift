import AgentsCore
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation
import StateTestSupport
import Testing

@Suite("Indexed artifact lifecycle", .serialized)
struct IndexedArtifactLifecycleTests {
  @Test(arguments: [InstallMode.copy, .link], [false, true])
  func publicLifecycleUsesVerifiedIndexAndColdLockedResources(
    _ mode: InstallMode, archive: Bool
  ) throws {
    let fixture = try SkillFixture()
    let web = fixture.root.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let server = try ArtifactHTTPServer(root: web)
    defer { server.stop() }
    func publish(_ body: String, validDigest: Bool = true) throws {
      let bytes = Data("---\nname: indexed\ndescription: Indexed fixture\n---\n\(body)\n".utf8)
      let payload =
        archive
        ? zipArchive(entries: [
          ("SKILL.md", bytes, 0o100644),
          ("references/context.md", Data(("Context: " + body).utf8), 0o100644),
        ]) : bytes
      let file = archive ? "/skill.zip" : "/SKILL.md"
      let kind = archive ? "archive" : "skill-md"
      try payload.write(to: web.appendingPathComponent(String(file.dropFirst())))
      let digest =
        validDigest ? FileHash.sha256Hex(data: payload) : String(repeating: "0", count: 64)
      let index = web.appendingPathComponent(".well-known/agent-skills/index.json")
      try FileManager.default.createDirectory(
        at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(
        "{\"$schema\":\"https://schemas.agentskills.io/discovery/0.2.0/schema.json\",\"skills\":[{\"name\":\"indexed\",\"type\":\"\(kind)\",\"description\":\"Indexed fixture\",\"url\":\"\(file)\",\"digest\":\"sha256:\(digest)\"}]}"
          .utf8
      ).write(to: index)
    }
    try publish("Original")
    _ = try SkillOperations.add(
      AddOptions(
        source: server.url, alias: "indexed", agents: [.codex], mode: mode, all: true,
        environment: fixture.environment))
    let store = fixture.store()
    #expect(try store.loadLedger().resources.values.contains { $0.kind == .artifact })
    #expect(
      try SkillOperations.listManaged(environment: fixture.environment).map(\.name) == ["indexed"])
    let watch = SkillOperations.watchOperations()
    try watch.add("indexed", environment: fixture.environment)
    let original = try Data(contentsOf: store.resolvedURL)
    try publish("Current")
    let before = try FileHash.folderHash(fixture.environment.projectDirectory)
    let preview = try SkillOperations.updateInstalled(environment: fixture.environment)
    #expect(try watch.status(environment: fixture.environment).first?.changes.isEmpty == false)
    #expect(preview.contains { $0.changed })
    #expect(try FileHash.folderHash(fixture.environment.projectDirectory) == before)
    #expect(try Data(contentsOf: store.resolvedURL) == original)
    _ = try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    #expect(try fixture.body(fixture.target("indexed")).contains("Current"))
    let current = try Data(contentsOf: store.resolvedURL)
    try watch.seen("indexed", environment: fixture.environment)
    try watch.remove("indexed", environment: fixture.environment)
    #expect(try Data(contentsOf: store.resolvedURL) == current)
    try publish("Unverified", validDigest: false)
    let valid = try FileHash.folderHash(fixture.environment.projectDirectory)
    #expect(throws: (any Error).self) {
      try SkillOperations.updateInstalled(environment: fixture.environment, apply: true)
    }
    #expect(try FileHash.folderHash(fixture.environment.projectDirectory) == valid)
    try publish("Current")
    server.stop()
    try FileManager.default.removeItem(at: fixture.target("indexed"))
    try FileManager.default.removeItem(at: store.cacheDirectory)
    _ = try SkillOperations.installResolvedReport(environment: fixture.environment)
    #expect(try Data(contentsOf: store.resolvedURL) == current)
    #expect(try fixture.body(fixture.target("indexed")).contains("Current"))
    if archive {
      #expect(
        try String(
          contentsOf: fixture.target("indexed").appendingPathComponent("references/context.md"),
          encoding: .utf8) == "Context: Current")
    }
    #expect(
      try SkillOperations.listManaged(environment: fixture.environment).allSatisfy {
        $0.isInstalled
      })
    // An empty selection must remove the last indexed member without contacting its origin.
    #expect(throws: Never.self) {
      try SkillOperations.remove(skillNames: ["indexed"], environment: fixture.environment)
    }
    #expect(try store.loadLedger().components.values.allSatisfy { $0.kind != "skills" })
    #expect(!FileManager.default.fileExists(atPath: fixture.target("indexed").path))
  }

  @Test func namedUpdatePreservesAnUnselectedIndexedArtifact() throws {
    let fixture = try SkillFixture()
    let web = fixture.root.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let server = try ArtifactHTTPServer(root: web)
    defer { server.stop() }
    func publish(_ body: String) throws {
      var entries: [[String: String]] = []
      for name in ["one", "two"] {
        let bytes = Data("---\nname: \(name)\ndescription: Indexed fixture\n---\n\(body)\n".utf8)
        try bytes.write(to: web.appendingPathComponent(name + ".md"))
        entries.append([
          "name": name, "description": "Indexed fixture", "type": "skill-md",
          "url": "/" + name + ".md", "digest": "sha256:" + FileHash.sha256Hex(data: bytes),
        ])
      }
      let index = web.appendingPathComponent(".well-known/agent-skills/index.json")
      try FileManager.default.createDirectory(
        at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: [
        "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json", "skills": entries,
      ]).write(to: index)
    }
    try publish("Original")
    _ = try SkillOperations.add(
      AddOptions(
        source: server.url, alias: "indexed", agents: [.codex], mode: .copy, all: true,
        environment: fixture.environment))
    let previous = try #require(fixture.store().loadResolved().skills["two"])
    try publish("Current")
    _ = try SkillOperations.updateInstalled(
      environment: fixture.environment, skillNames: ["one"], apply: true)
    #expect(try fixture.store().loadResolved().skills["two"] == previous)
    #expect(try fixture.body(fixture.target("two")).contains("Original"))
    #expect(try fixture.body(fixture.target("one")).contains("Current"))
  }

}

/// Serves fixture bytes to the production HTTP loader; no source-provided program is executed.
private final class ArtifactHTTPServer {
  private let process = Process()
  private let output = Pipe()
  let url: String

  init(root: URL, redirect: String? = nil) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
      "-e",
      #"""
      use IO::Socket::INET;
      alarm 120;
      my ($root, $redirect) = @ARGV;
      my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, Proto => 'tcp') or die $!;
      $| = 1; print $server->sockport, "\n";
      while (my $client = $server->accept()) {
        my $request = <$client>;
        my ($path) = $request =~ m{^GET (/[^ ]*) HTTP/};
        while (my $line = <$client>) { last if $line eq "\r\n"; }
        if (defined($path) && $path eq '/redirect.md' && length($redirect)) {
          print $client "HTTP/1.1 302 Found\r\nLocation: $redirect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
          close $client; next;
        }
        my $bytes = '';
        my $status = '404 Not Found';
        if (defined($path) && $path !~ /\.\./ && open(my $file, '<', "$root$path")) {
          binmode $file; local $/; $bytes = <$file>; close $file; $status = '200 OK';
        }
        print $client "HTTP/1.1 $status\r\nContent-Length: ", length($bytes), "\r\nConnection: close\r\n\r\n", $bytes;
        close $client;
      }
      """#, root.path, redirect ?? "",
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
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
      throw CoreError.invalidState("fixture HTTP listener did not start")
    }
    url = "http://127.0.0.1:\(port)"
  }

  func stop() {
    if process.isRunning { terminateProcess(process) }
    try? output.fileHandleForReading.close()
  }
}

extension IndexedArtifactLifecycleTests {
  @Test func acknowledgmentRevalidatesTheDisplayedArtifactDigests() throws {
    let fixture = try SkillFixture()
    let web = fixture.root.appendingPathComponent("watch-web")
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    let server = try ArtifactHTTPServer(root: web)
    defer { server.stop() }
    func publish(_ body: String) throws {
      let bytes = Data("---\nname: watched\ndescription: Watch\n---\n\(body)\n".utf8)
      try bytes.write(to: web.appendingPathComponent("watched.md"))
      let index = web.appendingPathComponent(".well-known/agent-skills/index.json")
      try FileManager.default.createDirectory(
        at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: [
        "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
        "skills": [
          [
            "name": "watched", "description": "Watch", "type": "skill-md", "url": "/watched.md",
            "digest": "sha256:" + FileHash.sha256Hex(data: bytes),
          ]
        ],
      ]).write(to: index)
    }
    try publish("original")
    let watch = SkillOperations.watchOperations()
    _ = try watch.add(server.url, alias: "watched", environment: fixture.environment)
    let displayed = try #require(watch.status(environment: fixture.environment).first)
    let baseline = try Data(contentsOf: fixture.store().watchURL)
    try publish("advanced")
    #expect(throws: (any Error).self) {
      try watch.seen(displayed, environment: fixture.environment)
    }
    #expect(try Data(contentsOf: fixture.store().watchURL) == baseline)
    let current = try #require(watch.status(environment: fixture.environment).first)
    _ = try watch.seen(current, environment: fixture.environment)
    #expect(try fixture.store().loadWatch().sources[current.sourceID]?.seen == current.current)
    #expect(try fixture.store().loadLedger().components.isEmpty)
  }
}

extension IndexedArtifactLifecycleTests {
  @Test func sourcePolicyEnforcesIndexAndDownstreamArtifactOrigins() throws {
    let fixture = try SkillFixture()
    let indexRoot = fixture.root.appendingPathComponent("index")
    let artifactRoot = fixture.root.appendingPathComponent("downstream")
    try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    let artifact = try ArtifactHTTPServer(root: artifactRoot)
    defer { artifact.stop() }
    let index = try ArtifactHTTPServer(root: indexRoot, redirect: artifact.url + "/SKILL.md")
    defer { index.stop() }
    let payload = Data("---\nname: indexed\ndescription: Policy fixture\n---\nContent.\n".utf8)
    try payload.write(to: artifactRoot.appendingPathComponent("SKILL.md"))
    let listing = indexRoot.appendingPathComponent(".well-known/agent-skills/index.json")
    try FileManager.default.createDirectory(
      at: listing.deletingLastPathComponent(), withIntermediateDirectories: true)
    func publish(artifactURL: String) throws {
      try JSONSerialization.data(withJSONObject: [
        "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
        "skills": [
          [
            "name": "indexed", "description": "Policy fixture", "type": "skill-md",
            "url": artifactURL,
            "digest": "sha256:" + FileHash.sha256Hex(data: payload),
          ]
        ],
      ]).write(to: listing)
    }
    try publish(artifactURL: artifact.url + "/SKILL.md")
    let environment = fixture.environment
    let policy = SourcePolicyOperations.policyURL(scope: .project, environment: environment)
    try FileManager.default.createDirectory(
      at: policy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let indexOnly = Data("version: 1\nallow: [{http: '\(index.url)'}]\n".utf8)
    try indexOnly.write(to: policy)
    let options = AddOptions(
      source: index.url, alias: "index", agents: [.codex], mode: .copy, all: true,
      environment: environment)
    do {
      _ = try SkillOperations.add(options)
      Issue.record("A disallowed artifact was acquired")
    } catch let failure as SourcePolicyFailure {
      #expect(failure.violations.map(\.origin) == [try .http(artifact.url)])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
    try Data("version: 1\nallow: [{http: '\(index.url)'}, {http: '\(artifact.url)'}]\n".utf8)
      .write(to: policy)
    try publish(artifactURL: index.url + "/redirect.md")
    do {
      _ = try SkillOperations.add(options)
      Issue.record("An unrecorded redirect was acquired")
    } catch {
      #expect(String(describing: error).contains("cross-origin downloads"))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.store().resolvedURL.path))
    try publish(artifactURL: artifact.url + "/SKILL.md")
    _ = try SkillOperations.add(options)
    #expect(FileManager.default.fileExists(atPath: fixture.target("indexed").path))
    index.stop()
    artifact.stop()
    try indexOnly.write(to: policy)
    try FileManager.default.removeItem(at: fixture.target("indexed"))
    let audit = try SourcePolicyOperations.audit(environment: environment)
    #expect(audit.violations.map(\.origin) == [try .http(artifact.url)])
    let before = try FileHash.folderHash(environment.projectDirectory)
    #expect(throws: SourcePolicyFailure.self) {
      try UpdateOperations.restore(environment: environment)
    }
    #expect(try FileHash.folderHash(environment.projectDirectory) == before)
  }
}
