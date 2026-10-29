/// A semantic version literal. Manifest domain validation diagnoses invalid spellings.
public struct Version: Sendable, Comparable, ExpressibleByStringLiteral {
  package let major: Int
  package let minor: Int
  package let patch: Int
  package let prerelease: [String]
  package let metadata: [String]
  package let valid: Bool
  package let normalized: String

  public init(stringLiteral value: String) {
    var body = value.drop(while: \.isWhitespace)
    while body.last?.isWhitespace == true { body = body.dropLast() }
    if body.first == "v" || body.first == "V" { body = body.dropFirst() }
    let builds = body.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    let releases = builds[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let numbers = releases[0].split(separator: ".", omittingEmptySubsequences: false)
    let parsed = numbers.map { Int($0) }
    let pre =
      releases.count == 2
      ? releases[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
    let meta =
      builds.count == 2
      ? builds[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
    major = parsed.first.flatMap { $0 } ?? 0
    minor = parsed.count > 1 ? parsed[1] ?? 0 : 0
    patch = parsed.count > 2 ? parsed[2] ?? 0 : 0
    prerelease = pre
    metadata = meta
    valid =
      numbers.count == 3 && parsed.allSatisfy { $0 != nil }
      && numbers.allSatisfy { Self.numeric(String($0)) && ($0.count == 1 || !$0.hasPrefix("0")) }
      && pre.allSatisfy {
        Self.identifier($0) && (!Self.numeric($0) || $0.count == 1 || !$0.hasPrefix("0"))
      }
      && meta.allSatisfy(Self.identifier)
    normalized = String(body)
  }

  private init(major: Int, minor: Int, patch: Int, valid: Bool = true) {
    self.major = major
    self.minor = minor
    self.patch = patch
    prerelease = []
    metadata = []
    self.valid = valid
    normalized = "\(major).\(minor).\(patch)"
  }

  public static func == (lhs: Version, rhs: Version) -> Bool {
    lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
      && lhs.prerelease == rhs.prerelease && lhs.valid == rhs.valid
  }

  public static func < (lhs: Version, rhs: Version) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
      return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
    }
    for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
      if left == right { continue }
      let ln = numeric(left)
      let rn = numeric(right)
      if ln && rn && left.count != right.count { return left.count < right.count }
      if ln != rn { return ln }
      return left < right
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  package func successor(major incrementMajor: Bool) -> Version {
    let (next, overflow) = (incrementMajor ? major : minor).addingReportingOverflow(1)
    if overflow || !valid { return Version(major: major, minor: minor, patch: patch, valid: false) }
    return Version(major: incrementMajor ? next : major, minor: incrementMajor ? 0 : next, patch: 0)
  }

  private static func numeric(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy {
        $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      }
  }
}

extension Version: ConstructionRepresentable {
  package var constructionValue: ConstructionValue { .version(self) }
}

extension Range where Bound == Version {
  public static func upToNextMajor(from version: Version) -> Range<Version> {
    Range(uncheckedBounds: (version, version.successor(major: true)))
  }

  public static func upToNextMinor(from version: Version) -> Range<Version> {
    Range(uncheckedBounds: (version, version.successor(major: false)))
  }
}
