import Foundation

/// Producer-owned invalidation interest. Entry dependencies observe the path and its ancestors;
/// subtree dependencies also observe descendants. An independent subtree interest remains valid
/// when an entry dependency names the same path.
public enum ReadDependency: Sendable, Hashable, Codable {
  case entry(URL)
  case subtree(URL)

  public var url: URL {
    switch self {
    case .entry(let url), .subtree(let url): url
    }
  }
}
