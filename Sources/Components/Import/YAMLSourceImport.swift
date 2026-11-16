import AgentsCore
import AgentsManifest
import Foundation

/// A view of the existing immutable YAML graph; no decoded dictionary or parallel value graph.
struct ImportYAML {
  let reader: YAMLReader
  let node: YAMLNode
  let pointer: String

  var location: ImportLocation {
    .init(
      document: reader.span(of: node).document.rawValue, pointer: pointer,
      span: reader.span(of: node))
  }
  var string: String? {
    guard let scalar = node.scalar, !scalar.decimalTag,
      scalar.quoted || YAMLScalar.classify(scalar.text) == .string
    else { return nil }
    return scalar.text
  }
  var integer: Int? {
    guard let scalar = node.scalar, !scalar.quoted, !scalar.decimalTag,
      YAMLScalar.classify(scalar.text) == .integer
    else { return nil }
    return YAMLScalar.integer(scalar.text)
  }
  var boolean: Bool? {
    guard let scalar = node.scalar, !scalar.quoted, !scalar.decimalTag,
      YAMLScalar.classify(scalar.text) == .boolean
    else { return nil }
    return scalar.text.lowercased() == "true"
  }
  var pairs: [(String, ImportYAML)]? {
    guard let pairs = node.pairs else { return nil }
    var result: [(String, ImportYAML)] = []
    for (index, pair) in pairs.enumerated() {
      let key = ImportYAML(reader: reader, node: pair.key, pointer: pointer)
      guard let name = key.string else { return nil }
      result.append(
        (name, .init(reader: reader, node: pair.value, pointer: pointer + "/member[\(index)]")))
    }
    return result
  }
  var items: [ImportYAML]? {
    node.items?.enumerated().map {
      .init(reader: reader, node: $0.element, pointer: pointer + "/\($0.offset)")
    }
  }
  var strings: [String]? {
    guard let items, items.allSatisfy({ $0.string != nil }) else { return nil }
    return items.compactMap(\.string)
  }
  subscript(_ field: String) -> ImportYAML? { pairs?.first { $0.0 == field }?.1 }

  static func check(_ root: YAMLNode, limits: SourceImportLimits) throws {
    var remaining = limits.nodes
    func visit(_ node: YAMLNode, depth: Int) throws {
      try Task.checkCancellation()
      guard remaining > 0, depth <= limits.depth else { throw ImportReadFailure.invalid }
      remaining -= 1
      for pair in node.pairs ?? [] {
        try visit(pair.key, depth: depth + 1)
        try visit(pair.value, depth: depth + 1)
      }
      for item in node.items ?? [] { try visit(item, depth: depth + 1) }
    }
    try visit(root, depth: 0)
  }

  func validate(
    strings: Set<String> = [], required: Set<String> = [], arrays: Set<String> = [],
    booleans: Set<String> = [], integers: Set<String> = [],
    into diagnostics: inout ImportDiagnostics
  ) -> Bool {
    var valid = true
    for field in strings.union(required).sorted()
    where self[field] != nil || required.contains(field) {
      if self[field]?.string == nil {
        diagnostics.add(
          .invalidInput, self[field]?.location ?? location, "Expected a producer string field.")
        valid = false
      }
    }
    for field in arrays.sorted() where self[field] != nil {
      if self[field]?.strings == nil {
        diagnostics.add(
          .invalidInput, self[field]!.location, "Expected producer string selections.")
        valid = false
      }
    }
    for field in booleans.sorted() where self[field] != nil {
      if self[field]?.boolean == nil {
        diagnostics.add(.invalidInput, self[field]!.location, "Expected a producer boolean field.")
        valid = false
      }
    }
    for field in integers.sorted() where self[field] != nil {
      if self[field]?.integer.map({ $0 >= 0 }) != true {
        diagnostics.add(
          .invalidInput, self[field]!.location, "Expected a nonnegative producer integer field.")
        valid = false
      }
    }
    return valid
  }

