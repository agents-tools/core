extension Declaration {
  /// Projects validated legacy intent without choosing recipients, resolving sources or
  /// applying migration transformations. Optional values retain inheritance boundaries.
  public func compatibilityProjection() throws -> DeclarationIR {
    func strings(_ values: [String]) -> DeclarationValue { .array(values.map { .string($0) }) }
    func recipients(_ values: [AgentID]?) -> DeclarationValue {
      values.map { strings($0.map(\.rawValue).sorted(by: compatibilityUTF8Less)) } ?? .null
    }
    func sections(_ values: [String]) -> DeclarationValue {
      .array(
        values.map { reference in
          let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
          return .record(
            DeclarationRecord(
              kind: "section",
              fields: [
                "name": .string(parts.last!),
                "source": parts.count == 2 ? .string(parts[0]) : .null,
                "condition": .null,
              ]))
        })
    }
    let sources = try self.sources.keys.sorted(by: compatibilityUTF8Less).map { alias in
      let source = self.sources[alias]!
      let location = source.kind == .git ? "url" : source.kind == .local ? "path" : "index"
      return DeclarationRecord(
        kind: source.kind == .wellKnown ? "index" : source.kind.rawValue,
        fields: [
          "name": .string(alias),
          location: .string(source.kind == .git ? source.gitURL : source.location),
          "subpath": source.path.map { .string($0) } ?? .null,
          "requirement": try source.requirement.map { .requirement(try $0.canonicalized()) }
            ?? .null,
        ])
    }
    var components = (skills ?? [:]).keys.sorted(by: compatibilityUTF8Less).map { alias in
      let selection = skills![alias]!
      let select: DeclarationValue
      switch selection.select {
      case .all: select = .string("all")
      case .names(let names): select = strings(names.sorted(by: compatibilityUTF8Less))
      }
      let overrides = (selection.overrides ?? [:]).keys.sorted(by: compatibilityUTF8Less).map {
        name in
        let override = selection.overrides![name]!
        return DeclarationValue.record(
          DeclarationRecord(
            kind: "skill",
            fields: [
              "name": .string(name), "mode": override.mode.map { .string($0.rawValue) } ?? .null,
              "agents": recipients(override.agents),
            ]))
      }
      return DeclarationRecord(
        kind: "skills",
        fields: [
          "source": .string(alias), "select": select,
          "exclude": strings((selection.exclude ?? []).sorted(by: compatibilityUTF8Less)),
          "mode": selection.mode.map { .string($0.rawValue) } ?? .null,
          "agents": recipients(selection.agents), "overrides": .array(overrides),
          "condition": .null, "native": .dictionary([:]),
        ])
    }
    if let instructions {
      let prompts = (instructions.chatgpt ?? [:]).keys.sorted(by: compatibilityUTF8Less).map {
        name in
        let prompt = instructions.chatgpt![name]!
        return DeclarationValue.record(
          DeclarationRecord(
            kind: "prompt",
            fields: [
              "name": .string(name), "sections": sections(prompt.sections),
              "append": prompt.append.map { .string($0) } ?? .null, "condition": .null,
            ]))
      }
      components.append(
        DeclarationRecord(
          kind: "instructions",
          fields: [
            "sections": sections(instructions.sections), "chatGPT": .array(prompts),
            "agents": recipients(instructions.agents), "condition": .null,
            "native": .dictionary([:]),
          ]))
    }
    return DeclarationIR(
      defaultAgents: agents.map { $0.map(\.rawValue).sorted(by: compatibilityUTF8Less) },
      sources: sources, components: components,
      watch: (watch ?? []).sorted(by: compatibilityUTF8Less))
  }
}

private func compatibilityUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
