import Foundation

/// Resource trees retain empty directories, symlink spellings and executable files separately.
package enum LedgerResources {
  /// The snapshot must have been extracted from the pinned commit when it includes support
  /// outside the resource's hashed tree. The saved hash is compared to the captured bytes.
  package static func captureLockedGit(
    _ resource: LedgerResource, snapshotRoot: URL
  ) throws -> (entries: [LedgerEntry], support: [LedgerEntry], objects: [String: Data]) {
    let root = try DirectoryHandle.readDirectory(at: snapshotRoot)
    var limits = LedgerLimits.standard
    var objects: [String: Data] = [:]
    func capture(
      _ path: String, matching expected: [LedgerEntry], recursive: Bool
    ) throws -> [LedgerEntry] {
      try ledgerPath(path)
      var parent = root
      let name: String
      if path == "." {
        parent = try DirectoryHandle.readDirectory(at: snapshotRoot.deletingLastPathComponent())
        name = snapshotRoot.lastPathComponent
      } else {
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
          guard let child = try parent.directory(part) else { throw CoreError.notFound(path) }
          parent = child
        }
        name = parts.last!
      }
      let expected = Dictionary(uniqueKeysWithValues: expected.map { ($0.path, $0) })
      let result = try parent.capturePortableTree(name, limits: limits, recursive: recursive) {
        relative in
        guard expected[relative.isEmpty ? "." : relative] != nil else {
          throw CoreError.invalidState("unexpected entry in locked resource: " + path)
        }
      }
      guard expected.count == result.entries.count,
        result.entries.allSatisfy({ entry in
          var recorded = entry
          recorded.object = nil
          return expected[entry.path] == recorded
        })
      else { throw CoreError.invalidState("locked resource shape changed: " + path) }
      for (digest, data) in result.objects where objects[digest] == nil {
        guard data.count <= limits.objectBytes else {
          throw CoreError.invalidState("locked object budget")
        }
        limits.objectBytes -= data.count
        objects[digest] = data
      }
      limits.entries -= result.entries.count
      limits.resourceBytes -= result.entries.reduce(0) { $0 + ($1.byteCount ?? 0) }
      return result.entries
    }
    let entries = try capture(resource.path, matching: resource.entries, recursive: true)
    let digest: String
    if entries.first?.kind == .file {
      digest = entries[0].object!
    } else {
      digest = try "sha256:" + FileHash.portableTreeHash(entries, objects: objects)
    }
    guard digest == resource.hash else {
      throw CoreError.invalidState("locked resource digest changed: " + resource.path)
    }
    var support: [LedgerEntry] = []
    for record in resource.support {
      var expected = record
      expected.path = "."
      var entry = try capture(record.path, matching: [expected], recursive: false)[0]
      entry.path = record.path
      support.append(entry)
    }
    return (entries, support, objects)
  }

  /// A live resource keeps its authored alias for link matching and uses its checked directory
  /// for reads and new links.
  package static func liveEditSource(
    _ resource: LedgerResource, ledger: ResolvedLedger, roots: [String: URL]
  ) throws -> (authored: URL, directory: URL) {
    guard resource.kind == .liveEdit, let location = resource.location,
      let source = ledger.sources[resource.source], source.kind == .local,
      let sourceLocation = source.location
    else { throw CoreError.invalidState("live edit skill needs a recorded local source") }
    let authored = try location.resolve(roots: roots).standardizedFileURL
    let root = try sourceLocation.resolve(roots: roots).standardizedFileURL
    guard let sourcePath = PathSafety.realPath(root.path),
      let directoryPath = PathSafety.realPath(authored.path)
    else { throw CoreError.notFound("live edit skill source: \(authored.path)") }
    guard
      sourcePath == "/" || directoryPath.utf8.elementsEqual(sourcePath.utf8)
        || directoryPath.utf8.starts(with: (sourcePath + "/").utf8)
    else {
      throw CoreError.unsafePath(
        "Live edit source \(authored.path) resolves outside its recorded source directory "
          + "\(root.path). Point the source alias inside that directory and retry.")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &directory),
      directory.boolValue
    else { throw CoreError.notFound("live edit skill source: \(authored.path)") }
    return (authored, URL(fileURLWithPath: directoryPath, isDirectory: true))
  }

  package static func capture(_ url: URL, embed: Bool, limits: LedgerLimits, sourceRoot: URL? = nil)
    throws -> (
      entries: [LedgerEntry], support: [LedgerEntry], objects: [String: Data], hash: String,
      flags: [String: Bool]
    )
  {
    var entries: [LedgerEntry] = []
    var objects: [String: Data] = [:]
    var support: [String: LedgerEntry] = [:]
    var visiting = Set<String>()
    var bytes = 0
    var expandedBytes = 0
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw CoreError.notFound("locked resource")
    }
    func collect(_ file: URL, path: String, supporting: Bool = false) throws {
      if supporting {
        if !visiting.insert(path).inserted { return }
        let parts = path.split(separator: "/")
        for count in 1..<parts.count {
          let ancestor = parts.prefix(count).joined(separator: "/")
          if support[ancestor] == nil {
            support[ancestor] = .init(path: ancestor, kind: .directory, executable: false)
          }
        }
      }
      func append(_ entry: LedgerEntry) {
        if supporting { support[entry.path] = entry } else { entries.append(entry) }
      }
      try Task.checkCancellation()
      guard entries.count + support.count < limits.entries else {
        throw CoreError.invalidState("resource entry budget")
      }
      let info = try FileManager.default.attributesOfItem(atPath: file.path)
      let type = info[.type] as? FileAttributeType
      if type == .typeDirectory {
        append(.init(path: path, kind: .directory, executable: false))
        for name in try FileManager.default.contentsOfDirectory(atPath: file.path).sorted() {
          try collect(
            file.appendingPathComponent(name), path: path == "." ? name : path + "/" + name,
            supporting: supporting)
        }
      } else if type == .typeSymbolicLink {
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        append(.init(path: path, kind: .symlink, link: link, executable: false))
        if let sourceRoot {
          // Resolve components in filesystem order: an intermediate link changes the meaning
          // of a following "..". Freeze every supporting link as well as the final target.
          var resolved = file.deletingLastPathComponent()
          enum Step {
            case part(String)
            case finish(String)
          }
          var pending: [Step] = link.split(separator: "/").reversed().map { .part(String($0)) }
          var followed: Set<String> = [file.path]
          guard !link.hasPrefix("/") else { throw CoreError.unsafePath("absolute resource link") }
          while let step = pending.popLast() {
            guard case .part(let part) = step else {
              if case .finish(let path) = step { followed.remove(path) }
              continue
            }
            if part == "." { continue }
            if part == ".." {
              resolved.deleteLastPathComponent()
            } else {
              resolved.appendPathComponent(part)
            }
            guard PathSafety.isContained(resolved, in: sourceRoot) else {
              throw CoreError.unsafePath("resource link escapes source snapshot")
            }
            let info = try FileManager.default.attributesOfItem(atPath: resolved.path)
            if info[.type] as? FileAttributeType == .typeSymbolicLink {
              guard followed.insert(resolved.path).inserted else {
                throw CoreError.unsafePath("resource link cycle")
              }
              if !PathSafety.isContained(resolved, in: url) {
                try collect(
                  resolved, path: PathSafety.relativePath(resolved.path, to: sourceRoot.path),
                  supporting: true)
              }
              let next = try FileManager.default.destinationOfSymbolicLink(atPath: resolved.path)
              guard !next.hasPrefix("/") else {
                throw CoreError.unsafePath("absolute resource link")
              }
              pending.append(.finish(resolved.path))
              resolved.deleteLastPathComponent()
              pending += next.split(separator: "/").reversed().map { .part(String($0)) }
            }
          }
          if !PathSafety.isContained(resolved, in: url) {
            let relative = PathSafety.relativePath(resolved.path, to: sourceRoot.path)
            let parts = relative.split(separator: "/")
            for count in 1..<parts.count {
              let ancestor = parts.prefix(count).joined(separator: "/")
              if support[ancestor] == nil {
                support[ancestor] = .init(path: ancestor, kind: .directory, executable: false)
              }
            }
            try collect(resolved, path: relative, supporting: true)
          }
        }
      } else if type == .typeRegular {
        let size = (info[.size] as? NSNumber)?.intValue ?? 0
        guard size >= 0, size <= limits.resourceBytes - expandedBytes else {
          throw CoreError.invalidState("expanded resource byte budget")
        }
        expandedBytes += size
        let object: String?
        if embed {
          guard size <= limits.objectBytes else {
            throw CoreError.invalidState("resource byte budget")
          }
          let data = try FileSystem.read(at: file)
          guard data.count == size else {
            throw CoreError.invalidState("resource changed during freeze")
          }
          let digest = "sha256:" + FileHash.sha256Hex(data: data)
          if objects[digest] == nil {
            guard size <= limits.objectBytes - bytes else {
              throw CoreError.invalidState("resource aggregate byte budget")
            }
            bytes += size
            objects[digest] = data
          }
          object = digest
        } else {
          object = nil
        }
        append(
          .init(
            path: path, kind: .file, object: object,
            executable: ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0,
            byteCount: size))
      } else {
        throw CoreError.invalidState("unsupported locked resource entry")
      }
    }
    try collect(url, path: ".")
    let hash =
      try "sha256:"
      + (isDirectory.boolValue
        ? FileHash.folderHash(url) : FileHash.sha256Hex(file: url))
    let flags =
      try isDirectory.boolValue
      ? FileHash.executableFlags(url)
      : [
        ".":
          ((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
          .intValue ?? 0) & 0o111 != 0
      ]
    return (entries, support.keys.sorted().map { support[$0]! }, objects, hash, flags)
  }

  /// Writes only beneath a caller-owned disposable directory. This is not publication.
  package static func materialize(
    _ resource: LedgerResource, objects: [String: Data], at destination: URL
  ) throws {
    guard resource.kind == .embedded else {
      throw CoreError.invalidState("resource is not embedded")
    }
    let unique = try validatedEntries(resource)
    for entry in unique.values.sorted(by: { $0.path < $1.path }) {
      try Task.checkCancellation()
      let file =
        entry.path == "."
        ? destination
        : try PathSafety.resolvedChild(base: destination, subpath: entry.path)
      switch entry.kind {
      case .directory: try FileSystem.createDirectory(at: file)
      case .file:
        guard let id = entry.object, let bytes = objects[id],
          "sha256:" + FileHash.sha256Hex(data: bytes) == id
        else {
          throw CoreError.invalidState("missing or corrupt content object")
        }
        try FileSystem.createDirectory(at: file.deletingLastPathComponent())
        try FileSystem.write(bytes, to: file)
        try FileManager.default.setAttributes(
          [.posixPermissions: entry.executable ? 0o755 : 0o644], ofItemAtPath: file.path)
      case .symlink:
        try FileSystem.createDirectory(at: file.deletingLastPathComponent())
        guard let link = entry.link else { throw CoreError.invalidState("missing link") }
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: link)
      }
    }
  }
}
