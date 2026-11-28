import AgentsCore
import Foundation

enum RulesyncSourceImport {
  static func read(
    _ fields: [String: Any], input: SourceImportInput, into diagnostics: inout ImportDiagnostics
  ) throws {
    let origin = ImportLocation(document: input.document, pointer: "")
    guard ImportInput.version(fields["lockfileVersion"], equals: 1) else {
      diagnostics.add(
        .unsupportedVersion, origin.appending("lockfileVersion"), "Expected lock version 1.")
      return
    }
    diagnostics.unknown(fields, allowed: ["lockfileVersion", "sources"], at: origin)
    guard let sources = fields["sources"] as? [String: Any] else {
      diagnostics.add(.invalidInput, origin.appending("sources"), "Expected a source map.")
      return
    }
    let npm = input.profile == .rulesyncNpmV1
    if npm {
      diagnostics.add(
        .unconverted, origin, "This npm source lock is an experimental producer format.")
    }
    for (index, key) in sources.keys.sorted().enumerated() {
      try Task.checkCancellation()
      let location = origin.appending("sources/member[\(index)]")
      let repositoryKey = key.components(separatedBy: "#")[0]
      let admissibleKey =
        npm
        ? RulesyncConfigImport.npmSelector(key)
        : (ImportInput.safeLocator(repositoryKey)
          || RulesyncConfigImport.githubLocator(repositoryKey) != nil)
      let choice = admissibleKey ? diagnostics.beginChoice(key, at: location) : nil
      defer { if let choice { diagnostics.endChoice(choice) } }
      guard input.enumerateChoices || (input.selection?.contains(key) ?? true) else { continue }
      if admissibleKey, !npm, input.sourceDeclarations[key] == nil {
        diagnostics.requireInput(.gitSource, key: key, at: location)
      }
      guard let entry = sources[key] as? [String: Any] else {
        diagnostics.add(.invalidInput, location, "Expected a locked source object.")
        continue
      }
      diagnostics.unknown(
        entry,
        allowed: Set([
          "requestedRef", "resolvedRef", "requestedVersion", "resolvedVersion", "registry",
          "integrity", "resolvedAt", "skills", "skillSelection", "skillsPath", "rules",
          "ruleSelection", "rulesPath", "resolvedRuleNames",
        ]).subtracting(
          npm
            ? ["requestedRef", "resolvedRef"]
            : [
              "requestedVersion", "resolvedVersion", "registry", "integrity",
            ]), at: location)
      guard
        diagnostics.typedFields(
          entry,
          strings: npm
            ? [
              "requestedVersion", "resolvedVersion", "registry", "integrity", "resolvedAt",
              "skillsPath", "rulesPath",
            ]
            : ["requestedRef", "resolvedRef", "resolvedAt", "skillsPath", "rulesPath"],
          required: npm ? ["resolvedVersion"] : ["resolvedRef"],
          arrays: ["skillSelection", "ruleSelection", "resolvedRuleNames"], at: location)
      else { continue }
      let commit = npm ? nil : ImportInput.hex(ImportInput.string(entry["resolvedRef"]), count: 40)
      let version = npm ? ImportInput.string(entry["resolvedVersion"]) : nil
      let integrity = npm ? sri(ImportInput.string(entry["integrity"])) : nil
      let requested = ImportInput.string(entry[npm ? "requestedVersion" : "requestedRef"])
      if npm ? (!ImportInput.packageVersion(version) || integrity == nil) : commit == nil {
        diagnostics.add(
          .incompletePin, location,
          npm
            ? "Exact package version and tarball SRI are required for complete package provenance."
            : "Only a full lowercase resolvedRef commit proves this Git pin.")
      }
      if let registry = ImportInput.string(entry["registry"]), !ImportInput.safeLocator(registry) {
        diagnostics.binding(location.appending("registry"))
        continue
      }
      let repository = key.components(separatedBy: "#")[0]
      if npm,
        key.range(
          of: #"^(@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$"#, options: .regularExpression)
          == nil
      {
        diagnostics.add(.invalidInput, location, "Expected an npm package name as source key.")
        continue
      }
      if !npm, !ImportInput.safeLocator(repository),
        RulesyncConfigImport.githubLocator(repository) == nil
      {
        diagnostics.binding(location)
        continue
      }
      if !npm, repository != key, input.sourceDeclarations[key] == nil {
        diagnostics.add(
          .unconverted, location,
          "Qualified source-key selection requires its ordered producer config; only repository identity is retained."
        )
      }
      var source = input.sourceDeclarations[key]
      if let declaration = source, !ImportInput.safeLocator(declaration.location) {
        diagnostics.binding(location)
        continue
      }
      if npm {
        source = nil
        diagnostics.add(
          .unconverted, location,
          "npm transport requires captured content before canonical source creation.")
      } else if source == nil {
        diagnostics.add(
          .ambiguousSource, location,
          "A normalized source lock key does not establish the original provider and transport; supply the source declaration."
        )
      } else if source?.kind != .git {
        diagnostics.add(
          .invalidInput, location, "Git source locks require a Git source declaration.")
        source = nil
      }
      if let commit, source != nil { source?.requirement = .revision(commit) }
      let alias = "import-source-\(index)"
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: location, declaration: source,
          pin: .init(
            commit: commit, version: ImportInput.packageVersion(version) ? version : nil,
            integrity: integrity),
          requestedRef: requested, producerPath: nil, producerIdentity: npm ? key : repository,
          registry: ImportInput.string(entry["registry"]),
          resolvedRef: npm ? nil : ImportInput.string(entry["resolvedRef"])))
      for field in ["skillSelection", "ruleSelection", "resolvedRuleNames"]
      where entry[field] != nil {
        // Lock artifact maps are concrete resources, while selections describe producer intent.
        diagnostics.add(
          .unconverted, location.appending(field),
          "Producer selection is not a canonical all-member declaration.")
      }
      try artifacts(
        entry, field: "skills", pathField: "skillsPath", alias: alias, source: source,
        location: location, into: &diagnostics)
      if entry["rules"] != nil {
        try artifacts(
          entry, field: "rules", pathField: "rulesPath", alias: alias, source: source,
          location: location, into: &diagnostics)
      }
      for field in ["resolvedAt"] where entry[field] != nil {
        diagnostics.add(
          .unconverted, location.appending(field),
          "Producer resolution bookkeeping is not imported.")
      }
    }
    if let selection = input.selection, !selection.isSubset(of: Set(sources.keys)) {
      diagnostics.add(
        .invalidInput, origin.appending("sources"),
        "A selected source is absent from this document.")
    }
  }

  private static func artifacts(
    _ entry: [String: Any], field: String, pathField: String, alias: String,
    source: SourceDeclaration?, location: ImportLocation, into diagnostics: inout ImportDiagnostics
  ) throws {
    let location = location.appending(field)
    guard let artifacts = entry[field] as? [String: Any] else {
      diagnostics.add(.invalidInput, location, "Expected an artifact integrity map.")
      return
    }
    let rawPath = ImportInput.string(entry[pathField]) ?? source?.path
    let path: String?
    do { path = try rawPath.map(ImportInput.path) } catch {
      diagnostics.add(
        .unsafePath, location, "Producer resource path must remain relative to its source.")
      return
    }
    if path == nil {
      diagnostics.add(
        .unconverted, location, "Resource root is absent from this lock; supply its declared path.")
    }
    for (index, name) in artifacts.keys.sorted().enumerated() {
      let item = location.appending("member[\(index)]")
      guard ImportInput.name(name), let object = artifacts[name] as? [String: Any] else {
        diagnostics.add(.invalidInput, item, "Expected a safe artifact name and integrity object.")
        continue
      }
      diagnostics.unknown(object, allowed: ["integrity"], at: item)
      let hash = ImportInput.string(object["integrity"])
      let integrity: ImportPin.Integrity?
      if let hash, hash.hasPrefix("sha256-"),
        ImportInput.hex(String(hash.dropFirst(7)), count: 64) != nil
      {
        integrity = .init(kind: .rulesyncSHA256, value: hash)
      } else {
        integrity = nil
        diagnostics.add(
          .incompletePin, item.appending("integrity"),
          "Artifact SHA-256 integrity is missing or invalid.")
      }
      let selection = ImportInput.strings(entry["skillSelection"])
      let memberDirectory = selection.map { $0 == ["*"] || $0.count > 1 } ?? false
      let resourcePath: String?
      if let path, field == "rules" || memberDirectory {
        let file = field == "rules" ? name + ".md" : name
        resourcePath = path == "." ? file : path + "/" + file
      } else {
        resourcePath = nil
        if path != nil {
          diagnostics.add(
            .unconverted, item,
            "This selection can use producer root fallback; the lock does not prove the member resource path."
          )
        }
      }
      diagnostics.proposal.resources.append(
        .init(
          origin: item, sourceAlias: alias, producerName: name, path: resourcePath,
          producerIntegrity: integrity, observedHash: nil, executableFlags: [:],
          requiresStandaloneSource: true, kind: field == "skills" ? .skills : .instructions))
      if field == "skills", let source, let resourcePath {
        // Each resource root gets its own alias: canonical discovery paths belong to sources.
        let itemAlias = alias + "-skill-\(index)"
        var declaration = source
        declaration.path = resourcePath
        diagnostics.proposal.sources.append(
          .init(
            alias: itemAlias, origin: item, declaration: declaration,
            pin: diagnostics.proposal.sources.first(where: { $0.alias == alias })!.pin,
            requestedRef: diagnostics.proposal.sources.first(where: { $0.alias == alias })!
              .requestedRef,
            producerPath: resourcePath,
            producerIdentity: diagnostics.proposal.sources.first(where: { $0.alias == alias })!
              .producerIdentity))
        diagnostics.proposal.components.append(
          .init(
            origin: item, declaration: .skills(source: itemAlias, .init(select: .names([name])))))
      } else if field == "rules" {
        diagnostics.add(
          .unconverted, item,
          "Rulesync rule frontmatter and targeting require semantic conversion before canonical instructions."
        )
      }
    }
  }

  private static func sri(_ value: String?) -> ImportPin.Integrity? {
    guard let value else { return nil }
    let parts = value.split(separator: " ", omittingEmptySubsequences: true)
    guard !parts.isEmpty else { return nil }
    for part in parts {
      let fields = part.split(separator: "-", maxSplits: 1)
      guard fields.count == 2,
        let size = ["sha256": 32, "sha384": 48, "sha512": 64][String(fields[0])],
        let bytes = Data(base64Encoded: String(fields[1])), bytes.count == size
      else { return nil }
    }
    return .init(kind: .npmSRI, value: value)
  }
}
