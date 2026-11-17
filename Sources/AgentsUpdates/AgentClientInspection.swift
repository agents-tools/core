import AgentsCore
import Components
import Foundation

public enum AgentClientObservationStatus: String, Sendable {
  case present, notFound, inaccessible, invalid, unavailable
}

public enum AgentClientVersionUnknown: String, Sendable {
  case artifactNotFound, unrecognizedLayout, missingMetadata, unreadableMetadata
  case malformedMetadata, oversizedMetadata, nonRegularMetadata, missingVersion, unavailable
}

/// Raw artifact metadata, independent of historical schema evidence and configuration admission.
public struct AgentClientVersion: Sendable {
  public let rawVersion: String?
  public let build: String?
  public let metadataURL: URL?
  public let metadataKey: String?
  public let unknownReason: AgentClientVersionUnknown?

  fileprivate init(_ value: ClientVersionObservation) {
    rawVersion = value.version
    build = value.build
    metadataURL = value.metadata
    metadataKey = value.key
    unknownReason = value.unknown.flatMap { AgentClientVersionUnknown(rawValue: $0.rawValue) }
  }
}

public struct AgentClientLookupIssue: Sendable {
  public let path: String
  public let status: AgentClientObservationStatus
  public let reason: String
}

public struct AgentClientPATHCoverage: Sendable {
  public let pathWasSupplied: Bool
  public let absoluteDirectories: [URL]
  /// Empty and relative entries are excluded rather than resolved against an implicit directory.
  public let excludedEntries: [String]
}

public struct AgentClientCommand: Sendable {
  public enum Role: String, Sendable { case agentCLI, editorLauncher }
  public let name: String
  public let role: Role
  public let location: URL?
  public let resolvedLocation: URL?
  public let status: AgentClientObservationStatus
  /// Earlier lookup errors mean a later selection is not guaranteed shell resolution.
  public let lookupIssues: [AgentClientLookupIssue]
  public let version: AgentClientVersion
}

public struct AgentClientApplication: Sendable {
  public let bundleIdentifier: String?
  public let location: URL?
  public let status: AgentClientObservationStatus
  public let version: AgentClientVersion
}

public struct AgentClientConfigurationLocation: Sendable {
  public enum Purpose: String, Sendable {
    case skillInstallation, skillScan, instructions, nativeConfiguration
  }
  public enum ObjectRole: String, Sendable { case file, container }
  public let identity: String
  public let scope: String
  public let purpose: Purpose
  public let objectRole: ObjectRole
  public let location: URL?
  public let status: AgentClientObservationStatus
  public let diagnostic: String?
}

public struct AgentClientSurface: Sendable {
  public let identifier: String
  public let displayName: String
}

public struct AgentClientSchemaEvidence: Sendable {
  public enum Status: String, Sendable { case recorded, unsupportedUnderEvidence, unverified }
  public enum Placement: String, Sendable { case standalone, pluginMember }
  public let surface: AgentClientSurface
  public let kind: DeclaredComponentKind
  public let scope: String
  public let placement: Placement
  public let status: Status
  public let revision: String?
  public let sources: [String]
  public let limitation: String?
}

public struct AgentClientRecord: Sendable {
  public let agent: AgentID
  public let commands: [AgentClientCommand]
  public let applications: [AgentClientApplication]
  public let configurationLocations: [AgentClientConfigurationLocation]
  public let schemaEvidence: [AgentClientSchemaEvidence]
}

/// An interval of passive observations, not an atomic snapshot or a configuration admission result.
public struct AgentClientInspection: Sendable {
  public let startedAt: Date
  public let finishedAt: Date
  public let scope: InstallScope
  public let projectDirectory: URL
  public let homeDirectory: URL
  public let pathCoverage: AgentClientPATHCoverage
  public let clients: [AgentClientRecord]
}

public enum AgentClientOperations {
  /// Never invokes clients, reads configuration contents, recovers state or writes destinations.
  /// Returned URLs are provenance; consumers should keep explicit re-detection independent of editing.
  public static func inspect(
    scope: InstallScope = .user, environment: RuntimeEnvironment
  ) throws -> AgentClientInspection {
    let started = Date()
    let coverage = ClientPathCoverage(environment: environment)
    let nativeLocations = NativeTargetRoute.clientLocations(scope: scope, environment: environment)
    let clients = AgentID.allCases.map { agent in
      let commands = AgentRegistry.clientCommands(for: agent).map { candidate in
        let value = AgentClientObservation.command(candidate, coverage: coverage)
        return AgentClientCommand(
          name: value.command, role: .init(rawValue: value.role)!,
          location: value.location, resolvedLocation: value.resolvedLocation,
          status: status(value.state),
          lookupIssues: value.issues.map {
            .init(path: $0.path, status: status($0.state), reason: $0.reason)
          }, version: .init(value.version))
      }
      let application = AgentClientApplications.inspect(agent: agent)
      var locations = AgentRegistry.clientSkillLocations(
        for: agent, scope: scope, environment: environment
      )
      .map { identity, url in
        location(
          identity, scope: scope.rawValue,
          purpose: identity == "skills.install" ? .skillInstallation : .skillScan,
          container: true, result: .success(url))
      }
      locations += InstructionLocations.clientFiles(
        for: agent, scope: scope, environment: environment
      ).map {
        location(
          $0.0, scope: scope.rawValue, purpose: .instructions, container: false,
          result: .success($0.1))
      }
      locations += nativeLocations.filter { $0.agents.contains(agent) }.map {
        location(
          $0.identity, scope: $0.evidenceScope, purpose: .nativeConfiguration,
          container: $0.container, result: $0.location)
      }
      return AgentClientRecord(
        agent: agent, commands: commands,
        applications: [
          .init(
            bundleIdentifier: application.bundleIdentifier,
            location: application.location, status: status(application.state),
            version: .init(application.version))
        ],
        configurationLocations: locations,
        schemaEvidence: ClientCapabilityInspection.entries(for: agent).map {
          .init(
            surface: .init(identifier: $0.surface.rawValue, displayName: $0.displayName),
            kind: $0.kind, scope: $0.scope, placement: .init(rawValue: $0.placement)!,
            status: .init(rawValue: $0.status)!, revision: $0.evidence?.revision,
            sources: $0.evidence?.sources ?? [], limitation: $0.reason)
        })
    }
    return .init(
      startedAt: started, finishedAt: Date(), scope: scope,
      projectDirectory: environment.projectDirectory, homeDirectory: environment.homeDirectory,
      pathCoverage: .init(
        pathWasSupplied: coverage.supplied, absoluteDirectories: coverage.directories,
        excludedEntries: coverage.excluded), clients: clients)
  }

  private static func status(_ value: ClientObservationState) -> AgentClientObservationStatus {
    .init(rawValue: value.rawValue)!
  }

  private static func location(
    _ identity: String, scope: String, purpose: AgentClientConfigurationLocation.Purpose,
    container: Bool, result: Result<URL, any Error>
  ) -> AgentClientConfigurationLocation {
    switch result {
    case .success(let url):
      .init(
        identity: identity, scope: scope, purpose: purpose,
        objectRole: container ? .container : .file, location: url,
        status: status(AgentClientObservation.presence(url, directory: container)), diagnostic: nil)
    case .failure(let error):
      .init(
        identity: identity, scope: scope, purpose: purpose,
        objectRole: container ? .container : .file, location: nil, status: .invalid,
        diagnostic: String(describing: error))
    }
  }
}
