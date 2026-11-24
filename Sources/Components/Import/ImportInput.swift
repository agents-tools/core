import AgentsCore
import CoreFoundation
import Foundation

/// Strict JSON admission reuses Core's duplicate-key and grammar checks before Foundation decoding.
/// An array envelope keeps ledger-specific top-level content decoding out of producer documents.
/// Entry counting remains bounded by the same aggregate node limit for every producer field.
enum ImportInput {
  static func document(_ input: SourceImportInput, limits: SourceImportLimits) throws -> [String:
    Any]
  {
    let bytes = try bytes(input, limits: limits)
    try LedgerAdmission.check(
      Data([91]) + bytes + Data([93]),
      limits: .init(
        encodedBytes: limits.documentBytes + 2, depth: limits.depth + 1, nodes: limits.nodes + 1,
        objectBytes: limits.documentBytes, entries: limits.nodes, keyBytes: limits.documentBytes))
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw ImportReadFailure.invalid
    }
    return object
  }

  static func bytes(_ input: SourceImportInput, limits: SourceImportLimits) throws -> Data {
    guard limits.documentBytes >= 0, limits.documentBytes <= Int.max - 2,
      limits.depth > 0, limits.depth < Int.max, limits.nodes > 0, limits.nodes < Int.max
    else { throw ImportReadFailure.invalid }
    let view = try snapshot(input.root)
    let file = try view.resource(input.document)
    let info = try FileManager.default.attributesOfItem(atPath: file.path)
    guard info[.type] as? FileAttributeType == .typeRegular,
      let size = (info[.size] as? NSNumber)?.intValue,
      size <= limits.documentBytes
    else { throw ImportReadFailure.invalid }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: limits.documentBytes + 1) ?? Data()
    guard bytes.count <= limits.documentBytes,
      (try handle.read(upToCount: 1) ?? Data()).isEmpty
    else { throw ImportReadFailure.invalid }
    return bytes
  }

  static func snapshot(_ root: URL) throws -> SourceSnapshot {
    guard root.isFileURL else { throw ImportReadFailure.invalid }
    return try SourceSnapshot(
      snapshot: .init(source: "explicit-import", revision: "local"), pin: nil, root: root)
  }

  static func string(_ value: Any?) -> String? { value as? String }

  static func version(_ value: Any?, equals expected: Int) -> Bool {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
      return false
    }
    return value.stringValue == String(expected)
  }

  static func strings(_ value: Any?) -> [String]? {
    guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return nil }
    return list.map { $0 as! String }
  }

  static func name(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
      && !value.contains("/") && !value.contains("\\")
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  static func packageVersion(_ value: String?) -> Bool {
    guard let value else { return false }
    guard
      value.range(
        of:
          #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#,
        options: .regularExpression) != nil
    else { return false }
    let build = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    if build.count == 2,
      build[1].split(separator: ".", omittingEmptySubsequences: false).contains("")
    {
      return false
    }
    let prerelease = build[0].split(separator: "-", maxSplits: 1)
    if prerelease.count == 2 {
      for item in prerelease[1].split(separator: ".", omittingEmptySubsequences: false) {
        if item.isEmpty
          || (item.utf8.allSatisfy { (48...57).contains($0) } && item.count > 1
            && item.first == "0")
        {
          return false
        }
      }
    }
    return true
  }

  static func path(_ value: String) throws -> String {
    guard !value.hasPrefix("~"), !value.contains("\\"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw ImportReadFailure.invalid }
    return try PathSafety.sanitizeSubpath(value)
  }

  static func hex(_ value: String?, count: Int) -> String? {
    guard let value, value.utf8.count == count,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    return value
  }

  static func credentialField(_ name: String) -> Bool {
    let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
    return [
      "env", "headers", "token", "password", "credentials", "auth", "apikey", "accesstoken",
      "secret", "authorization", "clientsecret",
    ].contains(normalized)
  }

  /// Source URL credentials and query tokens become local binding requirements, never provenance.
  static func safeLocator(_ value: String) -> Bool {
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !value.contains("?"), !value.contains("#")
    else { return false }
    if value.contains("://") {
      guard let url = URLComponents(string: value),
        url.user == nil || (url.scheme == "ssh" && url.user == "git"), url.password == nil
      else {
        return false
      }
    } else if value.contains("@") {
      // SCP-style git@host:path is a transport username; arbitrary userinfo is not.
      return value.hasPrefix("git@") && value.contains(":")
    }
    return true
  }
}

enum ImportReadFailure: Error { case invalid }

struct ImportDiagnostics {
  var proposal: SourceImportProposal
  var bindingReferences: [String: RuntimeBinding] = [:]
  var resolvedBindings: Set<ImportLocation> = []

  struct CanonicalAttempt {
    let components: Int
    let slots: Set<ImportLocation>
    let resolved: Set<ImportLocation>
  }

