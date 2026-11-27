import CPlatform
import Foundation

/// The central directory and its local headers must agree before any member can be used.
struct VerifiedVCSArchive {
  static let compressedLimit = 64 * 1024 * 1024
  static let expandedLimit = 128 * 1024 * 1024
  static let memberLimit = 10_000

  let treeDigest: String
  let byteDigest: String
  let entries: [PrivateTreeEntry]

  init(_ bytes: Data) throws {
    guard bytes.count <= Self.compressedLimit, bytes.count >= 22 else {
      throw SourceAccessError.invalidArchive
    }
    let members = try bytes.withUnsafeBytes { try Self.members($0) }
    entries = members.values.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    treeDigest =
      "sha256:"
      + FileHash.hashRecords(
        entries.map { entry in
          switch entry.content {
          case .directory: ("directory\0" + entry.relativePath, Data())
          case .file(let content, let executable):
            ((executable ? "executable\0" : "file\0") + entry.relativePath, content)
          case .symlink(let target): ("link\0" + entry.relativePath, Data(target.utf8))
          case .boundFile: preconditionFailure("archive entries contain only verified bytes")
          }
        })
    byteDigest = "sha256:" + FileHash.sha256Hex(data: bytes)
  }

  func extract(
    named name: String, in parent: DirectoryHandle, environment: RuntimeEnvironment
  ) throws -> URL {
    let tree = try PrivateTree(
      entries: entries, provider: NoArchiveBindings(), environment: environment)
    var bytes = 0
    try tree.construct(
      named: name, in: parent, bytes: &bytes, admit: { _, _, _ in }, validate: {})
    return parent.url.appendingPathComponent(name, isDirectory: true)
  }

  func matches(_ root: URL) throws -> Bool {
    let parent = try DirectoryHandle(at: root.deletingLastPathComponent())
    guard let snapshot = try FileSnapshot.read(root.lastPathComponent, from: parent) else {
      return false
    }
    do {
      _ = try parent.requirePrivateAccess(root.lastPathComponent)
      _ = try TreeMemberAccess.capture(
        root.lastPathComponent, in: parent, snapshot: snapshot, requirePrivate: true)
    } catch {
      return false
    }
    let directory = try parent.child(root.lastPathComponent)
    for entry in entries {
      let path = entry.relativePath.split(separator: "/").map(String.init)
      var container = directory
      for name in path.dropLast() {
        guard let child = try? container.child(name) else { return false }
        container = child
      }
      let name = path.last!
      guard let info = try container.info(name) else { return false }
      switch entry.content {
      case .directory:
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else { return false }
      case .file(let data, let executable):
        guard info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o7777 == (executable ? 0o700 : 0o600),
          info.st_size == data.count,
          try container.read(name, matching: info, maximumBytes: data.count) == data
        else { return false }
      case .symlink(let target):
        guard info.st_mode & S_IFMT == S_IFLNK,
          try container.readLink(name).utf8.elementsEqual(target.utf8)
        else { return false }
      case .boundFile:
        return false
      }
    }
    var count = 0
    var pending = snapshot.children ?? []
    while let entry = pending.popLast() {
      count += 1
      if count > entries.count { return false }
      pending += entry.snapshot.children ?? []
    }
    return count == entries.count
  }