  func unknown(_ allowed: Set<String>, into diagnostics: inout ImportDiagnostics) {
    for (name, value) in pairs ?? [] where !allowed.contains(name) {
      if ImportInput.credentialField(name) {
        diagnostics.binding(value.location)
      }
      value.unconverted(into: &diagnostics)
    }
  }
  func unconverted(into diagnostics: inout ImportDiagnostics) {
    diagnostics.add(.unconverted, location, "Producer field or item has no canonical conversion.")
    // Literal connection fields are never retained, including inside an otherwise unsupported item.
    if let value = string, value.contains("://"), !ImportInput.safeLocator(value) {
      diagnostics.binding(location)
    }
    for (key, value) in pairs ?? [] {
      if ImportInput.credentialField(key) {
        diagnostics.binding(value.location)
      }
      value.unconverted(into: &diagnostics)
    }
    for value in items ?? [] { value.unconverted(into: &diagnostics) }
  }
}

enum YAMLSourceImport {
  static func read(
    _ input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    var admission = limits
    admission.documentBytes = min(limits.documentBytes, ManifestLimits.Input.bytes)
    let bytes = try ImportInput.bytes(input, limits: admission)
    let reader = try YAMLReader(bytes: Array(bytes), identity: .init(input.document))
    let root = ImportYAML(reader: reader, node: reader.root, pointer: "")
    try ImportYAML.check(root.node, limits: limits)
    guard root.pairs != nil else {
      diagnostics.add(.invalidInput, root.location, "Expected a YAML mapping with string keys.")
      return
    }
    switch input.profile {
    case .apmManifest: try manifest(root, input: input, limits: limits, into: &diagnostics)
    case .apmLock, .rulesyncAPMV1: try lock(root, input: input, into: &diagnostics)
    case .rulesyncGitHubV1: try github(root, input: input, into: &diagnostics)
    default: preconditionFailure("YAML profile dispatch")
    }
    guard !diagnostics.proposal.diagnostics.contains(where: { $0.code == .unsupportedVersion })
    else { return }
    for (index, name) in input.installedSkills.keys.sorted().enumerated() {
      let location = root.location.appending("explicitContent/member[\(index)]")
      guard ImportInput.name(name), let path = input.installedSkills[name] else {
        diagnostics.add(.invalidInput, location, "Invalid explicit installed skill selection.")
        continue
      }
      do {
        let content = try ImportSkillContent.read(path, input: input, limits: limits)
        diagnostics.proposal.diagnostics += content.diagnostics
        diagnostics.proposal.bindings += content.bindings
        let alias = "yaml-content-\(index)"
        diagnostics.proposal.sources.append(
          .init(
            alias: alias, origin: location,
            declaration: .init(
              kind: .local, location: content.path,
              environment: .init(projectDirectory: input.root, homeDirectory: input.root)),
            pin: .init(), requestedRef: nil, producerPath: nil))
        diagnostics.proposal.resources.append(
          .init(
            origin: location, sourceAlias: alias, producerName: name, path: ".",
            producerIntegrity: nil, observedHash: content.hash, executableFlags: content.flags,
            requiresStandaloneSource: true, kind: .skills))
        diagnostics.proposal.components.append(
          .init(
            origin: location,
            declaration: .skills(
              source: alias,
              .init(select: .names([content.skill.name]), condition: content.skill.condition))))
        diagnostics.add(
          .unconverted, location,
          "Actual explicitly selected local content is captured independently; it does not verify recovery of the producer's upstream commit."
        )
      } catch is CancellationError { throw CancellationError() } catch CoreError.unsafePath {
        diagnostics.add(.unsafePath, location, "Explicit content escapes its input root.")
      } catch {
        diagnostics.add(
          .missingResource, location,
          "Explicit installed skill content is missing, malformed or exceeds bounds.")
      }
    }
  }

