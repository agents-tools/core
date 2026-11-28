import AgentsCore
import AgentsManifest
import Foundation

/// Explicit author inputs. This file is independent of installation intent and recipients.
public struct AuthorPackageSpecification: Codable, Equatable, Sendable {
  public let package: BundlePackage
  public let instructions: [String]
  public let skills: [String]
  public let mcpServers: [String]
  public let lockedMembers: [MarketplaceMemberKey]

  public init(
    package: BundlePackage, instructions: [String] = [], skills: [String] = [],
    mcpServers: [String] = [], lockedMembers: [MarketplaceMemberKey] = []
  ) {
    self.package = package
    self.instructions = instructions
    self.skills = skills
    self.mcpServers = mcpServers
    self.lockedMembers = lockedMembers
  }
}

public struct AuthorPackagePath: Encodable, Equatable, Sendable {
  public let member: MarketplaceMemberKey
  public let entry: LedgerEntry
}

/// An immutable archive and the inventory a caller can present before writing or publishing it.
public struct AuthorPackageArtifact: Sendable {
  public let archive: Data
  public let inspection: BundleInspection
  public var digest: String { inspection.archiveDigest }
  public let includedPaths: [AuthorPackagePath]
  public let contentFindings: [ContentAuditFinding]
  public let policyFindings: [OrganizationPolicyFinding]
  public let warnings: [AuthorPackageWarning]
  let registrySchemas: [MCPRegistryServer]
}

public struct AuthorPackageWarning: Encodable, Equatable, Sendable {
  public enum Reason: String, Encodable, Sendable { case credentialOmitted }

  public let member: MarketplaceMemberKey
  public let reason: Reason
  public let count: Int
}

public enum AuthorPackageOperations {
  public static let specificationFilename = "author-package.json"

