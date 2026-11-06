import AgentsCore

extension DeclarationDocument {
  /// Validates the concrete input expected by the current skill/instruction deployment paths.
  /// Full declaration readers and source-only watch operations do not use this gate.
  func requireDeploymentSubset() throws {
    func fail(
      _ pointer: String, _ message: String, code: String = "manifest.unsupported",
      related: [String] = []
    ) -> ManifestFailure {
      func span(_ pointer: String) -> SourceSpan {
        sourceMap.locations(at: pointer).first?.span ?? source.span(0..<0)
      }
      return ManifestFailure(
        ManifestDiagnostic(
          code: code, message: message, span: span(pointer), related: related.map(span)))
    }
    if !declaration.uses.isEmpty { throw fail("/uses/0", "group uses require component linking") }
    var matches: [String: [String]] = [:]
    var order: [String] = []
    for (index, component) in declaration.components.enumerated() {
      let key: String
      switch component.kind {
      case "skills": key = "skills occurrence: " + component["source"]!.string!
      case "instructions": key = "instructions occurrence"
      default: continue
      }
      if matches[key] == nil { order.append(key) }
      matches[key, default: []].append("/components/\(index)")
    }
    for key in order {
      let locations = matches[key]!
      if locations.count > 1 {
        throw fail(
          locations[0], "ambiguous " + key, code: "manifest.ambiguous",
          related: Array(locations.dropFirst()))
      }
    }
    for (index, component) in declaration.components.enumerated() {
      let path = "/components/\(index)"
      guard ["skills", "instructions"].contains(component.kind) else {
        throw fail(path, "\(component.kind) components require native lowering")
      }
      guard component["condition"] == .null else {
        throw fail(path + "/condition", "conditional components require component linking")
      }
      guard component["native"] == .dictionary([:]) else {
        throw fail(path + "/native", "native configuration requires native lowering")
      }
      if component.kind == "skills", component["source"]?.string == "." {
        throw fail(path + "/source", "own-package skills require component linking")
      }
      func sections(_ record: DeclarationRecord, _ path: String) throws {
        for (index, value) in (record["sections"]?.elements ?? []).enumerated()
        where value.record?["condition"] != .null {
          throw fail(
            path + "/sections/\(index)/condition", "conditional sections require component linking")
        }
      }
      try sections(component, path)
      for (index, value) in (component["chatGPT"]?.elements ?? []).enumerated() {
        let prompt = value.record!
        let path = path + "/chatGPT/\(index)"
        guard prompt["condition"] == .null else {
          throw fail(path + "/condition", "conditional prompts require component linking")
        }
        try sections(prompt, path)
      }
    }
  }
}
