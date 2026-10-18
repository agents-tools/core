import Foundation

/// Skill discovery supplies names and directory paths relative to the supplied search root.
public struct WatchSkill: Equatable, Sendable {
  public var name: String
  public var path: String

  public init(name: String, path: String) {
    self.name = name
    self.path = path
  }
}

/// An artifact provider supplies verified download bytes and its expanded file contents.
public struct WatchArtifact: Sendable {
  public var name: String
  public var artifact: LockedArtifact
  public var files: [String: Data]
  public var payloads: [String: Data]

  public init(
    name: String, artifact: LockedArtifact, files: [String: Data], payloads: [String: Data]
  ) {
    self.name = name
    self.artifact = artifact
    self.files = files
    self.payloads = payloads
  }
}

public enum WatchItemKind: String, Sendable {
  case skill, instructions, artifact
}

public enum WatchChangeKind: String, Sendable {
  case new, changed, removed
}

/// Entry bytes, executable mode, and link destinations are available for consumer diff rendering.
public enum WatchFileEntry: Equatable, Sendable {
  case file(Data, executable: Bool)
  case symbolicLink(String)
  case directory
}

public struct WatchFileChange: Equatable, Sendable {
  public let path: String
  public let before: WatchFileEntry?
  public let after: WatchFileEntry?
}

public struct WatchItemChange: Equatable, Sendable {
  public let name: String
  public let kind: WatchItemKind
  public let change: WatchChangeKind
  public let oldPath: String?
  public let newPath: String?
  public let oldDigest: String?
  public let newDigest: String?
  public let files: [WatchFileChange]

  public var fileCount: Int { files.count }
}

public struct WatchStatus: Equatable, Sendable {
  public let alias: String
  public let sourceID: String
  public let seen: WatchSeen
  public let current: WatchSeen
  /// Commits reachable from the current head but not from the seen revision; nil for indexes.
  public let commitCount: Int?
  public var changes: [WatchItemChange]
}
