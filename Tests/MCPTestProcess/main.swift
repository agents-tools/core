import CPlatform
import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

let arguments = CommandLine.arguments
let scenario = arguments.count > 1 ? arguments[1] : "normal"
let root = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "/tmp")
func record(_ value: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
  let file = root.appendingPathComponent("wire.jsonl")
  if !FileManager.default.fileExists(atPath: file.path) {
    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
  }
  if let handle = try? FileHandle(forWritingTo: file) {
    handle.seekToEndOfFile()
    handle.write(data)
    handle.write(Data([10]))
    try? handle.close()
  }
}
func output(_ data: Data, fd: Int32 = 1) {
  var offset = 0
  while offset < data.count {
    let size = data.withUnsafeBytes {
      platform_duplex_write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
    }
    if size <= 0 { exit(0) }
    offset += size
  }
}
func response(_ id: Any, _ result: [String: Any]) {
  if let bytes = try? JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0", "id": id, "result": result,
  ]) {
    output(bytes + Data([10]))
  }
}
try? String(getpid()).write(
  to: root.appendingPathComponent(scenario == "holder" ? "holder-pid" : "pid"), atomically: true,
  encoding: .utf8)
if scenario == "holder" || scenario == "ignore-input" || scenario == "blocked-input" {
  if scenario == "blocked-input" { alarm(10) }
  _ = signal(SIGTERM, SIG_IGN)
  try? "ready".write(
    to: root.appendingPathComponent("holder-ready"), atomically: true, encoding: .utf8)
  if scenario == "blocked-input" {
    while true {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      if poll(&descriptor, 1, 100) > 0 && descriptor.revents & Int16(POLLIN) != 0 {
        try? "ready".write(
          to: root.appendingPathComponent("stdin-pending"), atomically: true, encoding: .utf8)
        break
      }
      usleep(1000)
    }
  }
  while true { _ = sleep(1) }
}
if scenario == "descendant" {
  let argv = [arguments[0], "holder", root.path].map { strdup($0) } + [nil]
  let environment =
    ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
  var pid: pid_t = 0
  if posix_spawn(&pid, arguments[0], nil, nil, argv, environment) != 0 { exit(2) }
  for pointer in argv + environment { free(pointer) }
  try? String(pid).write(
    to: root.appendingPathComponent("descendant-pid"), atomically: true, encoding: .utf8)
  var descendantReady = false
  for _ in 0..<2000 {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("holder-ready").path) {
      descendantReady = true
      break
    }
    usleep(1000)
  }
  if !descendantReady || getpgid(pid) != getpgrp() { exit(2) }
}
let fd = Int32(ProcessInfo.processInfo.environment["FD_CHECK"] ?? "-1") ?? -1
record([
  "startup": true, "cwd": FileManager.default.currentDirectoryPath,
  "environment": ProcessInfo.processInfo.environment["FIXTURE_VALUE"] ?? "absent",
  "inheritedFD": fd >= 0 && fcntl(fd, F_GETFD) >= 0,
])
var line = Data()
while true {
  var byte: UInt8 = 0
  let count = read(0, &byte, 1)
  if count == 0 { exit(0) }
  if count < 0 {
    if errno == EINTR { continue }
    exit(1)
  }
  if byte != 10 {
    line.append(byte)
    if line.count > 1_048_576 { exit(2) }
    continue
  }
  defer { line.removeAll(keepingCapacity: true) }
  guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
    let method = message["method"] as? String
  else { continue }
  record(["method": method, "params": message["params"] ?? [:]])
  guard let id = message["id"] else { continue }
  if method == "initialize" {
    if scenario == "eof-initialize" { exit(0) }
    if scenario == "pending-initialize" { continue }
    if scenario == "stdout-flood" {
      output(Data(repeating: 120, count: 65536))
      continue
    }
    if scenario == "stderr-flood" {
      output(Data(repeating: 120, count: 65536), fd: 2)
      continue
    }
    let capabilities: [String: Any] = scenario == "no-tools" ? [:] : ["tools": [:]]
    response(
      id,
      [
        "protocolVersion": scenario == "wrong-version" ? "2099-01-01" : "2025-11-25",
        "capabilities": capabilities, "serverInfo": ["name": "local-fixture", "version": "1"],
      ])
  } else if method == "tools/list" {
    if scenario == "eof-tools" {
      let tools: [[String: Any]] = (0..<1000).map { index in
        [
          "name": "tool-" + String(index), "description": String(repeating: "x", count: 200),
          "inputSchema": ["type": "object"],
        ]
      }
      response(id, ["tools": tools])
      exit(0)
    }
    if scenario == "pending-tools" { continue }
    if scenario == "stubborn" {
      _ = signal(SIGTERM, SIG_IGN)
      try? "ready".write(
        to: root.appendingPathComponent("stubborn-ready"), atomically: true, encoding: .utf8)
      while true { _ = sleep(1) }
    }
    let cursor = (message["params"] as? [String: Any])?["cursor"] as? String
    let tool: [String: Any] = [
      "name": cursor == nil ? "first" : "second",
      "description": scenario == "long-text" ? String(repeating: "x", count: 17) : "fixture",
      "inputSchema": ["type": "object"],
    ]
    var result: [String: Any] = ["tools": [tool]]
    if cursor == nil || scenario == "cursor-cycle" { result["nextCursor"] = "next" }
    response(id, result)
  }
}