  private static func members(_ buffer: UnsafeRawBufferPointer) throws -> [Data: PrivateTreeEntry] {
    func u16(_ at: Int) -> Int { Int(buffer[at]) | Int(buffer[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    func name(_ offset: Int, _ count: Int) -> String? {
      String(bytes: buffer[offset..<(offset + count)], encoding: .utf8)
    }
    guard
      let end = (max(0, buffer.count - 65_557)...(buffer.count - 22)).reversed().first(where: {
        u32($0) == 0x0605_4b50 && $0 + 22 + u16($0 + 20) == buffer.count
      })
    else { throw SourceAccessError.invalidArchive }
    let count = u16(end + 10)
    let central = u32(end + 16)
    guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == count,
      count > 0, count <= Self.memberLimit, central + u32(end + 12) == end
    else { throw SourceAccessError.invalidArchive }
    var cursor = central
    var total = 0
    var records: [Range<Int>] = []
    var root: Data?
    var explicit = Set<Data>()
    var spellings: [String: Data] = [:]
    var result: [Data: PrivateTreeEntry] = [:]

    func put(_ path: String, _ content: PrivateTreeEntry.Content, explicit isExplicit: Bool) throws
    {
      let key = Data(path.utf8)
      let folded = path.precomposedStringWithCanonicalMapping.lowercased()
      guard spellings[folded] == nil || spellings[folded] == key,
        !isExplicit || explicit.insert(key).inserted
      else { throw SourceAccessError.invalidArchive }
      spellings[folded] = key
      if let existing = result[key] {
        guard case .directory = existing.content, case .directory = content else {
          throw SourceAccessError.invalidArchive
        }
      }
      guard result.count < Self.memberLimit || result[key] != nil else {
        throw SourceAccessError.invalidArchive
      }
      result[key] = PrivateTreeEntry(path, content: content)
    }

    for _ in 0..<count {
      try Task.checkCancellation()
      guard cursor + 46 <= end, u32(cursor) == 0x0201_4b50 else {
        throw SourceAccessError.invalidArchive
      }
      let flags = u16(cursor + 8)
      let method = u16(cursor + 10)
      let crc = u32(cursor + 16)
      let compressed = u32(cursor + 20)
      let expanded = u32(cursor + 24)
      let length = u16(cursor + 28)
      let external = u32(cursor + 38)
      let local = u32(cursor + 42)
      let start = cursor + 46
      let next = start + length + u16(cursor + 30) + u16(cursor + 32)
      guard next <= end, u16(cursor + 34) == 0, flags & ~0x080e == 0,
        method == 0 || method == 8, expanded <= Self.expandedLimit - total,
        length > 0, length <= 4096, let member = name(start, length),
        local + 30 <= central, u32(local) == 0x0403_4b50, u16(local + 6) == flags,
        u16(local + 8) == method, u16(local + 26) == length
      else { throw SourceAccessError.invalidArchive }
      cursor = next
      total += expanded
      let dataStart = local + 30 + length + u16(local + 28)
      var dataEnd = dataStart + compressed
      guard dataEnd <= central,
        buffer[(local + 30)..<(local + 30 + length)].elementsEqual(buffer[start..<(start + length)])
      else { throw SourceAccessError.invalidArchive }
      if flags & 8 != 0 {
        if dataEnd + 4 <= central, u32(dataEnd) == 0x0807_4b50 { dataEnd += 4 }
        guard dataEnd + 12 <= central,
          u32(dataEnd) == crc, u32(dataEnd + 4) == compressed, u32(dataEnd + 8) == expanded
        else { throw SourceAccessError.invalidArchive }
        dataEnd += 12
      } else {
        guard u32(local + 14) == crc, u32(local + 18) == compressed, u32(local + 22) == expanded
        else { throw SourceAccessError.invalidArchive }
      }
      records.append(local..<dataEnd)

      let directory = member.hasSuffix("/")
      let path = directory ? member.dropLast() : member[...]
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard !parts.isEmpty, parts.count <= 40,
        parts.allSatisfy({ part in
          !part.isEmpty && part != "." && part != ".." && part.lowercased() != ".git"
            && !part.contains("\\") && !part.contains(":")
            && part.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        })
      else { throw SourceAccessError.invalidArchive }
      let enclosing = Data(parts[0].utf8)
      guard root == nil || root == enclosing else { throw SourceAccessError.invalidArchive }
      root = enclosing
      let mode = external >> 16
      let type = mode & 0o170000
      guard mode & 0o7000 == 0,
        directory
          ? (type == 0 || type == 0o040000) && expanded == 0
          : (type == 0 || type == 0o100000 || type == 0o120000)
      else { throw SourceAccessError.invalidArchive }
      var content = Data(count: expanded)
      guard
        content.withUnsafeMutableBytes({ (output: UnsafeMutableRawBufferPointer) in
          platform_zip_member(
            buffer.baseAddress!.advanced(by: dataStart).assumingMemoryBound(to: UInt8.self),
            compressed, UInt32(method), output.baseAddress?.assumingMemoryBound(to: UInt8.self),
            expanded, UInt32(crc))
        })
      else { throw SourceAccessError.invalidArchive }
      if parts.count == 1 {
        guard directory, explicit.insert(Data()).inserted else {
          throw SourceAccessError.invalidArchive
        }
        continue
      }
      let relative = parts.dropFirst()
      for depth in 1..<relative.count {
        try put(relative.prefix(depth).joined(separator: "/"), .directory, explicit: false)
      }
      let memberContent: PrivateTreeEntry.Content
      if directory {
        memberContent = .directory
      } else if type == 0o120000 {
        guard let target = String(data: content, encoding: .utf8), !target.contains("\\"),
          content.count <= 4096
        else { throw SourceAccessError.invalidArchive }
        memberContent = .symlink(target)
      } else {
        memberContent = .file(content, executable: mode & 0o111 != 0)
      }
      try put(relative.joined(separator: "/"), memberContent, explicit: true)
    }
    var consumed = 0
    for interval in records.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      guard interval.lowerBound == consumed else { throw SourceAccessError.invalidArchive }
      consumed = interval.upperBound
    }
    guard cursor == end, consumed == central, root != nil else {
      throw SourceAccessError.invalidArchive
    }
    return result
  }
}

struct NoArchiveBindings: RuntimeBindingProvider {
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    throw SourceAccessError.invalidArchive
  }
}
