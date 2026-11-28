import CPlatform
import Foundation

enum BackupGeminiCheckpoints {
  static func isRecord(_ parts: [String]) -> Bool {
    parts.count == 4 && parts[0] == "tmp" && parts[2] == "checkpoints"
      && parts[3].hasSuffix(".json")
  }

  static func isPack(_ parts: [String]) -> Bool {
    parts.count == 6 && parts[0] == "history" && parts[2] == ".git"
      && parts[3] == "objects" && parts[4] == "pack" && packName(parts[5])
  }

  private static func packName(_ value: String) -> Bool {
    value.range(of: #"^pack-[a-f0-9]{40}\.(pack|idx)$"#, options: .regularExpression) != nil
  }

  private static func hex(_ value: String, length: ClosedRange<Int>) -> Bool {
    length.contains(value.utf8.count)
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  static func commit(in file: URL) throws -> String? {
    var result: String?
    let reader = try BackupJSONStream(file, selection: [["commitHash"]]) { _, value in
      guard result == nil, hex(value, length: 4...40) else {
        throw ClientBackupError.unsupportedLayout("Gemini checkpoint " + file.lastPathComponent)
      }
      result = value
      return nil
    }
    try reader.process()
    return result
  }

  static func capture(
    commits: [String], shadow: URL, scratch: DirectoryHandle,
    observe: (URL) throws -> BackupGeneration?
  ) throws -> [URL] {
    do {
      let repo = try repository(in: scratch)
      let input = shadow.appendingPathComponent(".git/objects")
      guard let objects = try BackupIO.directory(input) else {
        throw ClientBackupError.invalidLocation(input.path)
      }
      _ = try observe(input)
      let destination = try repo.child("objects")
      for prefix in try objects.names() where prefix == "pack" || hex(prefix, length: 2...2) {
        let directory = try objects.child(prefix)
        _ = try observe(directory.url)
        let target =
          try destination.info(prefix) == nil
          ? destination.createPrivateDirectory(prefix) : destination.child(prefix)
        for file in try directory.names()
        where prefix == "pack" ? packName(file) : hex(file, length: 38...38) {
          let url = directory.url.appendingPathComponent(file)
          guard let current = try observe(url),
            try BackupIO.copy(url, to: target, named: file).generation == current
          else { throw ClientBackupError.conflict(url.path) }
        }
      }
      let resolved = try commits.map { try resolve($0, in: repo) }
      let output = try scratch.createPrivateDirectory("gemini-pack-" + UUID().uuidString)
      let inputName = "commits-" + UUID().uuidString
      try scratch.write(
        inputName, data: Data((Set(resolved).sorted().joined(separator: "\n") + "\n").utf8))
      let prefix = output.url.appendingPathComponent("pack").path
      let name = try git(
        ["pack-objects", "--quiet", "--revs", "--non-empty", prefix],
        in: repo, input: scratch.url.appendingPathComponent(inputName))
      guard hex(name, length: 40...40) else {
        throw ClientBackupError.unsupportedLayout(shadow.path)
      }
      return ["idx", "pack"].map { output.url.appendingPathComponent("pack-" + name + "." + $0) }
    } catch {
      throw ClientBackupError.unsupportedLayout(shadow.path)
    }
  }

  struct Prepared {
    let commits: [String: String]
    let initialFiles: [String: URL]
    let references: [String: URL]
  }

  static func prepare(
    commits: [String], packs: [String: URL], scratch: DirectoryHandle, initialize: Bool
  ) throws -> Prepared {
    let repo = try repository(in: scratch)
    let directory = try repo.child("objects").child("pack")
    for (name, payload) in packs {
      guard packName(name) else { throw ClientBackupError.invalidPackage }
      try BackupIO.copy(payload, to: directory, named: name)
    }
    for name in packs.keys {
      let counterpart =
        name.hasSuffix(".pack")
        ? String(name.dropLast(5)) + ".idx" : String(name.dropLast(4)) + ".pack"
      guard packs[counterpart] != nil else { throw ClientBackupError.invalidPackage }
      if name.hasSuffix(".pack") {
        _ = try git(
          ["index-pack", "--verify", directory.url.appendingPathComponent(name).path], in: repo)
      }
    }
    var resolved: [String: String] = [:]
    for commit in commits where resolved[commit] == nil {
      resolved[commit] = try resolve(commit, in: repo)
    }
    var initialFiles: [String: URL] = [:]
    if initialize, let latest = commits.last.flatMap({ resolved[$0] }) {
      _ = try git(["read-tree", latest], in: repo)
      _ = try git(["update-ref", "refs/heads/main", latest], in: repo)
      for file in ["HEAD", "config", "index", "refs/heads/main"] {
        initialFiles[file] = repo.url.appendingPathComponent(file)
      }
    }
    let refs = try scratch.createPrivateDirectory("gemini-refs-" + UUID().uuidString)
    var references: [String: URL] = [:]
    for commit in Set(resolved.values) {
      try refs.write(commit, data: Data((commit + "\n").utf8))
      references["refs/agents-checkpoints/" + commit] = refs.url.appendingPathComponent(commit)
    }
    return Prepared(commits: resolved, initialFiles: initialFiles, references: references)
  }

  private static func repository(in scratch: DirectoryHandle) throws -> DirectoryHandle {
    let folder = try scratch.createPrivateDirectory("gemini-git-" + UUID().uuidString)
    _ = try git(
      ["init", "--quiet", "--template=", "--initial-branch=main", "--object-format=sha1"],
      in: folder)
    return try folder.child(".git")
  }

  private static func resolve(_ prefix: String, in repo: DirectoryHandle) throws -> String {
    guard hex(prefix, length: 4...40) else { throw ClientBackupError.invalidPackage }
    let sha = try git(["rev-parse", "--verify", prefix + "^{commit}"], in: repo)
    guard hex(sha, length: 40...40), sha.hasPrefix(prefix) else {
      throw ClientBackupError.unsupportedLayout("Gemini checkpoint commit")
    }
    return sha
  }

  @discardableResult
  static func git(_ arguments: [String], in folder: DirectoryHandle, input: URL? = nil) throws
    -> String
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = folder.url
    process.arguments =
      [
        "-c", "core.hooksPath=/dev/null", "-c", "maintenance.auto=false",
        "-c", "gc.auto=0",
      ] + arguments
    process.environment = [
      "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let handle = try input.map(FileHandle.init(forReadingFrom:))
    defer { try? handle?.close() }
    process.standardInput = handle ?? FileHandle.nullDevice
    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      throw ClientBackupError.unsupportedLayout("Gemini checkpoint Git objects")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
