import AgentsCore
import Foundation

enum VercelSourceImport {
  static func read(
    _ fields: [String: Any], input: SourceImportInput, limits: SourceImportLimits,
    into diagnostics: inout ImportDiagnostics
  ) throws {
    let origin = ImportLocation(document: input.document, pointer: "")
    let project = input.profile == .vercelProjectV2
    guard ImportInput.version(fields["version"], equals: project ? 2 : 3) else {
      diagnostics.add(
        .unsupportedVersion, origin.appending("version"),
        "Lock version does not match the explicit profile.")
      return
    }
    diagnostics.unknown(
      fields,
      allowed: project
        ? ["version", "skills"] : ["version", "skills", "dismissed", "lastSelectedAgents"],
      at: origin)
    for field in ["dismissed", "lastSelectedAgents"] where fields[field] != nil {
      diagnostics.add(
        .unconverted, origin.appending(field),
        "Global installer UI bookkeeping does not specify individual skill recipients.")
    }
    guard let skills = fields["skills"] as? [String: Any] else {
      diagnostics.add(.invalidInput, origin.appending("skills"), "Expected a skill map.")
      return
    }
    for (index, name) in skills.keys.sorted().enumerated() {
      try Task.checkCancellation()
      let location = origin.appending("skills/member[\(index)]")
      let choice = ImportInput.name(name) ? diagnostics.beginChoice(name, at: location) : nil
      defer { if let choice { diagnostics.endChoice(choice) } }
      guard input.enumerateChoices || (input.selection?.contains(name) ?? true) else { continue }
      var contentAdmitted = false
      defer {
        if ImportInput.name(name), !contentAdmitted {
          diagnostics.requireInput(.installedContent, key: name, at: location)
        }
      }
      guard ImportInput.name(name), let entry = skills[name] as? [String: Any],
        let source = ImportInput.string(entry["source"]),
        let sourceType = ImportInput.string(entry["sourceType"])
      else {
        diagnostics.add(
          .invalidInput, location, "Expected a safe skill name, source and sourceType.")
        continue
      }
      diagnostics.unknown(
        entry,
        allowed: project
          ? [
            "source", "sourceType", "sourceUrl", "ref", "skillPath", "version", "via",
            "computedHash", "subagents", "wellKnownDigest", "installMode",
          ]
          : [
            "source", "sourceType", "sourceUrl", "ref", "skillPath", "skillFolderHash",
            "installedAt", "updatedAt", "pluginName", "sourceBaseUrl", "wellKnownDigest",
            "installMode",
          ],
        at: location)
      guard
        diagnostics.typedFields(
          entry,
          strings: project
            ? [
              "source", "sourceType", "sourceUrl", "ref", "skillPath", "version", "via",
              "computedHash", "wellKnownDigest", "installMode",
            ]
            : [
              "source", "sourceType", "sourceUrl", "ref", "skillPath", "skillFolderHash",
              "installedAt", "updatedAt", "pluginName", "sourceBaseUrl", "wellKnownDigest",
              "installMode",
            ],
          required: project
            ? ["source", "sourceType", "computedHash"]
            : ["source", "sourceType", "sourceUrl", "skillFolderHash", "installedAt", "updatedAt"],
          arrays: project ? ["subagents"] : [], at: location)
      else { continue }
      let sourceURL = ImportInput.string(entry["sourceUrl"])
      // node_modules locks store an npm package identifier, not a credentialed URL.
      let packageIdentifier =
        sourceType == "node_modules"
        && source.range(
          of: #"^(@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$"#,
          options: .regularExpression) != nil
      guard packageIdentifier || ImportInput.safeLocator(source),
        sourceURL.map(ImportInput.safeLocator) ?? project,
        ImportInput.string(entry["sourceBaseUrl"]).map(ImportInput.safeLocator) ?? true
      else {
        diagnostics.binding(location.appending("sourceUrl"))
        continue
      }
      let path: String?
      do { path = try ImportInput.string(entry["skillPath"]).map(ImportInput.path) } catch {
        diagnostics.add(
          .unsafePath, location.appending("skillPath"),
          "Skill path must remain inside the producer source.")
        continue
      }
      if path == nil, input.installedSkills[name] == nil {
        diagnostics.add(
          .unconverted, location.appending("skillPath"),
          "Original resource coordinates are absent; supply actual installed content for capture.")
      }
      let hashField = project ? "computedHash" : "skillFolderHash"
      let hash = ImportInput.hex(ImportInput.string(entry[hashField]), count: project ? 64 : 40)
      let integrity = hash.map {
        ImportPin.Integrity(kind: project ? .vercelInstalledSHA256 : .githubTree, value: $0)
      }
      if integrity == nil {
        diagnostics.add(
          .incompletePin, location.appending(hashField),
          "Producer content integrity is missing or invalid.")
      }
      // Neither release format persists a resolved repository commit. A full-looking hash in
      // either integrity field or a requested ref cannot be promoted into that missing evidence.
      diagnostics.add(
        .incompletePin, location,
        "This lock does not prove an exact upstream repository commit; no ref is fetched.")
      let alias = "import-skill-\(index)"
      let version = ImportInput.string(entry["version"])
      if version != nil, !ImportInput.packageVersion(version) {
        diagnostics.add(
          .incompletePin, location.appending("version"),
          "Package version is not an exact semantic version.")
      }
      let upstream = canonicalSource(source: source, url: sourceURL, type: sourceType, path: path)
      if upstream == nil {
        diagnostics.add(
          .unconverted, location.appending("sourceType"),
          "Source transport cannot be represented as a canonical source without explicit content.")
      }
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: location, declaration: upstream,
          pin: .init(
            commit: nil, version: ImportInput.packageVersion(version) ? version : nil,
            integrity: integrity),
          requestedRef: ImportInput.string(entry["ref"]), producerPath: path,
          producerIdentity: source))
      for field in [
        "via", "subagents", "pluginName", "sourceBaseUrl", "wellKnownDigest", "installMode",
        "installedAt", "updatedAt",
      ] where entry[field] != nil {
        diagnostics.add(
          .unconverted, location.appending(field),
          "Producer placement, source or bookkeeping semantics require an explicit import decision."
        )
      }
      if let local = input.installedSkills[name] {
        do {
          let captured = try ImportSkillContent.read(local, input: input, limits: limits)
          diagnostics.proposal.diagnostics += captured.diagnostics
          diagnostics.proposal.bindings += captured.bindings
          if project, let hash, ImportSkillContent.vercelHash(captured) != hash {
            diagnostics.add(
              .integrityMismatch, location.appending(hashField),
              "Explicit installed content does not match the recorded installed-files hash.")
            continue
          }
          if !project {
            diagnostics.add(
              .unconverted, location.appending(hashField),
              "Captured actual local content has a SHA-256 pin; the recorded GitHub tree hash is not verified."
            )
          }
          contentAdmitted = true
          let contentAlias = alias + "-content"
          diagnostics.proposal.sources.append(
            .init(
              alias: contentAlias, origin: location,
              declaration: .init(
                kind: .local, location: captured.path,
                environment: .init(projectDirectory: input.root, homeDirectory: input.root)),
              pin: .init(commit: nil, version: nil, integrity: nil), requestedRef: nil,
              producerPath: nil))
          diagnostics.proposal.resources.append(
            .init(
              origin: location, sourceAlias: contentAlias, producerName: name, path: ".",
              producerIntegrity: integrity, observedHash: captured.hash,
              executableFlags: captured.flags, requiresStandaloneSource: true))
          diagnostics.proposal.components.append(
            .init(
              origin: location,
              declaration: .skills(
                source: contentAlias,
                .init(select: .names([captured.skill.name]), condition: captured.skill.condition))))
        } catch is CancellationError { throw CancellationError() } catch CoreError.unsafePath {
          diagnostics.add(
            .unsafePath, location, "Explicit installed content escapes its input root.")
        } catch {
          diagnostics.add(
            .missingResource, location,
            "Explicit installed content is missing, unsafe, malformed or exceeds resource limits.")
        }
      } else if let upstream {
        diagnostics.proposal.resources.append(
          .init(
            origin: location, sourceAlias: alias, producerName: name, path: upstream.path,
            producerIntegrity: integrity, observedHash: nil, executableFlags: [:],
            requiresStandaloneSource: true))
        diagnostics.proposal.components.append(
          .init(
            origin: location, declaration: .skills(source: alias, .init(select: .names([name])))))
      }
    }
    if let selection = input.selection, !selection.isSubset(of: Set(skills.keys)) {
      diagnostics.add(
        .invalidInput, origin.appending("skills"), "A selected skill is absent from this document.")
    }
  }

  private static func canonicalSource(
    source: String, url: String?, type: String, path: String?
  ) -> SourceDeclaration? {
    let location: String
    switch type {
    case "github":
      if let url {
        location = url
      } else {
        let parts = source.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ ImportInput.name(String($0)) }) else {
          return nil
        }
        location = "https://github.com/" + source
      }
    case "git":
      guard let url else { return nil }
      location = url
    default: return nil
    }
    let directory = path.map {
      $0.hasSuffix("/SKILL.md") ? String($0.dropLast(9)) : ($0 == "SKILL.md" ? "." : $0)
    }
    let declaration = SourceDeclaration(kind: .git, location: location, path: directory)
    guard (try? declaration.transportIdentity()) != nil else { return nil }
    return declaration
  }
}
