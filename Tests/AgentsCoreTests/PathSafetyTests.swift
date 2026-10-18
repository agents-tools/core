import Foundation
import Testing

@testable import AgentsCore

@Suite("Path Safety And Sanitization")
struct PathSafetyAndSanitizationTests {
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
