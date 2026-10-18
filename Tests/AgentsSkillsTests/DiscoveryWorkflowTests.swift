import Foundation
import Testing

@testable import AgentsCore
@testable import AgentsSkills

extension SkillDiscoveryTests {
  @Test func discoversSkillsFromFrontmatterAndPluginManifest() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let skill = root.appendingPathComponent("plugin/skills/write")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try """
    ---
    name: Write Docs\u{001B}[31m
    description: Documentation helper
    ---

    Body
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
    try """
    {
      "metadata": { "pluginRoot": "./plugin" },
      "plugins": [
        { "name": "docs", "source": "./", "skills": ["./skills/write"] }
      ]
    }
    """.write(
      to: root.appendingPathComponent(".claude-plugin/marketplace.json"), atomically: true,
      encoding: .utf8)

    let skills = try Discovery.discover(in: root)
    #expect(skills.count == 1)
    #expect(skills[0].name == "Write Docs")
    #expect(skills[0].pluginName == "docs")
  }

  @Test func respectsFullDepthAndInternalSkillFiltering() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested/public"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested/internal"), withIntermediateDirectories: true)
    try """
    ---
    name: Root
    description: Root skill
    ---
    """.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: Public
    description: Public skill
    ---
    """.write(
      to: root.appendingPathComponent("nested/public/SKILL.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: Internal
    description: Internal skill
    metadata:
      internal: true
    ---
    """.write(
      to: root.appendingPathComponent("nested/internal/SKILL.md"), atomically: true, encoding: .utf8
    )

    let shallow = try Discovery.discover(in: root)
    #expect(shallow.map(\.name) == ["Root"])

    let fullDepth = try Discovery.discover(in: root, options: DiscoveryOptions(fullDepth: true))
    #expect(fullDepth.map(\.name).contains("Root"))
    #expect(fullDepth.map(\.name).contains("Public"))
    #expect(!fullDepth.map(\.name).contains("Internal"))

    let withInternal = try Discovery.discover(
      in: root, options: DiscoveryOptions(includeInternal: true, fullDepth: true))
    #expect(withInternal.map(\.name).contains("Internal"))
  }

  @Test func skipsInvalidFrontmatterValues() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let invalidName = root.appendingPathComponent("skills/invalid-name")
    let invalidDescription = root.appendingPathComponent("skills/invalid-description")
    try FileManager.default.createDirectory(at: invalidName, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: invalidDescription, withIntermediateDirectories: true)
    try """
    ---
    name: 123
    description: Invalid name
    ---
    """.write(to: invalidName.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: Invalid Description
    description: true
    ---
    """.write(
      to: invalidDescription.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let skills = try Discovery.discover(in: root)
    #expect(skills.isEmpty)
  }

  @Test func skipsMalformedFrontmatterAndKeepsValidSkills() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let malformed = root.appendingPathComponent("skills/malformed")
    let valid = root.appendingPathComponent("skills/valid")
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
    try """
    ---
    name: [unterminated
    description: Broken
    ---
    """.write(to: malformed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try """
    ---
    name: Valid
    description: Valid skill
    ---
    """.write(to: valid.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let skills = try Discovery.discover(in: root)
    #expect(skills.map(\.name) == ["Valid"])
  }
}

extension SkillMatchingTests {
  @Test func filtersSkillsByNameAndDirectoryCaseInsensitively() throws {
    let skill = Skill(
      name: "Code Review",
      description: "Review code",
      path: "/tmp/code-review",
      skillFile: "/tmp/code-review/SKILL.md"
    )
    #expect(Discovery.filter([skill], names: ["code review"]).map(\.name) == ["Code Review"])
    #expect(Discovery.filter([skill], names: ["CODE-REVIEW"]).map(\.name) == ["Code Review"])
    #expect(Discovery.filter([skill], names: ["review"]).isEmpty)
  }
}