  private static func manifest(
    _ root: ImportYAML, input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    guard root["name"]?.string?.isEmpty == false, root["version"]?.string != nil else {
      diagnostics.add(
        .invalidInput, root.location, "APM manifest requires string name and version.")
      return
    }
    if let schema = root["$schema"] {
      let admitted = [
        "https://microsoft.github.io/apm/specs/schemas/manifest-v0.1.schema.json",
        "https://microsoft.github.io/apm/specs/schemas/manifest-v0.1.48.schema.json",
      ]
      guard let identity = schema.string, admitted.contains(identity) else {
        diagnostics.add(.unsupportedVersion, schema.location, "Unsupported APM schema identity.")
        return
      }
    }
    let name = root["name"]!
    let version = root["version"]!
    for field in [name, version]
    where field.string!.contains("://") && !ImportInput.safeLocator(field.string!) {
      diagnostics.binding(field.location)
      field.unconverted(into: &diagnostics)
      return
    }
    diagnostics.proposal.packageMetadata = .init(
      name: name.string!, version: version.string!,
      nameLocation: name.location, versionLocation: version.location)
    root.unknown(
      [
        "$schema", "name", "version", "target", "targets", "includes", "dependencies",
        "devDependencies",
      ], into: &diagnostics)
    if root["target"] != nil && root["targets"] != nil {
      diagnostics.add(
        .invalidInput, root.location, "APM target and targets are mutually exclusive.")
      return
    }
    if let targets = root["targets"] ?? root["target"] {
      selection(
        targets, kind: .targets, scalar: true, alias: nil, development: false, into: &diagnostics)
    }
    if let includes = root["includes"] {
      if includes.string == "auto" {
        diagnostics.proposal.selections.append(
          .init(
            origin: includes.location, sourceAlias: nil, kind: .includes, values: [],
            automatic: true, developmentOnly: false))
      } else {
        selection(
          includes, kind: .includes, scalar: false, alias: nil, development: false,
          into: &diagnostics)
      }
    }
    for group in ["dependencies", "devDependencies"] {
      guard let block = root[group] else { continue }
      guard block.pairs != nil else {
        diagnostics.add(.invalidInput, block.location, "Expected an APM dependency mapping.")
        continue
      }
      block.unknown(["apm"], into: &diagnostics)
      guard let apm = block["apm"] else { continue }
      guard let items = apm.items else {
        diagnostics.add(.invalidInput, apm.location, "Expected an APM dependency list.")
        continue
      }
      for (index, item) in items.enumerated() {
        try Task.checkCancellation()
        let alias = "apm-\(group)-\(index)"
        guard input.selection?.contains(String(index)) ?? true else { continue }
        let development = group == "devDependencies"
        let raw: String
        var requested: String?
        var path: String?
        var local = false
        var registry = false
        if let value = item.string {
          raw = value
          local =
            value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("/")
            || value.hasPrefix("~")
        } else if item.pairs != nil {
          guard
            item.validate(
              strings: ["git", "path", "ref", "version", "id", "registry", "alias"],
              arrays: ["skills", "targets"], into: &diagnostics)
          else { continue }
          item.unknown(
            ["git", "path", "ref", "version", "id", "registry", "alias", "skills", "targets"],
            into: &diagnostics)
          guard let value = item["git"]?.string ?? item["id"]?.string ?? item["path"]?.string else {
            diagnostics.add(
              .invalidInput, item.location, "APM dependency has no admitted source selector.")
            continue
          }
          raw = value
          registry = item["id"] != nil || item["registry"] != nil
          if item["git"] != nil && registry {
            diagnostics.add(
              .invalidInput, item.location, "Conflicting APM dependency source selectors.")
            continue
          }
          local = item["git"] == nil && !registry
          requested = item["ref"]?.string ?? item["version"]?.string
          if item["git"] != nil { path = item["path"]?.string }
          for (field, kind) in [
            ("skills", ImportProducerSelection.Kind.skills), ("targets", .targets),
          ] {
            if let value = item[field] {
              selection(
                value, kind: kind, scalar: false, alias: alias, development: development,
                into: &diagnostics)
            }
          }
          if let value = item["alias"] { value.unconverted(into: &diagnostics) }
          if item["ref"] != nil, let value = item["version"] {
            value.unconverted(into: &diagnostics)
          }
        } else {
          diagnostics.add(
            .invalidInput, item.location, "Expected an APM dependency string or mapping.")
          continue
        }
        let defaultRegistry = root["registries"]?["default"]?.string != nil
        let explicitGit = item["git"] != nil || raw.contains("://") || raw.hasPrefix("git@")
        if registry || (!local && !explicitGit && (defaultRegistry || root["default_host"] != nil))
        {
          diagnostics.add(
            .unconverted, item.location,
            "Registry or host-dependent resolution needs explicit locked coordinates; no resolver or user defaults are consulted."
          )
          diagnostics.add(
            .incompletePin, item.location, "Manifest dependency is not a resolved source pin.")
          continue
        }
        let declaration: SourceDeclaration?
        let locator: String
        if local {
          do {
            let relative = try ImportInput.path(raw)
            let base = (input.document as NSString).deletingLastPathComponent
            let joined = base.isEmpty ? relative : base + "/" + relative
            _ = try ImportInput.snapshot(input.root).resource(joined)
            locator = joined
            declaration = .init(
              kind: .local, location: input.root.appendingPathComponent(joined).path)
          } catch {
            diagnostics.add(
              .unsafePath, item.location,
              "Local APM source must be explicitly readable within its input root.")
            continue
          }
        } else {
          guard let parsed = gitLocator(raw, explicitPath: path, requested: requested) else {
            if !ImportInput.safeLocator(raw.components(separatedBy: "#")[0]) {
              diagnostics.binding(item.location)
            }
            diagnostics.add(
              .unconverted, item.location,
              "Source coordinates are ambiguous or require producer resolution.")
            continue
          }
          locator = parsed.location
          path = parsed.path
          requested = parsed.ref
          declaration = .init(kind: .git, location: locator, path: path)
        }
        diagnostics.proposal.sources.append(
          .init(
            alias: alias, origin: item.location, declaration: declaration, pin: .init(),
            requestedRef: requested, producerPath: path, producerIdentity: locator,
            developmentOnly: development))
        diagnostics.proposal.resources.append(
          .init(
            origin: item.location, sourceAlias: alias, producerName: "package", path: path ?? ".",
            producerIntegrity: nil, observedHash: nil, executableFlags: [:],
            requiresStandaloneSource: true))
        diagnostics.add(
          .incompletePin, item.location,
          "Manifest intent requires a resolved lock commit or explicitly captured installed content."
        )
        diagnostics.add(
          .unconverted, item.location,
          "APM package primitives require content inspection before canonical component conversion."
        )
      }
    }
    try APMPackageContentImport.read(
      input: input, origin: root.location.appending("localContent"), limits: limits,
      into: &diagnostics)
  }

