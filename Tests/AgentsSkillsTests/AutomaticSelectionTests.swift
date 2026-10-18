import AgentsCore
import Darwin
import Foundation
import Testing

@Suite("Automatic add selection")
struct AutomaticSelectionTests {
  @Test(arguments: ["skill", "instruction"], ["rename", "source", "removed-source", "content"])
  func revalidatesSelectionDuringConcurrentChanges(_ kind: String, _ change: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "Original")
    let instructions = fixture.repo.appendingPathComponent("instructions")
    try FileManager.default.createDirectory(at: instructions, withIntermediateDirectories: true)
    try Data("# Demo\n\nOriginal\n".utf8).write(to: instructions.appendingPathComponent("demo.md"))
    try fixture.commit()
    let store = fixture.store()
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    var declaration = Declaration(sources: [
      "source": SourceDeclaration(kind: .local, location: fixture.repo.path)
    ])
    try StateStore.encode(declaration).write(to: store.declarationURL)

    let root = fixture.environment.projectDirectory
    let resume = root.appendingPathComponent("resume-discovery")
    try #require(mkfifo(resume.path, 0o600) == 0)
    let descriptor = open(resume.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let child = try startAdd(root: root, kind: kind)
    defer {
      // Release the Git wrapper even if fixture preparation fails.
      _ = "\n".withCString { write(descriptor, $0, 1) }
      if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
    }
    try wait(for: child) {
      FileManager.default.fileExists(atPath: root.appendingPathComponent("discovery-ready").path)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: store.directory.appendingPathComponent(".agents.lock").path))

    if change == "source" {
      let replacement = fixture.root.appendingPathComponent("replacement-source")
      try ProcessRunner.run(
        "/usr/bin/git", arguments: ["clone", "--no-local", fixture.repo.path, replacement.path])
      declaration.sources["source"] = SourceDeclaration(kind: .local, location: replacement.path)
      try store.save(declaration: declaration, resolved: ResolvedState())
    } else if change == "removed-source" {
      declaration.sources.removeValue(forKey: "source")
      try store.save(declaration: declaration, resolved: ResolvedState())
    } else {
      if kind == "skill" {
        let name = change == "rename" ? "replacement" : "demo"
        // Keep the directory named demo while changing the declared skill name.
        try Data("---\nname: \(name)\ndescription: Test skill\n---\nCurrent\n".utf8).write(
          to: fixture.repo.appendingPathComponent("skills/demo/SKILL.md"))
      } else if change == "rename" {
        try FileManager.default.moveItem(
          at: instructions.appendingPathComponent("demo.md"),
          to: instructions.appendingPathComponent("replacement.md"))
      } else {
        try Data("# Demo\n\nCurrent\n".utf8).write(
          to: instructions.appendingPathComponent("demo.md"))
      }
      try fixture.commit()
    }
    let beforeDeclaration = try Data(contentsOf: store.declarationURL)
    let beforeLock = try? Data(contentsOf: store.resolvedURL)
    try #require("\n".withCString { write(descriptor, $0, 1) } == 1)
    try wait(for: child) { !child.isRunning }
    child.waitUntilExit()
    #expect(child.terminationStatus == 0)
    let result = try String(contentsOf: root.appendingPathComponent("add-result"), encoding: .utf8)
    if change == "content" || change == "source" {
      #expect(result == "applied")
      let lock = try store.loadResolved()
      let source = try #require(declaration.sources["source"])
      let sourceID = try source.identity(environment: fixture.environment)
      let content = change == "content" ? "Current" : "Original"
      if kind == "skill" {
        #expect(lock.skills.keys.sorted() == ["demo"])
        #expect(lock.skills["demo"]?.source == sourceID)
        #expect(lock.skills["demo"]?.revision == (try fixture.head()))
        #expect(try fixture.body(fixture.target("demo")).contains(content))
      } else {
        #expect(lock.instructions.sections.map(\.name) == ["demo"])
        #expect(lock.instructions.sections.first?.source == sourceID)
        #expect(lock.instructions.sections.first?.revision == (try fixture.head()))
        #expect(
          try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
            .contains(content))
      }
    } else {
      let expected =
        change == "removed-source"
        ? "Invalid source: expected a local path or repository URL"
        : "Invalid state: automatic \(kind) selection changed during discovery; retry the command"
      #expect(result == expected)
      #expect(try Data(contentsOf: store.declarationURL) == beforeDeclaration)
      #expect((try? Data(contentsOf: store.resolvedURL)) == beforeLock)
      #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills").path))
      #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
    }
  }

  private func startAdd(root: URL, kind: String) throws -> Process {
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let git = bin.appendingPathComponent("git")
    // Pause after the read pass captures its archive, before writer rediscovery can start.
    try Data(
      """
      #!/bin/sh
      /usr/bin/git "$@"
      result=$?
      [ "$result" -eq 0 ] || exit "$result"
      for argument in "$@"; do
        if [ "$argument" = archive ] && [ ! -e "$SELECTION_TEST_ROOT/discovery-ready" ]; then
          touch "$SELECTION_TEST_ROOT/discovery-ready"
          read -r resume < "$SELECTION_TEST_ROOT/resume-discovery"
        fi
      done
      """.utf8
    ).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
    var directory = Bundle(for: AutomaticSelectionTestBundle.self).bundleURL
      .deletingLastPathComponent()
    while !FileManager.default.isExecutableFile(
      atPath: directory.appendingPathComponent("StateTestProcess").path), directory.path != "/"
    {
      directory.deleteLastPathComponent()
    }
    let child = Process()
    child.executableURL = directory.appendingPathComponent("StateTestProcess")
    child.arguments = [root.path, "automatic-add", kind]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["SELECTION_TEST_ROOT"] = root.path
    child.environment = environment
    try child.run()
    return child
  }

  private func wait(for process: Process, until ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(20)
    while !ready(), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try #require(ready())
  }
}

private final class AutomaticSelectionTestBundle: NSObject {}
