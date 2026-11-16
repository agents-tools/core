import AgentsCore
import Foundation
import NativeDocuments

/// An operation-local reader. Native bytes and parser observations never enter the proposal.
struct NativeImportDocument {
  let input: SourceImportInput
  let bytes: Data
  let document: NativeDocument
  let fields: [String: NativeValue]
  let admission: NativeImportBudget

  init(
    _ input: SourceImportInput, format: NativeDocumentFormat, limits: SourceImportLimits,
    admission: NativeImportBudget? = nil
  ) throws {
    let bytes = try ImportInput.bytes(input, limits: limits)
    let admission = try admission ?? NativeImportBudget(limits)
    try admission.document(bytes, path: input.document)
    let budget = admission.parser
    do {
      let document = try NativeDocument(bytes: bytes, format: format, budget: budget)
      guard let observation = try document.read(.init(keys: [])),
        observation.projectionFailure == nil, case .object(let fields) = observation.value
      else { throw ImportReadFailure.invalid }
      self.input = input
      self.bytes = bytes
      self.document = document
      self.fields = fields
      self.admission = admission
    } catch NativeDocumentError.cancelled {
      throw CancellationError()
    } catch NativeDocumentError.invalidDocument(_, let range) {
      throw ImportLocatedFailure(
        location: .init(
          document: input.document, pointer: "",
          span: range.map { importSpan(bytes, document: input.document, range: $0) }))
    }
  }

  func location(_ keys: [String] = [], display: String? = nil) -> ImportLocation {
    let observation = try? document.read(.init(keys: keys))
    var range = observation?.valueRange ?? observation?.entryRanges.first
    if range == nil, let fields = observation?.value?.importObject {
      for key in fields.keys.sorted() {
        if let found = (try? document.read(.init(keys: keys + [key])))?.valueRange {
          range = found
          break
        }
      }
    }
    return .init(
      document: input.document, pointer: display ?? keys.map { "/" + $0 }.joined(),
      span: range.map { importSpan(bytes, document: input.document, range: $0) })
  }
}

enum NativeImportInput {
  static func agent(_ profile: SourceImportProfile) -> AgentID {
    switch profile {
    case .codexConfigV1: .codex
    case .cursorMCPV1, .cursorPluginV1, .cursorCommandV1, .cursorAgentV1, .cursorIgnoreV1: .cursor
    case .geminiSettingsV1, .geminiExtensionV1, .geminiCommandV1, .geminiAgentV1, .geminiIgnoreV1:
      .geminiCLI
    case .openCodeConfigV2, .openCodeCommandV2, .openCodeAgentV2: .opencode
    default: .claudeCode
    }
  }

  static func name(_ text: String) -> Bool {
    ImportInput.name(text) && !text.contains("://")
  }

  static func unknown(
    _ fields: [String: NativeValue], allowed: Set<String>, at origin: ImportLocation,
    into diagnostics: inout ImportDiagnostics
  ) {
    for (index, key) in fields.keys.sorted().enumerated() where !allowed.contains(key) {
      let location = origin.appending("member[\(index)]")
      if ImportInput.credentialField(key) { diagnostics.binding(location) }
      unconverted(fields[key]!, at: location, into: &diagnostics)
    }
  }

  static func unconverted(
    _ value: NativeValue, at location: ImportLocation,
    into diagnostics: inout ImportDiagnostics
  ) {
    diagnostics.add(
      .unconverted, location,
      "Native field requires an explicit semantic conversion; it is not imported.")
    switch value {
    case .object(let fields):
      for (index, key) in fields.keys.sorted().enumerated() {
        let child = location.appending("member[\(index)]")
        if ImportInput.credentialField(key) { diagnostics.binding(child) }
        unconverted(fields[key]!, at: child, into: &diagnostics)
      }
    case .array(let values):
      for (index, value) in values.enumerated() {
        unconverted(value, at: location.appending(String(index)), into: &diagnostics)
      }
    case .string(let text) where text.contains("://") && !ImportInput.safeLocator(text):
      diagnostics.binding(location)
    default: break
    }
  }

  static func sensitive(
    _ value: NativeValue, at location: ImportLocation, into diagnostics: inout ImportDiagnostics
  ) -> Bool {
    var found = false
    if let fields = value.importObject {
      for (index, key) in fields.keys.sorted().enumerated() {
        let item = location.appending("member[\(index)]")
        if ImportInput.credentialField(key) {
          diagnostics.binding(item)
          found = true
        }
        if sensitive(fields[key]!, at: item, into: &diagnostics) { found = true }
      }
    } else if case .array(let values) = value {
      for (index, value) in values.enumerated() {
        if sensitive(value, at: location.appending(String(index)), into: &diagnostics) {
          found = true
        }
      }
    } else if let string = value.importString, string.contains("://"),
      !ImportInput.safeLocator(string)
    {
      diagnostics.binding(location)
      found = true
    }
    return found
  }

