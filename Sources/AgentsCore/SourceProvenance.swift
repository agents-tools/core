public struct DocumentIdentity: Sendable, Hashable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Half-open UTF-8 byte offsets and the 1-based line and byte column of the start.
public struct SourceSpan: Sendable, Hashable {
  public let document: DocumentIdentity
  public let start: Int
  public let end: Int
  public let line: Int
  public let column: Int

  public init(document: DocumentIdentity, start: Int, end: Int, line: Int, column: Int) {
    self.document = document
    self.start = start
    self.end = end
    self.line = line
    self.column = column
  }
}

/// Stable source coordinates, independent of a checkout or cache location.
public struct SourceProvenance: Sendable, Equatable {
  public let sourceIdentity: String
  public let revision: String?
  public let artifactDigest: String?
  public let relativePath: String
  public let format: String
  public let adapterVersion: String
  public let group: String?
  public let referenceChain: [SourceSpan]

  public init(
    sourceIdentity: String, revision: String? = nil, artifactDigest: String? = nil,
    relativePath: String, format: String, adapterVersion: String, group: String? = nil,
    referenceChain: [SourceSpan] = []
  ) {
    self.sourceIdentity = sourceIdentity
    self.revision = revision
    self.artifactDigest = artifactDigest
    self.relativePath = relativePath
    self.format = format
    self.adapterVersion = adapterVersion
    self.group = group
    self.referenceChain = referenceChain
  }
}

public struct SourceMapEntry: Sendable, Equatable {
  public let pointer: String
  public let span: SourceSpan
  public let origins: [SourceSpan]
  public let defaulted: Bool

  public init(
    pointer: String, span: SourceSpan, origins: [SourceSpan] = [], defaulted: Bool = false
  ) {
    self.pointer = pointer
    self.span = span
    self.origins = origins
    self.defaulted = defaulted
  }
}

public struct DeclarationSourceMap: Sendable, Equatable {
  public let entries: [SourceMapEntry]
  public init(entries: [SourceMapEntry]) { self.entries = entries }
  public func locations(at pointer: String) -> [SourceMapEntry] {
    entries.filter { $0.pointer == pointer }
  }
}
