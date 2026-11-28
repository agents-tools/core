import AgentsCore
import Foundation

public enum ContentAuditStripError: Error, Equatable, Sendable {
  case outsideScope
  case unsupportedFile
}

/// Deletions use zero-based UTF-8 byte offsets in the reviewed preimage.
public struct ContentAuditStripEdit: Equatable, Sendable {
  public let bytes: Range<Int>
  public let codePoint: UInt32
  public let reason: ContentAuditReason
  public let severity: ContentAuditSeverity
  public let line: Int
  public let column: Int
}

public struct ContentAuditStripPreview: Sendable {
  public let file: URL
  public let originalBytes: Data
  public let replacementBytes: Data
  public let edits: [ContentAuditStripEdit]
  fileprivate let identity: ContentAuditFiles.FileIdentity
  fileprivate let profile: ContentAuditProfile

}

extension ContentAuditOperations {
  /// Prepare exact deletions from one explicitly selected regular UTF-8 prompt file.
  /// The caller presents the preview and makes the separate decision to apply it.
  public static func previewStrip(
    file: URL, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> ContentAuditStripPreview {
    let profile = ContentAuditProfile(
      scope: scope, environment: environment, agents: Set(AgentID.allCases))
    let (admitted, parent) = try stripPath(file, profile: profile)
    let (original, identity) = try ContentAuditFiles.readEditable(
      admitted.lastPathComponent, in: parent, maximumBytes: ContentAuditInspection.maximumFileBytes)
    guard let text = String(validating: original, as: UTF8.self),
      !text.unicodeScalars.contains("\0")
    else { throw ContentAuditStripError.unsupportedFile }
    let symbols = try ContentAuditUnicode.scan(text, leadingBOM: true)
    let edits = symbols.filter { $0.severity != .info }.map {
      ContentAuditStripEdit(
        bytes: $0.byteRange, codePoint: $0.codePoint, reason: $0.reason, severity: $0.severity,
        line: $0.line, column: $0.column)
    }
    var replacement = Data()
    replacement.reserveCapacity(original.count)
    var offset = original.startIndex
    for edit in edits {
      replacement.append(original[offset..<edit.bytes.lowerBound])
      offset = edit.bytes.upperBound
    }
    replacement.append(original[offset..<original.endIndex])
    return .init(
      file: admitted, originalBytes: original, replacementBytes: replacement, edits: edits,
      identity: identity, profile: profile)
  }

  /// Publish exactly the reviewed replacement after revalidating the path, object and bytes.
  /// Each call has a one-file publication boundary.
  public static func applyStrip(_ preview: ContentAuditStripPreview) throws {
    guard !preview.edits.isEmpty else { return }
    let (admitted, _) = try stripPath(preview.file, profile: preview.profile)
    try ContentAuditFiles.applyReviewedEdit(
      admitted, before: preview.originalBytes, after: preview.replacementBytes,
      identity: preview.identity)
  }

  private static func stripPath(_ file: URL, profile: ContentAuditProfile) throws
    -> (URL, DirectoryHandle)
  {
    guard let path = ContentAuditProfile.relative(file, to: profile.root), path != "." else {
      throw ContentAuditStripError.outsideScope
    }
    guard !profile.excludes(path), profile.explicitFormat(at: path) == .text else {
      throw ContentAuditStripError.unsupportedFile
    }
    let tree = try ContentAuditTree(profile: profile)
    guard let (parent, name) = try tree.parent(of: path),
      try ContentAuditFiles.kind(name, in: parent) == .regular
    else { throw ContentAuditStripError.unsupportedFile }
    return (profile.root.appendingPathComponent(path).standardizedFileURL, parent)
  }
}
