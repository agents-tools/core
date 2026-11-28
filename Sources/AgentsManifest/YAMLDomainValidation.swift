import AgentsCore
import Foundation

struct YAMLDomainValidation {
  let declaration: DeclarationIR
  let source: SourceText
  let locations: [String: YAMLNode]
  private let sources: [String: DeclarationRecord]
  private let groups: [String: DeclarationRecord]

  init(declaration: DeclarationIR, source: SourceText, locations: [String: YAMLNode]) {
    self.declaration = declaration
    self.source = source
    self.locations = locations
    sources = Dictionary(
      uniqueKeysWithValues: declaration.sources.map { ($0["name"]!.string!, $0) })
    groups = Dictionary(uniqueKeysWithValues: declaration.groups.map { ($0["name"]!.string!, $0) })
  }

  func validate() throws -> [ManifestDiagnostic] {
    var diagnostics: [ManifestDiagnostic] = []
    var sourceRoots = Set<[String]>()
    for (index, record) in declaration.sources.enumerated() {
      let path = "/sources/\(index)"
      let alias = record["name"]!.string!
      guard !alias.isEmpty, alias != ".", !alias.contains(":") else {
        throw fail(path, "invalid source alias")
      }
      let location = record[
        record.kind == "git" ? "url" : record.kind == "local" ? "path" : "index"]!.string!
      let identity: String
      if record.kind == "local" {
        guard !location.isEmpty, !location.contains("\0") else {
          throw fail(path, "invalid local source")
        }
        identity =
          URL(fileURLWithPath: location, relativeTo: URL(fileURLWithPath: "/")).standardizedFileURL
          .path
      } else {
        do {
          identity = try SourceDeclaration(
            kind: record.kind == "git" ? .git : .wellKnown, location: location
          ).transportIdentity()
        } catch { throw fail(path, "invalid source URL") }
      }
      if record.kind == "git", let node = locations[path + "/url"], let raw = node.text {
        let canonical = SourceDeclaration(kind: .git, location: raw).gitURL
        if raw != canonical, diagnostics.count < ManifestLimits.Diagnostics.warnings {
          diagnostics.append(
            ManifestDiagnostic(
              code: "manifest.domain", severity: .warning,
              message: "use the complete Git transport URL", span: source.span(node.range),
              fixIt: SourcePatch(
                range: node.range, replacement: Array(YAMLWriter.quote(canonical).utf8))))
        } else if raw != canonical, diagnostics.count == ManifestLimits.Diagnostics.warnings {
          diagnostics.append(
            ManifestDiagnostic(
              code: "manifest.diagnostics.truncated", severity: .warning,
              message: "further diagnostics omitted", span: source.span(node.range)))
        }
      }
      let subpath = record["subpath"]?.string ?? "."
      try resource(subpath, path)
      let root = try PathSafety.sanitizeSubpath(subpath)
      guard sourceRoots.insert([identity, record.kind == "index" ? "." : root]).inserted else {
        throw fail(path, "two aliases normalize to the same source and discovery root")
      }
      if case .requirement(let requirement) = record["requirement"] {
        do { try requirement.validate() } catch {
          throw fail(path + "/requirement", "invalid source requirement")
        }
      }
    }
    for (index, package) in declaration.packages.enumerated() {
      do {
        if package["version"] != nil {
          _ = try ManifestProjection.packageDependency(package)
        } else {
          _ = try ManifestProjection.marketplaceRoot(package)
        }
      } catch {
        throw fail("/packages/\(index)", "invalid marketplace package: \(error)")
      }
    }
    try unique(declaration.defaultAgents ?? [], "/defaultAgents")
    try unique(declaration.exports, "/exports")
    try unique(declaration.watch, "/watch")
    for name in declaration.exports where groups[name] == nil {
      throw fail("/exports", "unknown exported group: \(name)", code: "manifest.group.missing")
    }
    for name in declaration.watch { try alias(name, "/watch") }
    for (index, record) in declaration.components.enumerated() {
      try component(record, "/components/\(index)")
    }
    for (index, record) in declaration.groups.enumerated() {
      let path = "/groups/\(index)"
      try name(record["name"]!.string!, path)
      try condition(record["condition"], path + "/condition")
      for (i, value) in (record["components"]?.elements ?? []).enumerated() {
        try component(value.record!, path + "/components/\(i)")
      }
      for (i, value) in (record["uses"]?.elements ?? []).enumerated() {
        try use(value.record!, path + "/uses/\(i)")
      }
    }
    for (index, record) in declaration.uses.enumerated() { try use(record, "/uses/\(index)") }
    var completed = Set<String>()
    func cycle(_ name: String, stack: [String]) throws {
      guard stack.count < ManifestLimits.Groups.activeReferences else {
        throw fail("/groups", "group reference depth limit", code: "manifest.limit")
      }
      if stack.contains(name) {
        throw fail("/groups", "group reference cycle", code: "manifest.group.cycle")
      }
      if completed.contains(name) { return }
      for value in groups[name]?["uses"]?.elements ?? [] {
        let record = value.record!
        if record["source"]?.string == nil {
          try cycle(record["name"]!.string!, stack: stack + [name])
        }
      }
      completed.insert(name)
    }
    for group in declaration.groups { try cycle(group["name"]!.string!, stack: []) }
    return diagnostics
  }

