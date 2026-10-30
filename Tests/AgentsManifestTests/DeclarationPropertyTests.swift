import AgentsCore
import Foundation
import Testing

@testable import AgentsManifest

/// Deterministic declarations over a small alias, name and section vocabulary.
private struct DeclarationGenerator {
  var random = ManifestRandom(state: 0x5eed_2026_1030)

  mutating func flip() -> Bool { random.next(2) == 0 }

  mutating func subset<T>(_ values: [T]) -> [T] { values.filter { _ in flip() } }

  mutating func recipients() -> [AgentID]? {
    switch random.next(3) {
    case 0: return nil
    case 1: return []
    default: return subset(AgentID.allCases)
    }
  }

  mutating func source(_ alias: String) -> SourceDeclaration {
    let requirements: [SourceRequirement?] = [
      nil, .branch("main"), .revision("abc123"), .exact("1.2.3"), .upToNextMajor(from: "1.2.0"),
      .upToNextMinor(from: "1.2.0"), .range(from: "1.2.0", to: "1.5.0"),
    ]
    let subpath = flip() ? nil : "skills"
    switch random.next(3) {
    case 0:
      return SourceDeclaration(
        kind: .git, location: "example.org/team/\(alias).git",
        requirement: requirements[random.next(requirements.count)], path: subpath)
    case 1:
      return SourceDeclaration(
        kind: .local, location: "./\(alias)",
        requirement: requirements[random.next(requirements.count)], path: subpath)
    default:
      return SourceDeclaration(
        kind: .wellKnown, location: "https://example.org/\(alias)/index.json", path: subpath)
    }
  }

  mutating func skills() -> SkillDeclaration {
    let names = ["x", "y", "z"]
    let select: SkillSelection = flip() ? .all : .names(subset(names))
    var overrides: [String: SkillOverride] = [:]
    let candidates: [String]
    if case .names(let selected) = select { candidates = selected } else { candidates = names }
    for name in subset(candidates) {
      overrides[name] = SkillOverride(
        agents: recipients(), mode: [nil, .copy, .link][random.next(3)])
    }
    return SkillDeclaration(
      select: select, exclude: flip() ? nil : subset(names), agents: recipients(),
      mode: [nil, .copy, .link][random.next(3)], overrides: flip() ? nil : overrides)
  }

  mutating func sections(_ aliases: [String]) -> [String] {
    let pool = ["guide", "rules"] + aliases.map { $0 + ":guide" }
    return (0..<random.next(5)).map { _ in pool[random.next(pool.count)] }
  }

  mutating func instructions(_ aliases: [String]) -> InstructionsDeclaration? {
    guard flip() else { return nil }
    var prompts: [String: PromptDeclaration] = [:]
    for name in subset(["daily", "weekly"]) {
      prompts[name] = PromptDeclaration(
        sections: sections(aliases), append: flip() ? nil : "notes/\(name).md")
    }
    return InstructionsDeclaration(
      agents: recipients(), sections: sections(aliases), chatgpt: flip() ? nil : prompts)
  }

  mutating func declaration() -> Declaration {
    var declaration = Declaration(agents: recipients())
    for alias in subset(["a", "b", "c", "d"]) {
      declaration.sources[alias] = source(alias)
    }
    let aliases = declaration.sources.keys.sorted()
    var skills: [String: SkillDeclaration] = [:]
    for alias in subset(aliases) { skills[alias] = self.skills() }
    declaration.skills = skills.isEmpty && flip() ? nil : skills
    declaration.instructions = instructions(aliases)
    declaration.watch = flip() ? nil : subset(aliases)
    return declaration
  }

  /// A neighbor of `base`: each part is kept, changed or removed, and references follow sources.
  mutating func change(_ base: Declaration) -> Declaration {
    var result = base
    if random.next(3) == 0 { result.agents = recipients() }
    for alias in base.sources.keys.sorted() {
      switch random.next(4) {
      case 0: result.sources[alias] = nil
      case 1: result.sources[alias] = source(alias)
      default: break
      }
    }
    for alias in ["e", "f"] where random.next(3) == 0 { result.sources[alias] = source(alias) }
    let aliases = result.sources.keys.sorted()
    var skills = (result.skills ?? [:]).filter { result.sources[$0.key] != nil }
    for alias in aliases where random.next(3) == 0 {
      skills[alias] = flip() ? nil : self.skills()
    }
    result.skills = skills
    let referenced = result.instructions.map {
      ($0.sections + ($0.chatgpt ?? [:]).values.flatMap(\.sections)).allSatisfy {
        !$0.contains(":") || result.sources[String($0.split(separator: ":")[0])] != nil
      }
    }
    if referenced == false || random.next(3) == 0 { result.instructions = instructions(aliases) }
    result.watch = random.next(3) == 0 ? subset(aliases) : result.watch?.filter(aliases.contains)
    return result
  }
}