  private static func selection(
    _ value: ImportYAML, kind: ImportProducerSelection.Kind, scalar: Bool, alias: String?,
    development: Bool, into diagnostics: inout ImportDiagnostics
  ) {
    guard let values = value.strings ?? (scalar ? value.string.map { [$0] } : nil) else {
      diagnostics.add(.invalidInput, value.location, "Expected producer selection strings.")
      return
    }
    if kind == .includes, values.contains(where: { (try? ImportInput.path($0)) == nil }) {
      diagnostics.add(
        .unsafePath, value.location, "Includes must remain within the package source.")
      return
    }
    if kind == .targets {
      let admitted: Set<String> = [
        "all", "copilot", "vscode", "claude", "grok-build", "cursor", "opencode", "codex", "gemini",
        "antigravity", "windsurf", "kiro", "agent-skills", "hermes", "grok-bot", "grok-cloud",
        "openclaw", "copilot-cowork", "copilot-app",
      ]
      guard !values.isEmpty, values.allSatisfy(admitted.contains) else {
        diagnostics.add(.invalidInput, value.location, "Unsupported APM producer target.")
        return
      }
    }
    diagnostics.proposal.selections.append(
      .init(
        origin: value.location, sourceAlias: alias, kind: kind, values: values, automatic: false,
        developmentOnly: development))
    diagnostics.add(
      .unconverted, value.location,
      "Producer selection is retained independently of canonical installation scope.")
  }

