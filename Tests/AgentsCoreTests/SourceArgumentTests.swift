import Foundation
import Testing

@testable import AgentsCore

@Suite("Source arguments")
struct SourceArgumentTests {
  private let environment = RuntimeEnvironment(
    projectDirectory: URL(fileURLWithPath: "/project"),
    homeDirectory: URL(fileURLWithPath: "/home/test"), environment: [:])

  @Test(
    arguments: zip(
      [
        "owner/repo@branch:main", "owner/repo@revision:abc123", "owner/repo@ref:v1.2.0",
        "owner/repo@exact:1.2.3", "owner/repo@from:1.2.0", "owner/repo@minor:1.2.0",
      ],
      [
        SourceRequirement.branch("main"), .revision("abc123"), .revision("v1.2.0"),
        .exact("1.2.3"), .upToNextMajor(from: "1.2.0"), .upToNextMinor(from: "1.2.0"),
      ]))
  func parsesRequirementSelectors(_ input: String, _ requirement: SourceRequirement) throws {
    let argument = try SourceArgument(input)
    #expect(argument.location == "owner/repo")
    #expect(argument.requirement == requirement)
    #expect(argument.path == nil && argument.name == nil)
  }

  @Test func combinesSelectorsAndDecodesValues() throws {
    let argument = try SourceArgument("owner/repo@skill:pdf@branch:feature%2Fone@path:skills/team")
    #expect(argument.location == "owner/repo")
    #expect(argument.requirement == .branch("feature/one"))
    #expect(argument.path == "skills/team")
    #expect(argument.name == "pdf")
  }

  @Test(
    arguments: zip(
      [
        "git@github.com:owner/repo@branch:main", "./skills@branch:main", "owner/repo@pdf",
        "https://user@example.com/index", "owner/repo",
      ],
      [
        "git@github.com:owner/repo", "./skills", "owner/repo@pdf",
        "https://user@example.com/index", "owner/repo",
      ]))
  func keepsOtherAtSignsInTheLocation(_ input: String, _ location: String) throws {
    #expect(try SourceArgument(input).location == location)
  }

  @Test(arguments: [
    "owner/repo@branch:main@tag:v1", "owner/repo@branch:main@oops", "owner/repo@branch:",
    "owner/repo@branch:main@ref:main", "owner/repo@path:a@path:b",
    "owner/repo@skill:a@skill:b", "owner/repo@from:latest", "owner/repo@path:../escape",
    "@branch:main",
  ])
  func rejectsInvalidSelectors(_ input: String) {
    #expect(throws: CoreError.self) { try SourceArgument(input) }
  }

  @Test func selectionRequiresRepeatedValuesToAgree() throws {
    let argument = try SourceArgument("owner/repo@branch:main@path:skills")
    let selection = try argument.selection(
      in: Declaration(), requirement: .branch("main"), path: "skills", environment: environment)
    #expect(
      selection.source == SourceDeclaration(kind: .git, location: "https://github.com/owner/repo"))
    #expect(selection.requirement == .branch("main") && selection.path == "skills")
    #expect(throws: CoreError.self) {
      try argument.selection(
        in: Declaration(), requirement: .branch("dev"), path: nil, environment: environment)
    }
    #expect(throws: CoreError.self) {
      try argument.selection(
        in: Declaration(), requirement: nil, path: "other", environment: environment)
    }
  }

  @Test func explicitValuesReplaceATreeURLsBranchAndPath() throws {
    let tree = try SourceArgument("https://github.com/owner/repo/tree/main/skills")
    let implied = try tree.selection(
      in: Declaration(), requirement: nil, path: nil, environment: environment)
    #expect(implied.requirement == .branch("main") && implied.path == "skills")
    let replaced = try SourceArgument(
      "https://github.com/owner/repo/tree/main/skills@branch:dev"
    ).selection(in: Declaration(), requirement: nil, path: "rules", environment: environment)
    #expect(replaced.requirement == .branch("dev") && replaced.path == "rules")
  }

  @Test func selectorsApplyToADeclaredAlias() throws {
    let declared = SourceDeclaration(
      kind: .git, location: "https://github.com/owner/repo", requirement: .exact("1.0.0"))
    let selection = try SourceArgument("team@branch:main").selection(
      in: Declaration(sources: ["team": declared]), requirement: nil, path: nil,
      environment: environment)
    #expect(selection.source == declared)
    #expect(selection.applied(to: declared).requirement == .branch("main"))
  }
}
