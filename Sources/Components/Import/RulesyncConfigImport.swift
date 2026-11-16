import AgentsCore
import Foundation
import NativeDocuments

struct ImportLocatedFailure: Error { let location: ImportLocation }

struct ImportJSONC {
  let input: SourceImportInput
  let document: NativeDocument
  let fields: [String: NativeValue]

  init(_ input: SourceImportInput, limits: SourceImportLimits) throws {
    let bytes = try ImportInput.bytes(input, limits: limits)
    guard limits.documentBytes >= 0, limits.documentBytes <= (Int.max - 1024) / 64,
      limits.nodes > 0, limits.depth > 0
    else { throw ImportReadFailure.invalid }
    let budget = NativeDocumentBudget(
      limits: .init(
        storage: limits.documentBytes * 32 + 1024, work: limits.documentBytes * 64 + 1024,
        nodes: limits.nodes, depth: limits.depth, uninterruptedBytes: limits.documentBytes))
    do {
      let document = try NativeDocument(
        bytes: bytes, format: .jsonc(trailingCommas: true), budget: budget)
      guard let observation = try document.read(.init(keys: [])),
        observation.projectionFailure == nil,
        case .object(let fields) = observation.value
      else { throw ImportReadFailure.invalid }
      self.input = input
      self.document = document
      self.fields = fields
    } catch NativeDocumentError.cancelled {
      throw CancellationError()
    } catch NativeDocumentError.invalidDocument(_, let range) {
      throw ImportLocatedFailure(
        location: .init(
          document: input.document, pointer: "",
          span: range.map { importSpan(bytes, document: input.document, range: $0) }))
    }
  }
  func location(_ field: String? = nil) -> ImportLocation {
    let region = NativeRegion(keys: field.map { [$0] } ?? [])
    let range = (try? document.read(region))?.valueRange
    return .init(
      document: input.document, pointer: field.map { "/" + $0 } ?? "",
      span: range.map { importSpan(document.bytes, document: input.document, range: $0) })
  }
}

func importSpan(_ bytes: Data, document: String, range: Range<Int>) -> SourceSpan {
  var line = 1
  var start = 0
  var index = 0
  let end = min(range.lowerBound, bytes.count)
  while index < end {
    if bytes[index] == 13 {
      if index + 1 < end, bytes[index + 1] == 10 { index += 1 }
      line += 1
      start = index + 1
    } else if bytes[index] == 10 {
      line += 1
      start = index + 1
    }
    index += 1
  }
  return .init(
    document: .init(document), start: end, end: min(range.upperBound, bytes.count), line: line,
    column: end - start + 1)
}

extension NativeValue {
  var importString: String? { if case .string(let value) = self { value } else { nil } }
  var importStrings: [String]? {
    guard case .array(let values) = self, values.allSatisfy({ $0.importString != nil }) else {
      return nil
    }
    return values.compactMap(\.importString)
  }
  var importObject: [String: NativeValue]? {
    if case .object(let value) = self { value } else { nil }
  }
}

enum RulesyncConfigImport {
  static func read(
    _ input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    try read(configs: [input], locks: [], limits: limits, into: &diagnostics)
  }