  func beginCanonicalAttempt() -> CanonicalAttempt {
    .init(
      components: proposal.components.count,
      slots: Set(proposal.bindings.filter(\.canonicalSlot).map(\.location)),
      resolved: resolvedBindings)
  }

  mutating func endCanonicalAttempt(_ attempt: CanonicalAttempt) {
    guard proposal.components.count <= attempt.components else { return }
    for index in proposal.bindings.indices
    where !attempt.slots.contains(proposal.bindings[index].location) {
      proposal.bindings[index].canonicalSlot = false
    }
    resolvedBindings = attempt.resolved
  }

  struct ChoiceCapture {
    let index: Int
    let components: Int
    let sources: Int
    let resources: Int
    let diagnostics: Int
  }

  mutating func beginChoice(_ key: String, at location: ImportLocation) -> ChoiceCapture {
    let index: Int
    if let found = proposal.choices.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
      index = found
      if !proposal.choices[index].locations.contains(location) {
        proposal.choices[index].locations.append(location)
      }
    } else {
      index = proposal.choices.count
      proposal.choices.append(.init(key: key, locations: [location]))
    }
    return .init(
      index: index, components: proposal.components.count, sources: proposal.sources.count,
      resources: proposal.resources.count, diagnostics: proposal.diagnostics.count)
  }

  mutating func endChoice(_ capture: ChoiceCapture) {
    proposal.choices[capture.index].components += Array(
      capture.components..<proposal.components.count)
    proposal.choices[capture.index].sources += Array(capture.sources..<proposal.sources.count)
    proposal.choices[capture.index].resources += Array(capture.resources..<proposal.resources.count)
    proposal.choices[capture.index].diagnostics += Array(
      capture.diagnostics..<proposal.diagnostics.count)
  }

  mutating func requireInput(
    _ kind: ImportInputMetadata.Kind, key: String, at location: ImportLocation
  ) {
    let value = ImportInputMetadata(kind: kind, key: key, location: location)
    if !proposal.requiredInputs.contains(value) { proposal.requiredInputs.append(value) }
  }

  mutating func finalizeBindings() {
    proposal.bindings.removeAll { resolvedBindings.contains($0.location) }
    for requirement in proposal.bindings {
      if !proposal.diagnostics.contains(where: {
        $0.code == .credentialBinding && $0.location == requirement.location
      }) {
        add(
          .credentialBinding, requirement.location,
          "Credential literals cannot be retained in import proposals.")
      }
    }
  }

  mutating func add(
    _ code: SourceImportDiagnostic.Code, _ location: ImportLocation, _ message: String
  ) {
    proposal.diagnostics.append(.init(code: code, location: location, message: message))
  }

  mutating func unknown(_ fields: [String: Any], allowed: Set<String>, at location: ImportLocation)
  {
    for (index, field) in fields.keys.sorted().enumerated() where !allowed.contains(field) {
      let child = location.appending("member[\(index)]")
      if ImportInput.credentialField(field) { binding(child) }
      unconverted(fields[field]!, at: child)
    }
  }

  private mutating func unconverted(_ value: Any, at location: ImportLocation) {
    add(.unconverted, location, "Unrecognized field or item is not converted.")
    if let fields = value as? [String: Any] {
      for (index, field) in fields.keys.sorted().enumerated() {
        let child = location.appending("member[\(index)]")
        if ImportInput.credentialField(field) { binding(child) }
        unconverted(fields[field]!, at: child)
      }
    } else if let items = value as? [Any] {
      for (index, item) in items.enumerated() {
        unconverted(item, at: location.appending(String(index)))
      }
    } else if let value = value as? String, value.contains("://"), !ImportInput.safeLocator(value) {
      binding(location)
    }
  }

  mutating func typedFields(
    _ fields: [String: Any], strings: Set<String>, required: Set<String> = [],
    arrays: Set<String> = [], at location: ImportLocation
  ) -> Bool {
    var valid = true
    for field in strings.sorted() where fields[field] != nil || required.contains(field) {
      if ImportInput.string(fields[field]) == nil {
        add(.invalidInput, location.appending(field), "Expected a string field.")
        valid = false
      }
    }
    for field in arrays.sorted() where fields[field] != nil {
      if ImportInput.strings(fields[field]) == nil {
        add(.invalidInput, location.appending(field), "Expected an array of strings.")
        valid = false
      }
    }
    return valid
  }

  mutating func binding(_ location: ImportLocation, environmentVariable: String? = nil) {
    if environmentVariable == nil, !proposal.preservationBindings.contains(location) {
      proposal.preservationBindings.append(location)
    }
    guard !proposal.bindings.contains(where: { $0.location == location }) else { return }
    proposal.bindings.append(
      .init(
        location: location, reason: "Credential-bearing input requires an explicit local binding.",
        environmentVariable: environmentVariable)
    )
  }
}
