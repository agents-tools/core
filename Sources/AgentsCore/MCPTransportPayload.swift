extension MCPTransportDeclaration {
  /// Reads the portable transport shared by frozen state and managed MCP operations.
  package init(ledgerPayload payload: LedgerValue) throws {
    func invalid() -> CoreError { .invalidState("invalid frozen MCP transport") }
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
        Set(run.keys).subtracting(["workingDirectory", "executableSource"]) == [
          "executable", "arguments", "environment",
        ],
        run["arguments"]?.kind == .array, let arguments = run["arguments"]?.array
      else { throw invalid() }
      let executable = try string(run["executable"])
      let executableSource = try run["executableSource"].map { try string($0) }
      if executableSource != nil && !executable.contains("/") { throw invalid() }
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
      self = try .stdio(
        .init(
          executable: executable, executableSource: executableSource,
          arguments: arguments.map { try string($0) },
          environment: bindings(run["environment"]), workingDirectory: cwd))
    case "streamableHTTP", "sse":
      guard Set(fields.keys) == ["kind", "url", "headers"] else { throw invalid() }
      let url = try string(fields["url"])
      let headers = try bindings(fields["headers"])
      self =
        fields["kind"]?.text == "sse"
        ? .sse(url: url, headers: headers) : .streamableHTTP(url: url, headers: headers)
    default: throw invalid()
    }
  }
}