  /// Only syntactically unambiguous GitHub shorthand and explicit clone coordinates are converted.
  static func gitLocator(_ value: String, explicitPath: String? = nil, requested: String? = nil)
    -> (location: String, path: String?, ref: String?)?
  {
    let pieces = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard let base = pieces.first.map(String.init), !base.isEmpty, ImportInput.safeLocator(base),
      base != "parent"
    else { return nil }
    let ref = requested ?? (pieces.count == 2 ? String(pieces[1]) : nil)
    if let ref,
      ref.isEmpty || ref.hasPrefix("-")
        || ref.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    {
      return nil
    }
    var path = explicitPath
    let location: String
    if base.contains("://") || base.hasPrefix("git@") {
      guard (try? SourceDeclaration(kind: .git, location: base).transportIdentity()) != nil else {
        return nil
      }
      location = base
    } else {
      let parts = base.split(separator: "/").map(String.init)
      guard parts.count >= 2, !parts[0].contains(":"), !parts[0].contains("."),
        parts.allSatisfy(ImportInput.name)
      else { return nil }
      location = "https://github.com/" + parts[0] + "/" + parts[1]
      if parts.count > 2 {
        guard explicitPath == nil else { return nil }
        path = parts.dropFirst(2).joined(separator: "/")
      }
    }
    if let path, (try? ImportInput.path(path)) == nil { return nil }
    return (location, path, ref)
  }