  static func read(
    configs: [SourceImportInput], locks: [SourceImportInput], limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    guard !configs.isEmpty, configs.count <= 2,
      configs.allSatisfy({ $0.profile == .rulesyncConfig }),
      locks.allSatisfy({ [.rulesyncSourcesV1, .rulesyncNpmV1].contains($0.profile) })
    else { throw ImportReadFailure.invalid }
    var effective: [String: (NativeValue, ImportJSONC)] = [:]
    for input in configs {
      let parsed = try ImportJSONC(input, limits: limits)
      if parsed.fields["inputRoot"] != nil && parsed.fields["inputRoots"] != nil {
        diagnostics.add(
          .invalidInput, parsed.location(),
          "inputRoot and inputRoots cannot coexist in one producer config.")
        return
      }
      if parsed.fields["targets"]?.importObject != nil && parsed.fields["features"] != nil {
        diagnostics.add(
          .invalidInput, parsed.location("features"),
          "Object-form targets cannot be combined with features.")
        return
      }
      for (key, value) in parsed.fields { effective[key] = (value, parsed) }
      for (index, key) in parsed.fields.keys.sorted().enumerated()
      where !["sources", "inputRoot", "inputRoots", "targets", "features"].contains(key) {
        let location = parsed.location().appending("member[\(index)]")
        if ImportInput.credentialField(key) { diagnostics.binding(location) }
        unconverted(parsed.fields[key]!, at: location, into: &diagnostics)
      }
    }
    for field in ["targets", "features"] {
      guard let (value, parsed) = effective[field] else { continue }
      if field == "targets", let values = value.importStrings, values.allSatisfy(ImportInput.name) {
        diagnostics.proposal.selections.append(
          .init(
            origin: parsed.location(field), sourceAlias: nil, kind: .targets, values: values,
            automatic: false, developmentOnly: false))
      }
      unconverted(value, at: parsed.location(field), into: &diagnostics)
    }
    if effective["targets"]?.0.importObject != nil, effective["features"] != nil {
      diagnostics.add(
        .invalidInput, effective["features"]!.1.location("features"),
        "Object-form targets cannot be combined with features.")
      return
    }
    var entries: [(ImportOrderedSource, SourceDeclaration?, [String: NativeValue])] = []
    if let (value, parsed) = effective["sources"] {
      guard case .array(let sources) = value else { throw ImportReadFailure.invalid }
      for (index, source) in sources.enumerated() {
        let location = parsed.location("sources").appending(String(index))
        guard let object = source.importObject, let raw = object["source"]?.importString,
          !raw.isEmpty
        else {
          diagnostics.add(.invalidInput, location, "Expected a producer source entry.")
          continue
        }
        for (ordinal, key) in object.keys.sorted().enumerated()
        where ![
          "source", "skills", "rules", "transport", "ref", "path", "rulesPath", "registry",
          "tokenEnv",
        ].contains(key) {
          let member = location.appending("member[\(ordinal)]")
          if ImportInput.credentialField(key) { diagnostics.binding(member) }
          unconverted(object[key]!, at: member, into: &diagnostics)
        }
        guard
          ["transport", "ref", "path", "rulesPath", "registry", "tokenEnv"].allSatisfy({
            object[$0] == nil || object[$0]?.importString != nil
          })
        else {
          diagnostics.add(
            .invalidInput, location, "Source fields require producer string identity.")
          continue
        }
        if let selection = parsed.input.selection, !selection.contains(raw) { continue }
        let transport = object["transport"]?.importString ?? "github"
        guard ["github", "git", "npm"].contains(transport),
          object["skills"] == nil || object["skills"]?.importStrings != nil,
          object["rules"] == nil || object["rules"]?.importStrings != nil,
          object["ref"] == nil || object["ref"]?.importString != nil
        else {
          diagnostics.add(.invalidInput, location, "Invalid source transport or selection.")
          continue
        }
        let emptySelections = ["skills", "rules"].filter { object[$0]?.importStrings == [] }
        if !emptySelections.isEmpty {
          for field in emptySelections {
            diagnostics.add(
              .invalidInput, location.appending(field),
              "An empty producer selection invalidates the whole source; omit the feature or remove the source."
            )
          }
          continue
        }
        if object["registry"] != nil || object["tokenEnv"] != nil {
          guard transport == "npm" else {
            diagnostics.add(
              .invalidInput, location, "Registry bindings are npm-only producer fields.")
            continue
          }
          if let registry = object["registry"]?.importString {
            guard ImportInput.safeLocator(registry) else {
              diagnostics.binding(location.appending("registry"))
              continue
            }
            guard let url = URLComponents(string: registry),
              ["http", "https"].contains(url.scheme), url.host?.isEmpty == false
            else {
              diagnostics.add(
                .invalidInput, location, "Registry requires an explicit HTTP(S) locator.")
              continue
            }
          }
          if let token = object["tokenEnv"]?.importString {
            guard token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            else {
              diagnostics.add(
                .invalidInput, location,
                "Registry token binding requires an environment variable name.")
              continue
            }
            diagnostics.binding(location.appending("tokenEnv"), environmentVariable: token)
          }
        }
        var ref = object["ref"]?.importString
        var sourcePath = object["path"]?.importString
        var declaration: SourceDeclaration?
        var identity = raw
        if transport == "github" {
          if raw.contains("://"), !ImportInput.safeLocator(raw) {
            diagnostics.binding(location.appending("source"))
          }
          guard let github = githubLocator(raw) else {
            diagnostics.add(
              .unconverted, location, "Unsupported or ambiguous GitHub source selector.")
            continue
          }
          ref = ref ?? github.ref
          sourcePath = sourcePath ?? github.path
          identity = raw
          declaration = .init(kind: .git, location: github.location)
        } else if transport == "git" {
          guard ImportInput.safeLocator(raw) else {
            diagnostics.binding(location)
            continue
          }
          guard (try? SourceDeclaration(kind: .git, location: raw).transportIdentity()) != nil
          else {
            diagnostics.add(.invalidInput, location, "Invalid explicit Git source locator.")
            continue
          }
          declaration = .init(kind: .git, location: raw)
        } else {
          guard
            raw.range(
              of: #"^(@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$"#,
              options: .regularExpression) != nil
          else {
            diagnostics.add(.invalidInput, location, "Invalid npm source package selector.")
            continue
          }
          diagnostics.add(
            .unconverted, location,
            "Experimental npm source requires locked archive and captured content.")
        }
        if let ref,
          ref.hasPrefix("-")
            || ref.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
          diagnostics.add(.invalidInput, location, "Invalid requested producer ref.")
          continue
        }
        let skillsPath = sourcePath ?? "skills"
        let rulesPath = object["rulesPath"]?.importString ?? "rules"
        guard !skillsPath.contains(".."), !rulesPath.contains(".."),
          (try? ImportInput.path(skillsPath)) != nil, (try? ImportInput.path(rulesPath)) != nil
        else {
          diagnostics.add(
            .unsafePath, location, "Source paths must remain within their repository.")
          continue
        }
        let intent = ImportOrderedSource(
          origin: location, alias: "rulesync-source-\(index)", identity: identity,
          transport: transport, registry: object["registry"]?.importString, requestedRef: ref,
          skillsPath: skillsPath, rulesPath: rulesPath,
          skills: object["skills"]?.importStrings ?? (object["rules"] == nil ? ["*"] : nil),
          rules: object["rules"]?.importStrings?.map {
            $0.hasSuffix(".md") ? String($0.dropLast(3)) : $0
          })
        entries.append((intent, declaration, object))
        diagnostics.proposal.orderedSources.append(intent)
      }
    }
    let keys = lockKeys(entries)
    var locked: [String: (ImportedSource, [ImportResourceProposal], [String: Any])] = [:]
    for lock in locks {
      var request = lock
      for (index, entry) in entries.enumerated()
      where (entry.0.transport == "npm") == (lock.profile == .rulesyncNpmV1) {
        if let declaration = entry.1 { request.sourceDeclarations[keys[index]] = declaration }
      }
      var result = ImportDiagnostics(proposal: .init(profile: lock.profile))
      let fields = try ImportInput.document(request, limits: limits)
      try RulesyncSourceImport.read(fields, input: request, into: &result)
      diagnostics.proposal.diagnostics += result.proposal.diagnostics
      diagnostics.proposal.bindings += result.proposal.bindings
      for source in result.proposal.sources where !source.alias.contains("-skill-") {
        // Lookup uses exact producer lock coordinates; a normalized repository is not enough.
        let map = fields["sources"] as? [String: Any] ?? [:]
        let sorted = map.keys.sorted()
        guard let ordinal = Int(source.alias.replacingOccurrences(of: "import-source-", with: "")),
          ordinal < sorted.count
        else { continue }
        let key = (lock.profile == .rulesyncNpmV1 ? "npm:" : "git:") + sorted[ordinal]
        if locked[key] != nil {
          diagnostics.add(.ambiguousSource, source.origin, "Duplicate explicit lock identity.")
          continue
        }
        locked[key] = (
          source, result.proposal.resources.filter { $0.sourceAlias == source.alias },
          map[sorted[ordinal]] as? [String: Any] ?? [:]
        )
      }
    }
    let declaredKeys = Set(
      entries.enumerated().map {
        ($0.element.0.transport == "npm" ? "npm:" : "git:") + keys[$0.offset]
      })
    for key in locked.keys.sorted() where !declaredKeys.contains(key) {
      diagnostics.add(
        .unconverted, locked[key]!.0.origin,
        "Lock entry is absent from the effective ordered source config.")
    }
    var winners: Set<String> = []
    for (index, entry) in entries.enumerated() {
      let (intent, declaration, _) = entry
      let key = (intent.transport == "npm" ? "npm:" : "git:") + keys[index]
      var match = locked[key]
      if let candidate = match {
        let pathMatches =
          (candidate.2["skillsPath"] as? String).map {
            (try? ImportInput.path($0)) == (try? ImportInput.path(intent.skillsPath))
          } ?? true
        let rulesMatch =
          (candidate.2["rulesPath"] as? String).map {
            (try? ImportInput.path($0)) == (try? ImportInput.path(intent.rulesPath))
          } ?? true
        let refMatches =
          intent.requestedRef == nil || intent.requestedRef == candidate.0.requestedRef
        let registryMatches =
          intent.registry == nil
          || intent.registry?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == candidate.0.registry?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathMatches || !rulesMatch || !refMatches || !registryMatches {
          diagnostics.add(
            .ambiguousSource, candidate.0.origin,
            "Lock coordinates do not match the current ordered source declaration.")
          match = nil
        }
      }
      var exactDeclaration = declaration
      if let commit = match?.0.pin.commit { exactDeclaration?.requirement = .revision(commit) }
      diagnostics.proposal.sources.append(
        .init(
          alias: intent.alias, origin: intent.origin, declaration: exactDeclaration,
          pin: match?.0.pin ?? .init(), requestedRef: intent.requestedRef,
          producerPath: intent.skillsPath, producerIdentity: intent.identity,
          registry: intent.registry ?? match?.0.registry, resolvedRef: match?.0.resolvedRef))
      if match == nil {
        diagnostics.add(
          .incompletePin, intent.origin,
          "Ordered source has no matching explicitly supplied lock entry.")
      }
      for (resourceIndex, resource) in (match?.1 ?? []).enumerated() {
        let kind = resource.kind == .instructions ? "rules" : "skills"
        let selection = kind == "rules" ? intent.rules : intent.skills
        guard selection == ["*"] || selection?.contains(resource.producerName) == true else {
          diagnostics.add(
            .unconverted, resource.origin,
            "Locked artifact is outside the current explicit producer selection.")
          continue
        }
        let collision = kind + ":" + resource.producerName
        let selected = winners.insert(collision).inserted
        if !selected {
          diagnostics.add(
            .unconverted, resource.origin,
            "Earlier declared remote source wins this producer artifact collision.")
        }
        diagnostics.proposal.resources.append(
          .init(
            origin: resource.origin, sourceAlias: intent.alias, producerName: resource.producerName,
            path: resource.path, producerIntegrity: resource.producerIntegrity, observedHash: nil,
            executableFlags: [:], requiresStandaloneSource: true, kind: resource.kind,
            selected: selected))
        if selected, resource.kind == .skills, let path = resource.path, var source = declaration {
          let alias = intent.alias + "-skill-\(resourceIndex)"
          source.path = path
          source.requirement = match?.0.pin.commit.map(SourceRequirement.revision)
          diagnostics.proposal.sources.append(
            .init(
              alias: alias, origin: resource.origin, declaration: source,
              pin: match?.0.pin ?? .init(), requestedRef: intent.requestedRef, producerPath: path,
              producerIdentity: intent.identity))
          diagnostics.proposal.components.append(
            .init(
              origin: resource.origin,
              declaration: .skills(source: alias, .init(select: .names([resource.producerName])))))
        }
      }
    }
    let roots: [(String, SourceImportInput, ImportLocation)]
    if let (value, parsed) = effective["inputRoots"] {
      guard let values = value.importStrings, !values.isEmpty else {
        throw ImportReadFailure.invalid
      }
      roots = values.enumerated().map {
        ($0.element, parsed.input, parsed.location("inputRoots").appending(String($0.offset)))
      }
    } else if let (value, parsed) = effective["inputRoot"] {
      guard let value = value.importString else { throw ImportReadFailure.invalid }
      roots = [
        (
          value == "." ? ".rulesync" : value + "/.rulesync", parsed.input,
          parsed.location("inputRoot")
        )
      ]
    } else {
      roots = [
        (
          ".rulesync", configs[0],
          .init(document: configs[0].document, pointer: "/inputRoots/default")
        )
      ]
    }
    try localContent(roots, limits: limits, into: &diagnostics)
  }

  private static func unconverted(
    _ value: NativeValue, at location: ImportLocation, into diagnostics: inout ImportDiagnostics
  ) {
    diagnostics.add(
      .unconverted, location,
      "Producer configuration semantics are not canonical installation intent.")
    if let text = value.importString, text.contains("://"), !ImportInput.safeLocator(text) {
      diagnostics.binding(location)
    }
    if case .object(let fields) = value {
      for (index, key) in fields.keys.sorted().enumerated() {
        let child = location.appending("member[\(index)]")
        if ImportInput.credentialField(key) {
          diagnostics.binding(child)
        }
        unconverted(fields[key]!, at: child, into: &diagnostics)
      }
    } else if case .array(let values) = value {
      for (index, item) in values.enumerated() {
        unconverted(item, at: location.appending(String(index)), into: &diagnostics)
      }
    }
  }

  static func githubLocator(_ raw: String) -> (
    location: String, ref: String?, path: String?
  )? {
    guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !raw.contains("?"), !raw.contains("#")
    else { return nil }
    if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
      guard ImportInput.safeLocator(raw), let url = URLComponents(string: raw),
        let host = url.host?.lowercased(),
        ["github.com", "www.github.com", "gitlab.com", "www.gitlab.com"].contains(host)
      else { return nil }
      let parts = url.percentEncodedPath.split(separator: "/").map(String.init)
      guard parts.count >= 2, parts.prefix(2).allSatisfy(ImportInput.name) else { return nil }
      let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
      let location =
        "https://" + (host.contains("gitlab") ? "gitlab.com" : "github.com") + "/" + parts[0] + "/"
        + repo
      if parts.count > 2, ["tree", "blob"].contains(parts[2]) {
        guard parts.count > 3, let ref = parts[3].removingPercentEncoding else { return nil }
        let path =
          parts.count > 4 ? parts.dropFirst(4).joined(separator: "/").removingPercentEncoding : nil
        if parts.count > 4 && path == nil { return nil }
        return (location, ref, path)
      }
      return (location, nil, nil)
    }
    var value = raw
    var host = "github.com"
    for provider in ["github", "gitlab"] where value.hasPrefix(provider + ":") {
      host = provider + ".com"
      value.removeFirst(provider.count + 1)
      break
    }
    let pathParts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let refParts = pathParts[0].split(
      separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let parts = refParts[0].split(separator: "/").map(String.init)
    guard parts.count >= 2,
      parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }),
      !value.contains("?"),
      pathParts.count < 2 || !pathParts[1].isEmpty, refParts.count < 2 || !refParts[1].isEmpty
    else { return nil }
    return (
      "https://" + host + "/" + parts.joined(separator: "/"),
      refParts.count == 2 ? String(refParts[1]) : nil,
      pathParts.count == 2 ? String(pathParts[1]) : nil
    )
  }

  private static func normalizedKey(_ value: String) -> String {
    var result = value
    for prefix in [
      "https://www.github.com/", "https://github.com/", "http://www.github.com/",
      "http://github.com/", "https://www.gitlab.com/", "https://gitlab.com/",
      "http://www.gitlab.com/", "http://gitlab.com/",
    ] where result.lowercased().hasPrefix(prefix) {
      result.removeFirst(prefix.count)
      break
    }
    for prefix in ["github:", "gitlab:"] where result.hasPrefix(prefix) {
      result.removeFirst(prefix.count)
      break
    }
    while result.hasSuffix("/") { result.removeLast() }
    if result.hasSuffix(".git") { result.removeLast(4) }
    return result.lowercased()
  }
  private static func lockKeys(
    _ entries: [(ImportOrderedSource, SourceDeclaration?, [String: NativeValue])]
  ) -> [String] {
    let bare = entries.map { normalizedKey($0.0.identity) }
    var counts: [String: Int] = [:]
    for (index, entry) in entries.enumerated() where entry.0.transport != "npm" {
      counts[bare[index], default: 0] += 1
    }
    var occurrences: [String: Int] = [:]
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()/")
    return entries.enumerated().map { index, entry in
      guard entry.0.transport != "npm", counts[bare[index], default: 0] > 1 else {
        return bare[index]
      }
      var qualifiers: [String] = []
      for field in ["path", "rulesPath", "ref"] {
        guard var value = entry.2[field]?.importString else { continue }
        if field != "ref" { value = (try? ImportInput.path(value)) ?? value }
        qualifiers.append(
          field + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
      }
      let base = bare[index] + (qualifiers.isEmpty ? "" : "#" + qualifiers.joined(separator: "&"))
      occurrences[base, default: 0] += 1
      let occurrence = occurrences[base]!
      return occurrence == 1
        ? base : base + (qualifiers.isEmpty ? "#" : "&") + "entry=\(occurrence)"
    }
  }

  private static func localContent(
    _ roots: [(String, SourceImportInput, ImportLocation)], limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    struct Candidate {
      let name: String
      let path: String
      let input: SourceImportInput
      let origin: ImportLocation
      let skill: Bool
    }
    var candidates: [String: Candidate] = [:]
    var remaining = limits.resourceEntries
    var seenRoots: Set<String> = []
    for (rootIndex, root) in roots.enumerated() {
      let (path, input, origin) = root
      guard let relative = try? ImportInput.path(path) else {
        diagnostics.add(.unsafePath, origin, "Input root must stay within its explicit boundary.")
        continue
      }
      let view = try ImportInput.snapshot(input.root)
      let directory = try view.resource(relative)
      guard seenRoots.insert(directory.standardizedFileURL.path).inserted else { continue }
      guard FileManager.default.fileExists(atPath: directory.path) else {
        if rootIndex == 0 {
          diagnostics.add(.missingResource, origin, "Primary rulesync input root is absent.")
        }
        continue
      }
      func children(_ path: String) throws -> [String] {
        let file = try view.resource(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard
          let iterator = FileManager.default.enumerator(
            at: file, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        else { throw ImportReadFailure.invalid }
        var values: [String] = []
        for case let entry as URL in iterator {
          try Task.checkCancellation()
          guard remaining > 0 else { throw ImportReadFailure.invalid }
          remaining -= 1
          values.append(entry.lastPathComponent)
        }
        return values.sorted()
      }
      for (folder, skill) in [("skills", true), ("rules", false)] {
        for curated in [true, false] {
          let base = relative + "/" + folder + (curated ? "/.curated" : "")
          for (ordinal, child) in try children(base).enumerated() where child != ".curated" {
            let location = origin.appending(
              "\(folder)/\(curated ? "curated" : "local")/member[\(ordinal)]")
            guard ImportInput.name(child), skill || child.hasSuffix(".md") else {
              diagnostics.add(.unconverted, location, "Unrecognized rulesync source artifact.")
              continue
            }
            let itemPath = base + "/" + child
            let file = try view.resource(itemPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == (skill ? .typeDirectory : .typeRegular)
            else {
              diagnostics.add(
                .unsafePath, location, "Rulesync source artifact is not admitted regular content.")
              continue
            }
            let name = skill ? child : String(child.dropLast(3))
            let key = folder + ":" + name
            if let previous = candidates[key] {
              diagnostics.add(
                .unconverted, previous.origin,
                "Producer precedence selects local over curated and later input roots over earlier roots."
              )
            }
            candidates[key] = Candidate(
              name: name, path: itemPath, input: input, origin: location, skill: skill)
          }
        }
      }
      for (ordinal, child) in try children(relative).enumerated()
      where !["skills", "rules"].contains(child) {
        diagnostics.add(
          .unconverted, origin.appending("member[\(ordinal)]"),
          "Source tree item requires its producer component/native adapter.")
      }
    }
    for (index, key) in candidates.keys.sorted().enumerated() {
      let candidate = candidates[key]!
      let alias = "rulesync-local-\(index)"
      if candidate.skill {
        do {
          let content = try ImportSkillContent.read(
            candidate.path, input: candidate.input, limits: limits)
          diagnostics.proposal.diagnostics += content.diagnostics
          diagnostics.proposal.bindings += content.bindings
          for resourceIndex in diagnostics.proposal.resources.indices {
            let resource = diagnostics.proposal.resources[resourceIndex]
            if resource.selected, resource.producerName == candidate.name,
              resource.kind == (candidate.skill ? .skills : .instructions)
            {
              diagnostics.proposal.resources[resourceIndex].selected = false
              diagnostics.proposal.components.removeAll { $0.origin == resource.origin }
              diagnostics.add(
                .unconverted, resource.origin,
                "Explicit local source content supersedes the remote curated artifact.")
            }
          }
          diagnostics.proposal.sources.append(
            .init(
              alias: alias, origin: candidate.origin,
              declaration: .init(
                kind: .local, location: candidate.path,
                environment: .init(
                  projectDirectory: candidate.input.root, homeDirectory: candidate.input.root)),
              pin: .init(), requestedRef: nil, producerPath: candidate.path))
          diagnostics.proposal.components.append(
            .init(
              origin: candidate.origin,
              declaration: .skills(
                source: alias,
                .init(select: .names([content.skill.name]), condition: content.skill.condition))))
          diagnostics.proposal.resources.append(
            .init(
              origin: candidate.origin, sourceAlias: alias, producerName: candidate.name, path: ".",
              producerIntegrity: nil, observedHash: content.hash, executableFlags: content.flags,
              requiresStandaloneSource: true, kind: candidate.skill ? .skills : .instructions))
        } catch is CancellationError { throw CancellationError() } catch {
          diagnostics.add(
            .invalidInput, candidate.origin,
            "Selected skill content is not admitted within the explicit source boundary.")
        }
      } else {
        var request = candidate.input
        request = .init(profile: request.profile, root: request.root, document: candidate.path)
        let bytes = try ImportInput.bytes(request, limits: limits)
        let semantics = try ImportFrontmatter.inspect(
          bytes, document: candidate.path, converted: [], profile: .rulesyncConfig, limits: limits)
        diagnostics.proposal.diagnostics += semantics.diagnostics
        diagnostics.proposal.bindings += semantics.bindings
        for resourceIndex in diagnostics.proposal.resources.indices {
          let resource = diagnostics.proposal.resources[resourceIndex]
          if resource.selected, resource.producerName == candidate.name,
            resource.kind == (candidate.skill ? .skills : .instructions)
          {
            diagnostics.proposal.resources[resourceIndex].selected = false
            diagnostics.proposal.components.removeAll { $0.origin == resource.origin }
            diagnostics.add(
              .unconverted, resource.origin,
              "Explicit local source content supersedes the remote curated artifact.")
          }
        }
        diagnostics.proposal.sources.append(
          .init(
            alias: alias, origin: candidate.origin,
            declaration: .init(kind: .local, location: candidate.input.root.path), pin: .init(),
            requestedRef: nil, producerPath: nil))
        diagnostics.proposal.resources.append(
          .init(
            origin: candidate.origin, sourceAlias: alias, producerName: candidate.name,
            path: candidate.path, producerIntegrity: nil,
            observedHash: "sha256:" + FileHash.sha256Hex(data: bytes), executableFlags: [:],
            requiresStandaloneSource: true, kind: candidate.skill ? .skills : .instructions))
        diagnostics.add(
          .unconverted, candidate.origin,
          "Rulesync rule frontmatter and generation semantics require explicit conversion before canonical instructions."
        )
      }
    }
  }
}
