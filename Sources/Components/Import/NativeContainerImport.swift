import AgentsCore
import Foundation

/// Container discovery uses producer roots, never the parser's working directory.
enum NativeContainerImport {
  static func read(
    _ input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    let suffix: String
    switch input.profile {
    case .claudePluginV1: suffix = ".claude-plugin/plugin.json"
    case .cursorPluginV1: suffix = ".cursor-plugin/plugin.json"
    default: suffix = "gemini-extension.json"
    }
    guard input.document == suffix || input.document.hasSuffix("/" + suffix) else {
      diagnostics.add(
        .invalidInput, .init(document: input.document, pointer: ""),
        "Manifest location does not match the selected native container profile.")
      return
    }
    let root = input.document == suffix ? "." : String(input.document.dropLast(suffix.count + 1))
    let parsed = try NativeImportDocument(input, format: .json, limits: limits)
    guard let name = parsed.fields["name"]?.importString, NativeImportInput.name(name) else {
      throw ImportReadFailure.invalid
    }
    let snapshot = try ImportInput.snapshot(input.root)
    try parsed.admission.resource(try snapshot.resource(root), snapshot: snapshot)
    let agent = NativeImportInput.agent(input.profile)
    let alias = NativeImportInput.source(
      input, root: root, origin: parsed.location(), into: &diagnostics)
    let surface = NativeImportSemantics.surface(input.profile)
    let defaults: [String: String]
    do {
      defaults =
        agent == .geminiCLI
        ? [
          "commands": "commands", "agents": "agents", "skills": "skills",
          "hooks": "hooks/hooks.json",
        ]
        : try NativeComponentFieldsV1.pluginDefaults(
          surface: surface, document: suffix, fieldPrefix: [],
          explicitFields: Set(parsed.fields.keys))
    } catch let issue as NativeComponentFieldIssue {
      guard issue.document == suffix else { throw ImportReadFailure.invalid }
      NativeImportSemantics.report(issue, at: parsed.fieldLocation(issue.field), into: &diagnostics)
      return
    }
    var documents: [String: NativeImportDocument] = [:]
    let metadata: Set<String> = ["name", "version"]
    let members: Set<String> =
      agent == .geminiCLI
      ? ["mcpServers", "contextFileName"]
      : ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "rules"]
    NativeImportInput.unknown(
      parsed.fields, allowed: metadata.union(members), at: parsed.location(), into: &diagnostics)
    if agent == .geminiCLI {
      guard let version = parsed.fields["version"]?.importString, !version.isEmpty else {
        diagnostics.add(
          .invalidInput, parsed.location(["version"]), "Native extension requires a version string."
        )
        return
      }
      if !version.contains("://") || ImportInput.safeLocator(version) {
        diagnostics.proposal.packageMetadata = .init(
          name: name, version: version,
          nameLocation: parsed.fieldLocation(["name"]),
          versionLocation: parsed.fieldLocation(["version"]))
      }
    }
    // A container contributes typed children; .native selection/registration belongs to B/F.
    // Unknown/dependency fields are already diagnosed rather than becoming opaque payloads.
    for (field, kind) in [
      ("commands", DeclaredComponentKind.command),
      ("agents", .subagent), ("skills", .skills),
    ] {
      let supplied = parsed.fields[field]
      if agent == .geminiCLI, supplied != nil {
        NativeImportInput.unconverted(supplied!, at: parsed.location([field]), into: &diagnostics)
        continue
      }
      var paths: [String] = []
      var explicitPaths: Set<String> = []
      if let path = defaults[field] { paths.append(path) }
      if let supplied {
        if let path = supplied.importString {
          let relative = try componentPath(path, agent: agent)
          explicitPaths.insert(relative)
          paths.append(relative)
        } else if let list = supplied.importStrings {
          let relative = try list.map { try componentPath($0, agent: agent) }
          explicitPaths.formUnion(relative)
          paths += relative
        } else {
          NativeImportInput.unconverted(supplied, at: parsed.location([field]), into: &diagnostics)
        }
      }
      var seen: Set<String> = []
      for path in paths where seen.insert(path).inserted {
        try discover(
          path, kind: kind, root: root, input: input, limits: limits, into: &diagnostics,
          admission: parsed.admission,
          requiredOrigin: explicitPaths.contains(path) ? parsed.location([field]) : nil)
      }
    }
    var mcpSources: [(NativeValue, NativeImportDocument, [String])] = []
    if let mcpDefault = defaults["mcpServers"],
      let document = try optionalDocument(
        mcpDefault, root: root, input: input, limits: limits, admission: parsed.admission)
    {
      documents[mcpDefault] = document
      NativeImportInput.unknown(
        document.fields, allowed: ["mcpServers"], at: document.location(), into: &diagnostics)
      if let map = document.fields["mcpServers"] {
        mcpSources.append((map, document, ["mcpServers"]))
      } else {
        NativeImportInput.unconverted(
          .object(document.fields), at: document.location(), into: &diagnostics)
      }
    }
    if let declared = parsed.fields["mcpServers"] {
      try configurations(
        declared, field: "mcpServers", parsed: parsed, root: root, limits: limits,
        into: &mcpSources, documents: &documents, diagnostics: &diagnostics)
    }
    // The producer loads defaults then declarations; later duplicate names replace earlier ones.
    var winners: [String: (NativeValue, NativeImportDocument, [String])] = [:]
    for (value, document, keys) in mcpSources {
      try NativeSourceImport.classifyMembers(
        value, parsed: document, keys: keys, into: &diagnostics)
      guard let fields = value.importObject else { throw ImportReadFailure.invalid }
      for (name, entry) in fields {
        if let previous = winners[name] {
          diagnostics.add(
            .unconverted, previous.1.location(previous.2 + [name]),
            "Later native MCP declaration replaces this earlier source member.")
        }
        winners[name] = (entry, document, keys)
      }
    }
    for name in winners.keys.sorted() {
      let winner = winners[name]!
      try NativeSourceImport.mcp(
        .object([name: winner.0]), parsed: winner.1, keys: winner.2,
        container: root, limits: limits, into: &diagnostics)
    }
    var observed: Set<String> = []
    for (_, document, _) in mcpSources
    where document.input.document != input.document
      && observed.insert(document.input.document).inserted
    {
      let relative =
        root == "."
        ? document.input.document : String(document.input.document.dropFirst(root.count + 1))
      let rewrite = diagnostics.proposal.preservationBindings.contains {
        $0.document == document.input.document
      }
      try NativeImportInput.resource(
        relative, root: root, input: input, origin: document.location(), limits: limits,
        rewrite: rewrite, into: &diagnostics, admission: parsed.admission)
    }
    var lspSources: [(NativeValue, NativeImportDocument, [String])] = []
    if let lspDefault = defaults["lspServers"],
      let document = try optionalDocument(
        lspDefault, root: root, input: input, limits: limits, admission: parsed.admission)
    {
      documents[lspDefault] = document
      lspSources.append((.object(document.fields), document, []))
    }
    if let value = parsed.fields["lspServers"] {
      try configurations(
        value, field: "lspServers", parsed: parsed, root: root, limits: limits, into: &lspSources,
        documents: &documents, diagnostics: &diagnostics)
    }
    var lspWinners: [String: (NativeValue, NativeImportDocument, [String])] = [:]
    for (value, document, keys) in lspSources {
      try NativeSourceImport.classifyMembers(
        value, parsed: document, keys: keys, into: &diagnostics)
      for (name, entry) in value.importObject ?? [:] { lspWinners[name] = (entry, document, keys) }
    }
    for name in lspWinners.keys.sorted() {
      let entry = lspWinners[name]!
      try NativeSourceImport.lsp(
        .object([name: entry.0]), parsed: entry.1, keys: entry.2, container: root, limits: limits,
        into: &diagnostics)
    }
    var hookSources: [(NativeValue, NativeImportDocument, [String])] = []
    if let hookDefault = defaults["hooks"],
      let document = try optionalDocument(
        hookDefault, root: root, input: input, limits: limits, admission: parsed.admission)
    {
      documents[hookDefault] = document
      NativeImportInput.unknown(
        document.fields, allowed: ["hooks"], at: document.location(), into: &diagnostics)
      if let value = document.fields["hooks"] { hookSources.append((value, document, ["hooks"])) }
    }
    if let value = parsed.fields["hooks"] {
      try configurations(
        value, field: "hooks", parsed: parsed, root: root, limits: limits, into: &hookSources,
        documents: &documents, diagnostics: &diagnostics)
    }
    for (value, document, keys) in hookSources {
      try NativeSourceImport.hooks(
        value, parsed: document, keys: keys, container: root, limits: limits, into: &diagnostics)
    }
    for (_, document, _) in lspSources + hookSources
    where document.input.document != input.document
      && observed.insert(document.input.document).inserted
    {
      let path =
        root == "."
        ? document.input.document : String(document.input.document.dropFirst(root.count + 1))
      let rewrite = diagnostics.proposal.preservationBindings.contains {
        $0.document == document.input.document
      }
      try NativeImportInput.resource(
        path, root: root, input: input, origin: document.location(), limits: limits,
        rewrite: rewrite, into: &diagnostics, admission: parsed.admission)
    }
    for field in ["rules", "contextFileName"] where parsed.fields[field] != nil {
      NativeImportInput.unconverted(
        parsed.fields[field]!, at: parsed.location([field]), into: &diagnostics)
    }
    if agent != .geminiCLI {
      for (_, document, _) in mcpSources + lspSources + hookSources {
        guard document.input.document != input.document else { continue }
        let path =
          root == "."
          ? document.input.document : String(document.input.document.dropFirst(root.count + 1))
        documents[path] = document
      }
      do {
        _ = try NativeComponentFieldsV1.plugin(
          surface: surface, document: suffix, fieldPrefix: [], fields: parsed.fields,
          entries: try inventory(snapshot, root: root, limits: limits),
          documents: documents.mapValues { .object($0.fields) }, budget: parsed.admission.parser)
      } catch let issue as NativeComponentFieldIssue {
        let document: NativeImportDocument
        if issue.document == suffix {
          document = parsed
        } else {
          guard let captured = documents[issue.document] else { throw ImportReadFailure.invalid }
          document = captured
        }
        NativeImportSemantics.report(
          issue, at: document.fieldLocation(issue.field), into: &diagnostics)
      }
    }
    for field in metadata {
      if let value = parsed.fields[field] {
        _ = NativeImportInput.sensitive(value, at: parsed.location([field]), into: &diagnostics)
      }
    }
    if let options = parsed.fields["userConfig"]?.importObject {
      for (name, value) in options {
        guard let option = value.importObject, option["sensitive"] == .boolean(true),
          let literal = option["default"], literal != .string("")
        else { continue }
        diagnostics.binding(parsed.fieldLocation(["userConfig", name, "default"]))
      }
    }
    // Record the actual manifest, not a raw original bundle containing credential literals.
    let rewrite = diagnostics.proposal.preservationBindings.contains {
      $0.document == input.document
    }
    try NativeImportInput.resource(
      suffix, root: root, input: input, origin: parsed.location(), limits: limits, rewrite: rewrite,
      into: &diagnostics, admission: parsed.admission)
    if diagnostics.proposal.components.isEmpty {
      diagnostics.add(
        .unconverted, parsed.location(),
        "No typed child was converted; native container preservation/registration remains an explicit B/F operation."
      )
    }
    _ = alias
  }

  private static func inventory(
    _ snapshot: SourceSnapshot, root: String, limits: SourceImportLimits
  ) throws -> [LedgerEntry] {
    let url = try snapshot.resource(root)
    var entries: [LedgerEntry] = []
    func append(_ file: URL) throws {
      guard entries.count < limits.resourceEntries else { throw ImportReadFailure.invalid }
      let path = try snapshot.relativePath(file)
      let relative =
        path == root ? "." : root == "." ? path : String(path.dropFirst(root.count + 1))
      let info = try FileManager.default.attributesOfItem(atPath: file.path)
      let kind: LedgerEntry.Kind
      switch info[.type] as? FileAttributeType {
      case .typeRegular: kind = .file
      case .typeDirectory: kind = .directory
      case .typeSymbolicLink: kind = .symlink
      default: throw ImportReadFailure.invalid
      }
      entries.append(
        .init(
          path: relative, kind: kind,
          link: kind == .symlink
            ? try FileManager.default.destinationOfSymbolicLink(atPath: file.path) : nil,
          executable: kind == .file
            && ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0,
          byteCount: kind == .file ? (info[.size] as? NSNumber)?.intValue : nil))
    }
    try append(url)
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
      throw ImportReadFailure.invalid
    }
    for case let file as URL in walk {
      try Task.checkCancellation()
      try append(file)
      if entries.last?.kind == .symlink { walk.skipDescendants() }
    }
    return entries
  }

  private static func componentPath(_ path: String, agent: AgentID) throws -> String {
    if agent == .claudeCode, !path.hasPrefix("./"), path != "." {
      throw CoreError.unsafePath("native component path")
    }
    return try NativeSourceImport.nativePath(path, container: ".")
  }

  private static func configurations(
    _ value: NativeValue, field: String, parsed: NativeImportDocument,
    root: String, limits: SourceImportLimits,
    into sources: inout [(NativeValue, NativeImportDocument, [String])],
    documents: inout [String: NativeImportDocument],
    diagnostics: inout ImportDiagnostics
  ) throws {
    if let path = value.importString {
      let relative = try componentPath(path, agent: NativeImportInput.agent(parsed.input.profile))
      guard
        let document = try optionalDocument(
          relative, root: root, input: parsed.input, limits: limits, admission: parsed.admission)
      else {
        diagnostics.add(
          .missingResource, parsed.location([field]), "Explicit native component file is absent.")
        return
      }
      documents[relative] = document
      guard
        let fields = field == "lspServers"
          ? NativeValue.object(document.fields) : document.fields[field]
      else {
        NativeImportInput.unconverted(
          .object(document.fields), at: document.location(), into: &diagnostics)
        return
      }
      if field != "lspServers" {
        NativeImportInput.unknown(
          document.fields, allowed: [field],
          at: document.location(), into: &diagnostics)
      }
      sources.append((fields, document, field == "lspServers" ? [] : [field]))
    } else if case .array(let entries) = value {
      for entry in entries {
        try configurations(
          entry, field: field, parsed: parsed, root: root, limits: limits, into: &sources,
          documents: &documents, diagnostics: &diagnostics)
      }
    } else if value.importObject != nil, NativeImportInput.agent(parsed.input.profile) != .cursor {
      sources.append((value, parsed, [field]))
    } else {
      NativeImportInput.unconverted(value, at: parsed.location([field]), into: &diagnostics)
    }
  }

  private static func optionalDocument(
    _ path: String, root: String, input: SourceImportInput,
    limits: SourceImportLimits, admission: NativeImportBudget
  ) throws -> NativeImportDocument? {
    let relative = root == "." ? path : root + "/" + path
    let snapshot = try ImportInput.snapshot(input.root)
    let url = try snapshot.resource(relative)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try NativeImportDocument(
      .init(profile: input.profile, root: input.root, document: relative), format: .json,
      limits: limits, admission: admission)
  }

  private static func discover(
    _ path: String, kind: DeclaredComponentKind, root: String,
    input: SourceImportInput, limits: SourceImportLimits, into diagnostics: inout ImportDiagnostics,
    admission: NativeImportBudget, requiredOrigin: ImportLocation?
  ) throws {
    let snapshot = try ImportInput.snapshot(input.root)
    let relative = root == "." ? path : root + (path == "." ? "" : "/" + path)
    let url = try snapshot.resource(relative)
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
      if let requiredOrigin {
        diagnostics.add(.missingResource, requiredOrigin, "Explicit native member path is absent.")
      }
      return
    }
    guard
      try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        != .typeSymbolicLink
    else {
      diagnostics.add(
        .unconverted, .init(document: relative, pointer: ""),
        "Native member discovery through a link requires explicit contained support closure.")
      return
    }
    // A regular member directory reached through a linked ancestor is still link discovery.
    let memberPath =
      relative == root ? "." : root == "." ? relative : String(relative.dropFirst(root.count + 1))
    let memberParts = memberPath.split(separator: "/")
    if memberParts.count > 1 {
      for count in 1..<memberParts.count {
        let prefix = memberParts.prefix(count).joined(separator: "/")
        let ancestor = root == "." ? prefix : root + "/" + prefix
        if try FileManager.default.attributesOfItem(atPath: snapshot.resource(ancestor).path)[.type]
          as? FileAttributeType == .typeSymbolicLink
        {
          diagnostics.add(
            .unconverted, .init(document: ancestor, pointer: ""),
            "Native member discovery through a link requires explicit contained support closure.")
          return
        }
      }
    }
    var files: [String] = []
    var links: [String] = []
    var admittedSkills: [String] = []
    if directory.boolValue {
      guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
      else { throw ImportReadFailure.invalid }
      for case let file as URL in iterator {
        try Task.checkCancellation()
        guard files.count < limits.resourceEntries else { throw ImportReadFailure.invalid }
        let location = try snapshot.relativePath(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          links.append(location)
          iterator.skipDescendants()
          continue
        }
        if attributes[.type] as? FileAttributeType == .typeRegular { files.append(location) }
      }
    } else {
      files = [relative]
    }
    for file in files.sorted() {
      if kind == .skills {
        guard URL(fileURLWithPath: file).lastPathComponent == "SKILL.md" else { continue }
        let skillPath = (file as NSString).deletingLastPathComponent
        let content = try ImportSkillContent.read(
          skillPath, input: input, limits: limits, nativeContainer: root)
        diagnostics.proposal.diagnostics += content.diagnostics
        diagnostics.proposal.bindings += content.bindings
        diagnostics.proposal.preservationBindings += content.bindings.filter {
          $0.environmentVariable == nil
        }.map(\.location)
        if !content.bindings.isEmpty { continue }
        let alias = "native-skill-" + String(diagnostics.proposal.sources.count)
        diagnostics.proposal.sources.append(
          .init(
            alias: alias, origin: .init(document: file, pointer: ""),
            declaration: .init(
              kind: .local, location: skillPath,
              environment: .init(projectDirectory: input.root, homeDirectory: input.root)),
            pin: .init(), requestedRef: nil, producerPath: skillPath))
        NativeImportInput.emit(
          .skills(
            source: alias,
            .init(
              select: .names([content.skill.name]),
              agents: [NativeImportInput.agent(input.profile)], condition: content.skill.condition)),
          selector: .skill(name: content.skill.name),
          origin: .init(document: file, pointer: "/frontmatter"), container: root,
          profile: input.profile, into: &diagnostics, admission: admission)
        let preservationPath =
          root == "." ? skillPath : String(skillPath.dropFirst(root.count + 1))
        let resourceIndex = diagnostics.proposal.resources.count
        try NativeImportInput.resource(
          preservationPath, root: root, input: input,
          origin: .init(document: file, pointer: ""), limits: limits,
          into: &diagnostics, admission: admission)
        diagnostics.proposal.resources[resourceIndex].kind = .skills
        admittedSkills.append(skillPath)
      } else {
        let ext = URL(fileURLWithPath: file).pathExtension
        let allowed =
          NativeImportInput.agent(input.profile) == .geminiCLI && kind == .command
          ? ["toml"] : ["md", "mdc", "markdown", "txt"]
        guard allowed.contains(ext) else {
          diagnostics.add(
            .unconverted, .init(document: file, pointer: ""),
            "Native directory file has no converted member format.")
          continue
        }
        try NativeMemberImport.read(
          .init(profile: input.profile, root: input.root, document: file), container: root,
          kind: kind, limits: limits, into: &diagnostics, admission: admission,
          discoveryRoot: relative, inPlugin: true)
      }
    }
    for link in links where !admittedSkills.contains(where: { link.hasPrefix($0 + "/") }) {
      diagnostics.add(
        .unconverted, .init(document: link, pointer: ""),
        "Native member discovery through a link requires explicit contained support closure.")
    }
  }
}
