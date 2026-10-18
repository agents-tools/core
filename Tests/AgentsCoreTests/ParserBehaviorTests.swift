import Foundation
import Testing

@testable import AgentsCore

@Suite("Source parser")
struct SourceParserTests {
  @Test(arguments: [
    "https://User@GITHUB.com/owner/repo.git", "git@github.com:owner/repo.git",
    "ssh://git@github.com/owner/repo", "github.com/owner/repo", "owner/repo",
  ])
  func normalizesGitForms(_ input: String) throws {
    #expect(try SourceParser.identity(for: SourceParser.parse(input)) == "github.com/owner/repo")
  }

  @Test func retainsProviderPortAndPathCase() throws {
    #expect(
      try SourceParser.identity(
        for: SourceParser.parse("ssh://git@Example.COM:2222/Owner/Repo.git"))
        == "example.com:2222/Owner/Repo")
    #expect(
      try SourceParser.identity(for: SourceParser.parse("https://example.com"))
        == "https://example.com")
    #expect(
      try SourceParser.identity(
        for: SourceParser.parse("~/rules", homeDirectory: URL(fileURLWithPath: "/home/test")))
        == "local:/home/test/rules")
  }

  @Test func parsesHostedSearchRoots() throws {
    let source = try SourceParser.parse("https://github.com/owner/repo/tree/main/skills")
    #expect(source.requirement == .branch("main"))
    #expect(source.subpath == "skills")
    #expect(try SourceParser.identity(for: source) == "github.com/owner/repo")
  }
}