  private static func lock(
    _ root: ImportYAML, input: SourceImportInput, into diagnostics: inout ImportDiagnostics
  ) throws {
    let mirror = input.profile == .rulesyncAPMV1
    guard let version = root["lockfile_version"]?.string,
      (mirror ? ["1"] : ["1", "2"]).contains(version)
    else {
      diagnostics.add(
        .unsupportedVersion, root["lockfile_version"]?.location ?? root.location,
        "Unsupported producer YAML lock version.")
      return
    }
    guard
      root.validate(
        strings: ["generated_at", "apm_version"],
        required: mirror ? ["generated_at", "apm_version"] : [], into: &diagnostics)
    else { return }
    root.unknown(
      ["lockfile_version", "dependencies", "generated_at", "apm_version"], into: &diagnostics)
    guard let items = root["dependencies"]?.items else {
      diagnostics.add(.invalidInput, root.location, "Expected locked dependencies.")
      return
    }
    for (index, item) in items.enumerated() {
      try Task.checkCancellation()
      guard input.selection?.contains(String(index)) ?? true else { continue }
      guard item.pairs != nil, let repo = item["repo_url"]?.string else {
        diagnostics.add(.invalidInput, item.location, "Expected a locked repository entry.")
        continue
      }
      let common: Set<String> = [
        "repo_url", "resolved_commit", "resolved_ref", "version", "depth", "resolved_by",
        "package_type", "content_hash", "is_dev", "deployed_files", "source", "local_path",
        "virtual_path", "is_virtual",
      ]
      item.unknown(
        mirror
          ? common
          : common.union([
            "resolved_url", "resolved_hash", "tree_sha256", "constraint", "resolved_tag",
            "skill_subset",
          ]), into: &diagnostics)
      guard
        item.validate(
          strings: common.subtracting(["depth", "is_dev", "deployed_files", "is_virtual"]).union(
            mirror
              ? [] : ["resolved_url", "resolved_hash", "tree_sha256", "constraint", "resolved_tag"]),
          required: mirror ? ["repo_url", "package_type"] : ["repo_url"],
          arrays: mirror ? ["deployed_files"] : ["deployed_files", "skill_subset"],
          booleans: ["is_dev", "is_virtual"], integers: ["depth"], into: &diagnostics)
      else { continue }
      if mirror, item["depth"]?.integer == nil || item["deployed_files"]?.strings == nil {
        diagnostics.add(
          .invalidInput, item.location, "Rulesync APM mirror requires depth and deployed files.")
        continue
      }
      guard ImportInput.safeLocator(repo) else {
        diagnostics.binding(item.location)
        continue
      }
      let commit = ImportInput.hex(item["resolved_commit"]?.string, count: 40)
      let sourceKind = item["source"]?.string
      if let sourceKind, !["local", "registry"].contains(sourceKind) {
        diagnostics.add(
          .unconverted, item["source"]!.location,
          "Unknown producer source transport cannot establish a canonical Git source.")
        continue
      }
      let registry = sourceKind == "registry"
      let local = sourceKind == "local"
      let alias = "apm-lock-\(index)"
      var declaration: SourceDeclaration?
      var path = item["virtual_path"]?.string
      if let value = path, (try? ImportInput.path(value)) == nil {
        diagnostics.add(
          .unsafePath, item.location, "Virtual package path must remain relative to its source.")
        path = nil
      } else if !registry && !local, let parsed = gitLocator(repo, explicitPath: path) {
        declaration = .init(
          kind: .git, location: parsed.location, requirement: commit.map { .revision($0) },
          path: path)
      }
      let digestField =
        registry && !mirror
        ? "resolved_hash" : !mirror && item["tree_sha256"] != nil ? "tree_sha256" : "content_hash"
      let integrity =
        mirror ? rulesyncDigest(item[digestField]?.string) : digest(item[digestField]?.string)
      var resolvedURL: String?
      if registry, !mirror {
        if let locator = item["resolved_url"]?.string {
          if ImportInput.safeLocator(locator) {
            resolvedURL = locator
          } else {
            diagnostics.binding(item["resolved_url"]!.location)
          }
        }
        diagnostics.add(
          .unconverted, item.location,
          "Registry archive source requires explicit content capture; no Git revision is inferred.")
      } else if local {
        diagnostics.add(
          .unconverted, item.location,
          "Local lock paths require explicit source/content selection; deployment coordinates are not authoring sources."
        )
      }
      if registry
        ? (integrity == nil || resolvedURL == nil
          || !ImportInput.packageVersion(item["version"]?.string)) : commit == nil
      {
        diagnostics.add(
          .incompletePin, item.location,
          "Locked source lacks a complete exact pin for its transport.")
      }
      if item[digestField] != nil && integrity == nil {
        diagnostics.add(
          .unconverted, item[digestField]!.location,
          "Producer content hash is not a recognized digest envelope.")
      }
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: item.location, declaration: declaration,
          pin: .init(
            commit: registry || local ? nil : commit,
            version: ImportInput.packageVersion(item["version"]?.string)
              ? item["version"]?.string : nil, integrity: integrity),
          requestedRef: item["constraint"]?.string, producerPath: path, producerIdentity: repo,
          registry: nil, resolvedRef: item["resolved_ref"]?.string, resolvedURL: resolvedURL,
          developmentOnly: item["is_dev"]?.boolean == true))
      diagnostics.proposal.resources.append(
        .init(
          origin: item.location, sourceAlias: alias, producerName: "package", path: path,
          producerIntegrity: integrity, observedHash: nil, executableFlags: [:],
          requiresStandaloneSource: true))
      if let files = item["deployed_files"] {
        deployment(files, alias: alias, agent: nil, scope: nil, directory: nil, into: &diagnostics)
      }
      for field in [
        "resolved_by", "package_type", "depth", "is_dev", "local_path", "is_virtual",
        "resolved_tag", "version",
      ] where item[field] != nil { item[field]!.unconverted(into: &diagnostics) }
      if let skills = item["skill_subset"] {
        selection(
          skills, kind: .skills, scalar: false, alias: alias,
          development: item["is_dev"]?.boolean == true, into: &diagnostics)
      }
      diagnostics.add(
        .unconverted, item.location,
        "Lock provenance does not establish package component content or native ownership.")
    }
  }

  private static func github(
    _ root: ImportYAML, input: SourceImportInput, into diagnostics: inout ImportDiagnostics
  ) throws {
    guard root["lockfile_version"]?.string == "1" else {
      diagnostics.add(
        .unsupportedVersion, root.location, "Expected rulesync GitHub deployment lock version 1.")
      return
    }
    guard root.validate(required: ["generated_at"], into: &diagnostics) else { return }
    root.unknown(["lockfile_version", "generated_at", "installations"], into: &diagnostics)
    guard let items = root["installations"]?.items else {
      diagnostics.add(.invalidInput, root.location, "Expected GitHub deployment installations.")
      return
    }
    for (index, item) in items.enumerated() {
      try Task.checkCancellation()
      guard input.selection?.contains(String(index)) ?? true else { continue }
      item.unknown(
        [
          "source", "owner", "repo", "agent", "scope", "skill", "requested_ref", "resolved_ref",
          "resolved_commit", "install_dir", "deployed_files", "content_hash",
        ], into: &diagnostics)
      guard
        item.validate(
          strings: ["requested_ref", "content_hash"],
          required: [
            "source", "owner", "repo", "agent", "scope", "skill", "resolved_ref", "resolved_commit",
            "install_dir",
          ], arrays: ["deployed_files"], into: &diagnostics), item["deployed_files"]?.strings != nil
      else { continue }
      guard let owner = item["owner"]?.string, let repo = item["repo"]?.string,
        let source = item["source"]?.string,
        source.lowercased() == (owner + "/" + repo).lowercased(),
        ImportInput.name(owner), ImportInput.name(repo), let name = item["skill"]?.string,
        ImportInput.name(name),
        let agent = item["agent"]?.string, ImportInput.name(agent),
        let scope = item["scope"]?.string, ["project", "user"].contains(scope)
      else {
        diagnostics.add(
          .invalidInput, item.location, "Invalid GitHub source, skill or deployment coordinates.")
        continue
      }
      let commit = ImportInput.hex(item["resolved_commit"]?.string, count: 40)
      if commit == nil {
        diagnostics.add(
          .incompletePin, item.location, "GitHub deployment lacks a full resolved commit.")
      }
      if item["content_hash"] != nil && rulesyncDigest(item["content_hash"]?.string) == nil {
        diagnostics.add(
          .unconverted, item["content_hash"]!.location,
          "Producer content hash is not a recognized rulesync SHA-256 envelope.")
      }
      let alias = "rulesync-gh-\(index)"
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: item.location,
          declaration: .init(
            kind: .git, location: "https://github.com/" + owner + "/" + repo,
            requirement: commit.map { .revision($0) }),
          pin: .init(commit: commit, integrity: rulesyncDigest(item["content_hash"]?.string)),
          requestedRef: item["requested_ref"]?.string, producerPath: nil, producerIdentity: source,
          resolvedRef: item["resolved_ref"]?.string))
      diagnostics.proposal.resources.append(
        .init(
          origin: item.location, sourceAlias: alias, producerName: name, path: nil,
          producerIntegrity: rulesyncDigest(item["content_hash"]?.string), observedHash: nil,
          executableFlags: [:], requiresStandaloneSource: true))
      if let files = item["deployed_files"] {
        deployment(
          files, alias: alias, agent: agent, scope: scope, directory: item["install_dir"]?.string,
          into: &diagnostics)
      }
      diagnostics.add(
        .unconverted, item.location,
        "Deployment lock has no source skill path; target and scope are evidence, not canonical installation conditions or ownership."
      )
    }
  }

  private static func deployment(
    _ files: ImportYAML, alias: String, agent: String?, scope: String?, directory: String?,
    into diagnostics: inout ImportDiagnostics
  ) {
    guard let paths = files.strings, paths.allSatisfy({ (try? ImportInput.path($0)) != nil }),
      directory.map({ (try? ImportInput.path($0)) != nil }) ?? true
    else {
      diagnostics.add(
        .unsafePath, files.location,
        "Deployment paths are outside the bounded relative-path profile; no ownership is inferred.")
      return
    }
    diagnostics.proposal.deployments.append(
      .init(
        origin: files.location, sourceAlias: alias, agent: agent, scope: scope,
        installDirectory: directory, files: paths))
  }

  private static func rulesyncDigest(_ value: String?) -> ImportPin.Integrity? {
    guard let value, value.hasPrefix("sha256:"),
      ImportInput.hex(String(value.dropFirst(7)), count: 64) != nil
    else { return nil }
    return .init(kind: .rulesyncSHA256, value: value)
  }

  static func digest(_ value: String?) -> ImportPin.Integrity? {
    guard let value else { return nil }
    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
    if parts.count == 1, ImportInput.hex(value, count: 64) != nil {
      return .init(kind: .apmDigest, value: value)
    }
    guard parts.count == 2, let count = ["sha256": 64, "sha384": 96, "sha512": 128][parts[0]],
      ImportInput.hex(parts[1], count: count) != nil
    else { return nil }
    return .init(kind: .apmDigest, value: value)
  }
}
