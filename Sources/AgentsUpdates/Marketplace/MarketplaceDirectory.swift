import AgentsCore
import AgentsManifest
import Foundation

public struct RegisteredMarketplace: Equatable, Sendable {
  public let registration: MarketplaceRegistration
  public let scope: InstallScope
}

/// A named catalog is only a discovery address. Installing freezes its resolved origin in the package pin.
public enum MarketplaceDirectory {
  public static func list(
    scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [RegisteredMarketplace] {
    let scopes: [InstallScope] = scope == .project ? [.user, .project] : [.user]
    var result: [String: RegisteredMarketplace] = [:]
    for layer in scopes {
      let store = StateStore(scope: layer, environment: environment)
      let entries = try store.withReadLock { try read(store).entries }
      for entry in entries {
        var origin = entry.origin
        if layer == .user, !origin.location.hasPrefix("/") {
          let home = RuntimeEnvironment(
            projectDirectory: environment.homeDirectory, homeDirectory: environment.homeDirectory,
            environment: environment.environment)
          if let file = origin.fileURL(environment: home) {
            origin = try MarketplaceOrigin(
              kind: origin.kind, location: file.path, ref: origin.ref, subpath: origin.subpath)
          }
        }
        result[entry.name] = try RegisteredMarketplace(
          registration: MarketplaceRegistration(name: entry.name, origin: origin), scope: layer)
      }
    }
    return result.values.sorted { $0.registration.name < $1.registration.name }
  }

  public static func lookup(
    _ name: String, scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> MarketplaceRegistration {
    guard
      let entry = try list(scope: scope, environment: environment).first(where: {
        $0.registration.name == name
      })
    else { throw CoreError.notFound("marketplace registration " + name) }
    return entry.registration
  }

  public static func register(
    _ entry: MarketplaceRegistration, scope: InstallScope,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws {
    try edit(scope: scope, environment: environment) { entries in
      if let old = entries.first(where: { $0.name == entry.name }) {
        guard old == entry else { throw MarketplaceError.originConflict(entry.name) }
      } else {
        entries.append(entry)
      }
    }
  }

  public static func unregister(
    _ name: String, scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws {
    try edit(scope: scope, environment: environment) { entries in
      guard let index = entries.firstIndex(where: { $0.name == name }) else {
        throw CoreError.notFound(
          "marketplace registration " + name + " in " + scope.rawValue + " scope")
      }
      entries.remove(at: index)
    }
  }

  static func trustedHostedOrigins(environment: RuntimeEnvironment) throws -> (
    origins: Set<MarketplaceOrigin>, evidence: TargetPrecondition
  ) {
    let store = StateStore(scope: .user, environment: environment)
    let directory = try read(store)
    return (Set(directory.entries.map(\.origin).filter { $0.kind == .hosted }), directory.file)
  }

  private static func edit(
    scope: InstallScope, environment: RuntimeEnvironment,
    change: (inout [MarketplaceRegistration]) throws -> Void
  ) throws {
    let store = StateStore(scope: scope, environment: environment)
    let root = scope == .project ? try store.captureExistingProjectRoot() : nil
    try store.withLock(existingRoot: root) {
      let current = try read(store)
      var entries = current.entries
      try change(&entries)
      guard current.entries != entries else { return }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      func quote(_ text: String) throws -> String {
        String(decoding: try encoder.encode(text), as: UTF8.self)
      }
      var yaml = entries.isEmpty ? "{}\n" : ""
      for entry in entries.sorted(by: { $0.name < $1.name }) {
        let origin = entry.origin
        yaml +=
          try quote(entry.name) + ":\n  " + origin.kind.rawValue + ": " + quote(origin.location)
          + "\n"
        if let ref = origin.ref { yaml += try "  ref: " + quote(ref) + "\n" }
        if let path = origin.subpath { yaml += try "  subpath: " + quote(path) + "\n" }
      }
      let transaction = FileTransaction(store: store)
      try transaction.replace(
        current.file.url, with: .data(Data(yaml.utf8)), expecting: current.file)
      try transaction.commit()
    }
  }

  private static func read(_ store: StateStore) throws -> (
    entries: [MarketplaceRegistration], file: TargetPrecondition
  ) {
    let url = store.directory.appendingPathComponent(StateStore.marketplaceDirectoryFileName)
    let file = try TargetPrecondition.readingFile(url)
    guard let bytes = file.bytes else { return ([], file.evidence) }
    let reader = try YAMLReader(bytes: Array(bytes), identity: DocumentIdentity(url.path))
    func string(_ node: YAMLNode) throws -> String {
      guard let scalar = node.scalar, !scalar.decimalTag,
        scalar.quoted || YAMLScalar.classify(scalar.text) == .string
      else { throw MarketplaceError.invalidOrigin("expected a string in " + url.lastPathComponent) }
      return scalar.text
    }
    guard let pairs = reader.root.pairs else {
      throw MarketplaceError.invalidOrigin("expected a mapping of marketplace names")
    }
    let entries = try pairs.map { key, value in
      let name = try string(key)
      guard let fields = value.pairs else { throw MarketplaceError.invalidOrigin(name) }
      var kind: MarketplaceOrigin.Kind?
      var location: String?
      var ref: String?
      var subpath: String?
      for field in fields {
        switch try string(field.key) {
        case "directory", "git", "hosted":
          guard kind == nil else { throw MarketplaceError.invalidOrigin(name) }
          kind = MarketplaceOrigin.Kind(rawValue: try string(field.key))
          location = try string(field.value)
        case "ref": ref = try string(field.value)
        case "subpath": subpath = try string(field.value)
        default: throw MarketplaceError.invalidOrigin("unknown field in " + name)
        }
      }
      guard let kind, let location else { throw MarketplaceError.invalidOrigin(name) }
      return try MarketplaceRegistration(
        name: name,
        origin: MarketplaceOrigin(kind: kind, location: location, ref: ref, subpath: subpath))
    }
    return (entries, file.evidence)
  }
}
