import Foundation
import Testing

@testable import AgentsCore

@Suite("Path Safety And Sanitization")
struct PathSafetyAndSanitizationTests {
  @Test func linksStayInsideOnlyWhenResolutionWithinTheRootCannotLeaveIt() throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let repo = root.appendingPathComponent("repo")
    let skill = repo.appendingPathComponent("skills/demo")
    try FileManager.default.createDirectory(
      at: skill.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try Data("guide".utf8).write(to: skill.appendingPathComponent("docs/guide.md"))
    let links = [
      "here": ".", "leak": "here/here/../../settings.json", "guide": "here/docs/guide.md",
      "pdf": "../../library/missing.pdf", "up": "../../../outside", "absolute": "/etc/hosts",
      "loop": "loop-back", "loop-back": "loop", "here\u{0600}": ".",
      "unicode": "here\u{0600}/../../settings.json", "case": "HERE/HERE/../../settings.json",
      "missing-up": "missing/../docs/guide.md",
    ]
    for (name, destination) in links {
      try FileManager.default.createSymbolicLink(
        atPath: skill.appendingPathComponent(name).path, withDestinationPath: destination)
    }
    func stays(_ name: String, in base: URL) throws -> Bool {
      try PathSafety.linkStaysInside(
        skill.appendingPathComponent(name), root: try #require(PathSafety.realPath(base.path)))
    }
    for name in ["here", "guide"] { #expect(try stays(name, in: skill)) }
    // A grapheme cannot hide a separator, and a lookup that differs by case or normalization on
    // another filesystem cannot turn a missing entry into a step above the root.
    for name in ["leak", "pdf", "up", "absolute", "loop", "unicode", "case", "missing-up"] {
      #expect(try !stays(name, in: skill))
    }
    // In the whole repository, the same dangling links stay inside and cannot be followed out.
    for name in ["leak", "pdf"] { #expect(try stays(name, in: repo)) }
    #expect(try !stays("up", in: repo))
  }

  @Test func sanitizesSkillNamesForFilesystemPaths() {
    let cases: [(String, String)] = [
      ("MySkill", "myskill"),
      ("UPPERCASE", "uppercase"),
      ("my skill", "my-skill"),
      ("Convex Best Practices", "convex-best-practices"),
      ("my   skill", "my-skill"),
      ("bun.sh", "bun.sh"),
      ("my_skill", "my_skill"),
      ("skill.v2_beta", "skill.v2_beta"),
      ("skill123", "skill123"),
      ("v2.0", "v2.0"),
      ("skill@name", "skill-name"),
      ("skill#name", "skill-name"),
      ("skill$name", "skill-name"),
      ("skill!name", "skill-name"),
      ("skill@#$name", "skill-name"),
      ("a!!!b", "a-b"),
      ("../etc/passwd", "etc-passwd"),
      ("../../secret", "secret"),
      ("..\\..\\secret", "secret"),
      ("/etc/passwd", "etc-passwd"),
      ("C:\\Windows\\System32", "c-windows-system32"),
      (".hidden", "hidden"),
      ("..hidden", "hidden"),
      ("...skill", "skill"),
      ("skill.", "skill"),
      ("skill..", "skill"),
      ("-skill", "skill"),
      ("--skill", "skill"),
      ("skill-", "skill"),
      ("skill--", "skill"),
      (".-.-skill", "skill"),
      ("-.-.skill", "skill"),
      ("", "unnamed-skill"),
      ("...", "unnamed-skill"),
      ("---", "unnamed-skill"),
      ("@#$%", "unnamed-skill"),
      ("skill日本語", "skill"),
      ("émoji🎉skill", "moji-skill"),
      ("owner/repo.js", "owner-repo.js"),
      ("owner/repo-name", "owner-repo-name"),
      ("https://example.com", "https-example.com"),
      ("docs.example.com", "docs.example.com"),
    ]

    for (raw, expected) in cases {
      #expect(PathSafety.sanitizeName(raw) == expected, "sanitizeName: \(raw)")
    }

    let longName = String(repeating: "a", count: 300)
    #expect(PathSafety.sanitizeName(longName).count == 255)
  }

}
