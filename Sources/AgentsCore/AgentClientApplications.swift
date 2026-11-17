import Foundation

#if os(macOS)
  import AppKit
#endif

package struct ClientApplicationObservation: Sendable {
  package let bundleIdentifier: String?
  package let location: URL?
  package let state: ClientObservationState
  package let version: ClientVersionObservation
}

package enum AgentClientApplications {
  package static func inspect(agent: AgentID) -> ClientApplicationObservation {
    guard let identifier = AgentRegistry.clientBundleIdentifier(for: agent) else {
      return .init(
        bundleIdentifier: nil, location: nil, state: .unavailable,
        version: .unknown(.unrecognizedLayout))
    }
    #if os(macOS)
      guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
      else {
        return .init(
          bundleIdentifier: identifier, location: nil, state: .notFound,
          version: .unknown(.artifactNotFound))
      }
      let (state, version) = AgentClientObservation.bundleVersion(
        at: location, identifier: identifier)
      return .init(bundleIdentifier: identifier, location: location, state: state, version: version)
    #else
      return .init(
        bundleIdentifier: identifier, location: nil, state: .unavailable,
        version: .unknown(.unavailable))
    #endif
  }
}
