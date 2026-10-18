import Foundation

package enum SourceResolver {
  package static func resolve(
    _ input: String, environment: RuntimeEnvironment,
    requirement override: SourceRequirement? = nil,
    scope: InstallScope = .project
  ) throws -> ResolvedSource {
    let parsed = try parse(input, environment: environment, requirement: override)
    return try resolve(parsed, environment: environment, scope: scope)
  }

  package static func parse(
    _ input: String, environment: RuntimeEnvironment, requirement override: SourceRequirement? = nil
  ) throws -> ParsedSource {
    var parsed = try SourceParser.parse(input, currentDirectory: environment.projectDirectory)
    if let override {
      if let existing = parsed.requirement, existing != override {
        throw CoreError.invalidSource("conflicting source requirements")
      }
      parsed.requirement = override
      parsed.ref = override.checkoutRef
    }
    return parsed
  }

  package static func resolve(
    _ parsed: ParsedSource, environment: RuntimeEnvironment, scope: InstallScope
  ) throws -> ResolvedSource {
    let identity = SourceParser.identity(for: parsed)

    switch parsed.type {
    case .local:
      guard let localPath = parsed.localPath else {
        throw CoreError.invalidSource("local source has no path")
      }
      let checkout = URL(fileURLWithPath: localPath).standardizedFileURL
      guard FileManager.default.fileExists(atPath: checkout.path) else {
        throw CoreError.invalidSource("Local path does not exist: \(checkout.path)")
      }
      if let requirement = parsed.requirement {
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
        else {
          throw CoreError.invalidSource("local source requirements require a git repository")
        }
        let cache = AgentRegistry.sourceCacheDirectory(scope: scope, environment: environment)
        let result = try Git.ensureCheckout(
          url: checkout.path,
          requirement: requirement,
          cacheDirectory: cache,
          identity: identity
        )
        var gitParsed = parsed
        gitParsed.type = .git
        gitParsed.url = checkout.path
        gitParsed.localPath = nil
        return ResolvedSource(
          parsed: gitParsed,
          identity: identity,
          checkoutURL: result.url,
          revision: Git.revision(at: result.url),
          requestedRef: result.selectedRef,
          resolvedVersion: result.selectedVersion
        )
      }
      return ResolvedSource(
        parsed: parsed,
        identity: identity,
        checkoutURL: checkout,
        revision: Git.revision(at: checkout),
        requestedRef: parsed.ref
      )
    case .github, .gitlab, .git:
      let cache = AgentRegistry.sourceCacheDirectory(scope: scope, environment: environment)
      let result = try Git.ensureCheckout(
        url: parsed.url,
        requirement: parsed.requirement,
        cacheDirectory: cache,
        identity: identity
      )
      return ResolvedSource(
        parsed: parsed,
        identity: identity,
        checkoutURL: result.url,
        revision: Git.revision(at: result.url),
        requestedRef: result.selectedRef ?? parsed.ref,
        resolvedVersion: result.selectedVersion
      )
    case .wellKnown:
      throw CoreError.unsupported("well-known sources require a content provider")
    }
  }

  package static func resolveWatch(
    _ input: String, path: String? = nil, requirement: SourceRequirement? = nil,
    environment: RuntimeEnvironment, watches: WatchService
  ) throws -> ResolvedSource? {
    if let ledger = try? watches.store.load(environment: environment),
      let record = try? watches.record(matching: input, in: ledger),
      let checkoutPath = record.checkoutPath
    {
      if requirement != nil {
        throw CoreError.invalidSource("source requirement flags cannot be used with a watch source")
      }
      let requestedPath = try path.map(PathSafety.sanitizeSubpath)
      let selectedPath =
        try requestedPath.map { requested in
          guard let state = record.watchedPaths.first(where: { $0.path == requested }) else {
            throw CoreError.notFound("path '\(requested)' in watch '\(record.watchID)'")
          }
          return state
        } ?? (record.watchedPaths.count == 1 ? record.watchedPaths[0] : nil)
      let targetCommit =
        selectedPath?.reviewCoverage.reviewedCommit ?? record.watchBaseline
        ?? record.source.state.revision
      let checkout = URL(fileURLWithPath: checkoutPath)
      let installCheckout: URL
      if let targetCommit, Git.revision(at: checkout) != targetCommit,
        FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
      {
        installCheckout = try Git.materializeCheckout(
          repository: checkout,
          commit: targetCommit,
          cacheDirectory: environment.projectDirectory.appendingPathComponent(
            ".agent/cache/watch-installs"),
          identity: record.watchID
        )
      } else {
        installCheckout = checkout
      }
      let parsed = try parsedSource(from: record.source, subpath: selectedPath?.path)
      return ResolvedSource(
        parsed: parsed,
        identity: record.source.identity,
        checkoutURL: installCheckout,
        revision: targetCommit ?? record.source.state.revision,
        requestedRef: record.source.state.ref ?? record.source.state.branch,
        resolvedVersion: record.source.state.version,
        watchID: record.watchID,
        watchPath: selectedPath?.path,
        watchInstallCommit: targetCommit
      )
    }
    return nil
  }

  private static func parsedSource(from pin: SourcePin, subpath: String?) throws -> ParsedSource {
    switch pin.kind {
    case "localFileSystem":
      return ParsedSource(
        type: .local, url: pin.location, localPath: pin.location,
        ref: pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch,
        requirement: pin.requirement,
        subpath: subpath)
    case "remoteSourceControl":
      var parsed = try SourceParser.parse(pin.location)
      parsed.ref = pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch
      parsed.requirement = pin.requirement
      parsed.subpath = subpath ?? parsed.subpath
      return parsed
    default:
      return ParsedSource(
        type: .git, url: pin.location,
        ref: pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch,
        requirement: pin.requirement,
        subpath: subpath)
    }
  }

  package static func resolve(
    from pin: SourcePin, scope: InstallScope, environment: RuntimeEnvironment
  ) throws -> ResolvedSource {
    switch pin.kind {
    case "localFileSystem":
      let parsed = ParsedSource(
        type: .local, url: pin.location, localPath: pin.location,
        ref: pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch,
        requirement: pin.requirement)
      return ResolvedSource(
        parsed: parsed,
        identity: pin.identity,
        checkoutURL: URL(fileURLWithPath: pin.location),
        revision: Git.revision(at: URL(fileURLWithPath: pin.location)) ?? pin.state.revision,
        requestedRef: pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch,
        resolvedVersion: pin.state.version
      )
    case "remoteSourceControl":
      var parsed = try SourceParser.parse(
        pin.location, currentDirectory: environment.projectDirectory)
      parsed.requirement = pin.requirement
      parsed.ref = pin.requirement?.checkoutRef ?? pin.state.ref ?? pin.state.branch
      let result: Git.CheckoutResult
      if let requirement = pin.requirement {
        result = try Git.ensureCheckout(
          url: parsed.url,
          requirement: requirement,
          cacheDirectory: AgentRegistry.sourceCacheDirectory(
            scope: scope, environment: environment),
          identity: pin.identity
        )
      } else {
        let checkout = try Git.ensureCheckout(
          url: parsed.url,
          ref: pin.state.ref ?? pin.state.branch ?? pin.state.revision,
          cacheDirectory: AgentRegistry.sourceCacheDirectory(
            scope: scope, environment: environment),
          identity: pin.identity
        )
        result = Git.CheckoutResult(
          url: checkout,
          selectedRef: pin.state.ref ?? pin.state.branch,
          selectedVersion: pin.state.version
        )
      }
      return ResolvedSource(
        parsed: parsed,
        identity: pin.identity,
        checkoutURL: result.url,
        revision: Git.revision(at: result.url) ?? pin.state.revision,
        requestedRef: result.selectedRef ?? pin.state.ref ?? pin.state.branch,
        resolvedVersion: result.selectedVersion ?? pin.state.version
      )
    default:
      throw CoreError.unsupported("cannot restore source kind \(pin.kind)")
    }
  }
}
