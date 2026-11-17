import CPlatform
import Foundation

package enum ClientObservationState: String, Sendable {
  case present, notFound, inaccessible, invalid, unavailable
}

package enum ClientVersionUnknown: String, Sendable {
  case artifactNotFound, unrecognizedLayout, missingMetadata, unreadableMetadata
  case malformedMetadata, oversizedMetadata, nonRegularMetadata, missingVersion, unavailable
}

package struct ClientVersionObservation: Sendable {
  package let version: String?
  package let build: String?
  package let metadata: URL?
  package let key: String?
  package let unknown: ClientVersionUnknown?

  package static func unknown(_ reason: ClientVersionUnknown, at metadata: URL? = nil) -> Self {
    .init(version: nil, build: nil, metadata: metadata, key: nil, unknown: reason)
  }
}

package struct ClientPathIssue: Sendable {
  package let path: String
  package let state: ClientObservationState
  package let reason: String
}

package struct ClientPathCoverage: Sendable {
  package let supplied: Bool
  package let directories: [URL]
  package let excluded: [String]

  package init(environment: RuntimeEnvironment) {
    supplied = environment.environment["PATH"] != nil
    let entries = environment.environment["PATH"]?.components(separatedBy: ":") ?? []
    directories = entries.filter { $0.hasPrefix("/") && !$0.contains("\0") }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    excluded = entries.filter { !$0.hasPrefix("/") || $0.contains("\0") }
  }
}

package struct ClientCommandObservation: Sendable {
  package let command: String
  package let role: String
  package let location: URL?
  package let resolvedLocation: URL?
  package let state: ClientObservationState
  package let issues: [ClientPathIssue]
  package let version: ClientVersionObservation
}

package enum AgentClientObservation {
  package static func failureState(_ code: Int32) -> ClientObservationState {
    switch code {
    case ENOENT, ENOTDIR: .notFound
    case EACCES, EPERM: .inaccessible
    default: .invalid
    }
  }

  package static func presence(_ url: URL, directory: Bool) -> ClientObservationState {
    guard url.isFileURL, !url.path.contains("\0") else { return .invalid }
    var info = stat()
    guard stat(url.path, &info) == 0 else { return failureState(errno) }
    let kind = info.st_mode & mode_t(S_IFMT)
    return kind == mode_t(directory ? S_IFDIR : S_IFREG) ? .present : .invalid
  }

  package static func command(
    _ candidate: AgentRegistry.ClientCommand, coverage: ClientPathCoverage
  ) -> ClientCommandObservation {
    var issues: [ClientPathIssue] = []
    for directory in coverage.directories {
      let url = directory.appendingPathComponent(candidate.name)
      var info = stat()
      if stat(url.path, &info) != 0 {
        let code = errno
        if code != ENOENT && code != ENOTDIR {
          issues.append(
            .init(path: url.path, state: failureState(code), reason: "executable lookup failed"))
        }
        continue
      }
      guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
      guard access(url.path, X_OK) == 0 else {
        issues.append(
          .init(path: url.path, state: failureState(errno), reason: "executable access denied"))
        continue
      }
      let resolved = url.resolvingSymlinksInPath()
      let version: ClientVersionObservation
      if let bundle = AgentRegistry.clientBundle(for: candidate.name, resolvedExecutable: resolved),
        let identifier = AgentRegistry.clientBundleIdentifier(for: .cursor)
      {
        version = bundleVersion(at: bundle, identifier: identifier).1
      } else {
        version = .unknown(.unrecognizedLayout)
      }
      return .init(
        command: candidate.name, role: candidate.role, location: url, resolvedLocation: resolved,
        state: .present, issues: issues, version: version)
    }
    return .init(
      command: candidate.name, role: candidate.role, location: nil, resolvedLocation: nil,
      state: coverage.directories.isEmpty
        ? .unavailable : issues.first?.state ?? .notFound,
      issues: issues,
      version: .unknown(
        coverage.directories.isEmpty || !issues.isEmpty ? .unavailable : .artifactNotFound))
  }

  /// Follows installation symlinks, validates the opened object, and bounds even growing files.
  package static func metadata(_ url: URL) throws -> Data {
    guard url.isFileURL, !url.path.contains("\0") else {
      throw ClientVersionUnknownError(.unreadableMetadata)
    }
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else {
      throw ClientVersionUnknownError(
        errno == ENOENT || errno == ENOTDIR ? .missingMetadata : .unreadableMetadata)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw ClientVersionUnknownError(.unreadableMetadata) }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw ClientVersionUnknownError(.nonRegularMetadata)
    }
    let limit = 1_048_576
    guard info.st_size >= 0, info.st_size <= limit else {
      throw ClientVersionUnknownError(.oversizedMetadata)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw ClientVersionUnknownError(.unreadableMetadata)
      }
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else { throw ClientVersionUnknownError(.oversizedMetadata) }
    }
  }

  package static func bundleVersion(at bundle: URL, identifier: String)
    -> (ClientObservationState, ClientVersionObservation)
  {
    let url = bundle.appendingPathComponent("Contents/Info.plist")
    do {
      let bytes = try metadata(url)
      guard
        let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
          as? [String: Any],
        plist["CFBundleIdentifier"] as? String == identifier
      else { return (.invalid, .unknown(.malformedMetadata, at: url)) }
      let version = (plist["CFBundleShortVersionString"] as? String).flatMap {
        $0.isEmpty ? nil : $0
      }
      let build = (plist["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      return (
        .present,
        .init(
          version: version, build: build, metadata: url,
          key: "CFBundleShortVersionString", unknown: version == nil ? .missingVersion : nil)
      )
    } catch let error as ClientVersionUnknownError {
      let state: ClientObservationState =
        error.reason == .unreadableMetadata ? .inaccessible : .invalid
      return (state, .unknown(error.reason, at: url))
    } catch { return (.invalid, .unknown(.malformedMetadata, at: url)) }
  }
}

package struct ClientVersionUnknownError: Error {
  package let reason: ClientVersionUnknown
  package init(_ reason: ClientVersionUnknown) { self.reason = reason }
}
