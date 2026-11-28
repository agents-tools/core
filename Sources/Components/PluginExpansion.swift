import AgentsCore
import Foundation

extension Expansion {
  func plugin(
    _ declaration: ComponentDeclaration, context: LinkingDocument, group: String?,
    condition: DeclarationCondition, chain: [SourceSpan], position: SourceMapEntry?,
    dependencies: [SourceSnapshotID]
  ) throws {
    guard
      case .plugin(
        let name, let path, let alias, let mode, let select, let exclude,
        let agents, let authoredCondition, let authoredNative) = declaration
    else { return }
    guard active.count + pluginDepth < 64 else { throw LinkError.budget("active references") }
    let componentKey = key(name, kind: .plugin, context: context, group: group)
    let address = try linking.address(alias, in: context, chain: chain)
    let view: SourceSnapshot
    if linking.directPins[componentKey] == nil,
      let selected = try linking.view(address, pin: choices[address.id])
    {
      view = selected
    } else {
      view = try selectedView(address, key: componentKey)
    }
    let container = try view.relativePath(
      PathSafety.resolvedChild(base: view.directory(), subpath: path))
    let recipients = condition.recipients(
      requested: agents ?? context.declaration.defaultAgents,
      scope: linking.store.scope, platform: linking.platform)
    if mode == .native {
      guard recipients.count == 1, select == nil, exclude.isEmpty else {
        throw LinkError.invalid("native plugin requires one recipient and no filters", chain)
      }
      try append(
        key: componentKey, snapshot: view.snapshot, pin: view.pin,
        payload: .declaration(declaration), context: context, group: group,
        condition: condition, recipients: recipients, chatGPT: false,
        resources: [resource(path, in: view, chain: chain)], chain: chain, position: position,
        dependencies: dependencies + [view.snapshot])
      return
    }
    let profiles: [(SourceImportProfile, String)] = [
      (.claudePluginV1, ".claude-plugin/plugin.json"),
      (.cursorPluginV1, ".cursor-plugin/plugin.json"),
      (.geminiExtensionV1, "gemini-extension.json"),
    ]
    let entries = try profiles.compactMap { profile, suffix -> (SourceImportProfile, String)? in
      let document = container == "." ? suffix : container + "/" + suffix
      let file = try view.resource(document)
      return FileManager.default.fileExists(atPath: file.path) ? (profile, document) : nil
    }
    guard entries.count == 1, let (profile, document) = entries.first else {
      throw LinkError.invalid("plugin requires one supported native container manifest", chain)
    }
    let proposal = try SourceImport.preview(
      .init(profile: profile, root: view.root, document: document))
    if let failure = proposal.diagnostics.first(where: {
      ![.unconverted, .credentialBinding].contains($0.code)
    }) {
      throw LinkError.invalid(
        "native plugin \(failure.code.rawValue) at \(failure.location.document)\(failure.location.pointer)",
        chain)
    }
    var effective = declaration
    if profile == .geminiExtensionV1, let metadata = proposal.packageMetadata {
      guard let version = metadata.version, let versionLocation = metadata.versionLocation,
        proposal.profile == profile,
        [metadata.nameLocation, versionLocation].allSatisfy({
          $0.document.utf8.elementsEqual(document.utf8)
            && $0.span?.document.rawValue.utf8.elementsEqual(document.utf8) == true
        })
      else {
        throw LinkError.invalid("native package metadata has different producer coordinates", chain)
      }
      if authoredNative[AgentID.geminiCLI.rawValue]?["version"] == nil {
        var native = authoredNative
        native[AgentID.geminiCLI.rawValue, default: [:]]["version"] = .string(version)
        effective = .plugin(
          name: name, path: path, source: alias, mode: mode, select: select, exclude: exclude,
          agents: agents, condition: authoredCondition, native: native)
      }
    }
    // G's aliases are read coordinates in the already selected immutable producer tree.
    var aliases: [String: SourceSnapshot] = [:]
    for source in proposal.sources {
      try linking.budget.step()
      guard source.declaration?.kind == .local, let path = source.producerPath else {
        throw LinkError.invalid("native member has no contained producer coordinates", chain)
      }
      aliases[source.alias] = try SourceSnapshot(
        snapshot: view.snapshot, pin: view.pin, root: view.root, discoveryPath: path,
        packageIdentity: view.packageIdentity)
    }
    let namespace = pluginFrame?.root ?? view.discoveryPath
    let input = LedgerInputProvenance(
      format: "native/" + profile.rawValue + "@1", adapterVersion: "1")
    let parentIndex = components.count
    let parent = nextOccurrence
    try append(
      key: componentKey, snapshot: view.snapshot, pin: view.pin,
      payload: .declaration(effective), context: context, group: group,
      condition: condition, recipients: recipients, chatGPT: false, resources: [],
      chain: chain, position: position, dependencies: dependencies + [view.snapshot])
    let actualRecipients = components[parentIndex].origins[0].recipients
    components[parentIndex].origins[0].pluginExpansion = LinkedPluginExpansion(
      snapshot: view.snapshot, root: namespace, containerRoot: container,
      document: document, input: input, children: [])
    let previous = pluginFrame
    pluginDepth += 1
    defer {
      pluginFrame = previous
      pluginDepth -= 1
    }
    let childView = try SourceSnapshot(
      snapshot: view.snapshot, pin: view.pin, root: view.root,
      discoveryPath: container, packageIdentity: view.packageIdentity)
    var childContext = LinkingDocument(
      declaration: context.declaration, document: context.document,
      view: childView, manifestPath: document, producer: true)
    childContext.importedSources = aliases
    var documents = Set<Data>()
    for path in [document] + proposal.components.map({ $0.origin.document })
      + proposal.resources.map({ $0.origin.document })
    where documents.insert(Data(path.utf8)).inserted {
      let bytes = try Data(contentsOf: view.resource(path))
      try linking.budget.manifest(view.snapshot, path: path, bytes: bytes.count)
    }
    let exclusions = try Set(
      exclude.map {
        try linking.budget.step()
        return try ResolvedLedgerCodec.bytes(LedgerPayload.reference($0))
      })
    var resourcesByDocument: [Data: [ImportResourceProposal]] = [:]
    for resource in proposal.resources {
      try linking.budget.step()
      resourcesByDocument[Data(resource.origin.document.utf8), default: []].append(resource)
    }
    var selectors = Set<Data>()
    for child in proposal.components {
      if child.declaration.kind == .skills {
        try linking.budget.step()
      } else {
        try spendNativeValue(LedgerPayload.component(child.declaration))
      }
      guard let coordinate = child.member,
        coordinate.containerRoot.utf8.elementsEqual(container.utf8)
      else {
        throw LinkError.invalid("native member lacks container coordinates", chain)
      }
      let selector = LedgerPayload.reference(coordinate.selector)
      let bytes = try ResolvedLedgerCodec.bytes(selector)
      guard selectors.insert(bytes).inserted else {
        throw LinkError.invalid("duplicate native member selector", chain)
      }
      guard select?.contains(child.declaration.kind) ?? true, !exclusions.contains(bytes)
      else { continue }
      pluginFrame = PluginFrame(
        parent: parent, selector: coordinate.selector,
        root: namespace, containerRoot: container, origin: child.origin,
        input: .init(
          format: "native/" + coordinate.profile.rawValue + "@" + String(coordinate.formatVersion),
          adapterVersion: "1",
          pointer: child.origin.pointer), recipients: actualRecipients)
      let condition = condition.intersecting(child.declaration.condition ?? .init())
      let start = components.count
      try emitComponent(
        child.declaration, in: childContext, group: nil, condition: condition,
        chain: chain,
        position: child.origin.span.map {
          SourceMapEntry(pointer: child.origin.pointer, span: $0, origins: [], defaulted: false)
        }, dependencies: dependencies + [view.snapshot])
      // Literal prompt payloads retain their selected safe native input, never a raw bundle.
      if [.command, .subagent].contains(child.declaration.kind) {
        let selected = (resourcesByDocument[Data(child.origin.document.utf8)] ?? []).filter {
          ($0.kind == nil || $0.kind == child.declaration.kind) && !$0.requiresBindingRewrite
        }
        for entry in selected {
          guard let path = entry.path, let source = aliases[entry.sourceAlias] else {
            throw LinkError.invalid("native member resource lacks producer coordinates", chain)
          }
          let resource = try resource(path, in: source, chain: chain)
          for index in start..<components.count {
            if !components[index].resources.contains(resource) {
              components[index].resources.append(resource)
            }
          }
        }
      }
    }
    components[parentIndex].origins[0].pluginExpansion?.children = pluginChildren[parent] ?? []
  }

