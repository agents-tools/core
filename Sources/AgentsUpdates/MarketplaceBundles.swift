import AgentsCore
import Foundation

extension MarketplaceOperations {
  /// Verifies metadata, byte length, digest and embedded coordinates of every published archive.
  /// Git releases are read from a single checkout of the selected ref.
  public static func verifyCatalog(
    _ registration: MarketplaceRegistration, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    hostedAccess: HostedMarketplaceAccess? = nil
  ) throws -> MarketplaceCatalog {
    let origin = registration.origin
    let source = try origin.policyOrigin(environment: environment)
    let policy = try OrganizationPolicySnapshot(
      store: StateStore(scope: scope, environment: environment))
    try policy.admit(policy.evaluator.catalogAdmission(.init(source, root: origin.policyPath)))
    return try withObservedCatalog(
      origin, scope: scope, environment: environment,
      maximumReleases: LedgerLimits.standard.entries,
      expectedOrigin: source, requireRecordedTransport: policy.evaluator.requiresRecordedGitOrigin,
      hostedAccess: hostedAccess, organizationPolicy: policy
    ) { observed in
      for release in observed.releases {
        try Task.checkCancellation()
        try policy.admit(
          policy.evaluator.packageIdentity(
            .init(source, suffix: release.coordinate.package, root: origin.policyPath),
            catalog: .init(source, root: origin.policyPath)))
        let package = try observed.acquire(release)
        if origin.kind != .hosted { _ = try package.inspectBundle() }
      }
      try policy.validate()
      return MarketplaceCatalog(
        registration: registration, catalogCommit: observed.commit, releases: observed.releases,
        indexDigest: observed.indexDigest)
    }
  }

  /// Lists newer releases from the catalog recorded by this installed dependency.
  public static func availableUpdates(
    for pin: MarketplacePin, scope: InstallScope,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) throws -> [MarketplaceRelease] {
    let registration = try MarketplaceRegistration(
      name: pin.dependency.name, origin: pin.dependency.catalog)
    return try browse(registration, scope: scope, environment: environment).updates(for: pin)
  }

  /// Rechecks the selected scope's policies for the exact bundle and directory before publication.
  @discardableResult
  public static func publishBundle(
    _ archive: Data, to directory: URL, summary: String? = nil, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment(),
    registrySchemas: [MCPRegistryServer] = []
  ) throws -> MarketplaceRelease {
    try publishAdmitted(
      archive, inspection: BundleOperations.inspect(archive), to: directory, summary: summary,
      scope: scope, environment: environment, registrySchemas: registrySchemas)
  }

  static func publishAdmitted(
    _ archive: Data, inspection: BundleInspection, to directory: URL, summary: String?,
    scope: InstallScope, environment: RuntimeEnvironment, registrySchemas: [MCPRegistryServer]
  ) throws -> MarketplaceRelease {
    let package = inspection.package
    let coordinate = try MarketplaceCoordinate(package: package.name, version: package.version)
    let policy = try AuthorPackagePolicy(
      environment, scope: scope, registrySchemas: registrySchemas)
    try AuthorPackageOperations.requireLocalFileURL(directory)
    let destination = try PathIdentity(directory)
    _ = try policy.admit(inspection.archive)
    try policy.admitCatalog(directory, package: package)
    return try publish(archive, coordinate: coordinate, to: directory, summary: summary) {
      try policy.validate()
      try destination.validate()
    }
  }
}

extension VerifiedMarketplacePackage {
  /// Inspects a selected release and checks that its archive declares the catalogued coordinate.
  public func inspectBundle() throws -> BundleInspection {
    let bundle = try BundleOperations.inspect(archive)
    guard bundle.package.name == release.coordinate.package,
      bundle.package.version == release.coordinate.version,
      bundle.archiveDigest == release.archiveDigest
    else {
      throw MarketplaceError.integrityMismatch(release.coordinate.releasePath)
    }
    return bundle
  }
}

extension VerifiedMarketplacePackage {
  /// Previews installing or upgrading this release under the given dependency name.
  public func previewImport(
    as name: String, selections: [BundleImportSelection], scope: InstallScope,
    environment: RuntimeEnvironment = RuntimeEnvironment(), replace: Bool = false
  ) throws -> BundleImportPreview {
    guard release.origin.kind != .hosted else {
      throw MarketplaceError.dependenciesRequireResolution(release.coordinate.label)
    }
    return try BundleOperations.makeImportPreview(
      inspectBundle(), selections: selections, scope: scope, environment: environment,
      replace: replace, marketplace: (self, name))
  }

  public func previewImportLifecycle(
    as name: String, selections: [BundleImportSelection], intent: LifecycleOperationIntent,
    scope: InstallScope, environment: RuntimeEnvironment = RuntimeEnvironment(),
    replace: Bool = false
  ) throws -> LifecyclePackageReview<BundleImportPreview, UpdateApplyResult> {
    try BundleOperations.reviewImportLifecycle(
      intent: intent, scope: scope, environment: environment
    ) {
      try previewImport(
        as: name, selections: selections, scope: scope, environment: environment, replace: replace)
    }
  }
}

extension BundleInspection {
  /// Carries selected clients to uniquely matching members of a new release. Members added or
  /// renamed by the publisher require explicit selection.
  public func retainedSelections(for pin: MarketplacePin, in scope: ScopeInspection) throws
    -> [BundleImportSelection]
  {
    guard scope.marketplacePackages.contains(pin), package.name == pin.dependency.coordinate.package
    else {
      throw MarketplaceError.selectionMismatch(pin.dependency.name)
    }
    let records = Set(pin.componentRecords)
    let installed = scope.components.filter { records.contains($0.record) }
    var result: [BundleImportSelection] = []
    for item in components {
      let matches = installed.filter { $0.kind == item.kind && $0.name == item.name }
      guard !matches.isEmpty else { continue }
      guard matches.count == 1, let match = matches.first,
        components.filter({ $0.kind == item.kind && $0.name == item.name }).count == 1
      else { throw MarketplaceError.selectionMismatch(pin.dependency.name + " / " + item.name) }
      let targets = item.supportedTargets(in: scope.scope).filter(match.recipients.contains)
      if !targets.isEmpty { result.append(.init(componentID: item.id, targets: targets)) }
    }
    return result
  }
}
