import AgentsCore
import Foundation

/// A fixed source resource or explicitly live local path. Capture borrowed source
/// resources before their read scope ends; no borrowed URL is retained.
public struct MCPConnectionResource: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private enum Storage: Sendable {
    case live(URL, Identity)
    case captured(LedgerResource, [String: Data], [String: Bool])
  }
  private struct Identity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let targetDevice: UInt64
    let targetInode: UInt64
    let realPath: String
  }
  private let storage: Storage
  private let sourcePath: String
  let directory: Bool
  let byteCount: Int
  var sensitivePaths: [String] {
    if case .live(let url, let identity) = storage { return [url.path, identity.realPath] }
    return []
  }
  var isCaptured: Bool {
    if case .captured = storage { true } else { false }
  }
  var displayPath: String { sourcePath }
  var readDependencies: [ReadDependency] {
    sensitivePaths.map { .entry(URL(fileURLWithPath: $0).standardizedFileURL) }
  }
  public var description: String { "<MCP connection resource>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }

  /// Live directories preserve live content semantics; their physical identity is
  /// checked again immediately before starting the connection.
  public static func live(_ url: URL) throws -> Self {
    do {
      guard url.isFileURL else { throw MCPConnectionPreparationError.invalidResource }
      let url = url.standardizedFileURL
      let identity = try identity(url)
      let attributes = try FileManager.default.attributesOfItem(atPath: identity.realPath)
      let directory = attributes[.type] as? FileAttributeType == .typeDirectory
      guard directory || attributes[.type] as? FileAttributeType == .typeRegular else {
        throw MCPConnectionPreparationError.invalidResource
      }
      return Self(
        storage: .live(url, identity), sourcePath: url.path, directory: directory, byteCount: 0)
    } catch { throw MCPConnectionPreparationError.invalidResource }
  }

  /// Reads only the selected resource and its contained symlink support. The
  /// expected hash comes from the caller's exact linked/frozen selection.
  public static func capture(
    sourceRoot: URL, path: String, expectedHash: String,
    expectedExecutableFiles: [String: Bool]
  ) throws -> Self {
    do {
      let view = try SourceSnapshot(
        snapshot: .init(source: "selected", revision: expectedHash), pin: nil, root: sourceRoot)
      let url = try view.resource(path)
      try view.validateResourceTree(url)
      let captured = try LedgerResources.capture(
        url, embed: true, limits: .standard, sourceRoot: sourceRoot)
      guard captured.hash == expectedHash, captured.flags == expectedExecutableFiles else {
        throw MCPConnectionPreparationError.resourceChanged
      }
      let resource = LedgerResource(
        kind: .embedded, source: "selected", path: try view.relativePath(url),
        hash: captured.hash, entries: captured.entries, support: captured.support)
      let type =
        try FileManager.default.attributesOfItem(
          atPath: url.resolvingSymlinksInPath().path)[.type] as? FileAttributeType
      let directory = type == .typeDirectory
      guard directory || type == .typeRegular else {
        throw MCPConnectionPreparationError.invalidResource
      }
      let count = (captured.entries + captured.support).reduce(0) { $0 + ($1.byteCount ?? 0) }
      return Self(
        storage: .captured(resource, captured.objects, expectedExecutableFiles),
        sourcePath: resource.path, directory: directory, byteCount: count)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MCPConnectionPreparationError {
      throw error
    } catch { throw MCPConnectionPreparationError.invalidResource }
  }

  /// Selected retained closure only; never acquires a source or reads deployed settings.
  static func retaining(
    _ resource: LedgerResource, objects: [String: Data], gitRoot: URL?
  ) throws -> Self {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agents-mcp-capture-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let result = Result { () throws -> Self in
      let root: URL
      let path: String
      if resource.kind == .git {
        guard let gitRoot else { throw MCPConnectionPreparationError.invalidResource }
        root = gitRoot
        path = resource.path
      } else {
        guard resource.kind == .embedded || resource.kind == .artifact else {
          throw MCPConnectionPreparationError.invalidResource
        }
        let destination = workspace.appendingPathComponent("tree")
        var embedded = resource
        embedded.kind = .embedded
        try LedgerResources.materialize(embedded, objects: objects, at: destination)
        root = resource.support.isEmpty ? workspace : destination
        path = resource.support.isEmpty ? "tree" : resource.path
      }
      let view = try SourceSnapshot(
        snapshot: .init(source: "selected", revision: resource.hash), pin: nil, root: root)
      let file = try view.resource(path)
      try view.validateResourceTree(file)
      let captured = try LedgerResources.capture(
        file, embed: true, limits: .standard, sourceRoot: root)
      func metadata(_ entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.map { entry in
          var entry = entry
          entry.object = nil
          return entry
        }
      }
      guard captured.hash == resource.hash,
        metadata(captured.entries) == metadata(resource.entries),
        metadata(captured.support) == metadata(resource.support)
      else { throw MCPConnectionPreparationError.resourceChanged }
      let type =
        try FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path)[.type]
        as? FileAttributeType
      guard type == .typeDirectory || type == .typeRegular else {
        throw MCPConnectionPreparationError.invalidResource
      }
      let retained = LedgerResource(
        kind: .embedded, source: "selected", path: path, hash: captured.hash,
        entries: captured.entries, support: captured.support)
      let count = (captured.entries + captured.support).reduce(0) { $0 + ($1.byteCount ?? 0) }
      return Self(
        storage: .captured(retained, captured.objects, captured.flags),
        sourcePath: resource.path, directory: type == .typeDirectory, byteCount: count)
    }
    try FileManager.default.removeItem(at: workspace)
    return try result.get()
  }

  func materialize(in workspace: URL, name: String) throws -> URL {
    switch storage {
    case .live(let url, _):
      try revalidate()
      return url
    case .captured(let resource, let objects, let expectedFlags):
      let destination = workspace.appendingPathComponent(name)
      try LedgerResources.materialize(resource, objects: objects, at: destination)
      let file =
        resource.support.isEmpty
        ? destination : try PathSafety.resolvedChild(base: destination, subpath: resource.path)
      let hash = try directory ? FileHash.folderHash(file) : FileHash.sha256Hex(file: file)
      let flags: [String: Bool]
      if directory {
        flags = try FileHash.executableFlags(file)
      } else {
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        flags = [".": ((mode as? NSNumber)?.intValue ?? 0) & 0o111 != 0]
      }
      guard "sha256:" + hash == resource.hash, flags == expectedFlags else {
        throw MCPConnectionPreparationError.resourceChanged
      }
      return file
    }
  }

  func revalidate() throws {
    if case .live(let url, let expected) = storage {
      do {
        guard try Self.identity(url) == expected else {
          throw MCPConnectionPreparationError.resourceChanged
        }
      } catch { throw MCPConnectionPreparationError.resourceChanged }
    }
  }

  private static func identity(_ url: URL) throws -> Identity {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let real = url.resolvingSymlinksInPath().standardizedFileURL
    let target = try FileManager.default.attributesOfItem(atPath: real.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber,
      let targetDevice = target[.systemNumber] as? NSNumber,
      let targetInode = target[.systemFileNumber] as? NSNumber
    else { throw MCPConnectionPreparationError.resourceChanged }
    return Identity(
      device: device.uint64Value, inode: inode.uint64Value,
      targetDevice: targetDevice.uint64Value, targetInode: targetInode.uint64Value,
      realPath: real.path)
  }
}
