import AgentsCore
import AgentsDescription

package enum Lowering {
  package static func declaration(_ value: ConstructionValue) -> DeclarationIR {
    let fields = value.fields
    return DeclarationIR(
      defaultAgents: fields["defaultAgents"]?.array?.compactMap { lower($0).string },
      exports: fields["exports"]?.strings ?? [],
      sources: (fields["sources"]?.array ?? []).compactMap { lower($0).record },
      components: (fields["components"]?.array ?? []).compactMap { lower($0).record },
      groups: (fields["groups"]?.array ?? []).compactMap { lower($0).record },
      uses: (fields["uses"]?.array ?? []).compactMap { lower($0).record },
      watch: fields["watch"]?.strings ?? [])
  }

  package static func requirement(_ range: Range<Version>) -> SourceRequirement {
    let lower = range.lowerBound
    let upper = range.upperBound
    let major = lower.successor(major: true)
    let minor = lower.successor(major: false)
    if major.valid && upper == major { return .upToNextMajor(from: lower.normalized) }
    if minor.valid && upper == minor { return .upToNextMinor(from: lower.normalized) }
    return .range(from: lower.normalized, to: upper.normalized)
  }

  package static func lower(_ value: ConstructionValue) -> DeclarationValue {
    switch value {
    case .text(let text): return .string(text)
    case .integer(let integer): return .integer(integer)
    case .boolean(let boolean): return .boolean(boolean)
    case .none: return .null
    case .version(let version): return .string(version.normalized)
    case .range(let range): return .requirement(requirement(range))
    case .array(let values): return .array(values.map(lower))
    case .object(let fields): return .dictionary(fields.mapValues(lower))
    case .node(let type, let member, let fields):
      let scalarEnums: Set<String> = [
        "Agent", "Scope", "Platform", "InstallMode", "IgnorePurpose", "PluginMode", "ComponentKind",
      ]
      if scalarEnums.contains(type) {
        let ids = [
          "claudeCode": "claude-code", "geminiCLI": "gemini-cli", "openCode": "opencode",
          "macOS": "macos",
        ]
        return .string(ids[member] ?? member)
      }
      if type == "SkillSelection" {
        return member == "all" ? .string("all") : .array((fields["names"]?.array ?? []).map(lower))
      }
      if type == "Requirement", let text = fields["value"]?.text {
        return .requirement(
          member == "exact" ? .exact(text) : member == "branch" ? .branch(text) : .revision(text))
      }
      var lowered = fields.mapValues(lower)
      var kind = member
      if type == "Source" {
        kind = fields["url"] != nil ? "git" : fields["path"] != nil ? "local" : "index"
        if let url = fields["url"]?.text {
          lowered["url"] = .string(SourceDeclaration(kind: .git, location: url).gitURL)
        }
      }
      if type == "GroupReference" { kind = fields["source"]?.text == nil ? "local" : "exported" }
      return .record(DeclarationRecord(kind: kind, fields: lowered))
    }
  }
}