  /// Creates a complete new author directory under an existing parent. Never edits a project
  /// in place or creates installation state. An identical scaffold is a no-op.
  @discardableResult
  public static func scaffold(
    _ package: BundlePackage, at destination: URL,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> AuthorPackageSpecification {
    let policy = try AuthorPackagePolicy(environment)
    try policy.admit(package)
    let specification = AuthorPackageSpecification(
      package: package, skills: ["skills/getting-started"])
    var tree = AuthorOutputTree()
    try tree.add(specificationFilename, bytes: ResolvedLedgerCodec.bytes(specification))
    try tree.add(".agent/agents.yaml", bytes: Data("version: 1\n".utf8))
    try tree.add(
      "skills/getting-started/SKILL.md",
      bytes: Data(
        """
        ---
        name: getting-started
        description: Describe when to use this skill.
        ---

        # Getting started

        Describe the workflow here.

        """.utf8))
    try policy.validate()
    try tree.write(to: destination, beforeCommit: policy.validate)
    return specification
  }

  /// Reads the explicit author specification and captures its selected closure without writes.
  public static func preview(
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> AuthorPackageArtifact {
    let root = try projectRoot(environment)
    let bytes = try root.readRegularFile(
      specificationFilename, maximumBytes: LedgerLimits.standard.encodedBytes)
    try LedgerAdmission.check(bytes, limits: .standard)
    let specification = try JSONDecoder().decode(AuthorPackageSpecification.self, from: bytes)
    return try capture(
      specification, root: root, environment: environment, registrySchemas: registrySchemas)
  }

  /// Captures explicitly supplied selections instead of reading a specification file.
  public static func preview(
    _ specification: AuthorPackageSpecification,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> AuthorPackageArtifact {
    let root = try projectRoot(environment)
    return try capture(
      specification, root: root, environment: environment, registrySchemas: registrySchemas)
  }

  /// A later process must supply the digest from its review when rebuilding for publication.
  public static func rebuild(
    expectedDigest: String, environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> AuthorPackageArtifact {
    try checking(
      preview(environment: environment, registrySchemas: registrySchemas),
      expectedDigest: expectedDigest)
  }

  public static func rebuild(
    _ specification: AuthorPackageSpecification, expectedDigest: String,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> AuthorPackageArtifact {
    try checking(
      preview(specification, environment: environment, registrySchemas: registrySchemas),
      expectedDigest: expectedDigest)
  }

  /// Opens an explicitly chosen archive once. Publication retains these bytes even if the file
  /// is subsequently edited or deleted. Supply an expected digest for a separate earlier review.
  public static func readArchive(
    at source: URL, expectedDigest: String? = nil,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> AuthorPackageArtifact {
    let (parent, name) = try outputLocation(source)
    let bytes = try parent.readRegularFile(name, maximumBytes: LedgerLimits.standard.encodedBytes)
    let policy = try AuthorPackagePolicy(environment, registrySchemas: registrySchemas)
    let artifact = try report(bytes, warnings: [], policy: policy)
    if let expectedDigest { return try checking(artifact, expectedDigest: expectedDigest) }
    return artifact
  }

  /// Writes the exact captured archive to a new file beneath an existing parent.
  public static func write(
    _ artifact: AuthorPackageArtifact, to destination: URL,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws {
    let policy = try outputPolicy(artifact, environment: environment)
    let (parent, name) = try outputLocation(destination)
    if try parent.publishRegularFile(
      named: name, bytes: artifact.archive, beforeCommit: policy.validate)
    {
      return
    }
    guard
      let existing = try? parent.readRegularFile(name, maximumBytes: artifact.archive.count),
      existing == artifact.archive
    else { throw CoreError.invalidState("artifact publication conflict: " + name) }
  }

  /// Publishes the captured archive and its authored summary to an existing local team catalog.
  @discardableResult
  public static func publish(
    _ artifact: AuthorPackageArtifact, to catalog: URL,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> MarketplaceRelease {
    try MarketplaceOperations.publishAdmitted(
      artifact.archive, inspection: artifact.inspection, to: catalog,
      summary: artifact.inspection.package.description, scope: .project, environment: environment,
      registrySchemas: artifact.registrySchemas)
  }

  private static func checking(
    _ artifact: AuthorPackageArtifact, expectedDigest: String
  ) throws -> AuthorPackageArtifact {
    guard artifact.digest == expectedDigest else {
      throw CoreError.invalidState("package digest differs from the reviewed archive")
    }
    return artifact
  }

  static func outputLocation(_ url: URL) throws -> (DirectoryHandle, String) {
    try requireLocalFileURL(url)
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0)
    else { throw CoreError.unsafePath("expected a local artifact path") }
    return (try .readDirectory(at: url.deletingLastPathComponent()), name)
  }

  private static func projectRoot(_ environment: RuntimeEnvironment) throws -> DirectoryHandle {
    let url = environment.projectDirectory
    try requireLocalFileURL(url)
    return try .readDirectory(at: url)
  }

  static func requireLocalFileURL(_ url: URL) throws {
    guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true,
      url.path.hasPrefix("/"), !url.path.utf8.contains(0)
    else { throw CoreError.unsafePath("expected a local file URL") }
  }

  static func outputPolicy(
    _ artifact: AuthorPackageArtifact, environment: RuntimeEnvironment
  ) throws -> AuthorPackagePolicy {
    let policy = try AuthorPackagePolicy(environment, registrySchemas: artifact.registrySchemas)
    _ = try policy.admit(artifact.inspection.archive)
    try policy.validate()
    return policy
  }

  private static func capture(
    _ specification: AuthorPackageSpecification, root: DirectoryHandle,
    environment: RuntimeEnvironment, registrySchemas: [MCPRegistryServer]
  ) throws -> AuthorPackageArtifact {
    let policy = try AuthorPackagePolicy(environment, registrySchemas: registrySchemas)
    try policy.admit(specification.package)
    let store = StateStore(scope: .project, environment: environment)
    return try store.withReadLock {
      var capture = AuthorCapture(root: root)
      try capture.addFirstParty(specification, store: store, policy: policy)
      if !specification.lockedMembers.isEmpty {
        try capture.addLocked(specification.lockedMembers, store: store, policy: policy)
      }
      let archive = try BundleArchive(
        package: specification.package, components: capture.items, objects: capture.objects)
      return try report(
        ResolvedLedgerCodec.bytes(archive), warnings: capture.warnings, policy: policy)
    }
  }

  private static func report(
    _ bytes: Data, warnings: [AuthorPackageWarning], policy: AuthorPackagePolicy
  ) throws -> AuthorPackageArtifact {
    let inspection = try BundleOperations.inspect(bytes)
    let findings = try policy.admit(inspection.archive)
    var audit = AuthorContentAudit()
    try audit.scan(archive: inspection.archive)
    try policy.validate()
    return .init(
      archive: bytes, inspection: inspection,
      includedPaths: inspection.components.flatMap { member in
        member.entries.filter { $0.path != "." }.map {
          AuthorPackagePath(member: member.marketplaceKey, entry: $0)
        }
      }, contentFindings: audit.findings, policyFindings: findings, warnings: warnings,
      registrySchemas: policy.registrySchemas)
  }
}

struct AuthorOutputTree: Sendable {
  var tree = BundleTree()
  var objects: [String: Data] = [:]

  mutating func add(_ path: String, bytes: Data) throws {
    let digest = BundleArchive.digest(bytes)
    try tree.insert(
      .init(path: path, kind: .file, object: digest, executable: false, byteCount: bytes.count))
    objects[digest] = bytes
  }

  func validatedEntries() throws -> [LedgerEntry] {
    let entries = tree.sortedEntries
    try AuthorContentAudit.validatePaths(entries)
    _ = try LedgerResources.validatedEntries(
      .init(kind: .embedded, source: "", path: ".", hash: "", entries: entries))
    return entries
  }

  func write(to destination: URL, beforeCommit: () throws -> Void) throws {
    let entries = try validatedEntries()
    let (parent, name) = try AuthorPackageOperations.outputLocation(destination)
    if try parent.publishPortableTree(
      named: name, entries: entries, objects: objects, beforeCommit: beforeCommit)
    {
      return
    }
    guard let existing = try? parent.capturePortableTree(name, admitting: { _ in }),
      existing.entries == entries, existing.objects == objects
    else { throw CoreError.invalidState("artifact publication conflict: " + name) }
  }
}
