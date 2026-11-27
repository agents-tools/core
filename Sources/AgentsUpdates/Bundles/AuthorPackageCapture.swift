import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Components
import Foundation

struct AuthorCapture {
  let root: DirectoryHandle
  private(set) var items: [BundleItem] = []
  private(set) var objects: [String: Data] = [:]
  private(set) var warnings: [AuthorPackageWarning] = []
  private var members = Set<MarketplaceMemberKey>()
  private var limits = LedgerLimits.standard

  init(root: DirectoryHandle) { self.root = root }

  mutating func addFirstParty(
    _ specification: AuthorPackageSpecification, store: StateStore, policy: AuthorPackagePolicy
  ) throws {
    if !specification.instructions.isEmpty || !specification.skills.isEmpty {
      try policy.source.effective.require(.local(at: store.environment.projectDirectory))
      try policy.source.effective.require(.local)
    }
    for name in specification.instructions {
      try addInstruction(name)
    }
    for path in specification.skills {
      let resource = try capture(path, as: "skill")
      guard resource.entries.first?.kind == .directory,
        let manifest = resource.entries.first(where: { $0.path == "SKILL.md" }),
        let digest = manifest.object, let bytes = objects[digest]
      else { throw CoreError.invalidSource("expected complete skill directory: " + path) }
      let name = try SkillSnapshotReader.manifestName(bytes, path: path + "/SKILL.md")
      var tree = BundleTree()
      let discovery = try tree.add(resource, under: "payload")
      try add(.skills, name: name, tree: tree, discovery: discovery)
    }
    if !specification.mcpServers.isEmpty {
      try policy.source.effective.require(.inline)
      let declaration = try store.readDeclaration()
      for name in specification.mcpServers {
        let matches = declaration.components.filter {
          if case .mcpServer(let declared, _, _, _, _, _) = $0 { return declared == name }
          return false
        }
        guard matches.count == 1, let component = matches.first,
          case .mcpServer(_, let transport, _, let condition, let native, let registry) = component,
          condition == nil, registry == nil
        else {
          throw CoreError.invalidSource("expected one unconditional authored MCP: " + name)
        }
        try addMCP(name: name, transport: transport, native: native, policy: policy)
      }
    }
  }

  private mutating func addInstruction(_ name: String) throws {
    guard Declaration.isInstructionName(name) else {
      throw CoreError.invalidSource("invalid authored instruction name: " + name)
    }
    let path = "instructions/" + name + ".md"
    let resource = try capture(".agent/" + path, as: path, fileOnly: true)
    guard let entry = resource.entries.first, entry.kind == .file,
      let digest = entry.object, let bytes = objects[digest]
    else { throw CoreError.invalidSource("expected authored instruction file: " + name) }
    let section = try Instructions.validateSource(bytes, id: name, allowRestrictions: true)
    var tree = BundleTree()
    _ = try tree.add(resource, under: "payload")
    for relative in try AuthorContentAudit.references(
      in: section.content, at: path, confinedTo: "instructions"
    ) {
      let output = "payload/" + relative
      if tree.entries[output]?.kind == .file { continue }
      let reference = try capture(".agent/" + relative, as: relative, fileOnly: true)
      _ = try tree.add(reference, under: "payload")
    }
    try add(.instructions, name: name, tree: tree, discovery: "payload")
  }

  private mutating func addMCP(
    name: String, transport: MCPTransportDeclaration,
    native: NativeConfiguration, policy: AuthorPackagePolicy
  ) throws {
    let sanitized = try AuthorMCP.sanitize(transport, native: native, named: name)
    var transport = sanitized.transport
    var tree = BundleTree()
    if case .stdio(var run) = transport {
      guard run.executableSource == nil, run.workingDirectory?.source == nil else {
        throw CoreError.invalidSource("authored MCP cannot read an unlocked source: " + name)
      }
      if run.executable.contains("/") {
        let path = try AuthorMCP.resourcePath(run.executable)
        let program = try capture(path, as: path, fileOnly: true)
        guard program.entries[0].executable else {
          throw CoreError.invalidSource("authored MCP resource is not executable: " + name)
        }
        run.executable = try tree.add(program, under: "payload")
      }
      if var working = run.workingDirectory {
        let path = try AuthorMCP.resourcePath(working.path)
        let directory = try capture(path, as: path)
        guard directory.entries[0].kind == .directory else {
          throw CoreError.invalidSource("authored MCP working directory is not a directory")
        }
        working.path = try tree.add(directory, under: "payload")
        run.workingDirectory = working
      }
      transport = .stdio(run)
    }
    noteOmissions(sanitized.omissions, name: name)
    let configuration = try AuthorMCP.configuration(
      name: name, transport: transport, native: sanitized.native)
    if let url = configuration.object?["transport"]?.object?["url"]?.text {
      try policy.source.effective.require(.http(url), reference: name)
    }
    try add(
      .mcpServer, name: name, tree: tree, discovery: nil, configuration: configuration,
      origin: .inline)
  }

