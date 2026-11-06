import AgentsCore
import AgentsManifest
import Foundation

/// Links symbolic declarations to exact, ordered contributions. The caller owns the read lock
/// and consumes borrowed resources inside `withLinkedComponents`; no state is published here.
package enum ComponentLinker {
  package static func withLinkedComponents<T>(
    document: DeclarationDocument, store: StateStore, platform: DeclarationPlatform,
    preserving pins: [String: SourceRevision] = [:],
    directPins: [ComponentKey: SourceRevision] = [:],
    _ body: (LinkedComponents, SourceResolutionSession) throws -> T
  ) throws -> T {
    try SourceResolutionSession.withTemporaryRead(store: store) { session in
      let linker = Linking(
        document: document, store: store, platform: platform,
        session: session, directPins: directPins)
      let graph = try linker.solve(preserving: pins)
      return try body(graph, session)
    }
  }
}

struct LinkingDocument {
  let declaration: Declaration
  let document: DeclarationDocument
  let view: SourceSnapshot
  let manifestPath: String
  let producer: Bool

}

struct SourceAddress {
  let id: String
  let source: SourceDeclaration?
  let contained: SourceSnapshot?
  let root: String
}

struct GroupIdentity: Hashable {
  let snapshot: SourceSnapshotID
  let root: String
  let name: String
}

struct RequirementSearch: Error {
  let constraints: [SourceConstraint]
}

final class Linking {
  let document: DeclarationDocument
  let store: StateStore
  let platform: DeclarationPlatform
  let session: SourceResolutionSession
  let directPins: [ComponentKey: SourceRevision]
  let budget = LinkBudget()
  var documents: [GroupIdentity: LinkingDocument] = [:]
  var nonGit = Set<String>()
  var git = Set<String>()
  var addresses: [String: SourceAddress] = [:]
  private var componentMaps: [GroupIdentity: [String: [SourceMapEntry]]] = [:]
  private var positions: [GroupIdentity: [String: SourceMapEntry]] = [:]

  init(
    document: DeclarationDocument, store: StateStore, platform: DeclarationPlatform,
    session: SourceResolutionSession, directPins: [ComponentKey: SourceRevision]
  ) {
    self.document = document
    self.store = store
    self.platform = platform
    self.session = session
    self.directPins = directPins
  }

  func solve(preserving pins: [String: SourceRevision]) throws -> LinkedComponents {
    try budget.step(document.metrics.evaluationSteps)
    let declaration = try ManifestProjection.declaration(
      of: document, environment: store.environment)
    let packageRoot =
      store.scope == .user ? store.directory : store.environment.projectDirectory
    let root = try SourceSnapshot(
      snapshot: SourceSnapshotID(
        source: "local:" + packageRoot.path,
        revision: "live"), pin: nil,
      root: packageRoot,
      localEnvironment: SourceEnvironment(
        projectDirectory: packageRoot, homeDirectory: store.environment.homeDirectory),
      liveRoot: packageRoot)
    session.register(root)
    let context = LinkingDocument(
      declaration: declaration, document: document, view: root,
      manifestPath: store.scope == .user ? "Agents.swift" : ".agent/Agents.swift",
      producer: false)
    try budget.manifest(root.snapshot, path: context.manifestPath, bytes: document.bytes.count)
    guard let result = try search(root: context, choices: pins) else {
      throw LinkError.incompatible(lastFailure)
    }
    return result
  }

  var lastFailure: [SourceConstraint] = []

  func componentLocations(at pointer: String, in context: LinkingDocument) throws
    -> [SourceMapEntry]
  {
    let key = GroupIdentity(
      snapshot: context.view.snapshot, root: context.view.discoveryPath, name: "")
    if componentMaps[key] == nil {
      var locations: [String: [SourceMapEntry]] = [:]
      var firstPositions: [String: SourceMapEntry] = [:]
      for entry in context.document.sourceMap.entries {
        try budget.step()
        if firstPositions[entry.pointer] == nil { firstPositions[entry.pointer] = entry }
        let path = entry.pointer.split(separator: "/")
        let prefix: Int
        if path.first == "components", path.count >= 2 {
          prefix = 2
        } else if path.first == "groups", path.count >= 4, path[2] == "components" {
          prefix = 4
        } else {
          continue
        }
        locations["/" + path.prefix(prefix).joined(separator: "/"), default: []].append(entry)
      }
      componentMaps[key] = locations
      positions[key] = firstPositions
    }
    return componentMaps[key]?[pointer] ?? []
  }

  func position(at pointer: String, in context: LinkingDocument) throws -> SourceMapEntry? {
    _ = try componentLocations(at: pointer, in: context)
    return positions[
      GroupIdentity(snapshot: context.view.snapshot, root: context.view.discoveryPath, name: "")
    ]?[pointer]
  }

