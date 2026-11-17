import AgentsCore
import AgentsManifest
import Components
import Foundation

extension MCPConnectionOperations {
  /// Prepares one managed inspection selection without resolving sources, reading
  /// native configuration, acquiring bindings or starting the selected program.
  /// All read locks and borrowed resource scopes end before this value returns.
  public static func snapshot(
    selection: ComponentSelection, scope: InstallScope, environment: RuntimeEnvironment
  ) throws -> MCPConnectionSnapshot {
    let store = StateStore(scope: scope, environment: environment)
    do {
      return try store.withReadLock {
        let baseline = try StatePrecondition(store: store)
        let document = try store.declarationDocument(prepared: baseline)
        let ledger = try store.readLedger(prepared: baseline)
        let generation = try ResolvedLedgerCodec.digest([
          ResolvedLedgerCodec.digest(ledger), document?.digest ?? "absent",
        ])
        guard generation == selection.generation else {
          throw MCPConnectionPreparationError.invalidSelection
        }
        let matches = try ledger.components.filter {
          try LedgerImpact.identity($0.value, ledger: ledger, roots: store.ledgerRoots)
            == selection.identity
        }
        guard matches.count == 1, let selected = matches.first,
          selected.value.kind == DeclaredComponentKind.mcpServer.rawValue
        else { throw MCPConnectionPreparationError.invalidSelection }
        let occurrences = ledger.occurrences.filter { $0.component == selected.key }
        guard !occurrences.isEmpty,
          selection.occurrence.map({ id in occurrences.contains { $0.id == id } }) ?? true
        else { throw MCPConnectionPreparationError.invalidSelection }
        guard selected.value.payload.object?["name"]?.kind == .string,
          selected.value.payload.object?["name"]?.text == selected.value.name
        else { throw MCPConnectionPreparationError.invalidConfiguration }
        let transport = try managedTransport(selected.value.payload)
        var remaining = LedgerLimits.standard.resourceBytes
        for id in selected.value.resources {
          guard let resource = ledger.resources[id] else {
            throw MCPConnectionPreparationError.invalidResource
          }
          for entry in resource.entries + resource.support {
            let count = entry.byteCount ?? 0
            guard count >= 0, count <= remaining else {
              throw MCPConnectionPreparationError.invalidResource
            }
            remaining -= count
          }
        }
        var resources = selected.value.resources.makeIterator()
        func capture() throws -> MCPConnectionResource {
          guard let id = resources.next(), let resource = ledger.resources[id] else {
            throw MCPConnectionPreparationError.invalidResource
          }
          if resource.kind == .liveEdit {
            guard let location = resource.location else {
              throw MCPConnectionPreparationError.invalidResource
            }
            return try .live(location.resolve(roots: store.ledgerRoots))
          }
          var root: URL?
          if resource.kind == .git {
            var sourceID = resource.source
            while let parent = ledger.sources[sourceID]?.container { sourceID = parent }
            guard let source = ledger.sources[sourceID] else {
              throw MCPConnectionPreparationError.invalidResource
            }
            let cache = SourceCache(store: store)
            let retained = cache.materializedURL(
              sourceID: try ledger.sourceIdentity(sourceID, roots: store.ledgerRoots),
              revision: source.revision)
            try cache.validatePath(retained)
            root = retained
          }
          return try .retaining(resource, objects: ledger.contentObjects, gitRoot: root)
        }
        var directory: MCPConnectionResource?
        var executable: MCPConnectionResource?
        if case .stdio(let run) = transport {
          if run.executable.contains("/") { executable = try capture() }
          directory =
            try run.workingDirectory == nil ? .live(environment.projectDirectory) : capture()
        }
        guard resources.next() == nil else { throw MCPConnectionPreparationError.invalidResource }
        let result = try snapshot(
          selectionID: selection.identity, transport: transport,
          workingDirectory: directory, executable: executable)
        try baseline.validate()
        return result
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MCPConnectionPreparationError {
      throw error
    } catch { throw MCPConnectionPreparationError.invalidSelection }
  }

  private static func managedTransport(_ payload: LedgerValue) throws -> MCPTransportDeclaration {
    func invalid() -> MCPConnectionPreparationError { .invalidConfiguration }
    func string(_ value: LedgerValue?) throws -> String {
      guard value?.kind == .string, let text = value?.text else { throw invalid() }
      return text
    }
    func bindings(_ value: LedgerValue?) throws -> [String: RuntimeBinding] {
      guard value?.kind == .object, let values = value?.object else { throw invalid() }
      return try values.mapValues { item in
        guard let text = item.text else { throw invalid() }
        switch item.kind {
        case .literal: return .literal(text)
        case .environment: return .environment(text)
        case .secret: return .secret(text)
        default: throw invalid()
        }
      }
    }
    guard let fields = payload.object?["transport"]?.object else { throw invalid() }
    switch try string(fields["kind"]) {
    case "stdio":
      guard Set(fields.keys) == ["kind", "run"], let run = fields["run"]?.object,
        Set(run.keys).subtracting(["workingDirectory"]) == [
          "executable", "arguments", "environment",
        ],
        run["arguments"]?.kind == .array, let arguments = run["arguments"]?.array
      else { throw invalid() }
      let cwd: ResourceDeclaration?
      if let directory = run["workingDirectory"] {
        guard let object = directory.object, Set(object.keys).isSubset(of: ["path", "source"])
        else {
          throw invalid()
        }
        cwd = try .init(
          path: string(object["path"]), source: object["source"].map { try string($0) })
      } else {
        cwd = nil
      }
      return try .stdio(
        .init(
          executable: string(run["executable"]), arguments: arguments.map { try string($0) },
          environment: bindings(run["environment"]), workingDirectory: cwd))
    case "streamableHTTP", "sse":
      guard Set(fields.keys) == ["kind", "url", "headers"] else { throw invalid() }
      let url = try string(fields["url"])
      let headers = try bindings(fields["headers"])
      return fields["kind"]?.text == "sse"
        ? .sse(url: url, headers: headers) : .streamableHTTP(url: url, headers: headers)
    default: throw invalid()
    }
  }
}
