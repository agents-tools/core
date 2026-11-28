import AgentsCore
import Foundation

struct ProducerPatchDestination {
  private let url: URL
  private let anchor: DirectoryHandle
  private let ancestry: PathIdentity
  private let missing: [String]
  private let protected: [URL]

  init(_ output: URL, excluding protected: [URL]) throws {
    guard output.isFileURL, output.path.hasPrefix("/"), !output.path.utf8.contains(0),
      output.host == nil || output.host == "" || output.host == "localhost",
      !output.path.split(separator: "/").contains(".."),
      output.query == nil, output.fragment == nil
    else { throw ProducerPatchError.unsafeDestination(output) }
    let url = output.standardizedFileURL
    self.url = url
    self.protected = protected
    do {
      var path = url
      var missing: [String] = []
      while true {
        if let directory = try DirectoryHandle.readDirectoryIfPresent(at: path) {
          anchor = directory
          break
        }
        missing.append(path.lastPathComponent)
        path.deleteLastPathComponent()
      }
      self.missing = missing.reversed()
      ancestry = try PathIdentity(anchor.url)
      try validateAnchor()
      try validateProtection()
    } catch {
      throw ProducerPatchError.unsafeDestination(output)
    }
  }

  private func validateProtection() throws {
    let excluded = protected.flatMap { [$0.standardizedFileURL, $0.resolvingSymlinksInPath()] }
    let protectedIDs = Set(
      excluded.compactMap {
        try? DirectoryHandle.readDirectoryIfPresent(at: $0)?.objectIdentity
      })
    guard !excluded.contains(where: { $0.path == "/" || PathSafety.isContained(url, in: $0) })
    else {
      throw ProducerPatchError.unsafeDestination(url)
    }
    var parent = anchor.url
    while true {
      let identity = try DirectoryHandle.readDirectory(at: parent).objectIdentity
      guard !protectedIDs.contains(identity) else {
        throw ProducerPatchError.unsafeDestination(url)
      }
      if parent.path == "/" { break }
      parent.deleteLastPathComponent()
    }
  }

  private func validateAnchor() throws {
    do {
      try ancestry.validate()
      guard
        try DirectoryHandle.readDirectory(at: anchor.url).objectIdentity == anchor.objectIdentity
      else { throw ProducerPatchError.unsafeDestination(url) }
    } catch {
      throw ProducerPatchError.unsafeDestination(url)
    }
  }

