import AgentsCore
import Foundation

/// Catalog entries are coordinates only. Resolution, selection and fetching stay with B.
enum NativeCatalogImport {
  static func read(
    _ input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    let parsed = try NativeImportDocument(input, format: .json, limits: limits)
    NativeImportInput.unknown(
      parsed.fields, allowed: ["name", "plugins"], at: parsed.location(),
      into: &diagnostics)
    guard let catalogName = parsed.fields["name"]?.importString,
      NativeImportInput.name(catalogName),
      parsed.fields["owner"]?.importObject?["name"]?.importString?.isEmpty == false,
      case .array(let entries) = parsed.fields["plugins"]
    else {
      throw ImportReadFailure.invalid
    }
    let enumerated = Set(entries.compactMap { $0.importObject?["name"]?.importString })
    guard let selection = input.enumerateChoices ? enumerated : input.selection else {
      diagnostics.add(
        .unconverted, parsed.location(["plugins"]),
        "Catalog coordinates require an explicit entry selection; no catalog is installed or resolved."
      )
      return
    }
    let suffix = ".claude-plugin/marketplace.json"
    guard input.document == suffix || input.document.hasSuffix("/" + suffix) else {
      throw ImportReadFailure.invalid
    }
    let root = input.document == suffix ? "." : String(input.document.dropLast(suffix.count + 1))
    var counts: [String: Int] = [:]
    for value in entries {
      if let name = value.importObject?["name"]?.importString { counts[name, default: 0] += 1 }
    }
    var selected: Set<String> = []
    for (index, value) in entries.enumerated() {
      let origin = parsed.location(["plugins"]).appending(String(index))
      guard let fields = value.importObject, let name = fields["name"]?.importString,
        NativeImportInput.name(name)
      else {
        NativeImportInput.unconverted(value, at: origin, into: &diagnostics)
        continue
      }
      let choice = diagnostics.beginChoice(name, at: origin)
      defer { diagnostics.endChoice(choice) }
      guard selection.contains(name) else { continue }
      if counts[name, default: 0] > 1 {
        diagnostics.add(
          .ambiguousSource, origin,
          "Catalog selection has multiple declarations; no source is chosen.")
        continue
      }
      guard selected.insert(name).inserted else {
        diagnostics.add(
          .ambiguousSource, origin, "Selected catalog name has multiple declarations.")
        continue
      }
      NativeImportInput.unknown(
        fields,
        allowed: [
          "name", "source", "version", "description", "author", "homepage", "keywords", "category",
          "tags", "strict",
        ], at: origin, into: &diagnostics)
      if let strict = fields["strict"], strict != .boolean(true) {
        NativeImportInput.unconverted(strict, at: origin.appending("strict"), into: &diagnostics)
        continue
      }
      for key in ["version", "description", "author", "homepage", "keywords", "category", "tags"]
      where fields[key] != nil {
        NativeImportInput.unconverted(fields[key]!, at: origin.appending(key), into: &diagnostics)
      }
      let declaration: SourceDeclaration
      var exact: String?
      var requested: String?
      var path: String?
      if let local = fields["source"]?.importString {
        let relative = try NativeSourceImport.nativePath(local, container: root)
        let location = root == "." ? relative : root + "/" + relative
        declaration = .init(
          kind: .local, location: location,
          environment: .init(projectDirectory: input.root, homeDirectory: input.root))
        diagnostics.add(
          .incompletePin, origin,
          "Local catalog entry needs explicit content capture; a version label is not an exact content pin."
        )
      } else if let source = fields["source"]?.importObject {
        NativeImportInput.unknown(
          source, allowed: ["source", "repo", "url", "ref", "sha", "path"],
          at: origin.appending("source"), into: &diagnostics)
        let location: String
        if source["source"] == .string("github"), let repo = source["repo"]?.importString,
          repo.split(separator: "/", omittingEmptySubsequences: false).count == 2,
          repo.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
          })
        {
          location = "https://github.com/" + repo
        } else if [NativeValue.string("url"), .string("git-subdir")].contains(
          source["source"] ?? .null),
          let url = source["url"]?.importString
        {
          guard ImportInput.safeLocator(url) else {
            diagnostics.binding(origin.appending("source"))
            continue
          }
          location = url
        } else {
          NativeImportInput.unconverted(
            fields["source"]!, at: origin.appending("source"), into: &diagnostics)
          continue
        }
        exact = ImportInput.hex(source["sha"]?.importString, count: 40)
        requested = source["ref"]?.importString
        if source["source"] == .string("git-subdir") {
          guard let raw = source["path"]?.importString else {
            diagnostics.add(
              .invalidInput, origin.appending("source/path"),
              "Git subdirectory source requires an explicit path.")
            continue
          }
          path = try NativeSourceImport.nativePath(raw, container: root)
        } else if source["path"] != nil {
          NativeImportInput.unconverted(
            source["path"]!, at: origin.appending("source/path"), into: &diagnostics)
          continue
        }
        declaration = .init(
          kind: .git, location: location, requirement: exact.map(SourceRequirement.revision),
          path: path)
        guard (try? declaration.transportIdentity()) != nil else {
          diagnostics.add(
            .invalidInput, origin, "Catalog Git coordinate is not a valid canonical source.")
          continue
        }
        if exact == nil {
          diagnostics.add(
            .incompletePin, origin,
            "Catalog ref/version is requested provenance; no resolved commit is invented or fetched."
          )
        }
      } else {
        NativeImportInput.unconverted(
          fields["source"] ?? .null, at: origin.appending("source"), into: &diagnostics)
        continue
      }
      let alias = "catalog-\(index)"
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: origin, declaration: declaration,
          pin: .init(commit: exact), requestedRef: requested, producerPath: path,
          producerIdentity: name))
      NativeImportInput.emit(
        .plugin(
          name: name, path: ".", source: alias, mode: .components, agents: [.claudeCode]),
        selector: .plugin(name: name), origin: origin, container: root, profile: input.profile,
        into: &diagnostics)
    }
    if !selection.isSubset(of: selected) {
      diagnostics.add(
        .invalidInput, parsed.location(["plugins"]),
        "A selected catalog entry is absent or invalid.")
    }
  }
}