  private func search(root: LinkingDocument, choices initial: [String: SourceRevision]) throws
    -> LinkedComponents?
  {
    struct Decision {
      let source: String
      let candidates: [SourceRevision]
      var next: Int
    }
    var choices = initial
    var decisions: [Decision] = []
    func backtrack() throws -> Bool {
      while var decision = decisions.popLast() {
        try budget.step()
        choices.removeValue(forKey: decision.source)
        if decision.next < decision.candidates.count {
          choices[decision.source] = decision.candidates[decision.next]
          decision.next += 1
          decisions.append(decision)
          return true
        }
      }
      return false
    }
    while true {
      try budget.step()
      let pass = Expansion(linking: self, choices: choices, emit: false)
      do { try pass.expandRoot(root) } catch let error as RequirementSearch {
        lastFailure = error.constraints
        if try backtrack() { continue }
        return nil
      }
      if let next = pass.constraints.keys.filter({ choices[$0] == nil }).sorted().first {
        let requirements = pass.constraints[next]!
        let candidates = try session.candidates(
          for: addresses[next]!.source!,
          requirements: requirements.map(\.requirement), spending: budget.step)
        try budget.step(candidates.count)
        guard let candidate = candidates.first else {
          lastFailure = requirements
          if try backtrack() { continue }
          return nil
        }
        decisions.append(Decision(source: next, candidates: candidates, next: 1))
        choices[next] = candidate
        continue
      }
      let final = Expansion(linking: self, choices: choices, emit: true)
      do { try final.expandRoot(root) } catch let error as RequirementSearch {
        lastFailure = error.constraints
        if try backtrack() { continue }
        return nil
      }
      return try final.result()
    }
  }

  func address(_ alias: String?, in context: LinkingDocument, chain: [SourceSpan]) throws
    -> SourceAddress
  {
    try budget.step(chain.count + 1)
    guard let alias, alias != "." else {
      return SourceAddress(
        id: context.view.snapshot.source, source: nil,
        contained: context.view, root: context.view.discoveryPath)
    }
    guard let source = context.declaration.sources[alias] else {
      throw LinkError.missing("source alias '\(alias)'", chain)
    }
    if context.producer, context.view.localEnvironment == nil, source.kind == .local {
      let raw = source.location
      guard !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.contains("\\") else {
        throw LinkError.invalid("producer-local source must stay inside its package", chain)
      }
      let relative = try PathSafety.sanitizeSubpath(raw)
      let directory = try context.view.directory().appendingPathComponent(relative)
        .standardizedFileURL
      let path = try context.view.relativePath(directory)
      let sourceID =
        path == "."
        ? context.view.packageIdentity
        : context.view.packageIdentity + ":contained:" + String(path.utf8.count) + ":" + path
      let discoveryPath = try PathSafety.sanitizeSubpath(path + "/" + (source.path ?? "."))
      let view = try SourceSnapshot(
        snapshot: SourceSnapshotID(source: sourceID, revision: context.view.snapshot.revision),
        pin: context.view.pin, root: context.view.root, discoveryPath: discoveryPath,
        packageIdentity: context.view.packageIdentity)
      guard source.requirement == nil else {
        throw LinkError.invalid("contained sources inherit their producer snapshot", chain)
      }
      try budget.snapshot(view.snapshot)
      session.register(view)
      return SourceAddress(id: sourceID, source: nil, contained: view, root: view.discoveryPath)
    }
    let id = try source.identity(environment: store.environment)
    let root = try PathSafety.sanitizeSubpath(source.path ?? ".")
    let result = SourceAddress(id: id, source: source, contained: nil, root: root)
    addresses[id] = result
    return result
  }

  func view(_ address: SourceAddress, pin: SourceRevision? = nil) throws -> SourceSnapshot? {
    if let contained = address.contained { return contained }
    let source = address.source!
    guard source.kind != .wellKnown else {
      throw LinkError.invalid("skill indexes cannot supply package resources", [])
    }
    if let pin {
      let view = try session.snapshot(source, at: pin)
      try budget.snapshot(view.snapshot)
      return view
    }
    if source.requirement != nil {
      git.insert(address.id)
      return nil
    }
    if try nonGit.contains(address.id)
      || (!git.contains(address.id) && !session.isGitSource(source))
    {
      nonGit.insert(address.id)
      let view = try session.localSnapshot(source)
      try budget.snapshot(view.snapshot)
      return view
    }
    git.insert(address.id)
    return nil
  }

  func producer(_ view: SourceSnapshot, chain: [SourceSpan]) throws -> LinkingDocument {
    let key = GroupIdentity(snapshot: view.snapshot, root: view.discoveryPath, name: "")
    if let existing = documents[key] { return existing }
    let root = try view.directory()
    let file = root.appendingPathComponent(
      root.lastPathComponent == ".agent" ? "Agents.swift" : ".agent/Agents.swift")
    let relative = try view.relativePath(file)
    let handle = try FileHandle(forReadingFrom: view.resource(relative))
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: ManifestLimits.Input.bytes + 1) ?? Data()
    guard bytes.count <= ManifestLimits.Input.bytes else {
      throw LinkError.budget("manifest input bytes")
    }
    try budget.manifest(
      view.snapshot, path: relative, bytes: bytes.count)
    let coordinates = try JSONEncoder().encode([view.snapshot.source, view.discoveryPath, relative])
    let identity = DocumentIdentity("source:" + String(decoding: coordinates, as: UTF8.self))
    let document = try DeclarationDocument(bytes: Array(bytes), identity: identity)
    let environment = RuntimeEnvironment(
      projectDirectory: view.localEnvironment.map {
        $0.projectDirectory.appendingPathComponent(view.discoveryPath)
      } ?? root,
      homeDirectory: view.localEnvironment?.homeDirectory ?? store.environment.homeDirectory,
      environment: [:])
    try budget.step(document.metrics.evaluationSteps)
    let declaration = try ManifestProjection.declaration(of: document, environment: environment)
    let result = LinkingDocument(
      declaration: declaration, document: document, view: view,
      manifestPath: relative, producer: true)
    documents[key] = result
    return result
  }
}