  private func spendNativeValue(_ value: LedgerValue) throws {
    var pending = [value]
    while let value = pending.popLast() {
      try linking.budget.step()
      pending += value.array ?? []
      pending += value.object.map { Array($0.values) } ?? []
    }
  }

  /// Native resource payloads use the same snapshot-relative coordinates as their frozen bytes.
  func resolvedNativeResources(_ declaration: ComponentDeclaration, context: LinkingDocument) throws
    -> ComponentDeclaration
  {
    guard pluginFrame != nil else { return declaration }
    func path(_ value: ResourceDeclaration) throws -> ResourceDeclaration {
      let address = try linking.address(value.source, in: context, chain: [])
      guard let view = address.contained else {
        throw LinkError.invalid("unselected native resource", [])
      }
      return try ResourceDeclaration(
        path: view.relativePath(
          PathSafety.resolvedChild(base: view.directory(), subpath: value.path)))
    }
    func run(_ value: ExecutableDeclaration) throws -> ExecutableDeclaration {
      var value = value
      if value.executable.contains("/") {
        let relative = try path(.init(path: value.executable, source: value.executableSource)).path
        value.executable = relative.contains("/") ? relative : "./" + relative
        value.executableSource = nil
      }
      value.workingDirectory = try value.workingDirectory.map(path)
      return value
    }
    func prompt(_ value: PromptBody) throws -> PromptBody {
      if case .file(let resource) = value { return try .file(path(resource)) }
      return value
    }
    switch declaration {
    case .mcpServer(
      let name, .stdio(let invocation), let agents, let condition, let native, let registry):
      return try .mcpServer(
        name: name, transport: .stdio(run(invocation)), agents: agents,
        condition: condition, native: native, registry: registry)
    case .hook(
      let name, let event, let invocation, let matcher, let timeout, let agents, let condition,
      let native):
      return try .hook(
        name: name, event: event, run: run(invocation), matcher: matcher,
        timeoutSeconds: timeout, agents: agents, condition: condition, native: native)
    case .lspServer(
      let name, let invocation, let languages, let options, let agents, let condition, let native):
      return try .lspServer(
        name: name, run: run(invocation), languages: languages,
        initializationOptions: options, agents: agents, condition: condition, native: native)
    case .command(
      let name, let description, let body, let parameters, let agents, let condition, let native):
      return try .command(
        name: name, description: description, prompt: prompt(body),
        parameters: parameters, agents: agents, condition: condition, native: native)
    case .subagent(
      let name, let description, let body, let model, let tools, let agents, let condition,
      let native):
      return try .subagent(
        name: name, description: description, prompt: prompt(body), model: model,
        tools: tools, agents: agents, condition: condition, native: native)
    default: return declaration
    }
  }
}