  private mutating func add(
    _ kind: BundleItem.Kind, name: String, tree: BundleTree, discovery: String?,
    configuration: LedgerValue? = nil, origin: SourceOrigin = .local
  ) throws {
    let entries = tree.sortedEntries
    let revision = try ResolvedLedgerCodec.digest(
      [ResolvedLedgerCodec.digest(entries), ResolvedLedgerCodec.digest(configuration)])
    try append(
      .init(
        kind: kind, name: name, sources: [.init(origin: origin, revision: revision)],
        entries: entries, discovery: discovery, configuration: configuration, mcpRegistry: nil))
  }

  mutating func append(_ item: BundleItem) throws {
    let key = MarketplaceMemberKey(
      kind: DeclaredComponentKind(rawValue: item.kind.rawValue)!, name: item.name)
    guard members.insert(key).inserted else {
      throw CoreError.invalidSource("duplicate authored package member: " + item.name)
    }
    try item.validate()
    items.append(item)
  }

  mutating func absorb(_ captured: [String: Data]) throws {
    for (digest, bytes) in captured where objects[digest] == nil {
      guard bytes.count <= limits.objectBytes else {
        throw CoreError.invalidSource("package exceeds content object budget")
      }
      objects[digest] = bytes
      limits.objectBytes -= bytes.count
    }
  }

  mutating func noteOmissions(_ count: Int, name: String) {
    if count > 0 {
      warnings.append(
        .init(
          member: .init(kind: .mcpServer, name: name), reason: .credentialOmitted, count: count))
    }
  }

  private mutating func capture(
    _ source: String, as path: String, fileOnly: Bool = false
  ) throws -> LedgerResource {
    try BundleItem.validatePath(source)
    try AuthorContentAudit.requirePublishable(source)
    let components = source.split(separator: "/").map(String.init)
    guard components.first != ".agent" || source.hasPrefix(".agent/instructions/") else {
      throw CoreError.unsafePath("private project state is not an authored resource")
    }
    var parent = root
    for name in components.dropLast() {
      guard let child = try parent.directory(name) else { throw CoreError.notFound(source) }
      parent = child
    }
    let leaf = components.last!
    if fileOnly, try ContentAuditFiles.kind(leaf, in: parent) != .regular {
      throw CoreError.invalidSource("expected an authored regular file: " + source)
    }
    if path == "skill" {
      guard let skill = try parent.directory(leaf),
        try ContentAuditFiles.kind("SKILL.md", in: skill) == .regular
      else { throw CoreError.invalidSource("expected complete skill directory: " + source) }
    }
    var remaining = limits
    remaining.objectBytes = remaining.resourceBytes
    if fileOnly { remaining.entries = min(remaining.entries, 1) }
    let captured = try parent.capturePortableTree(leaf, limits: remaining) { relative in
      if !relative.isEmpty {
        try BundleItem.validatePath(relative)
        try AuthorContentAudit.requirePublishable(source + "/" + relative)
      }
    }
    if fileOnly, captured.entries.first?.kind != .file {
      throw CoreError.invalidSource("expected an authored regular file: " + source)
    }
    try absorb(captured.objects)
    limits.entries -= captured.entries.count
    limits.resourceBytes -= captured.entries.reduce(0) { $0 + ($1.byteCount ?? 0) }
    return .init(
      kind: .embedded, source: "", path: path, hash: "", entries: captured.entries)
  }
}
