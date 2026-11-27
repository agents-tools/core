import AgentsCore
import Foundation

struct ProducerPatchNativeInputs: Equatable, Sendable {
  private enum Observation: Equatable, Sendable {
    case missing(FileObjectIdentity?)
    case blocked
    case other(FileObjectIdentity, FileObjectIdentity)
    case regular(FileObjectIdentity, FileObjectIdentity, executable: Bool, digest: String)
  }

  private var files: [URL: Observation] = [:]
  private var remaining = ProducerPatchInputs.limits.resourceBytes

  mutating func read(_ path: URL) throws -> RegularFileObservation? {
    let (observation, file) = try Self.observe(path, maximumBytes: remaining)
    if let known = files[path], known != observation { throw ProducerPatchError.stale }
    if files.updateValue(observation, forKey: path) == nil,
      case .regular(_, _, let bytes) = file
    {
      remaining -= bytes.count
    }
    return file
  }

  func validate() throws {
    var remaining = ProducerPatchInputs.limits.resourceBytes
    for (path, expected) in files {
      try Task.checkCancellation()
      let (actual, file) = try Self.observe(path, maximumBytes: remaining)
      guard actual == expected else { throw ProducerPatchError.stale }
      if case .regular(_, _, let bytes) = file { remaining -= bytes.count }
    }
  }

  private static func observe(_ path: URL, maximumBytes: Int) throws
    -> (Observation, RegularFileObservation?)
  {
    let parent: DirectoryHandle?
    do {
      parent = try DirectoryHandle.readDirectoryIfPresent(at: path.deletingLastPathComponent())
    } catch CoreError.unsafePath {
      return (.blocked, nil)
    }
    guard let parent else { return (.missing(nil), .missing) }
    let directory = try parent.objectIdentity
    let file = try parent.observeRegularFile(
      path.lastPathComponent, maximumBytes: maximumBytes, requireUnshared: true)
    switch file {
    case .missing: return (.missing(directory), file)
    case .other(let identity): return (.other(directory, identity), file)
    case .regular(let identity, let executable, let bytes):
      return (
        .regular(
          directory, identity, executable: executable, digest: FileHash.sha256Hex(data: bytes)),
        file
      )
    }
  }
}

struct ProducerPatchPlan {
  struct Edit {
    let producer: ProducerPatchProducer
    let selectors: [String]
    let path: String
    let native: URL
    let before: Data
    let after: Data
    let executable: Bool
  }

  private(set) var native = ProducerPatchNativeInputs()
  private(set) var edits: [Edit] = []
  private var findings: [ProducerPatchSkip]
  private var remaining = ProducerPatchInputs.limits.entries
  var skipped: [ProducerPatchSkip] {
    findings.sorted {
      if !$0.path.path.utf8.elementsEqual($1.path.path.utf8) {
        return $0.path.path.utf8.lexicographicallyPrecedes($1.path.path.utf8)
      }
      return $0.reason.rawValue < $1.reason.rawValue
    }
  }

  init(skipped: [ProducerPatchSkip]) {
    findings = skipped
    remaining -= skipped.count
  }

  mutating func skip(_ path: URL, _ reason: ProducerPatchSkip.Reason) throws {
    try charge()
    findings.append(.init(path: path, reason: reason))
  }

  private mutating func charge() throws {
    guard remaining > 0 else { throw CoreError.invalidState("producer patch entry budget") }
    remaining -= 1
  }

  mutating func compare(
    _ copy: ProducerPatchRoutes.Copy, resources: [String: URL], lineage: ProducerPatchLineage
  ) throws {
    let origin = try lineage.origin(for: copy, replayed: resources)
    guard case .owned(let context) = origin else {
      if case .skip(let reason) = origin { try skip(copy.target, reason) }
      return
    }
    let record = lineage.resource(copy.resource)
    guard let source = resources[copy.resource] else {
      throw ProducerPatchError.lockedInputUnavailable
    }
    var pending: [Edit] = []
    try scan(
      record.entries, source: source, target: copy.target, prefix: record.path,
      context: context, pending: &pending)
    if let support = copy.support {
      var root = source
      for _ in record.path.split(separator: "/") where record.path != "." {
        root.deleteLastPathComponent()
      }
      try scan(
        record.support, source: root, target: support, prefix: ".",
        context: context, pending: &pending)
    }
    if let git = context.gitSource, case .git(let commit) = context.producer.base {
      try lineage.verifyGit(git, commit: commit) { matches in
        for edit in pending {
          if try matches(edit.path, edit.before, edit.executable) {
            edits.append(edit)
          } else {
            findings.append(.init(path: edit.native, reason: .transformed))
          }
        }
      }
    } else {
      edits += pending
    }
  }