private func equivalent(_ lhs: Declaration, _ rhs: Declaration) -> Bool {
  ManifestProjection.equivalent(lhs, rhs, environment: projectionEnvironment)
}

private func projection(of bytes: [UInt8]) throws -> Declaration {
  try ManifestProjection.declaration(
    of: DeclarationDocument(bytes: bytes, identity: DocumentIdentity("manifest")),
    environment: projectionEnvironment)
}

/// Comments above every source, skills and instructions entry that `next` keeps unchanged.
private func commented(_ text: String, keeping kept: [String]) -> String {
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  for marker in kept {
    let (call, name) = (marker.split(separator: " ")[0], marker.split(separator: " ")[1])
    guard
      let index = lines.indices.first(where: { index in
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let next = index + 1 < lines.count ? lines[index + 1] : ""
        return line.hasPrefix(String(call) + "(")
          && (line.contains("\"\(name)\"")
            || !line.hasSuffix(")") && !line.hasSuffix("),")
              && next.contains("\"\(name)\""))
      })
    else { continue }
    let indentation = lines[index].prefix { $0 == " " }
    lines.insert(indentation + "// keep " + marker, at: index)
  }
  lines.insert("// file comment", at: 3)
  return lines.joined(separator: "\n") + "// end of file\n"
}

@Suite("Declaration properties")
struct DeclarationPropertyTests {
  @Test func printedDeclarationsProjectToThemselves() throws {
    var generator = DeclarationGenerator()
    for _ in 0..<96 {
      let declaration = generator.declaration()
      try declaration.validate(environment: projectionEnvironment)
      guard let bytes = try planned(Declaration(), declaration, in: nil) else {
        #expect(equivalent(declaration, Declaration()))
        continue
      }
      #expect(try planned(Declaration(), declaration, in: nil) == bytes)
      #expect(equivalent(try projection(of: bytes), declaration), "\(declaration)")
    }
  }

  @Test func plansReachTheirTargetAndKeepCommentsOfUnchangedEntries() throws {
    var generator = DeclarationGenerator()
    var (edited, markers) = (0, 0)
    for _ in 0..<96 {
      let previous = generator.declaration()
      let next = generator.change(previous)
      try next.validate(environment: projectionEnvironment)
      let printed = String(
        decoding: try planned(Declaration(), previous, in: nil) ?? [], as: UTF8.self)
      guard !printed.isEmpty else { continue }
      var kept: [String] = []
      for alias in previous.sources.keys.sorted() {
        if let source = next.sources[alias], source == previous.sources[alias] {
          kept.append(".source \(alias)")
        }
      }
      for alias in (previous.skills ?? [:]).keys.sorted()
      where next.skills?[alias] == previous.skills?[alias] {
        kept.append(".skills \(alias)")
      }
      let text = commented(printed, keeping: kept)
      let bytes = try planned(previous, next, in: text)
      guard let bytes else {
        #expect(equivalent(previous, next))
        continue
      }
      #expect(equivalent(try projection(of: bytes), next), "\(previous) -> \(next)")
      let result = String(decoding: bytes, as: UTF8.self)
      #expect(
        result.contains(
          "// agents-tools-version: 1.0\nimport AgentsDescription\n\n// file comment\n"))
      #expect(result.hasSuffix(")\n// end of file\n"))
      for marker in kept {
        #expect(result.components(separatedBy: "// keep " + marker + "\n").count == 2, "\(marker)")
      }
      edited += 1
      markers += kept.count
    }
    // The seed must exercise edits and retained comments, not only no-op or empty plans.
    #expect(edited >= 64 && markers >= 64)
  }
}