  static func binding(
    _ location: ImportLocation, environment: String? = nil,
    into diagnostics: inout ImportDiagnostics
  ) -> RuntimeBinding {
    let key =
      "import-" + FileHash.sha256Hex(data: Data((location.document + "\0" + location.pointer).utf8))
    diagnostics.binding(location, environmentVariable: environment)
    if let index = diagnostics.proposal.bindings.firstIndex(where: { $0.location == location }) {
      diagnostics.proposal.bindings[index].key = key
    }
    return environment.map(RuntimeBinding.environment) ?? .secret(key)
  }

  static func bindings(
    _ value: NativeValue?, at location: ImportLocation, symbolic: Bool = false,
    into diagnostics: inout ImportDiagnostics, profile: SourceImportProfile? = nil
  ) throws -> [String: RuntimeBinding] {
    guard let value else { return [:] }
    guard case .object(let fields) = value else { throw ImportReadFailure.invalid }
    var result: [String: RuntimeBinding] = [:]
    for (index, key) in fields.keys.sorted().enumerated() {
      let item = location.appending("member[\(index)]")
      guard name(key), let text = fields[key]?.importString else { throw ImportReadFailure.invalid }
      if symbolic {
        guard MCPReferenceSyntax.isName(text)
        else { throw ImportReadFailure.invalid }
        result[key] = binding(item, environment: text, into: &diagnostics)
      } else {
        var reference: String?
        if let profile {
          let client = agent(profile)
          if [.claudeCode, .geminiCLI].contains(client), text.hasPrefix("${"), text.hasSuffix("}") {
            reference = String(text.dropFirst(2).dropLast())
          } else if client == .opencode, text.hasPrefix("{env:"), text.hasSuffix("}") {
            reference = String(text.dropFirst(5).dropLast())
          }
        }
        if let reference,
          MCPReferenceSyntax.isName(reference)
        {
          result[key] = binding(item, environment: reference, into: &diagnostics)
        } else if text.contains("${") || text.contains("{env:") || text.contains("{file:") {
          diagnostics.binding(item)
          diagnostics.add(
            .unconverted, item,
            "Native interpolation is not a single admitted symbolic environment reference.")
          throw ImportReadFailure.invalid
        } else {
          result[key] = binding(item, into: &diagnostics)
        }
      }
    }
    return result
  }

  static func source(
    _ input: SourceImportInput, root: String, origin: ImportLocation,
    into diagnostics: inout ImportDiagnostics
  ) -> String {
    let alias = "native-input"
    if !diagnostics.proposal.sources.contains(where: { $0.alias == alias }) {
      diagnostics.proposal.sources.append(
        .init(
          alias: alias, origin: origin,
          declaration: .init(
            kind: .local, location: root,
            environment: .init(projectDirectory: input.root, homeDirectory: input.root)),
          pin: .init(), requestedRef: nil, producerPath: root))
    }
    return alias
  }

  static func emit(
    _ declaration: ComponentDeclaration, selector: ComponentReferenceDeclaration,
    origin: ImportLocation, container: String, profile: SourceImportProfile,
    into diagnostics: inout ImportDiagnostics, admission: NativeImportBudget? = nil
  ) {
    let member = ImportMemberCoordinate(
      containerRoot: container, selector: selector,
      profile: profile, formatVersion: 1)
    guard admission?.ambiguousMembers.contains(member) != true,
      !diagnostics.proposal.components.contains(where: { $0.member == member })
    else {
      diagnostics.proposal.components.removeAll { $0.member == member }
      admission?.ambiguousMembers.append(member)
      diagnostics.add(
        .ambiguousSource, origin, "Two native declarations have the same typed member identity.")
      return
    }
    diagnostics.proposal.components.append(
      .init(origin: origin, declaration: declaration, member: member))
  }