  private mutating func scan(
    _ entries: [LedgerEntry], source: URL, target: URL, prefix: String,
    context: ProducerPatchLineage.Context, pending: inout [Edit]
  ) throws {
    for entry in entries where entry.kind != .directory {
      try Task.checkCancellation()
      try charge()
      let targetFile = Self.child(target, entry.path)
      guard entry.kind == .file else {
        findings.append(.init(path: targetFile, reason: .nonRegular))
        continue
      }
      let path = prefix == "." ? entry.path : entry.path == "." ? prefix : prefix + "/" + entry.path
      guard path != "." else {
        findings.append(.init(path: targetFile, reason: .missingPathAttribution))
        continue
      }
      guard let captured = try native.read(targetFile) else {
        findings.append(.init(path: targetFile, reason: .nonRegular))
        continue
      }
      switch captured {
      case .missing: findings.append(.init(path: targetFile, reason: .deleted))
      case .other: findings.append(.init(path: targetFile, reason: .nonRegular))
      case .regular(_, let mode, let bytes):
        guard mode == entry.executable else {
          findings.append(.init(path: targetFile, reason: .modeChanged))
          continue
        }
        let baseFile = Self.child(source, entry.path)
        let parent = try DirectoryHandle.readDirectory(at: baseFile.deletingLastPathComponent())
        guard let count = entry.byteCount,
          case .regular(_, let executable, let base) = try parent.observeRegularFile(
            baseFile.lastPathComponent, maximumBytes: count),
          base.count == count, executable == entry.executable
        else { throw ProducerPatchError.lockedInputUnavailable }
        if let entries = context.releaseEntries {
          guard let archived = entries[Data(path.utf8)], archived.kind == .file,
            archived.executable == entry.executable, archived.byteCount == count,
            archived.object == "sha256:" + FileHash.sha256Hex(data: base)
          else {
            findings.append(.init(path: targetFile, reason: .missingPathAttribution))
            continue
          }
        }
        guard Self.isText(base), Self.isText(bytes) else {
          findings.append(.init(path: targetFile, reason: .binary))
          continue
        }
        guard base == Self.normalized(base) else {
          findings.append(.init(path: targetFile, reason: .uncleanSource))
          continue
        }
        let edited = Self.normalized(bytes)
        guard edited != base else { continue }
        pending.append(
          .init(
            producer: context.producer, selectors: context.selectors,
            path: path, native: targetFile, before: base, after: edited, executable: executable))
      }
    }
  }

  /// Compare modified copies before assigning edits to a package, including overlapping roots.
  mutating func coalesce() {
    struct File: Hashable {
      let source: String
      let package: String?
      let base: ProducerPatchBase
      let path: Data
    }
    let files = Dictionary(grouping: edits) {
      File(
        source: $0.producer.source, package: $0.producer.package, base: $0.producer.base,
        path: Data($0.path.utf8))
    }
    edits = files.values.compactMap { copies in
      let owner = copies.min {
        $0.producer.root.utf8.lexicographicallyPrecedes($1.producer.root.utf8)
      }!
      guard copies.allSatisfy({ $0.before == owner.before && $0.after == owner.after }) else {
        for copy in Set(copies.map(\.native)) {
          findings.append(.init(path: copy, reason: .conflictingEdits))
        }
        return nil
      }
      return .init(
        producer: owner.producer, selectors: Array(Set(copies.flatMap(\.selectors))).sorted(),
        path: owner.path, native: owner.native, before: owner.before, after: owner.after,
        executable: owner.executable)
    }
  }

  private static func child(_ directory: URL, _ path: String) -> URL {
    path == "." ? directory : directory.appendingPathComponent(path)
  }

  private static func isText(_ bytes: Data) -> Bool {
    !bytes.contains(0) && String(data: bytes, encoding: .utf8) != nil
  }

  private static func normalized(_ bytes: Data) -> Data {
    let start = bytes.starts(with: [239, 187, 191]) ? bytes.startIndex + 3 : bytes.startIndex
    let body = bytes[start...]
    guard body.contains(13) else { return body }
    var result = Data()
    result.reserveCapacity(body.count)
    for index in body.indices {
      if body[index] == 13, index + 1 < body.endIndex, body[index + 1] == 10 { continue }
      result.append(body[index])
    }
    return result
  }
}
