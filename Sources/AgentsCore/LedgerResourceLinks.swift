import Foundation

extension LedgerResources {
  /// Validates the graph in the coordinates used by materialization, before any writes.
  /// Supporting entries extend ownership to the source root; otherwise the selected tree is root.
  static func validatedEntries(_ resource: LedgerResource) throws -> [String: LedgerEntry] {
    var entries: [String: LedgerEntry] = [:]
    for original in resource.support
      + resource.entries.map({ original in
        var entry = original
        if !resource.support.isEmpty {
          entry.path =
            original.path == "."
            ? resource.path
            : resource.path == "." ? original.path : resource.path + "/" + original.path
        }
        return entry
      })
    {
      try ledgerPath(original.path)
      guard entries[original.path] == nil || entries[original.path] == original else {
        throw CoreError.invalidState("conflicting resource support")
      }
      entries[original.path] = original
    }
    if !resource.support.isEmpty {
      let parents = resource.path.split(separator: "/").dropLast()
      for count in 0...parents.count {
        let path = count == 0 ? "." : parents.prefix(count).joined(separator: "/")
        if entries[path] == nil {
          entries[path] = .init(path: path, kind: .directory, executable: false)
        }
      }
    }
    for path in entries.keys where path != "." {
      let parts = path.split(separator: "/")
      guard entries["."]?.kind == .directory else {
        throw CoreError.invalidState("resource ancestor is not a directory")
      }
      for count in 1..<parts.count {
        guard entries[parts.prefix(count).joined(separator: "/")]?.kind == .directory else {
          throw CoreError.invalidState("resource ancestor is not a directory")
        }
      }
    }
    enum Step {
      case part(String)
      case finish(String)
    }
    var resolved: [String: [String]] = [:]
    for entry in entries.values where entry.kind == .symlink && resolved[entry.path] == nil {
      guard entry.path != "." else {
        throw CoreError.invalidState("resource root link escapes tree")
      }
      var path = entry.path.split(separator: "/").dropLast().map(String.init)
      var active: Set<String> = [entry.path]
      var pending: [Step] = [.finish(entry.path)]
      func parts(_ link: String?) throws -> [Step] {
        guard let link, !link.isEmpty, !link.hasPrefix("/"), !link.contains("\0"),
          !link.contains("\\")
        else { throw CoreError.invalidState("invalid resource link") }
        return link.split(separator: "/").reversed().map { .part(String($0)) }
      }
      pending += try parts(entry.link)
      while let step = pending.popLast() {
        switch step {
        case .finish(let link):
          resolved[link] = path
          active.remove(link)
        case .part(let part):
          let current = path.isEmpty ? "." : path.joined(separator: "/")
          guard entries[current]?.kind == .directory else {
            throw CoreError.invalidState("resource link traverses non-directory")
          }
          if part == "." { continue }
          if part == ".." {
            guard !path.isEmpty else { throw CoreError.invalidState("resource link escapes tree") }
            path.removeLast()
            continue
          }
          let next = (path + [part]).joined(separator: "/")
          guard let target = entries[next] else {
            throw CoreError.invalidState("resource link has missing support")
          }
          if target.kind == .symlink {
            if let cached = resolved[next] {
              path = cached
            } else {
              guard active.insert(next).inserted else {
                throw CoreError.invalidState("resource link cycle")
              }
              pending.append(.finish(next))
              pending += try parts(target.link)
            }
          } else {
            path.append(part)
          }
        }
      }
    }
    return entries
  }
}
