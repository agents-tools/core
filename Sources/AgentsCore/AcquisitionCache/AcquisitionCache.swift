import Foundation

public enum AcquisitionCacheStore: String, CaseIterable, Codable, Sendable {
  case git
  case http
  case deployed
}

public enum AcquisitionCacheMaintenance: Equatable, Sendable {
  case clean
  case prune(days: Int = 30)
}

public enum AcquisitionCacheError: LocalizedError, Equatable, Sendable {
  case unsafeRoot(String)
  case rootChanged
  case invalidAge
  case busy
  case invalidEntry

  public var errorDescription: String? {
    switch self {
    case .unsafeRoot(let path): "Unsafe acquisition cache root: \(path)"
    case .rootChanged: "The acquisition cache root changed after review."
    case .invalidAge: "The acquisition cache prune age must be nonnegative."
    case .busy: "The acquisition cache entry is in use."
    case .invalidEntry: "The acquisition cache entry has invalid or unsafe contents."
    }
  }
}

public struct AcquisitionCacheEntry: Equatable, Sendable {
  public let store: AcquisitionCacheStore
  public let id: String
  public let object: String
  public let lastUsed: Date
  public let bytes: Int64
  public let pendingDisposal: Bool
  /// Reference indexes are attributed to Git, but do not count as immutable commit groups.
  public var isGitObservation: Bool { store == .git && object.hasPrefix("ref:") }
  let generation: UUID
  let identities: [String: FileObjectIdentity]
  let files: [String: AcquisitionFileGeneration]
}

public struct AcquisitionCacheIssue: Equatable, Sendable {
  public let path: String
  public let reason: String
}

public struct AcquisitionCacheInventory: Sendable {
  public let root: URL
  public let entries: [AcquisitionCacheEntry]
  public let issues: [AcquisitionCacheIssue]

  public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

  public func bytes(in store: AcquisitionCacheStore) -> Int64 {
    entries.lazy.filter { $0.store == store }.reduce(0) { $0 + $1.bytes }
  }
}

/// An in-memory review tied to the opened cache root and the listed generations.
public struct AcquisitionCachePreview: Sendable {
  public let root: URL
  public let operation: AcquisitionCacheMaintenance
  public let candidates: [AcquisitionCacheEntry]
  public let issues: [AcquisitionCacheIssue]
  public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
  let rootIdentity: FileObjectIdentity?
  let cutoff: Date?
}

public struct AcquisitionCacheRemoval: Sendable {
  public let removed: [AcquisitionCacheEntry]
  public let skipped: [AcquisitionCacheEntry]
  public let failures: [AcquisitionCacheIssue]
  public let reclaimedBytes: Int64
  public var isComplete: Bool { failures.isEmpty }
}

/// Disposable public acquisition storage shared by consumers of the Swift runtime.
public struct AcquisitionCache: Sendable {
  package static let registryResponseLimit = 8 * 1024 * 1024

  public let root: URL
  let environment: RuntimeEnvironment

  public init(environment: RuntimeEnvironment = RuntimeEnvironment()) {
    self.environment = environment
    root = environment.acquisitionCacheDirectory
  }

  /// Reads the inventory without creating or recovering anything.
  public func inspect() throws -> AcquisitionCacheInventory {
    try withRoot { directory in
      try inventory(directory).report
    }
  }

  public func preview(
    _ operation: AcquisitionCacheMaintenance, now: Date = Date()
  ) throws -> AcquisitionCachePreview {
    let cutoff: Date?
    switch operation {
    case .clean: cutoff = nil
    case .prune(let days):
      guard days >= 0 else { throw AcquisitionCacheError.invalidAge }
      cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    }
    return try withRoot { directory in
      let scan = try inventory(directory)
      let candidates = scan.report.entries.filter { entry in
        guard let cutoff else { return true }
        return entry.store == .git
          && (entry.pendingDisposal || (!entry.isGitObservation && entry.lastUsed < cutoff))
      }
      return AcquisitionCachePreview(
        root: root, operation: operation, candidates: candidates, issues: scan.report.issues,
        rootIdentity: scan.identity, cutoff: cutoff)
    }
  }

  /// Applies the reviewed candidates independently. Reused or replaced entries are skipped.
  public func apply(_ preview: AcquisitionCachePreview) throws -> AcquisitionCacheRemoval {
    try apply(preview, afterDetach: {})
  }
}

extension RuntimeEnvironment {
  public var acquisitionCacheDirectory: URL {
    if let root = acquisitionCacheRoot { return root.standardizedFileURL }
    if let configured = environment["AGENTS_CACHE_DIR"], !configured.isEmpty {
      let project = URL(fileURLWithPath: projectDirectory.path, isDirectory: true)
      return URL(fileURLWithPath: configured, relativeTo: project).standardizedFileURL
    }
    #if os(macOS)
      let base = homeDirectory.appendingPathComponent("Library/Caches")
    #else
      let base =
        environment["XDG_CACHE_HOME"].flatMap {
          $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? homeDirectory.appendingPathComponent(".cache")
    #endif
    return base.appendingPathComponent("agents")
  }
}

struct AcquisitionFileGeneration: Equatable, Sendable {
  let info: stat

  static func == (lhs: Self, rhs: Self) -> Bool {
    DirectoryHandle.sameGeneration(lhs.info, rhs.info)
  }
}
