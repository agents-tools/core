import Foundation

/// Organization policy is selected by the host application. A project manifest never selects it.
public enum OrganizationPolicySource: Equatable, Sendable, Encodable {
  case local(URL)
  case https(URL)
  /// Discover from a GitHub remote already identified by the trusted caller.
  case organization(gitRemote: String)
  case invalidLocation
}

public struct OrganizationPolicySelection: Equatable, Sendable, Encodable {
  public let source: OrganizationPolicySource
  public let required: Bool

  init(location: String) {
    if location.hasPrefix("/") {
      self.init(.local(URL(fileURLWithPath: location)))
    } else if location.hasPrefix("github:") {
      self.init(.organization(gitRemote: "https://github.com/" + location.dropFirst(7)))
    } else if let url = URL(string: location), url.scheme?.lowercased() == "https" {
      self.init(.https(url))
    } else {
      self.init(.invalidLocation)
    }
  }

  public init(_ source: OrganizationPolicySource, required: Bool = true) {
    self.source = source
    self.required = required
  }
}

public enum OrganizationPolicyMode: String, Codable, Sendable, Comparable {
  case off, warn, block

  public static func < (lhs: Self, rhs: Self) -> Bool {
    let rank: [Self] = [.off, .warn, .block]
    return rank.firstIndex(of: lhs)! < rank.firstIndex(of: rhs)!
  }
}

public struct OrganizationPolicyDocumentEvidence: Codable, Equatable, Sendable {
  public let url: URL
  public let digest: String
  public let name: String?
  public let version: String?
  public let ageSeconds: Int?
  public let stale: Bool

  package init(
    url: URL, digest: String, name: String?, version: String?, ageSeconds: Int?, stale: Bool
  ) {
    self.url = url
    self.digest = digest
    self.name = name
    self.version = version
    self.ageSeconds = ageSeconds
    self.stale = stale
  }
}

public struct OrganizationPolicyFinding: Codable, Hashable, Sendable {
  public enum Subject: String, Codable, Sendable {
    case policy, source, package, mcp, executable, manifest, workspace
  }

  public let subject: Subject
  public let identity: String
  public let rule: String
  public let matchedPattern: String?
  public let dependencyPath: [String]
  public let authority: InstallScope
  public let document: URL?
  public let documentDigest: String?
  public let outcome: OrganizationPolicyMode
  public let message: String

  package init(
    subject: Subject, identity: String, rule: String, matchedPattern: String? = nil,
    dependencyPath: [String] = [], authority: InstallScope, document: URL?,
    documentDigest: String?, outcome: OrganizationPolicyMode, message: String
  ) {
    self.subject = subject
    self.identity = identity
    self.rule = rule
    self.matchedPattern = matchedPattern
    self.dependencyPath = dependencyPath
    self.authority = authority
    self.document = document
    self.documentDigest = documentDigest
    self.outcome = outcome
    self.message = message
  }
}

public struct OrganizationPolicyStatus: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Sendable { case loaded, absent, unavailable }

  public let authority: InstallScope
  public let outcome: Outcome
  public let mode: OrganizationPolicyMode?
  /// Parent first. The leaf is the last document.
  public let documents: [OrganizationPolicyDocumentEvidence]

  package init(
    authority: InstallScope, outcome: Outcome, mode: OrganizationPolicyMode? = nil,
    documents: [OrganizationPolicyDocumentEvidence] = []
  ) {
    self.authority = authority
    self.outcome = outcome
    self.mode = mode
    self.documents = documents
  }
}

public struct OrganizationPolicyReport: Codable, Equatable, Sendable {
  public let policies: [OrganizationPolicyStatus]
  public let findings: [OrganizationPolicyFinding]
  public var isBlocked: Bool { findings.contains { $0.outcome == .block } }

  package init(policies: [OrganizationPolicyStatus], findings: [OrganizationPolicyFinding]) {
    self.policies = policies
    self.findings = findings
  }

  package func requireAdmission() throws {
    if isBlocked { throw OrganizationPolicyFailure(report: self) }
  }
}

public struct OrganizationPolicyFailure: Error, Sendable, CustomStringConvertible {
  public let report: OrganizationPolicyReport

  package init(report: OrganizationPolicyReport) { self.report = report }

  public var description: String {
    report.findings.filter { $0.outcome == .block }.map {
      let origin = $0.document.map { " [\($0.absoluteString)]" } ?? ""
      return "\($0.authority.rawValue) organization policy \($0.rule): \($0.identity) "
        + "— \($0.message)\(origin)"
    }.joined(separator: "\n")
  }
}

package struct OrganizationRules: Sendable {
  package enum Resolution: String, CaseIterable, Sendable {
    case projectWins = "project-wins"
    case policyWins = "policy-wins"
    case block
  }

  package enum Action: String, CaseIterable, Sendable {
    case ignore, warn, deny
  }

  package enum SelfDefined: String, CaseIterable, Sendable {
    case allow, warn, deny
  }

  package struct RequiredPackage: Sendable {
    package let identity: String
    package let version: SourceRequirement?

    package init(identity: String, version: SourceRequirement?) {
      self.identity = identity
      self.version = version
    }
  }

  package var name: String?
  package var version: String?
  package var parent: String?
  package var enforcement: OrganizationPolicyMode = .warn
  package var fetchFailure: OrganizationPolicyMode = .warn
  package var ttl = 3600
  package var sourceAllow: [String]?
  package var sourceDeny: [String] = []
  package var dependencyAllow: [String]?
  package var dependencyDeny: [String] = []
  package var dependencyRequire: [RequiredPackage] = []
  package var resolution: Resolution?
  package var maximumDepth: Int?
  package var pinnedConstraint = false
  package var marketplaceAllow: [String]?
  package var mcpAllow: [String]?
  package var mcpDeny: [String] = []
  package var mcpRequire: [String] = []
  package var mcpTransportAllow: [String]?
  package var mcpSelfDefined: SelfDefined?
  package var mcpTrustTransitive: Bool?
  package var executableDenyAll = false
  package var executableDeny: [String] = []
  package var executableRequire: [String] = []
  package var requiredFields: [String] = []
  package var explicitIncludes = false
  package var contentTypes: [String]?
  package var scriptsDenied = false
  package var requireHashes = false
  package var failOnDrift = false
  package var unmanagedAction: Action = .ignore
  package var unmanagedDirectories: [String] = []
  package var unmanagedExclude: [String] = []
  package var warnings: [String] = []

  package init() {}
}
