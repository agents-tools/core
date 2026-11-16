import Foundation
import MCP

struct MCPWireHeader: Decodable {
  var id: ID?
  var method: String?
}

/// The delegate and stdio pump share one locked admission boundary. Stream
/// capacity times frameBytes never exceeds queueBytes, even for a slow consumer.
final class MCPMessageSink: @unchecked Sendable {
  let stream: AsyncThrowingStream<Data, Error>
  let failures: AsyncStream<MCPConnectionIssue>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private let failureContinuation: AsyncStream<MCPConnectionIssue>.Continuation
  private let lock = NSLock()
  let limits: MCPConnectionLimits
  private var received = 0
  private var sent = 0
  private var stderr = 0
  private var issue: MCPConnectionIssue?
  private var pendingResponses = Set<ID>()
  private var initializeID: ID?
  private var negotiated: String?

  init(_ limits: MCPConnectionLimits) {
    self.limits = limits
    (stream, continuation) = AsyncThrowingStream.makeStream(
      bufferingPolicy: .bufferingOldest(
        min(limits.queueMessages, limits.queueBytes / limits.frameBytes)))
    (failures, failureContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }

  var failure: MCPConnectionIssue? { lock.withLock { issue } }
  var version: String? { lock.withLock { negotiated } }
  var responsesAdmitted: Bool { lock.withLock { pendingResponses.isEmpty } }

  func fail(_ error: MCPConnectionIssue) {
    lock.withLock { finishLocked(error) }
  }

  private func finishLocked(_ error: MCPConnectionIssue) {
    guard issue == nil else { return }
    issue = error
    continuation.finish(throwing: error)
    failureContinuation.yield(error)
    failureContinuation.finish()
  }

  func receiveBytes(_ count: Int, standardError: Bool = false) throws {
    try lock.withLock {
      if let issue { throw issue }
      if standardError {
        guard count <= limits.stderrBytes - stderr else {
          finishLocked(.stderrLimit)
          throw MCPConnectionIssue.stderrLimit
        }
        stderr += count
      } else {
        guard count <= limits.receivedBytes - received else {
          finishLocked(.receiveLimit)
          throw MCPConnectionIssue.receiveLimit
        }
        received += count
      }
    }
  }

  /// Call before I/O. Initialize belongs to SDK Client, not the runner.
  func prepare(_ data: Data) throws -> MCPWireHeader {
    try lock.withLock {
      if let issue { throw issue }
      guard data.count <= limits.frameBytes else { throw MCPConnectionIssue.messageLimit }
      guard data.count < limits.sentBytes - sent else { throw MCPConnectionIssue.sendLimit }
      sent += data.count + 1  // Includes the stdio newline; conservatively shared by HTTP.
      let header: MCPWireHeader
      do { header = try JSONDecoder().decode(MCPWireHeader.self, from: data) } catch {
        throw MCPConnectionIssue.protocolError
      }
      if header.method == Initialize.name {
        guard initializeID == nil else { throw MCPConnectionIssue.protocolError }
        guard let id = header.id else { throw MCPConnectionIssue.protocolError }
        initializeID = id
      } else if header.method == InitializedNotification.name {
        guard negotiated != nil else { throw MCPConnectionIssue.unsupportedVersion }
      } else if let method = header.method, method != ListTools.name {
        throw MCPConnectionIssue.protocolError
      }
      if header.method != nil, let id = header.id { pendingResponses.insert(id) }
      return header
    }
  }

  /// Raw bytes have already been counted, and the frame bound precedes SDK decode.
  func admit(_ data: Data) throws {
    try lock.withLock {
      if let issue { throw issue }
      guard data.count <= limits.frameBytes else {
        finishLocked(.messageLimit)
        throw MCPConnectionIssue.messageLimit
      }
      let header = try? JSONDecoder().decode(MCPWireHeader.self, from: data)
      if negotiated == nil && header?.method == nil {
        let response: Response<Initialize>
        do { response = try JSONDecoder().decode(Response<Initialize>.self, from: data) } catch {
          finishLocked(.protocolError)
          throw MCPConnectionIssue.protocolError
        }
        guard response.id == initializeID else {
          finishLocked(.protocolError)
          throw MCPConnectionIssue.protocolError
        }
        if case .success(let result) = response.result {
          guard Version.supported.contains(result.protocolVersion) else {
            finishLocked(.unsupportedVersion)
            throw MCPConnectionIssue.unsupportedVersion
          }
          negotiated = result.protocolVersion
        }
      }
      switch continuation.yield(data) {
      case .enqueued:
        if header?.method == nil, let id = header?.id { pendingResponses.remove(id) }
      case .dropped:
        finishLocked(.queueLimit)
        throw MCPConnectionIssue.queueLimit
      case .terminated:
        finishLocked(.connectionClosed)
        throw MCPConnectionIssue.connectionClosed
      @unknown default:
        finishLocked(.connectionClosed)
        throw MCPConnectionIssue.connectionClosed
      }
    }
  }
}

/// Incremental SSE line/event parser. All raw bytes, including comments, are
/// counted by its caller; neither an unterminated line nor event can grow freely.
struct MCPSSEParser {
  struct Event {
    var name: String
    var data: Data
    var id: String?
    var retry: TimeInterval?
  }
  private var line = Data()
  private var data = Data()
  private var name = ""
  private(set) var lastID: String?
  private(set) var retry: TimeInterval?
  private var afterCR = false
  private var firstLine = true
  let limit: Int

  mutating func restart() {
    line.removeAll(keepingCapacity: true)
    data.removeAll(keepingCapacity: true)
    name = ""
    afterCR = false
    firstLine = true
  }

  mutating func feed(_ bytes: Data, emit: (Event) throws -> Void) throws {
    for byte in bytes {
      if byte == 10 && afterCR {
        afterCR = false
        continue
      }
      afterCR = byte == 13
      if byte == 10 || byte == 13 {
        try endLine(emit)
      } else {
        guard line.count < limit else { throw MCPConnectionIssue.messageLimit }
        line.append(byte)
      }
    }
  }

  private mutating func endLine(_ emit: (Event) throws -> Void) throws {
    defer {
      line.removeAll(keepingCapacity: true)
      firstLine = false
    }
    if firstLine && line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
    if line.isEmpty {
      if !data.isEmpty {
        data.removeLast()  // SSE removes the final data-field newline.
        try emit(Event(name: name, data: data, id: lastID, retry: retry))
      }
      data.removeAll(keepingCapacity: true)
      name = ""
      return
    }
    if line.first == 58 { return }
    let separator = line.firstIndex(of: 58) ?? line.endIndex
    let field = String(decoding: line[..<separator], as: UTF8.self)
    var value = separator == line.endIndex ? Data() : Data(line[line.index(after: separator)...])
    if value.first == 32 { value.removeFirst() }
    switch field {
    case "data":
      guard value.count < limit - data.count else { throw MCPConnectionIssue.messageLimit }
      data.append(value)
      data.append(10)
    case "event": name = String(decoding: value, as: UTF8.self)
    case "id":
      if !value.contains(0) { lastID = String(decoding: value, as: UTF8.self) }
    case "retry":
      if !value.isEmpty && value.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let milliseconds = UInt64(String(decoding: value, as: UTF8.self))
      {
        retry = Double(milliseconds) / 1000
      }
    default: break
    }
  }
}
