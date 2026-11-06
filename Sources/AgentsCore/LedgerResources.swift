import Foundation

/// Resource trees retain empty directories, symlink spellings and executable files separately.
package enum LedgerResources {
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
      if supporting, !visiting.insert(path).inserted { return }
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
        if embed, let sourceRoot {
          let target = file.deletingLastPathComponent().appendingPathComponent(link)
            .standardizedFileURL
          guard !link.hasPrefix("/"), PathSafety.isContained(target, in: sourceRoot),
            PathSafety.isContained(
              target.resolvingSymlinksInPath(), in: sourceRoot.resolvingSymlinksInPath())
          else {
            throw CoreError.unsafePath("resource link escapes source snapshot")
          }
          if !PathSafety.isContained(target, in: url) {
            let relative = PathSafety.relativePath(target.path, to: sourceRoot.path)
            let parts = relative.split(separator: "/")
            for count in 1..<parts.count {
              let ancestor = parts.prefix(count).joined(separator: "/")
              support[ancestor] = .init(path: ancestor, kind: .directory, executable: false)
            }
            try collect(target, path: relative, supporting: true)
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
    var all = resource.support
    let hasSupport = !all.isEmpty
    let selected =
      hasSupport
      ? try PathSafety.resolvedChild(base: destination, subpath: resource.path) : destination
    if hasSupport {
      try FileSystem.createDirectory(at: selected.deletingLastPathComponent())
      all += resource.entries.map { original in
        var entry = original
        entry.path = original.path == "." ? resource.path : resource.path + "/" + original.path
        return entry
      }
    } else {
      all = resource.entries
    }
    var unique: [String: LedgerEntry] = [:]
    for entry in all {
      guard unique[entry.path] == nil || unique[entry.path] == entry else {
        throw CoreError.invalidState("conflicting resource support")
      }
      unique[entry.path] = entry
    }
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
        guard let link = entry.link else { throw CoreError.invalidState("missing link") }
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: link)
      }
    }
  }
}
