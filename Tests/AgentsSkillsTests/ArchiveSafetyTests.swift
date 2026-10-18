import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

@Suite("Archive path safety")
struct ArchiveSafetyTests {
  @Test(arguments: [
    "../escape", "../escape/", "nested/../../escape", "nested\\..\\..\\escape", "/absolute",
    "/absolute/", "link",
  ])
  func rejectsZipTraversalAbsolutePathsAndSymlinks(_ path: String) throws {
    let fixture = try SkillFixture()
    try fixture.skill("demo", body: "A")
    try fixture.commit()
    _ = try fixture.add(mode: .copy)
    let before = try fixture.stateAndTargetBytes()
    let archive = zip(entries: [
      ("SKILL.md", Data("---\nname: zip-skill\ndescription: Test\n---".utf8), 0o100644),
      (
        path, path.hasSuffix("/") ? Data() : Data("payload".utf8),
        path == "link" ? 0o120777 : path.hasSuffix("/") ? 0o040755 : 0o100644
      ),
    ])
    let digest = "sha256:" + FileHash.sha256Hex(data: archive)
    let index = Data(
      "{\"$schema\":\"https://schemas.agentskills.io/discovery/0.2.0/schema.json\",\"skills\":[{\"name\":\"zip-skill\",\"type\":\"archive\",\"description\":\"Test\",\"url\":\"skill.zip\",\"digest\":\"\(digest)\"}]}"
        .utf8)
    let provider = WellKnownProvider { url in url.path.hasSuffix("index.json") ? index : archive }
    let expected: CoreError =
      path == "link"
      ? .invalidSource("well-known archive contains unsupported entry type")
      : .unsafePath(
        path.hasPrefix("/")
          ? "subpath must be relative: \(path)" : "subpath contains path traversal segment: \(path)"
      )
    #expect(throws: expected) {
      try SkillOperations.add(
        AddOptions(
          source: "https://zip.test", agents: [.codex], all: true, environment: fixture.environment),
        provider: provider)
    }
    #expect(try fixture.stateAndTargetBytes() == before)
  }

  @Test func rejectsAbsoluteTarPaths() throws {
    let fixture = try SkillFixture()
    let file = fixture.root.appendingPathComponent("absolute")
    try Data("sentinel".utf8).write(to: file)
    let archive = fixture.root.appendingPathComponent("absolute.tar.gz")
    try ProcessRunner.run("/usr/bin/env", arguments: ["tar", "-czPf", archive.path, file.path])
    let data = try Data(contentsOf: archive)
    let artifact = LockedArtifact(
      type: .archive, url: "https://archive.test/absolute.tar.gz",
      digest: "sha256:" + FileHash.sha256Hex(data: data))
    let provider = WellKnownProvider { _ in data }
    #expect(throws: CoreError.unsafePath("subpath must be relative: \(file.path)")) {
      try provider.restore(artifact, cache: SourceCache(store: fixture.store()))
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "sentinel")
  }

  @Test func generatedZipFixtureIsAValidArchive() throws {
    let fixture = try SkillFixture()
    let skill = Data("---\nname: demo\ndescription: Test\n---".utf8)
    let data = zip(entries: [("SKILL.md", skill, 0o100644)])
    let provider = WellKnownProvider { _ in data }
    let artifact = LockedArtifact(
      type: .archive, url: "https://archive.test/skill.zip",
      digest: "sha256:" + FileHash.sha256Hex(data: data))
    let restored = try provider.restore(artifact, cache: SourceCache(store: fixture.store()))
    #expect(restored.files["SKILL.md"] == skill)
  }

  private func zip(entries: [(String, Data, UInt32)]) -> Data {
    var local = Data()
    var central = Data()
    func number<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    for (path, content, mode) in entries {
      let name = Data(path.utf8)
      let offset = UInt32(local.count)
      var crc: UInt32 = 0xffff_ffff
      for byte in content {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
      }
      crc ^= 0xffff_ffff
      number(UInt32(0x0403_4b50), to: &local)
      for value: UInt16 in [20, 0, 0, 0, 0] { number(value, to: &local) }
      for value in [crc, UInt32(content.count), UInt32(content.count)] { number(value, to: &local) }
      number(UInt16(name.count), to: &local)
      number(UInt16(0), to: &local)
      local.append(name)
      local.append(content)
      number(UInt32(0x0201_4b50), to: &central)
      for value: UInt16 in [0x0314, 20, 0, 0, 0, 0] { number(value, to: &central) }
      for value in [crc, UInt32(content.count), UInt32(content.count)] {
        number(value, to: &central)
      }
      for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { number(value, to: &central) }
      number(mode << 16, to: &central)
      number(offset, to: &central)
      central.append(name)
    }
    let offset = UInt32(local.count)
    local.append(central)
    number(UInt32(0x0605_4b50), to: &local)
    for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] {
      number(value, to: &local)
    }
    number(UInt32(central.count), to: &local)
    number(offset, to: &local)
    number(UInt16(0), to: &local)
    return local
  }
}
