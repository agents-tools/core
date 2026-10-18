import Testing

@testable import AgentsSkills

@Suite("Text Sanitizer")
struct TextSanitizerTests {
  @Test func stripsUnsafeTerminalControlCharacters() {
    let esc = "\u{001B}"
    let cases: [(String, String)] = [
      ("Hello \(esc)[31mred\(esc)[0m", "Hello red"),
      ("\(esc)[1;32mbold green\(esc)[0m", "bold green"),
      ("\(esc)[38;5;145mextended color\(esc)[0m", "extended color"),
      ("\(esc)[H", ""),
      ("\(esc)[5;10H", ""),
      ("\(esc)[A\(esc)[10B\(esc)[C\(esc)[D", ""),
      ("Move\(esc)[2Jclear", "Moveclear"),
      ("\(esc)[3J\(esc)[K\(esc)[2K", ""),
      ("\(esc)[S\(esc)[T", ""),
      ("Title\(esc)]0;owned\u{0007}done", "Titledone"),
      ("\(esc)]0;title\(esc)\\", ""),
      ("Link \(esc)]8;;https://evil.example\u{0007}click\(esc)]8;;\u{0007}", "Link click"),
      ("Save\(esc)7restore\(esc)8", "Saverestore"),
      ("\(esc)M\(esc)c", ""),
      ("Bell\u{0007}Back\u{0008}Return\rNull\u{0000}", "BellBackReturnNull"),
      ("hello\tworld", "hello\tworld"),
      ("hello\nworld", "hello\nworld"),
      ("hello\u{009B}world\u{009D}", "helloworld"),
      ("plain ASCII", "plain ASCII"),
      ("unicode 日本語", "unicode 日本語"),
      ("emoji 🎉", "emoji 🎉"),
      ("safe-skill\(esc)[8m(downloads malware)\(esc)[0m", "safe-skill(downloads malware)"),
      (
        "safe-skill\(esc)[2J\(esc)[H\(esc)[32m✓ Verified Safe\(esc)[0m", "safe-skill✓ Verified Safe"
      ),
      (
        "\(esc)]0;pwned\u{0007}\(esc)[3J\(esc)[2J\(esc)[H\(esc)[32mFake output\(esc)[0m",
        "Fake output"
      ),
    ]

    for (raw, expected) in cases {
      #expect(TextSanitizer.stripTerminalEscapes(raw) == expected)
    }

    let malicious =
      "\(esc)]0;[POC] skills output hijacked\u{0007}\(esc)[3J\(esc)[2J\(esc)[H\(esc)[31m[POC] Terminal output injected from SKILL.md\(esc)[0m\n\(esc)[33mThis cleared the screen and overwrote CLI output.\(esc)[0m"
    let stripped = TextSanitizer.stripTerminalEscapes(malicious)
    #expect(!stripped.contains(esc))
    #expect(!stripped.contains("\u{0007}"))
    #expect(stripped.contains("[POC] Terminal output injected from SKILL.md"))
    #expect(stripped.contains("This cleared the screen and overwrote CLI output."))

    #expect(TextSanitizer.sanitizeMetadata("  \(esc)[31mhello\(esc)[0m  ") == "hello")
    #expect(TextSanitizer.sanitizeMetadata("line1\nline2\nline3") == "line1 line2 line3")
    #expect(TextSanitizer.sanitizeMetadata("  hello\nworld\r\nagain  ") == "hello world again")
    #expect(
      TextSanitizer.sanitizeMetadata(malicious)
        == "[POC] Terminal output injected from SKILL.md This cleared the screen and overwrote CLI output."
    )
    #expect(TextSanitizer.sanitizeMetadata("next-best-practices") == "next-best-practices")
    #expect(TextSanitizer.sanitizeMetadata("AI SDK") == "AI SDK")
    #expect(TextSanitizer.sanitizeMetadata("Creating Diagrams") == "Creating Diagrams")
    #expect(
      TextSanitizer.sanitizeMetadata("Build UIs with @nuxt/ui v4")
        == "Build UIs with @nuxt/ui v4")
  }
}
