import AgentsCore
import Foundation
import MCP

private final class MCPDeadline: @unchecked Sendable {
  private let lock = NSLock()
  let total: ContinuousClock.Instant
  private var request: ContinuousClock.Instant
  init(_ limits: MCPConnectionLimits, started: ContinuousClock.Instant) {
    total = started + .seconds(limits.totalTimeout)
    request = min(total, .now + .seconds(limits.requestTimeout))
  }
  func arm(_ seconds: TimeInterval) {
    lock.withLock { request = min(total, .now + .seconds(seconds)) }
  }
  var expired: Bool { lock.withLock { ContinuousClock.now >= min(total, request) } }
}

private actor MCPDiscoveryProgress {
  var version: String?
  var tools: [MCPDiscoveredTool] = []
  func handshake(_ version: String) { self.version = version }
  func append(_ next: [MCPDiscoveredTool]) { tools.append(contentsOf: next) }
  func outcome(_ status: MCPConnectionOutcome.Status) -> MCPConnectionOutcome {
    MCPConnectionOutcome(
      status: status, negotiatedVersion: version, tools: tools, cleanupComplete: false)
  }
}

package enum MCPConnectionRunner {
  private enum Event: Sendable {
    case completed(MCPConnectionOutcome.Status)
    case failed(MCPConnectionIssue)
  }

  package static func run(
    _ input: MCPConnectionInput, client identity: MCPConnectionClient,
    limits: MCPConnectionLimits = .init()
  ) async -> MCPConnectionOutcome {
    let started = ContinuousClock.now
    do {
      try limits.validate()
      try validate(input, limits: limits)
      guard !identity.name.isEmpty, !identity.version.isEmpty,
        [identity.name, identity.version].allSatisfy({
          !$0.utf8.contains(0) && $0.utf8.count <= limits.textBytes
        })
      else { throw MCPConnectionIssue.invalidInput }
      try Task.checkCancellation()
    } catch {
      return MCPConnectionOutcome(
        status: .failed(error is CancellationError ? .cancelled : .invalidInput),
        negotiatedVersion: nil, tools: [], cleanupComplete: true)
    }
    let deadline = MCPDeadline(limits, started: started)
    if deadline.expired {
      return MCPConnectionOutcome(
        status: .failed(.timeout), negotiatedVersion: nil, tools: [], cleanupComplete: true)
    }
    let transport = MCPBoundedTransport(input, limits: limits)
    let client = Client(
      name: identity.name, version: identity.version, capabilities: .init(), configuration: .strict)
    let progress = MCPDiscoveryProgress()
    return await withTaskCancellationHandler {
      await withTaskGroup(of: Event.self) { group in
        group.addTask {
          do {
            let initialized = try await client.connect(transport: transport)
            guard initialized.protocolVersion == transport.sink.version else {
              throw MCPConnectionIssue.protocolError
            }
            await progress.handshake(initialized.protocolVersion)
            guard initialized.capabilities.tools != nil else { return .completed(.noTools) }
            var cursor: String?
            var seen = Set<String>()
            var toolCount = 0
            var pages = 0
            repeat {
              guard pages < limits.pages else { throw MCPConnectionIssue.pageLimit }
              deadline.arm(limits.requestTimeout)
              let request =
                cursor.map { ListTools.request(.init(cursor: $0)) } ?? ListTools.request(.init())
              let context = try await client.send(request)
              let result = try await context.value
              pages += 1
              guard result.tools.count <= limits.tools - toolCount else {
                throw MCPConnectionIssue.toolLimit
              }
              var tools: [MCPDiscoveredTool] = []
              for tool in result.tools {
                guard
                  [tool.name, tool.title ?? "", tool.description ?? ""].allSatisfy({
                    $0.utf8.count <= limits.textBytes
                  })
                else { throw MCPConnectionIssue.textLimit }
                tools.append(
                  MCPDiscoveredTool(
                    name: tool.name, title: tool.title, description: tool.description))
              }
              toolCount += tools.count
              await progress.append(tools)
              cursor = result.nextCursor
              if let cursor {
                guard cursor.utf8.count <= limits.frameBytes else {
                  throw MCPConnectionIssue.messageLimit
                }
                guard seen.insert(cursor).inserted else { throw MCPConnectionIssue.cursorCycle }
              }
            } while cursor != nil
            return .completed(.discovered)
          } catch {
            return .failed(error as? MCPConnectionIssue ?? .protocolError)
          }
        }
        group.addTask {
          while !Task.isCancelled {
            if deadline.expired {
              transport.abort(.timeout)
              return .failed(.timeout)
            }
            do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
          }
          return .failed(.cancelled)
        }
        group.addTask {
          for await issue in transport.sink.failures { return .failed(issue) }
          return .failed(.connectionClosed)
        }
        var event = await group.next() ?? .failed(.connectionClosed)
        if case .failed(.connectionClosed) = event, transport.sink.responsesAdmitted {
          // EOF must not interrupt SDK decoding of responses already admitted to
          // its queue. The existing request/total timer still bounds this join.
          event = await group.next() ?? event
        }
        let transportIssue = transport.sink.closeAdmission()
        if let transportIssue, transportIssue != .connectionClosed {
          event = .failed(transportIssue)
        }
        // A separate cleanup task is deliberately joined and is not cancelled
        // with the caller: cancelling sleep must not skip EOF/TERM/KILL budgets.
        let cleanup = Task {
          transport.abort(.connectionClosed)
          await client.disconnect()
          // The runner joins the transport it created; disconnect is idempotent.
          await transport.disconnect()
          return await transport.cleanupComplete()
        }
        let clean = await cleanup.value
        group.cancelAll()
        while await group.next() != nil {}
        let status: MCPConnectionOutcome.Status
        switch event {
        case .completed(let value): status = value
        case .failed(let failure):
          let issue = transportIssue ?? failure
          let state = await progress.outcome(.failed(issue))
          status = state.negotiatedVersion == nil ? .failed(issue) : .incomplete(issue)
        }
        var outcome = await progress.outcome(clean ? status : .failed(.cleanupFailed))
        outcome.cleanupComplete = clean
        outcome.resolvedExecutable = await transport.resolvedExecutable()
        return outcome
      }
    } onCancel: {
      transport.abort(.cancelled)
    }
  }

  private static func validate(_ input: MCPConnectionInput, limits: MCPConnectionLimits) throws {
    var remaining = limits.inputBytes
    func admit(_ string: String) throws {
      // Charge the terminator as well, bounding arrays of empty arguments.
      guard string.utf8.count < remaining else { throw MCPConnectionIssue.invalidInput }
      remaining -= string.utf8.count + 1
    }
    switch input {
    case .stdio(let configuration):
      try admit(configuration.executable)
      try admit(configuration.directory.path)
      for argument in configuration.arguments { try admit(argument) }
      for (key, value) in configuration.environment {
        try admit(key)
        try admit(value)
      }
    case .streamableHTTP(let url, let headers), .legacySSE(let url, let headers):
      try admit(url.absoluteString)
      for (key, value) in headers {
        try admit(key)
        try admit(value)
      }
      guard MCPHTTPConnection.validURL(url), MCPHTTPConnection.validHeaders(headers) else {
        throw MCPConnectionIssue.invalidInput
      }
    }
  }
}
