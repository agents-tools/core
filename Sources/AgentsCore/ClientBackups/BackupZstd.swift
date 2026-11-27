import Foundation

/// Codex's compressed rollouts hold the same JSONL byte stream as plain rollouts.
/// Transcoding on relocation leaves the package's original frame bytes intact.
enum BackupZstd {
  static func executable(path: String?) -> URL? {
    let installed = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    let directories = (path ?? "").split(separator: ":").map(String.init) + installed
    for value in directories where value.hasPrefix("/") {
      let binary = URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent("zstd")
      if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
    }
    return nil
  }

  static func transcode(
    _ input: URL, into output: FileHandle, using tool: URL, decode: Bool
  ) throws {
    let source = try FileHandle(forReadingFrom: input)
    defer { try? source.close() }
    let task = Process()
    task.executableURL = tool
    task.arguments = decode ? ["-q", "-d", "-c"] : ["-q", "-c"]
    task.environment = ["PATH": "/usr/bin:/bin"]
    task.standardInput = source
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      throw ClientBackupError.unsupportedLayout("Codex compressed rollout")
    }
  }
}
