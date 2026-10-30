import Foundation

/// Captures existing ancestry and the final entry without following that entry's link.
/// Missing ancestors may be created, but existing ancestors cannot be exchanged.
package struct PathIdentity {
  private let url: URL
  private let physical: URL
  private let entry: FileObjectIdentity?
  private let ancestors: [(URL, FileObjectIdentity)]

  package init(_ url: URL) throws {
    self.url = url
    physical =
      url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    entry = try Self.read(physical)
    var ancestors: [(URL, FileObjectIdentity)] = []
    var parent = physical.deletingLastPathComponent()
    while parent.path != "/" {
      if let value = try Self.read(parent) { ancestors.append((parent, value)) }
      parent.deleteLastPathComponent()
    }
    self.ancestors = ancestors
  }

  package func validate() throws {
    let current = url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    guard current == physical, try Self.read(physical) == entry else {
      throw CoreError.invalidState("path changed during preparation: \(url.path)")
    }
    for (path, value) in ancestors where try Self.read(path) != value {
      throw CoreError.invalidState("path ancestry changed during preparation: \(url.path)")
    }
  }

  private static func read(_ url: URL) throws -> FileObjectIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      if errno == ENOENT { return nil }
      throw CoreError.unsafePath("cannot inspect path: \(url.path)")
    }
    return FileObjectIdentity(value)
  }
}

/// Prepared evidence checked again before publication, except for targets that the
/// transaction journal verifies itself.
package protocol PreparedEvidence {
  func validate(excludingTargets targets: Set<String>) throws
}

/// State bytes and presence belong to the same generation as the rendered targets.
package struct StatePrecondition: PreparedEvidence {
  private let files: [(url: URL, evidence: TargetPrecondition, bytes: Data?)]

  package init(store: StateStore) throws {
    files = try [store.declarationURL, store.resolvedURL, store.watchURL].map {
      let input = try TargetPrecondition.readingFile($0)
      return ($0, input.evidence, input.bytes)
    }
    try validate()
  }

  package func evidence(for url: URL) throws -> TargetPrecondition {
    try file(for: url).evidence
  }

  package func bytes(for url: URL) throws -> Data? {
    try file(for: url).bytes
  }

  private func file(for url: URL) throws -> (url: URL, evidence: TargetPrecondition, bytes: Data?) {
    guard let file = files.first(where: { $0.url.path == url.standardizedFileURL.path }) else {
      throw CoreError.invalidState("state precondition does not include target")
    }
    return file
  }

  package func validate(excludingTargets targets: Set<String> = []) throws {
    for (url, evidence, _) in files where !targets.contains(url.standardizedFileURL.path) {
      try evidence.validate()
    }
  }
}

/// The generation captured by a plan is also the journal's expected preimage.
package struct TargetPrecondition {
  package let url: URL
  let snapshot: FileSnapshot?
  private let identity: PathIdentity

  var physicalURL: URL {
    url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(
      url.lastPathComponent
    ).standardizedFileURL
  }

  package init(_ url: URL) throws {
    self.url = url.standardizedFileURL
    identity = try PathIdentity(url)
    snapshot = try FileSnapshot.read(at: url)
    try identity.validate()
  }

  private init(url: URL, snapshot: FileSnapshot?, identity: PathIdentity) {
    self.url = url.standardizedFileURL
    self.snapshot = snapshot
    self.identity = identity
  }

  /// Rendering and its expected preimage use the same opened-file bytes and inode.
  package static func readingFile(_ url: URL) throws -> (bytes: Data?, evidence: Self) {
    let identity = try PathIdentity(url)
    let capture = try FileSnapshot.captureFile(at: url)
    guard capture.snapshot?.isRegular != false else {
      throw CoreError.unsafePath("expected regular file: \(url.path)")
    }
    try identity.validate()
    return (capture.bytes, Self(url: url, snapshot: capture.snapshot, identity: identity))
  }

  package func sameGeneration(as other: Self) -> Bool {
    url.path == other.url.path && snapshot == other.snapshot
  }

  func validateIdentity() throws { try identity.validate() }

  package func validate() throws {
    try validateIdentity()
    guard try FileSnapshot.read(at: url) == snapshot else {
      throw CoreError.invalidState("target changed during preparation: \(url.path)")
    }
  }
}
