import AgentsCore
import AgentsDescription

enum Lowering {
  static func declaration(_ value: ConstructionValue) -> DeclarationIR {
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

  static func requirement(_ range: Range<Version>) -> SourceRequirement {
    SourceRequirement.range(
      from: range.lowerBound.normalized, to: range.upperBound.normalized
    ).canonical
  }

  static func recordKind(
    type: String, member: String, fields: [String: ConstructionValue]
  ) -> String {
    if type == "Source" {
      return fields["url"] != nil ? "git" : fields["path"] != nil ? "local" : "index"
    }
    if type == "GroupReference" { return fields["source"]?.text == nil ? "local" : "exported" }
    return member
  }

  static func lower(_ value: ConstructionValue) -> DeclarationValue {
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
      if let spelling = Vocabulary.scalarValues[type]?[member] {
        return .string(spelling)
      }
      if type == "SkillSelection" {
        return member == "all" ? .string("all") : .array((fields["names"]?.array ?? []).map(lower))
      }
      if type == "Requirement", let text = fields["value"]?.text {
        return .requirement(
          member == "exact" ? .exact(text) : member == "branch" ? .branch(text) : .revision(text))
      }
      var lowered = fields.mapValues(lower)
      let kind = recordKind(type: type, member: member, fields: fields)
      if type == "Source" {
        if let url = fields["url"]?.text {
          lowered["url"] = .string(SourceDeclaration(kind: .git, location: url).gitURL)
        }
      }
      return .record(DeclarationRecord(kind: kind, fields: lowered))
    }
  }
}
