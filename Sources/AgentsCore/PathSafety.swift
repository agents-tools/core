import Foundation

public enum PathSafety {
  package static func sanitizeSubpath(_ subpath: String) throws -> String {
    let normalized = subpath.replacingOccurrences(of: "\\", with: "/")
    if normalized.contains("\0") {
      throw CoreError.unsafePath("subpath contains null byte: \(subpath)")
    }
    if normalized.isEmpty || normalized == "." {
      return "."
    }
    if normalized.hasPrefix("/")
      || normalized.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
    {
      throw CoreError.unsafePath("subpath must be relative: \(subpath)")
    }
    let segments = normalized.split(separator: "/", omittingEmptySubsequences: true).map(
      String.init)
    for segment in segments where segment == ".." {
      throw CoreError.unsafePath("subpath contains path traversal segment: \(subpath)")
    }
    let safe = segments.filter { $0 != "." }.joined(separator: "/")
    return safe.isEmpty ? "." : safe
  }

  package static func isSubpathSafe(base: URL, subpath: String) -> Bool {
    let normalized = subpath.replacingOccurrences(of: "\\", with: "/")
    let target = base.appendingPathComponent(normalized).standardizedFileURL
    return isContained(target, in: base)
  }

  package static func resolvedChild(base: URL, subpath: String) throws -> URL {
    let safe = try sanitizeSubpath(subpath)
    let target = safe == "." ? base : base.appendingPathComponent(safe)
    guard isContained(target, in: base) else {
      throw CoreError.unsafePath("\(subpath) escapes \(base.path)")
    }
    return target
  }

  /// Whether the symbolic link at `link` stays inside the real directory `root` wherever that
  /// tree is placed. Its destination is resolved from the link's directory as the kernel does,
  /// byte by byte and following links inside `root`. An absolute destination, a step above `root`
  /// and a link loop leave it. Resolution may stop at a missing entry, since the kernel cannot pass
  /// it, but only when no `..` follows: another filesystem may look the name up differently, as
  /// another entry of the same directory, which is itself checked.
  package static func linkStaysInside(_ link: URL, root: String) throws -> Bool {
    guard let directory = realPath(link.deletingLastPathComponent().path),
      directory.utf8.elementsEqual(root.utf8) || directory.utf8.starts(with: (root + "/").utf8)
    else { return false }
    let relative = directory.utf8.dropFirst(min(root.utf8.count + 1, directory.utf8.count))
    var current = components(String(decoding: relative, as: UTF8.self)).compactMap { $0 }
    var pending = try components(FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    var expansions = 0
    func isParent(_ component: String?) -> Bool { component?.utf8.elementsEqual("..".utf8) == true }
    while !pending.isEmpty {
      guard let next = pending.removeFirst() else { return false }
      if next.utf8.elementsEqual(".".utf8) { continue }
      if isParent(next) {
        guard current.popLast() != nil else { return false }
        continue
      }
      let path = ([root] + current + [next]).joined(separator: "/")
      if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
        expansions += 1
        guard expansions <= 32 else { return false }
        pending = components(destination) + pending
        continue
      }
      guard FileManager.default.fileExists(atPath: path) else {
        return !pending.contains { $0 == nil || isParent($0) }
      }
      current.append(next)
    }
    return true
  }

  /// A path's components split at `/` bytes, so no Unicode grapheme hides a separator; an
  /// absolute path yields a single nil.
  private static func components(_ path: String) -> [String?] {
    guard path.utf8.first != UInt8(ascii: "/") else { return [nil] }
    return path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
  }

  /// The path as the kernel resolves it for a reader, or nil when it does not exist.
  package static func realPath(_ path: String) -> String? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
  }

  package static func isContained(_ target: URL, in base: URL) -> Bool {
    let basePath = base.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    return targetPath == basePath || targetPath.hasPrefix(basePath + "/")
  }

  public static func sanitizeName(_ name: String) -> String {
    let lowercased = name.lowercased()
    let replaced = lowercased.replacingOccurrences(
      of: #"[^a-z0-9._]+"#,
      with: "-",
      options: .regularExpression
    )
    let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    let limited = String(trimmed.prefix(255))
    return limited.isEmpty ? "unnamed-skill" : limited
  }

  package static func relativePath(_ path: String, to base: String) -> String {
    let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    let baseComponents = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
    var index = 0
    while index < pathComponents.count, index < baseComponents.count,
      pathComponents[index] == baseComponents[index]
    {
      index += 1
    }
    let up = Array(repeating: "..", count: max(0, baseComponents.count - index))
    let down = pathComponents.dropFirst(index)
    let components = up + down
    return components.isEmpty ? "." : components.joined(separator: "/")
  }
}
