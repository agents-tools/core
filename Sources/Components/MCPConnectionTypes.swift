import AgentsCore
import Foundation

/// Already-bound values borrowed only for this run. No serialization or public API.
package enum MCPConnectionInput: Sendable {
  case stdio(DuplexProcessConfiguration)
  case streamableHTTP(URL, headers: [String: String])
  case legacySSE(URL, headers: [String: String])
}

package struct MCPConnectionClient: Sendable {
  package var name: String
  package var version: String
  package init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}

package struct MCPConnectionLimits: Sendable {
  package var totalTimeout: TimeInterval = 15
  package var requestTimeout: TimeInterval = 5
  package var cleanupGrace: TimeInterval = 0.1
  package var cleanupTerminate: TimeInterval = 0.1
  package var cleanupKillWait: TimeInterval = 1
  // Bytes: at most four 256 KiB frames queued, with 4 MiB aggregate input.
  package var inputBytes = 256 * 1024
  package var frameBytes = 256 * 1024
  package var receivedBytes = 4 * 1024 * 1024
  package var sentBytes = 256 * 1024
  package var stderrBytes = 64 * 1024
  package var queueBytes = 1024 * 1024
  package var queueMessages = 4
  package var pages = 16
  package var tools = 256
  package var textBytes = 4096
  package var redirects = 4
  package var resumes = 2

  package init() {}

  func validate() throws {
    let times = [totalTimeout, requestTimeout, cleanupGrace, cleanupTerminate, cleanupKillWait]
    guard times.allSatisfy({ $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 1_000_000_000 }),
      [
        inputBytes, frameBytes, receivedBytes, sentBytes, stderrBytes, queueBytes, queueMessages,
        pages, tools, textBytes, redirects, resumes,
      ].allSatisfy({ $0 > 0 }),
      queueBytes >= frameBytes
    else { throw MCPConnectionIssue.invalidInput }
  }
}

package enum MCPConnectionIssue: String, Error, Sendable {
  case invalidInput
  case connectionFailed
  case connectionClosed
  case protocolError
  case unsupportedVersion
  case authenticationRequired
  case forbidden
  case authorityChanged
  case sessionExpired
  case messageLimit
  case receiveLimit
  case sendLimit
  case stderrLimit
  case queueLimit
  case pageLimit
  case toolLimit
  case textLimit
  case redirectLimit
  case resumeLimit
  case cursorCycle
  case timeout
  case cancelled
  case cleanupFailed
}

package struct MCPDiscoveredTool: Sendable {
  package var name: String
  package var title: String?
  package var description: String?
}

/// Private result values must be redacted by the facade before presentation.
package struct MCPConnectionOutcome: Sendable {
  package enum Status: Sendable, Equatable {
    case discovered
    case noTools
    case incomplete(MCPConnectionIssue)
    case failed(MCPConnectionIssue)
  }
  package var status: Status
  package var negotiatedVersion: String?
  package var tools: [MCPDiscoveredTool]
  package var cleanupComplete: Bool
  package var resolvedExecutable: String? = nil
}
