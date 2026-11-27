import AgentsCore
import Foundation
import NativeDocuments

/// Registration is the existing closed named-directory recipe. E owns reader union, all physical
/// writes, owner retirement, private receipts and publication. Members never become direct owners.
package struct NativeGeneratedPluginContribution {
  package let request: NativeComponentRequest
  package let component: String
  package let directory: String
  package let route: NativeComponentRoute
  package let manifestPath: String
  package let occurrences: [Int]
  package let recipients: [AgentID]
  package let knownReaders: [AgentID]
  package let members: [Member]
  package let resources: [String: LedgerResource]
  private let metadata: [String: NativeValue]

  package struct Member {
    package let component: String
    package let occurrences: [Int]
    package let content: Content
    package enum Content {
      case component(NativeComponentContribution)
      case mcp(NativeMCPContribution)
      case skill(name: String, resource: String)
    }
  }

  /// E materializes these exact frozen resource roots through Core, including supporting links
  /// and file modes; it admits final paths before calling stagedBundle. No copy is performed here.
  package struct ResourcePlacement {
    package let resource: String
    package let path: String
  }
  package var resourcePlacements: [ResourcePlacement] {
    let skills = members.compactMap { member -> ResourcePlacement? in
      if case .skill(let name, let resource) = member.content {
        return .init(resource: resource, path: "skills/" + name)
      }
      return nil
    }
    let skillResources = Set(skills.map(\.resource))
    return skills
      + resources.keys.sorted().filter { !skillResources.contains($0) }.map {
        .init(resource: $0, path: "resources/" + $0.replacingOccurrences(of: "sha256:", with: ""))
      }
  }

  package struct Bundle {
    /// UTF8 native files are nonexecutable. Resource modes are on the frozen resource entries.
    package let files: [String: Data]
    /// JSON document values for the existing NativeDocuments writer, including the manifest.
    package let documents: [String: NativeValue]
  }

  /// Invoke only inside D/E's private render closure. Values and intermediate bundle documents
  /// are ephemeral; never persist them in the public lowering, content store, report or hashes.
  package func stagedBundle(
    bindings: RuntimeBindingValues, environment: RuntimeEnvironment,
    resourcePaths: [String: String], budget: NativeDocumentBudget,
    cursorCommandShell: NativeProgramV1.CommandShell? = nil
  ) throws -> Bundle {
    var files: [String: Data] = [:]
    var manifest = metadata
    manifest["name"] = .string(directory)
    var hooks: [String: [NativeValue]] = [:]
    var servers: [String: NativeValue] = [:]
    var lsps: [String: NativeValue] = [:]
    var paths: [String: [NativeValue]] = [:]
    func invalid() -> CoreError { .invalidState("invalid generated native bundle composition") }
    func put(_ path: String, _ bytes: Data) throws {
      try budget.allocate(bytes.count, stage: "generated native file")
      try budget.step(bytes.count)
      guard files[path] == nil else { throw invalid() }
      files[path] = bytes
    }
    for member in members {
      try budget.step()
      switch member.content {
      case .skill(let name, _):
        paths["skills", default: []].append(.string("./skills/" + name))
      case .mcp(let contribution):
        guard servers[contribution.name] == nil else { throw invalid() }
        servers[contribution.name] = try contribution.stagedValue(
          bindings: bindings, environment: environment, resourcePaths: resourcePaths, budget: budget
        )
      case .component(let contribution):
        for output in contribution.outputs {
          switch output.content {
          case .file(let path, let bytes):
            let field = contribution.kind == .command ? "commands" : "agents"
            let relative = field + "/" + path
            try put(relative, bytes)
            paths[field, default: []].append(.string("./" + relative))
          case .hook(let hook):
            if request.surface == .cursorEditor {
              // Plugin hooks only support command handlers, regardless of standalone capability.
              let value = try hook.value.stagedValue(
                bindings: bindings, environment: environment, resourcePaths: resourcePaths,
                budget: budget, cursorCommandShell: cursorCommandShell)
              guard case .object(let handler) = value, handler["type"] == .string("command") else {
                throw invalid()
              }
              hooks[hook.event, default: []].append(value)
            } else {
              hooks[hook.event, default: []].append(
                try hook.value.stagedValue(
                  bindings: bindings, environment: environment, resourcePaths: resourcePaths,
                  budget: budget))
            }
          case .generatedLSPPlugin(_, _, let value):
            guard request.surface == .claudeCode,
              case .object(let fields) = try value.stagedValue(
                bindings: bindings, environment: environment, resourcePaths: resourcePaths,
                budget: budget),
              case .object(let entries) = fields["lspServers"]
            else { throw invalid() }
            for (name, server) in entries {
              guard lsps[name] == nil else { throw invalid() }
              lsps[name] = server
            }
          default: throw invalid()
          }
        }
      }
    }
    var documents: [String: NativeValue] = [:]
    if !hooks.isEmpty {
      var value: [String: NativeValue] = ["hooks": .object(hooks.mapValues(NativeValue.array))]
      if request.surface == .cursorEditor { value["version"] = .integer(1) }
      if request.surface == .claudeCode {
        manifest["hooks"] = .object(hooks.mapValues(NativeValue.array))
      } else {
        documents["hooks/hooks.json"] = .object(value)
        if request.surface == .cursorEditor { manifest["hooks"] = .string("./hooks/hooks.json") }
      }
    }
    if !servers.isEmpty {
      if request.surface == .cursorEditor {
        documents["mcp.json"] = .object(["mcpServers": .object(servers)])
        manifest["mcpServers"] = .string("./mcp.json")
      } else {
        manifest["mcpServers"] = .object(servers)
      }
    }
    if !lsps.isEmpty { manifest["lspServers"] = .object(lsps) }
    if request.surface != .geminiCLI {
      for (field, values) in paths { manifest[field] = .array(values) }
    }
    documents[manifestPath] = .object(manifest)
    return .init(files: files, documents: documents)
  }

  package static func decode(
    _ lowering: LockedLowering, ledger: ResolvedLedger, artifacts: [ReplayedArtifact],
    limits: LedgerLimits
  ) throws -> NativeGeneratedPluginContribution {
    let (input, nested, owners) = try NativeGeneratedPluginLayoutV1.decode(
      lowering, ledger: ledger, limits: limits)
    func invalid() -> CoreError {
      .invalidState("invalid sealed generated native plugin contribution")
    }
    guard ledger.lowerings.filter({ $0.id == lowering.id }) == [lowering],
      lowering.artifacts.count == 1, artifacts.count == 1, artifacts[0].name == lowering.id,
      artifacts[0].kind == .ownedValues, artifacts[0].location == nil,
      let values = artifacts[0].values?.object?["members"]?.array, values.count == nested.count
    else { throw invalid() }
    try admit(artifacts[0].values!, budget: input.budget)
    guard try artifacts[0].digest(limits: limits) == lowering.artifacts[0],
      try ResolvedLedgerCodec.bytes(artifacts[0].values!)
        == ResolvedLedgerCodec.bytes(
          NativeGeneratedPluginLayoutV1.envelope(input, members: values))
    else { throw invalid() }
    let (route, manifest) = try NativeGeneratedPluginLayoutV1.recipe(input)
    let directory = try input.filename()
    if input.request.surface == .claudeCode, !NativePluginFieldsV1.validClaudeName(directory) {
      throw invalid()
    }
    if input.request.surface == .cursorEditor,
      directory.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression)
        == nil
    {
      throw invalid()
    }
    if input.request.surface == .geminiCLI,
      directory.range(of: #"^[a-zA-Z0-9-]+$"#, options: .regularExpression) == nil
    {
      throw invalid()
    }
    let metadataFields = try input.checkedNative(["version": .string, "description": .string])
    if input.request.surface == .geminiCLI, metadataFields["version"]?.text?.isEmpty != false {
      throw input.issue(
        ["native", "gemini-cli", "version"], .integrationRequired,
        "generated Gemini extensions require explicit frozen native version metadata")
    }
    var metadata: [String: NativeValue] = [:]
    for (key, value) in metadataFields { metadata[key] = .string(value.text!) }
    if input.request.surface != .geminiCLI {
      _ = try NativeComponentFieldsV1.plugin(
        surface: input.request.surface, document: manifest,
        fields: metadata.merging(["name": .string(directory)]) { value, _ in value },
        entries: [], documents: [:], budget: input.budget)
    }
    var members: [Member] = []
    var names = Set<Data>()
    var nativeNames = Set<String>()
    for (index, var child) in nested.enumerated() {
      let component = child.inputs[0]
      let record = ledger.components[component]!
      let identity = record.kind + "/" + record.name
      guard names.insert(Data(identity.utf8)).inserted, nativeNames.insert(identity).inserted else {
        throw input.issue(
          ["children"], .invalid, "native member identities conflict in the generated container")
      }
      let content: Member.Content
      if record.kind == "skills" {
        guard
          record.payload.object?["native"]?.object?[input.request.surface.agent.rawValue]?.object?
            .isEmpty ?? true
        else {
          throw input.issue(
            ["children", "skills", "native"], .unverified,
            "native skill options require their exact container interpretation")
        }
        guard values[index] == .init(), !record.name.isEmpty,
          !record.name.contains("/"), !record.name.contains("\\"), record.name != ".",
          record.name != ".."
        else { throw invalid() }
        content = .skill(name: record.name, resource: record.resources[0])
      } else if record.kind == "mcpServer" {
        guard values[index] == child.layout else { throw invalid() }
        content = .mcp(try MCPLayoutV1.contribution(child, ledger: ledger))
      } else {
        let output = ReplayedArtifact(name: child.id, kind: .ownedValues, values: values[index])
        child.artifacts = [try output.digest(limits: limits)]
        var childLedger = ledger
        childLedger.lowerings = [child]
        let contribution = try NativeComponentLayoutsV1.contribution(
          child, ledger: childLedger, artifacts: [output], limits: limits)
        content = .component(contribution)
      }
      members.append(.init(component: component, occurrences: owners[index], content: content))
    }
    var readers: Set<AgentID> = [input.request.surface.agent]
    for member in members {
      if case .component(let contribution) = member.content {
        readers.formUnion(contribution.knownReaders)
      } else if case .mcp(let contribution) = member.content {
        readers.formUnion(contribution.descriptor.knownReaders)
      }
    }
    return .init(
      request: input.request, component: input.component, directory: directory, route: route,
      manifestPath: manifest, occurrences: input.occurrences,
      recipients: [input.request.surface.agent],
      knownReaders: readers.sorted { $0.rawValue < $1.rawValue }, members: members,
      resources: Dictionary(
        uniqueKeysWithValues: lowering.resources.map { ($0, ledger.resources[$0]!) }),
      metadata: metadata)
  }

  static func admit(_ value: LedgerValue, budget: NativeDocumentBudget, depth: Int = 0) throws {
    try budget.node(depth: depth)
    try budget.step()
    if let text = value.text {
      try budget.allocate(text.utf8.count, stage: "generated native input")
      try budget.step(text.utf8.count)
    }
    for child in value.array ?? [] { try admit(child, budget: budget, depth: depth + 1) }
    for (key, child) in value.object ?? [:] {
      try budget.allocate(key.utf8.count, stage: "generated native key")
      try budget.step(key.utf8.count)
      try admit(child, budget: budget, depth: depth + 1)
    }
    var node = value
    if node.array != nil { node.array = [] }
    if node.object != nil { node.object = [:] }
    try node.validate()
  }
}