  static func resource(
    _ path: String, root: String, input: SourceImportInput,
    origin: ImportLocation, limits: SourceImportLimits, rewrite: Bool = false,
    into diagnostics: inout ImportDiagnostics, admission: NativeImportBudget? = nil
  ) throws {
    let root = try ImportInput.path(root)
    let path = try ImportInput.path(path)
    let relative = root == "." ? path : root + (path == "." ? "" : "/" + path)
    let snapshot = try ImportInput.snapshot(input.root)
    let url = try snapshot.resource(relative)
    try admission?.resource(url, snapshot: snapshot)
    let needsRewrite =
      rewrite
      || diagnostics.proposal.bindings.contains {
        $0.location.document == relative || $0.location.document.hasPrefix(relative + "/")
          || relative == "."
      }
    let frozen = try LedgerResources.capture(
      url, embed: false,
      limits: .init(
        encodedBytes: limits.resourceBytes, depth: limits.depth, nodes: limits.nodes,
        objectBytes: limits.resourceBytes, entries: limits.resourceEntries,
        keyBytes: limits.resourceBytes, resourceBytes: limits.resourceBytes),
      sourceRoot: try snapshot.resource(root))
    for entry in frozen.support {
      let supportPath = root == "." ? entry.path : root + "/" + entry.path
      try admission?.resource(try snapshot.resource(supportPath), snapshot: snapshot)
    }
    let alias = source(input, root: root, origin: origin, into: &diagnostics)
    diagnostics.proposal.resources.append(
      .init(
        origin: origin, sourceAlias: alias,
        producerName: url.lastPathComponent, path: path, producerIntegrity: nil,
        observedHash: needsRewrite ? nil : frozen.hash, executableFlags: frozen.flags,
        requiresStandaloneSource: true, requiresBindingRewrite: needsRewrite))
    // Support targets remain separate resources relative to the same native-format root.
    for entry in frozen.support where entry.kind == .file {
      diagnostics.proposal.resources.append(
        .init(
          origin: origin, sourceAlias: alias,
          producerName: URL(fileURLWithPath: entry.path).lastPathComponent, path: entry.path,
          producerIntegrity: nil, observedHash: nil,
          executableFlags: [entry.path: entry.executable],
          requiresStandaloneSource: true, requiresBindingRewrite: needsRewrite))
    }
  }
}

/// Shared only within one bounded import operation; no bytes or state escape in a proposal.
final class NativeImportBudget {
  let parser: NativeDocumentBudget
  private let limits: SourceImportLimits
  private var documentBytes: Int
  private var resourceBytes: Int
  private var entries: Int
  var ambiguousMembers: [ImportMemberCoordinate] = []
  var memberOccurrences: [String: Int] = [:]
  private var documents: Set<String> = []
  private var resources: Set<String> = []

  init(_ limits: SourceImportLimits) throws {
    guard limits.documentBytes >= 0, limits.documentBytes <= (Int.max - 1024) / 64,
      limits.resourceBytes >= 0, limits.resourceEntries > 0, limits.depth > 0, limits.nodes > 0
    else { throw ImportReadFailure.invalid }
    self.limits = limits
    documentBytes = limits.documentBytes
    resourceBytes = limits.resourceBytes
    entries = limits.resourceEntries
    parser = .init(
      limits: .init(
        storage: limits.documentBytes * 32 + 1024,
        work: limits.documentBytes * 64 + 1024, nodes: limits.nodes, depth: limits.depth,
        uninterruptedBytes: limits.documentBytes))
  }

  func document(_ bytes: Data, path: String) throws {
    if documents.insert(path).inserted {
      guard bytes.count <= documentBytes else { throw ImportReadFailure.invalid }
      documentBytes -= bytes.count
    }
  }

  func resource(_ url: URL, snapshot: SourceSnapshot) throws {
    func admit(_ file: URL) throws {
      try Task.checkCancellation()
      let path = try snapshot.relativePath(file)
      guard !resources.contains(path) else { return }
      guard entries > 0, path.split(separator: "/").count <= limits.depth else {
        throw ImportReadFailure.invalid
      }
      let info = try FileManager.default.attributesOfItem(atPath: file.path)
      if info[.type] as? FileAttributeType == .typeRegular {
        guard let size = (info[.size] as? NSNumber)?.intValue, size >= 0, size <= resourceBytes
        else { throw ImportReadFailure.invalid }
        resourceBytes -= size
      } else if ![FileAttributeType.typeDirectory, .typeSymbolicLink].contains(
        info[.type] as? FileAttributeType ?? .typeUnknown)
      {
        throw ImportReadFailure.invalid
      }
      resources.insert(path)
      entries -= 1
    }
    try admit(url)
    let info = try FileManager.default.attributesOfItem(atPath: url.path)
    if info[.type] as? FileAttributeType == .typeDirectory {
      guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
      else { throw ImportReadFailure.invalid }
      for case let file as URL in walk { try admit(file) }
    }
  }
}