  func publish(_ patches: [ProducerPatchFile], validate: () throws -> Void) throws
    -> ProducerPatchExport
  {
    func file(_ patch: ProducerPatchFile) -> URL { url.appendingPathComponent(patch.filename) }
    if let first = missing.first {
      // Publish the missing directory chain together. A stale preview or a competing directory
      // leaves the entire selected path unmodified.
      var committed = false
      do {
        guard
          try anchor.publishDirectory(
            named: first,
            beforeCommit: {
              try validate()
              try validateAnchor()
              try validateProtection()
            },
            afterCommit: { committed = true },
            populate: { staging in
              let directory = try missing.dropFirst().reduce(staging) {
                try $0.createDirectoryExclusively($1)
              }
              for patch in patches {
                guard
                  try directory.publishRegularFile(
                    named: patch.filename, bytes: Data(patch.content.utf8))
                else { throw CoreError.invalidState("duplicate staged patch filename") }
              }
            }
          )
        else { throw ProducerPatchError.unsafeDestination(url) }
        return .init(directory: url, written: patches.map(file), reused: [], failures: [])
      } catch {
        if committed {
          return .init(
            directory: url, written: patches.map(file), reused: [],
            failures: patches.map { .init(file: file($0), reason: .publicationFailed) })
        }
        if let known = error as? ProducerPatchError { throw known }
        if error is CancellationError { throw CancellationError() }
        return .init(
          directory: url, written: [], reused: [],
          failures: patches.map { .init(file: file($0), reason: .publicationFailed) })
      }
    }

    var written: [URL] = []
    var reused: [URL] = []
    var failures: [ProducerPatchExport.Failure] = []
    var validated = false
    for patch in patches {
      let location = file(patch)
      let bytes = Data(patch.content.utf8)
      var committed = false
      do {
        try Task.checkCancellation()
        try validateAnchor()
        let published = try anchor.publishRegularFile(
          named: patch.filename, bytes: bytes, afterCommit: { committed = true },
          beforeCommit: {
            try validateAnchor()
            if !validated {
              try validate()
              try validateProtection()
            }
            try validateAnchor()
            validated = true
          })
        if published {
          try validateAnchor()
          written.append(location)
        } else if case .regular(_, _, let existing) = try? anchor.observeRegularFile(
          patch.filename, maximumBytes: bytes.count), bytes == existing
        {
          try validateAnchor()
          reused.append(location)
        } else {
          failures.append(.init(file: location, reason: .occupied))
        }
      } catch ProducerPatchError.stale {
        throw ProducerPatchError.stale
      } catch {
        if committed, (try? validateAnchor()) != nil { written.append(location) }
        let reason: ProducerPatchExport.Failure.Reason
        if error is CancellationError {
          reason = .cancelled
        } else if error is ProducerPatchError || (try? validateAnchor()) == nil {
          reason = .destinationChanged
        } else {
          reason = .publicationFailed
        }
        failures.append(.init(file: location, reason: reason))
      }
    }
    return .init(directory: url, written: written, reused: reused, failures: failures)
  }
}

extension ProducerPatchInputs {
  func protectedLocations() throws -> [URL] {
    let environment = store.environment
    let packageRoot = store.scope == .project ? environment.projectDirectory : store.directory
    let implicit = LedgerLocation(
      kind: .registered, root: store.scope == .project ? "project" : "state", path: ".")
    var result = [
      StateStore(scope: .project, environment: environment).directory,
      StateStore(scope: .user, environment: environment).directory,
      environment.projectDirectory.appendingPathComponent(".git"),
    ]
    for scope in [InstallScope.project, .user] {
      result += AgentRegistry.skillAgents.map {
        AgentRegistry.installSkillsDirectory(for: $0, scope: scope, environment: environment)
      }
      result += AgentID.allCases.compactMap {
        InstructionLocations.file(for: $0, scope: scope, environment: environment)
      }
      result += NativeTargetRoute.clientLocations(scope: scope, environment: environment).compactMap
      {
        try? $0.location.get()
      }
    }
    result += roots[InstructionLocations.ruleRoot(in: store.scope)].map { [$0] } ?? []
    result += try ledger.deployments.map { try $0.target.resolve(roots: roots) }
    result += sourcePolicy.readDependencies.map(\.url) + organization.readDependencies.map(\.url)
    result += try declared.sourceDeclarations.compactMap { entry in
      guard entry.source.kind == .local else { return nil }
      let local = entry.source.localURL(environment: environment)
      let directory = try PathSafety.resolvedChild(base: local, subpath: entry.source.path ?? ".")
      return directory == packageRoot ? nil : directory
    }
    let catalogs =
      (ledger.marketplaceGraph?.nodes.map(\.catalog) ?? [])
      + (ledger.marketplacePackages?.map(\.dependency.catalog) ?? [])
    result += catalogs.compactMap { $0.fileURL(environment: store.marketplaceEnvironment) }
    for (id, source) in ledger.sources where source.kind == .local {
      guard let location = source.location else { continue }
      let local = try location.resolve(roots: roots)
      if location == implicit || local.standardizedFileURL == packageRoot.standardizedFileURL {
        for resource in ledger.resources.values where resource.source == id && resource.path != "."
        {
          result.append(try PathSafety.resolvedChild(base: local, subpath: resource.path))
        }
      } else {
        result.append(local)
      }
    }
    return result.filter(\.isFileURL)
  }
}
