import AgentsCore
import Foundation
import Logging
import MCP

/// Cancellation may arrive before connect installs its resource. Installation
/// observes the latched abort, so a late resource cannot escape cleanup.
private final class MCPAbortHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var aborted = false
  private var action: (@Sendable () -> Void)?
  func install(_ action: @escaping @Sendable () -> Void) {
    let run = lock.withLock {
      self.action = action
      return aborted
    }
    if run { action() }
  }
  func abort() {
    let action = lock.withLock {
      aborted = true
      return self.action
    }
    action?()
  }
}

actor MCPBoundedTransport: Transport {
  nonisolated let logger = Logger(
    label: "MCPConnection", factory: { _ in SwiftLogNoOpLogHandler() })
  nonisolated let sink: MCPMessageSink
  private nonisolated let abortHandle = MCPAbortHandle()
  private let input: MCPConnectionInput
  private var process: OwnedDuplexProcess?
  private var executable: String?
  private var http: MCPHTTPConnection?
  private var pumpTask: Task<Void, Never>?
  private var started = false
  private var clean = false
  private var cleanupTask: Task<Bool, Never>?
  private var line = Data()
  private struct Write {
    var bytes: Data
    var offset: Int
    var continuation: CheckedContinuation<Void, Error>
  }
  private var writes: [Write] = []
  private var writeBytes = 0

  init(_ input: MCPConnectionInput, limits: MCPConnectionLimits) {
    self.input = input
    sink = MCPMessageSink(limits)
  }

  nonisolated func abort(_ issue: MCPConnectionIssue) {
    sink.fail(issue)
    abortHandle.abort()
  }

  func connect() async throws {
    guard !started else { throw MCPConnectionIssue.protocolError }
    if let issue = sink.failure { throw issue }
    started = true
    switch input {
    case .stdio(let configuration):
      do {
        let process = try OwnedDuplexProcess(configuration)
        self.process = process
        executable = process.resolvedExecutable
        abortHandle.install { process.closeInput() }
      } catch DuplexProcessError.invalidInput {
        throw MCPConnectionIssue.invalidInput
      } catch { throw MCPConnectionIssue.connectionFailed }
    case .streamableHTTP(let url, let headers):
      let http = MCPHTTPConnection(url: url, headers: headers, mode: .streamable, sink: sink)
      self.http = http
      abortHandle.install { http.abort() }
    case .legacySSE(let url, let headers):
      let http = MCPHTTPConnection(url: url, headers: headers, mode: .legacy, sink: sink)
      self.http = http
      abortHandle.install { http.abort() }
    }
    pumpTask = Task { await pump() }
    try await http?.connect()
    if let issue = sink.failure { throw issue }
  }

  func receive() -> AsyncThrowingStream<Data, Error> { sink.stream }

  func send(_ bytes: Data) async throws {
    let header = try sink.prepare(bytes)
    guard started else { throw MCPConnectionIssue.connectionClosed }
    if let http {
      try await http.send(bytes, header: header)
      return
    }
    guard process != nil else { throw MCPConnectionIssue.connectionClosed }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      guard bytes.count < sink.limits.queueBytes - writeBytes,
        writes.count < sink.limits.queueMessages
      else {
        continuation.resume(throwing: MCPConnectionIssue.queueLimit)
        abort(.queueLimit)
        return
      }
      var frame = bytes
      frame.append(10)
      writeBytes += frame.count
      writes.append(Write(bytes: frame, offset: 0, continuation: continuation))
    }
  }

  private func pump() async {
    do {
      while sink.failure == nil && !Task.isCancelled {
        if let process {
          switch try process.readStandardOutput() {
          case .bytes(let bytes):
            try sink.receiveBytes(bytes.count)
            for byte in bytes {
              if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if !line.isEmpty { try sink.admit(line) }
                line.removeAll(keepingCapacity: true)
              } else {
                guard line.count < sink.limits.frameBytes else {
                  throw MCPConnectionIssue.messageLimit
                }
                line.append(byte)
              }
            }
          case .end: throw MCPConnectionIssue.connectionClosed
          case .wouldBlock: break
          }
          switch try process.readStandardError() {
          case .bytes(let bytes): try sink.receiveBytes(bytes.count, standardError: true)
          case .end, .wouldBlock: break
          }
          if !writes.isEmpty {
            let written = try process.write(writes[0].bytes, offset: writes[0].offset)
            writes[0].offset += written
            if writes[0].offset == writes[0].bytes.count {
              let completed = writes.removeFirst()
              writeBytes -= completed.bytes.count
              completed.continuation.resume()
            }
          }
        }
        http?.tick()
        try await Task.sleep(for: .milliseconds(1))
      }
    } catch {
      abort(error as? MCPConnectionIssue ?? .connectionFailed)
    }
    for pending in writes {
      pending.continuation.resume(throwing: sink.failure ?? MCPConnectionIssue.connectionClosed)
    }
    writes.removeAll()
    writeBytes = 0
    line.removeAll()
  }

  func disconnect() async {
    if let cleanupTask {
      clean = await cleanupTask.value
      return
    }
    abort(.connectionClosed)
    pumpTask?.cancel()
    let pump = pumpTask
    let process = process
    let http = http
    let limits = sink.limits
    let task = Task {
      await pump?.value
      if let process {
        return await process.finish(
          grace: .seconds(limits.cleanupGrace),
          terminate: .seconds(limits.cleanupTerminate), killWait: .seconds(limits.cleanupKillWait))
      }
      if let http { return await http.finish() }
      return true
    }
    cleanupTask = task
    clean = await task.value
    self.process = nil
    self.http = nil
    pumpTask = nil
  }

  func cleanupComplete() -> Bool { clean }
  func resolvedExecutable() -> String? { executable }
}
