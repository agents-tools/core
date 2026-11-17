import Foundation

/// An owned complete candidate. Renderers receive values, never writable filesystem authority.
package struct PrivateTreeEntry {
  package enum Content {
    case directory
    case file(Data, executable: Bool = false)
    case boundFile(
      bindings: Set<String>, executable: Bool = false,
      render: (RuntimeBindingValues) throws -> Data)
    case symlink(String)
  }
  package let relativePath: String
  package let content: Content
  package init(_ relativePath: String, content: Content) {
    self.relativePath = relativePath
    self.content = content
  }
}

struct PrivateTree {
  let entries: [PrivateTreeEntry]
  let provider: any RuntimeBindingProvider
  let environment: RuntimeEnvironment
  let inputBytes: Int
  let metadataBytes: Int

  init(
    entries: [PrivateTreeEntry], provider: any RuntimeBindingProvider,
    environment: RuntimeEnvironment
  ) throws {
    let limits = LedgerLimits.standard
    guard entries.count <= limits.entries else {
      throw CoreError.invalidState("private tree exceeds member limit")
    }
    var bytes = 0
    var contentBytes = 0
    var paths = Set<Data>()
    var directories = Set<Data>()
    var links: [(String, String)] = []
    for entry in entries {
      let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
      guard !parts.isEmpty, parts.count < limits.depth / 4,
        parts.allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
        }),
        paths.insert(Data(entry.relativePath.utf8)).inserted
      else { throw CoreError.unsafePath("invalid or duplicate private tree member") }
      bytes += entry.relativePath.utf8.count
      switch entry.content {
      case .directory: directories.insert(Data(entry.relativePath.utf8))
      case .file(let data, _):
        bytes += data.count
        contentBytes += data.count
      case .boundFile(let names, _, _):
        guard names.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
          throw CoreError.invalidState("invalid private tree bindings")
        }
        bytes += names.reduce(0) { $0 + $1.utf8.count }
      case .symlink(let destination):
        links.append((entry.relativePath, destination))
        bytes += destination.utf8.count
      }
      guard bytes <= limits.resourceBytes else {
        throw CoreError.invalidState("private tree exceeds byte limit")
      }
    }
    for entry in entries {
      let parts = entry.relativePath.split(separator: "/").dropLast()
      for count in 1...max(1, parts.count) where count <= parts.count {
        guard directories.contains(Data(parts.prefix(count).joined(separator: "/").utf8)) else {
          throw CoreError.unsafePath("private tree member lacks a real directory parent")
        }
      }
    }
    // Resolve the closed candidate graph with the same containment/dangling semantics
    // as PathSafety.linkStaysInside, before creating anything or requesting bindings.
    let destinations = Dictionary(uniqueKeysWithValues: links.map { (Data($0.0.utf8), $0.1) })
    var work = 0
    for (path, destination) in links {
      guard !destination.hasPrefix("/"), !destination.isEmpty, !destination.contains("\0") else {
        throw CoreError.unsafePath("private tree link escapes container")
      }
      var pending = destination.split(separator: "/").reversed().map(String.init)
      var resolved = path.split(separator: "/").dropLast().map(String.init)
      var expansions = 0
      while let component = pending.popLast() {
        work += 1
        guard work <= limits.nodes else {
          throw CoreError.invalidState("private tree link work limit")
        }
        if component == "." { continue }
        if component == ".." {
          guard !resolved.isEmpty else {
            throw CoreError.unsafePath("private tree link escapes container")
          }
          resolved.removeLast()
          continue
        }
        let key = Data((resolved + [component]).joined(separator: "/").utf8)
        if let next = destinations[key] {
          expansions += 1
          guard expansions <= 32, !next.hasPrefix("/") else {
            throw CoreError.unsafePath("private tree link cycle or escape")
          }
          pending += next.split(separator: "/").reversed().map(String.init)
        } else if paths.contains(key) {
          resolved.append(component)
        } else {
          guard !pending.contains("..") else {
            throw CoreError.unsafePath("private tree dangling link escapes container")
          }
          break
        }
      }
    }
    self.entries = entries.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    self.provider = provider
    self.environment = environment
    inputBytes = bytes
    metadataBytes = bytes - contentBytes
  }

  func construct(
    named name: String, in container: DirectoryHandle, bytes: inout Int,
    admit: (FileSnapshot, FileAccessEvidence, [TreeMemberAccess]?) throws -> Void,
    validate: () throws -> Void
  )
    throws
  {
    let root = try container.createPrivateDirectory(name)
    func parent(_ path: String) throws -> (DirectoryHandle, String) {
      let parts = path.split(separator: "/").map(String.init)
      var directory = root
      for component in parts.dropLast() { directory = try directory.child(component) }
      return (directory, parts.last!)
    }
    for entry in entries {
      if case .directory = entry.content {
        let (directory, name) = try parent(entry.relativePath)
        _ = try directory.createPrivateDirectory(name)
      }
    }
    var files: [(PrivateTreeEntry, PrivateFileHandle)] = []
    for entry in entries {
      let executable: Bool
      switch entry.content {
      case .file(_, let flag), .boundFile(_, let flag, _): executable = flag
      default: continue
      }
      let (directory, name) = try parent(entry.relativePath)
      files.append((entry, try directory.createPrivateFile(name, executable: executable)))
    }
    for entry in entries {
      if case .symlink(let destination) = entry.content {
        let (directory, name) = try parent(entry.relativePath)
        try directory.link(name, destination: destination)
      }
    }
    guard let physicalRoot = PathSafety.realPath(root.url.path) else {
      throw CoreError.invalidState("private tree root changed during construction")
    }
    for entry in entries {
      if case .symlink = entry.content {
        guard
          try PathSafety.linkStaysInside(
            root.url.appendingPathComponent(entry.relativePath), root: physicalRoot)
        else {
          throw CoreError.unsafePath("private tree link escapes container")
        }
      }
    }
    try validate()
    let emptySnapshot = try FileSnapshot.read(name, from: container)!
    let rootAccess = try container.requirePrivateAccess(name)
    let memberAccess = try TreeMemberAccess.capture(
      name, in: container, snapshot: emptySnapshot, requirePrivate: true)
    try admit(emptySnapshot, rootAccess, memberAccess)
    var names = Set<String>()
    for entry in entries {
      if case .boundFile(let bindings, _, _) = entry.content { names.formUnion(bindings) }
    }
    var values: [String: Data] = [:]
    guard metadataBytes <= LedgerLimits.standard.resourceBytes - bytes else {
      throw CoreError.invalidState("private trees exceed byte limit")
    }
    bytes += metadataBytes
    do {
      for binding in names.sorted() {
        let data = try provider.value(for: binding, environment: environment)
        guard data.count <= LedgerLimits.standard.resourceBytes - bytes else {
          throw CoreError.invalidState("private tree exceeds byte limit")
        }
        bytes += data.count
        values[binding] = data
      }
      let bound = RuntimeBindingValues(values)
      for (entry, file) in files {
        let data: Data
        switch entry.content {
        case .file(let bytes, _): data = bytes
        case .boundFile(_, _, let render): data = try render(bound)
        default: preconditionFailure()
        }
        guard data.count <= LedgerLimits.standard.resourceBytes - bytes else {
          throw CoreError.invalidState("private tree exceeds byte limit")
        }
        bytes += data.count
        try validate()
        try file.write(data)
      }
    } catch {
      throw CoreError.invalidState("private tree could not resolve or construct its content")
    }
    let sealed = try FileSnapshot.read(name, from: container)!
    try container.synchronize(name, as: sealed)
  }
}