  private func fail(_ pointer: String, _ message: String, code: String = "manifest.domain")
    -> ManifestFailure
  {
    source.failure(code, message, locations[pointer]?.range.lowerBound ?? 0)
  }
  private func strings(_ value: DeclarationValue?) -> [String] {
    (value?.elements ?? []).map { $0.string! }
  }
  private func unique(_ values: [String], _ pointer: String) throws {
    guard Set(values).count == values.count else { throw fail(pointer, "duplicate value") }
  }
  private func name(_ text: String, _ pointer: String) throws {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      !text.contains(":"), !text.contains("\\"),
      !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { throw fail(pointer, "invalid relative name") }
  }
  private func resource(_ text: String, _ pointer: String) throws {
    if text == "~" || text.hasPrefix("~/") { throw fail(pointer, "unsafe resource path") }
    do { _ = try PathSafety.sanitizeSubpath(text) } catch {
      throw fail(pointer, "unsafe resource path")
    }
  }
  private func alias(_ text: String, _ pointer: String) throws {
    guard text == "." || sources[text] != nil else {
      throw fail(pointer, "unknown source alias: \(text)")
    }
  }
  private func condition(_ value: DeclarationValue?, _ pointer: String) throws {
    guard let record = value?.record else { return }
    for field in ["agents", "scopes", "platforms"] {
      try unique(strings(record[field]), pointer + "/" + field)
    }
  }
  private func use(_ record: DeclarationRecord, _ pointer: String) throws {
    let group = record["name"]!.string!
    try name(group, pointer)
    if let source = record["source"]?.string {
      try alias(source, pointer)
    } else if groups[group] == nil {
      throw fail(pointer, "unknown local group: \(group)", code: "manifest.group.missing")
    }
    try condition(record["condition"], pointer + "/condition")
  }
  private func section(_ record: DeclarationRecord, _ pointer: String) throws {
    guard Declaration.isInstructionName(record["name"]!.string!) else {
      throw fail(pointer, "invalid section name")
    }
    if let source = record["source"]?.string { try alias(source, pointer) }
    try condition(record["condition"], pointer + "/condition")
    try unique(strings(record["recipients"]), pointer + "/recipients")
  }
  private func resource(_ record: DeclarationRecord, _ pointer: String) throws {
    try resource(record["path"]!.string!, pointer)
    if let source = record["source"]?.string { try alias(source, pointer) }
  }
  private func run(_ record: DeclarationRecord, _ pointer: String) throws {
    let executable = record["executable"]!.string!
    guard !executable.isEmpty, !executable.contains("\0") else {
      throw fail(pointer, "invalid executable")
    }
    if executable.contains("/") || executable.hasPrefix("~") { try resource(executable, pointer) }
    if let alias = record["executableSource"]?.string {
      try self.alias(alias, pointer + "/executableSource")
      guard executable.contains("/") else {
        throw fail(pointer + "/executableSource", "executable source requires a resource path")
      }
    }
    if let directory = record["workingDirectory"]?.record { try resource(directory, pointer) }
  }
  private func component(_ record: DeclarationRecord, _ pointer: String) throws {
    try unique(strings(record["agents"]), pointer + "/agents")
    try condition(record["condition"], pointer + "/condition")
    if let n = record["name"]?.string { try name(n, pointer + "/name") }
    switch record.kind {
    case "skills":
      let source = record["source"]!.string!
      try alias(source, pointer)
      if let path = record["path"]?.string {
        try resource(path, pointer + "/path")
        guard sources[source]?.kind != "index" else {
          throw fail(pointer + "/path", "skill paths require a filesystem source")
        }
      }
      let selected = record["select"]?.elements.map { $0.map { $0.string! } }
      let excluded = strings(record["exclude"])
      do {
        try Declaration.validateNames(selected ?? [])
        try Declaration.validateNames(excluded)
      } catch { throw fail(pointer, "invalid skill names") }
      let overrides = (record["overrides"]?.elements ?? []).map { $0.record! }
      let names = overrides.map { $0["name"]!.string! }
      do { try Declaration.validateNames(names) } catch {
        throw fail(pointer, "invalid skill overrides")
      }
      for override in overrides {
        if let selected, !selected.contains(override["name"]!.string!) {
          throw fail(pointer, "override is outside explicit skill selection")
        }
        try unique(strings(override["agents"]), pointer)
      }
      if ([record["mode"]?.string] + overrides.map { $0["mode"]?.string }).contains("edit"),
        source != ".",
        sources[source]?.kind != "local" || sources[source]?["requirement"] != .null
      {
        throw fail(pointer, "edit mode needs a local source without a requirement")
      }
    case "instructions":
      for (index, value) in record["sections"]!.elements!.enumerated() {
        try section(value.record!, pointer + "/sections/\(index)")
      }
      for value in record["chatGPT"]!.elements! {
        let prompt = value.record!
        for sectionValue in prompt["sections"]!.elements! {
          guard sectionValue.record?["recipients"] == .null else {
            throw fail(pointer, "named prompt sections inherit the named prompt destination")
          }
          try section(sectionValue.record!, pointer)
        }
        if let append = prompt["append"]?.string { try resource(append, pointer) }
        try condition(prompt["condition"], pointer)
      }
    case "mcpServer":
      let transport = record["transport"]!.record!
      if transport.kind == "stdio" {
        try run(transport, pointer)
      } else {
        let url = URLComponents(string: transport["url"]!.string!)
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""),
          url?.host?.isEmpty == false, url?.user == nil, url?.password == nil, url?.fragment == nil
        else { throw fail(pointer, "invalid HTTP transport URL") }
      }
    case "hook":
      try run(record["run"]!.record!, pointer)
      if record["event"]!.record!.kind == "native", record["agents"]?.elements?.count != 1 {
        throw fail(pointer, "native hook event requires exactly one explicit recipient")
      }
    case "subagent", "command":
      let prompt = record["prompt"]!.record!
      if prompt.kind == "file" { try resource(prompt, pointer) }
      if record.kind == "command" {
        let parameters = (record["parameters"]?.elements ?? []).map { $0.record! }
        let names = parameters.map { $0["name"]!.string! }
        try unique(names, pointer)
        guard
          names.allSatisfy({
            !$0.isEmpty && !$0.contains("}") && !$0.contains(":") && !$0.contains("\0")
          })
        else { throw fail(pointer, "invalid prompt parameter name") }
        if prompt.kind == "literal" {
          let bytes = Array(prompt["value"]!.string!.utf8)
          let escaped = Array("$${input:".utf8)
          let token = Array("${input:".utf8)
          var i = 0
          while i < bytes.count {
            if bytes[i...].starts(with: escaped) {
              i += escaped.count
              while i < bytes.count && bytes[i] != 125 { i += 1 }
            } else if bytes[i...].starts(with: token) {
              let start = i + token.count
              i = start
              while i < bytes.count && bytes[i] != 125 { i += 1 }
              guard i < bytes.count,
                names.contains(String(decoding: bytes[start..<i], as: UTF8.self))
              else { throw fail(pointer, "undeclared or malformed input token") }
            }
            i += 1
          }
        }
      }
    case "lspServer":
      try run(record["run"]!.record!, pointer)
      if case .dictionary(let languages) = record["languages"] {
        for (ext, value) in languages {
          guard ext.hasPrefix("."), ext.count > 1, !ext.contains("/"), !ext.contains("\0"),
            value.string?.isEmpty == false
          else { throw fail(pointer, "invalid language extension mapping") }
        }
      }
    case "permissions":
      for value in record["rules"]!.elements! {
        let rule = value.record!
        if ["read", "write"].contains(rule["operation"]!.record!.kind) {
          try resource(rule["pattern"]!.string!, pointer)
        }
      }
    case "plugin":
      try alias(record["source"]!.string!, pointer)
      try resource(record["path"]!.string!, pointer)
      try unique(strings(record["select"]), pointer)
      let excluded = record["exclude"]!.elements!
      guard
        Set(excluded.map { $0.record!.kind + ":" + $0.record!["name"]!.string! }).count
          == excluded.count
      else { throw fail(pointer, "duplicate plugin exclusion") }
      for value in excluded { try name(value.record!["name"]!.string!, pointer) }
      if record["mode"]?.string == "native",
        record["agents"]?.elements?.count != 1 || record["select"] != .null || !excluded.isEmpty
      {
        throw fail(
          pointer, "native plugin requires one explicit recipient and no selection/exclusions")
      }
    default: break
    }
  }
}
